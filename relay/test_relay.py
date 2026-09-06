"""End-to-end tests for relay.py using only the standard library.

Run:  python3 relay/test_relay.py   (or python -m pytest relay/)
"""
import http.client
import os
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import relay  # noqa: E402

SIGNAL = "HDR|1|123|USD|100.00|100.00|1757184000|1757184000|MT5\r\nPOS|1|EURUSD|0|0.10000000|1.1|0|0|1757183900|0|\r\nEND\r\n"


class Server:
    def __init__(self, data_dir=None, write_key=None):
        read_keys = ["readkey"] + ([write_key] if write_key else [])
        write_keys = [write_key] if write_key else ["readkey"]
        self.store = relay.Store(data_dir)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), relay.make_handler(self.store, read_keys, write_keys, False))
        self.port = self.httpd.server_port
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def request(self, method, path, body=None, key=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {}
        if key:
            headers["X-Api-Key"] = key
        conn.request(method, path, body=body.encode() if body else None, headers=headers)
        resp = conn.getresponse()
        data = resp.read().decode()
        result = (resp.status, data, dict(resp.getheaders()))
        conn.close()
        return result

    def stop(self):
        self.httpd.shutdown()


def test_round_trip():
    s = Server()
    try:
        assert s.request("GET", "/signal/m1", key="readkey")[0] == 404
        assert s.request("POST", "/signal/m1", SIGNAL, key="readkey")[0] == 204
        status, text, headers = s.request("GET", "/signal/m1", key="readkey")
        assert status == 200 and text == SIGNAL
        assert float(headers["X-Age-Seconds"]) < 2
        status, health, _ = s.request("GET", "/health")
        assert status == 200 and '"channels": 1' in health
        status, health, _ = s.request("GET", "/health", key="readkey")
        assert '"m1"' in health and '"positions": 1' in health
    finally:
        s.stop()


def test_auth_and_validation():
    s = Server(write_key="writekey")
    try:
        assert s.request("POST", "/signal/m1", SIGNAL)[0] == 401
        assert s.request("POST", "/signal/m1", SIGNAL, key="readkey")[0] == 401, "read-only key must not write"
        assert s.request("POST", "/signal/m1", SIGNAL, key="writekey")[0] == 204
        assert s.request("GET", "/signal/m1")[0] == 401
        assert s.request("GET", "/signal/m1", key="wrong")[0] == 401
        assert s.request("GET", "/signal/m1", key="readkey")[0] == 200
        assert s.request("GET", "/signal/m1?key=readkey")[0] == 200
        assert s.request("POST", "/signal/m1", "garbage", key="writekey")[0] == 400
        assert s.request("POST", "/signal/m1", SIGNAL.replace("END", ""), key="writekey")[0] == 400
        assert s.request("POST", "/signal/bad.channel", SIGNAL, key="writekey")[0] == 404
        assert s.request("GET", "/nothing", key="readkey")[0] == 404
    finally:
        s.stop()


def test_persistence():
    with tempfile.TemporaryDirectory() as d:
        s = Server(data_dir=d)
        try:
            assert s.request("POST", "/signal/m2", SIGNAL, key="readkey")[0] == 204
        finally:
            s.stop()
        time.sleep(0.05)
        s2 = Server(data_dir=d)
        try:
            status, text, headers = s2.request("GET", "/signal/m2", key="readkey")
            assert status == 200 and text == SIGNAL
            assert float(headers["X-Age-Seconds"]) >= 0
        finally:
            s2.stop()


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok ", name)
