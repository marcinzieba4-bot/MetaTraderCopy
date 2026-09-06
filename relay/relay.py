#!/usr/bin/env python3
"""MetaTraderCopy relay: lets CopySlave EAs on other machines read the master's signal.

The master EA POSTs its signal text to   /signal/<channel>
Slave EAs GET the latest text from        /signal/<channel>
Health check (no key needed)              /health

Only the newest signal per channel is kept, in memory (and on disk when --data-dir is
given, so a restart does not lose it). Standard library only: `python3 relay.py` is enough.

    python3 relay.py --key CHANGE_ME                       # single key for master and slaves
    python3 relay.py --key READ_KEY --write-key WRITE_KEY  # slaves get a read-only key

Keys can also come from the environment: MTC_API_KEY and MTC_WRITE_KEY.
Put the relay behind HTTPS (see docker-compose.yml / Caddyfile) when it is reachable from the internet.
"""
import argparse
import hmac
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

CHANNEL_RE = re.compile(r"^[A-Za-z0-9_\-]{1,64}$")
MAX_BODY = 512 * 1024


class Store:
    def __init__(self, data_dir=None):
        self._lock = threading.Lock()
        self._signals = {}  # channel -> (text, received_at, positions)
        self._data_dir = data_dir
        if data_dir:
            os.makedirs(data_dir, exist_ok=True)
            for name in os.listdir(data_dir):
                if name.endswith(".txt") and CHANNEL_RE.match(name[:-4]):
                    path = os.path.join(data_dir, name)
                    with open(path, "r", encoding="utf-8", newline="") as fh:
                        text = fh.read()
                    self._signals[name[:-4]] = (text, os.path.getmtime(path), count_positions(text))

    def put(self, channel, text):
        now = time.time()
        positions = count_positions(text)
        with self._lock:
            self._signals[channel] = (text, now, positions)
            if self._data_dir:
                path = os.path.join(self._data_dir, channel + ".txt")
                tmp = path + ".tmp"
                with open(tmp, "w", encoding="utf-8", newline="") as fh:
                    fh.write(text)
                os.replace(tmp, path)

    def get(self, channel):
        with self._lock:
            return self._signals.get(channel)

    def summary(self):
        now = time.time()
        with self._lock:
            return {ch: {"age_seconds": round(now - ts, 1), "positions": pos} for ch, (_, ts, pos) in self._signals.items()}


def count_positions(text):
    return sum(1 for line in text.splitlines() if line.startswith("POS|"))


def validate_signal(text):
    lines = text.splitlines()
    if not lines or not lines[0].startswith("HDR|"):
        return "first line must be HDR|..."
    if len(lines[0].split("|")) < 9:
        return "HDR line has too few fields"
    if not any(line.strip() == "END" for line in lines):
        return "missing END line"
    for line in lines[1:]:
        if line.strip() and not (line.startswith("POS|") or line.strip() == "END"):
            return "unexpected line: " + line[:40]
    return None


def make_handler(store, read_keys, write_keys, verbose):
    class Handler(BaseHTTPRequestHandler):
        server_version = "MetaTraderCopyRelay/1.0"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            if verbose:
                sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

        # --- helpers -------------------------------------------------------
        def _send(self, code, body=b"", content_type="text/plain; charset=utf-8", extra=None):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _presented_key(self, query):
            key = self.headers.get("X-Api-Key")
            if not key:
                auth = self.headers.get("Authorization", "")
                if auth.lower().startswith("bearer "):
                    key = auth[7:].strip()
            if not key:
                key = (query.get("key") or [""])[0]
            return key or ""

        def _authorized(self, query, allowed):
            presented = self._presented_key(query)
            return any(hmac.compare_digest(presented, k) for k in allowed)

        def _channel(self, path):
            parts = path.strip("/").split("/")
            if len(parts) == 2 and parts[0] == "signal" and CHANNEL_RE.match(parts[1]):
                return parts[1]
            return None

        # --- routes --------------------------------------------------------
        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            url = urlsplit(self.path)
            query = parse_qs(url.query)
            if url.path == "/health":
                body = json.dumps({"ok": True, "channels": store.summary() if self._authorized(query, read_keys) else len(store.summary())})
                return self._send(200, body, "application/json")
            channel = self._channel(url.path)
            if channel is None:
                return self._send(404, "not found\n")
            if not self._authorized(query, read_keys):
                return self._send(401, "missing or invalid API key\n")
            entry = store.get(channel)
            if entry is None:
                return self._send(404, "no signal published on channel %s yet\n" % channel)
            text, received_at, _ = entry
            age = max(0.0, time.time() - received_at)
            return self._send(200, text, extra={"X-Age-Seconds": "%.3f" % age, "X-Received-At": "%.3f" % received_at})

        def do_POST(self):
            url = urlsplit(self.path)
            query = parse_qs(url.query)
            channel = self._channel(url.path)
            if channel is None:
                return self._send(404, "not found\n")
            if not self._authorized(query, write_keys):
                return self._send(401, "missing or invalid API key\n")
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self._send(400, "bad Content-Length\n")
            if length <= 0 or length > MAX_BODY:
                return self._send(413 if length > MAX_BODY else 400, "body must be 1..%d bytes\n" % MAX_BODY)
            text = self.rfile.read(length).decode("utf-8", errors="replace")
            problem = validate_signal(text)
            if problem:
                return self._send(400, "invalid signal: %s\n" % problem)
            store.put(channel, text)
            return self._send(204)

    return Handler


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=int(os.environ.get("MTC_PORT", "8080")))
    ap.add_argument("--key", default=os.environ.get("MTC_API_KEY", ""), help="API key accepted for reading (and writing unless --write-key is set)")
    ap.add_argument("--write-key", default=os.environ.get("MTC_WRITE_KEY", ""), help="separate key required for POST (master); --key then becomes read-only")
    ap.add_argument("--data-dir", default=os.environ.get("MTC_DATA_DIR", ""), help="persist the latest signal per channel here")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    if not args.key:
        ap.error("an API key is required (--key or MTC_API_KEY)")
    read_keys = [args.key] + ([args.write_key] if args.write_key else [])
    write_keys = [args.write_key] if args.write_key else [args.key]

    store = Store(args.data_dir or None)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store, read_keys, write_keys, args.verbose))
    server.daemon_threads = True
    print("MetaTraderCopy relay listening on %s:%d (%d channel(s) loaded)" % (args.host, server.server_port, len(store.summary())), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
