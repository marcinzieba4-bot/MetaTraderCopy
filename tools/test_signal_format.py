"""Sanity tests for the signal file format shared by the EAs and signal_monitor.py.

Run:  python -m pytest tools/   (or simply: python tools/test_signal_format.py)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import signal_monitor as sm  # noqa: E402

SAMPLE = (
    "HDR|1|12345678|USD|10000.00|10123.45|1757184000|1757176800|MT5\r\n"
    "POS|100001|EURUSD|0|0.10000000|1.10500|1.10000|1.11500|1757183900|0|manual\r\n"
    "POS|100002|XAUUSD.m|1|0.05000000|2400.12|0.00|0.00|1757183950|777|\r\n"
    "END\r\n"
)


def test_parse_sample():
    sig = sm.parse_signal(SAMPLE)
    assert sig.header.login == 12345678
    assert sig.header.platform == "MT5"
    assert sig.header.balance == 10000.0
    assert len(sig.positions) == 2
    buy, sell = sig.positions
    assert buy.symbol == "EURUSD" and buy.type == 0 and buy.volume == 0.1 and buy.sl == 1.1 and buy.comment == "manual"
    assert sell.symbol == "XAUUSD.m" and sell.type == 1 and sell.sl == 0.0 and sell.comment == ""


def test_truncated_file_is_rejected():
    for bad in (SAMPLE.replace("END\r\n", ""), "", SAMPLE.split("\r\n", 1)[1]):
        try:
            sm.parse_signal(bad)
        except ValueError:
            continue
        raise AssertionError("truncated file was accepted")


def test_empty_position_list():
    sig = sm.parse_signal("HDR|1|1|EUR|1.00|1.00|0|0|MT4\nEND\n")
    assert sig.positions == []


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok ", name)
