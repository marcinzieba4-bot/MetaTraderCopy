#!/usr/bin/env python3
"""Watch and validate the MetaTraderCopy signal file written by CopyMaster.

Usage:
    python signal_monitor.py                 # auto-locates Common\\Files\\MTC_master.txt on Windows
    python signal_monitor.py path/to/file    # explicit path
    python signal_monitor.py --follow        # refresh every second
    python signal_monitor.py --check         # exit 1 if the file is missing, malformed or stale
    python signal_monitor.py --url https://relay.example.com/signal/mymaster --key KEY   # read from the relay

Useful when a slave shows "signal file not readable" or "signal is N s old":
it shows exactly what the master publishes and how old it is.
"""
import argparse
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class Header:
    version: int
    login: int
    currency: str
    balance: float
    equity: float
    server_time: int
    gmt_time: int
    platform: str


@dataclass
class Position:
    ticket: int
    symbol: str
    type: int          # 0 = buy, 1 = sell
    volume: float
    price: float
    sl: float
    tp: float
    open_time: int
    magic: int
    comment: str


@dataclass
class Signal:
    header: Header
    positions: List[Position]


def default_path() -> str:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "MTC_master.txt")
    return "MTC_master.txt"


def parse_signal(text: str) -> Signal:
    header: Optional[Header] = None
    positions: List[Position] = []
    ended = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        p = line.split("|")
        if p[0] == "HDR":
            if len(p) < 9:
                raise ValueError(f"HDR line has {len(p)} fields, expected 9: {line}")
            header = Header(int(p[1]), int(p[2]), p[3], float(p[4]), float(p[5]), int(p[6]), int(p[7]), p[8])
        elif p[0] == "POS":
            if len(p) < 9:
                raise ValueError(f"POS line has {len(p)} fields, expected at least 9: {line}")
            positions.append(Position(
                int(p[1]), p[2], int(p[3]), float(p[4]), float(p[5]), float(p[6]), float(p[7]), int(p[8]),
                int(p[9]) if len(p) > 9 and p[9] else 0,
                p[10] if len(p) > 10 else "",
            ))
        elif p[0] == "END":
            ended = True
        else:
            raise ValueError(f"unknown record type: {line}")
    if header is None:
        raise ValueError("no HDR line - file is empty or truncated")
    if not ended:
        raise ValueError("no END line - file is truncated")
    return Signal(header, positions)


def render(sig: Signal, path: str) -> str:
    h = sig.header
    age = time.time() - h.gmt_time
    out = [
        f"file     : {path}",
        f"master   : login {h.login} ({h.platform}), format v{h.version}",
        f"account  : balance {h.balance:.2f} {h.currency}, equity {h.equity:.2f}",
        f"published: {age:.1f} s ago (server time {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(h.server_time))})",
        f"positions: {len(sig.positions)}",
    ]
    if sig.positions:
        out.append(f"  {'ticket':>12} {'symbol':<12} {'side':<4} {'lots':>8} {'open':>12} {'sl':>12} {'tp':>12} {'age':>8}  comment")
        for p in sig.positions:
            side = "BUY" if p.type == 0 else "SELL"
            pos_age = h.server_time - p.open_time
            out.append(f"  {p.ticket:>12} {p.symbol:<12} {side:<4} {p.volume:>8.2f} {p.price:>12} {p.sl:>12} {p.tp:>12} {pos_age:>7}s  {p.comment}")
    return "\n".join(out)


def read_source(args) -> str:
    if args.url:
        req = urllib.request.Request(args.url, headers={"X-Api-Key": args.key} if args.key else {})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            raise ValueError(f"relay answered HTTP {exc.code}: {exc.read().decode(errors='replace').strip()}") from None
    with open(args.path, "r", encoding="latin-1") as fh:
        return fh.read()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", default=default_path())
    ap.add_argument("--follow", "-f", action="store_true", help="refresh every second")
    ap.add_argument("--check", action="store_true", help="exit non-zero if missing, malformed or older than --max-age")
    ap.add_argument("--max-age", type=float, default=15.0, help="seconds (used with --check)")
    ap.add_argument("--url", help="read from the relay instead of a file, e.g. https://relay.example.com/signal/mymaster")
    ap.add_argument("--key", default=os.environ.get("MTC_API_KEY", ""), help="relay API key (or MTC_API_KEY)")
    args = ap.parse_args()
    source = args.url or args.path

    while True:
        try:
            sig = parse_signal(read_source(args))
        except FileNotFoundError:
            print(f"signal file not found: {args.path}", file=sys.stderr)
            if not args.follow:
                return 1
        except (urllib.error.URLError, OSError) as exc:
            print(f"relay not reachable: {exc}", file=sys.stderr)
            if not args.follow:
                return 1
        except ValueError as exc:
            print(f"malformed signal file: {exc}", file=sys.stderr)
            if not args.follow:
                return 1
        else:
            if args.follow:
                os.system("cls" if os.name == "nt" else "clear")
            print(render(sig, source))
            if args.check:
                age = time.time() - sig.header.gmt_time
                if age > args.max_age:
                    print(f"STALE: published {age:.1f} s ago (> {args.max_age} s) - is CopyMaster running?", file=sys.stderr)
                    return 1
                return 0
        if not args.follow:
            return 0
        time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
