# MetaTraderCopy

Copy every trade from one MetaTrader account (the **master**) into any number of other
MetaTrader accounts (the **slaves**), in near real time, with lot-size scaling and symbol mapping.
Works with **MT4 and MT5 in any combination** (MT4 master → MT5 slave, MT5 → MT4, etc.)
and across different brokers.

```
 ┌──────────────────────┐   writes 4x/s    ┌─────────────────────────────┐
 │ Terminal A (master)  │ ───────────────► │ %APPDATA%\MetaQuotes\       │
 │  CopyMaster EA       │                  │ Terminal\Common\Files\      │
 └──────────────────────┘                  │   MTC_master.txt            │
                                           └──────────┬──────────────────┘
                     reads 4x/s, opens/closes/modifies │
          ┌──────────────────────┬─────────────────────┼─────────────────────┐
          ▼                      ▼                     ▼                     ▼
 ┌────────────────┐    ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
 │ Terminal B     │    │ Terminal C     │    │ Terminal D     │    │ ...            │
 │ CopySlave EA   │    │ CopySlave EA   │    │ CopySlave EA   │    │                │
 │ (MT5, broker X)│    │ (MT4, broker Y)│    │ (MT5, x0.5 lots)│   │                │
 └────────────────┘    └────────────────┘    └────────────────┘    └────────────────┘
```

All terminals must run on the **same Windows machine or VPS**, because they talk through the
shared `Common\Files` folder. No DLLs, no internet service, no third party.

## What gets copied

| Master action                         | Slave action                                                |
|---------------------------------------|-------------------------------------------------------------|
| Opens a market buy/sell               | Opens the same trade (scaled lots, mapped symbol)           |
| Closes a trade                        | Closes the copy                                             |
| Partially closes a trade              | Partially closes the copy by the same proportion            |
| Adds to a position (MT5 netting)      | Opens an extra copy for the added volume                    |
| Changes SL / TP                       | Copies the new SL / TP levels (`InpSLTPMode = SLTP_PRICE`)  |
| Copy hits its own SL/TP on the slave  | The link is dropped; nothing is reopened                    |
| Pending orders                        | **Not copied** (only executed market positions are copied)  |

Trades that already existed before the slave was started are ignored by default
(`InpMaxTradeAgeSec = 120`), so you never copy a stale position at a bad price.
If the master terminal goes offline or the signal stops updating, the slave freezes and does
**not** close anything (`InpMaxSignalAgeSec`).

## Installation

### 1. Master terminal (the account you trade on)

1. Open MetaEditor from the master terminal (`Tools → MetaQuotes Language Editor` or F4).
2. Copy `MQL5/Experts/CopyMaster.mq5` (or `MQL4/Experts/CopyMaster.mq4` for MT4) into the
   terminal's `MQL5\Experts` (or `MQL4\Experts`) folder. `File → Open Data Folder` in the
   terminal shows you where that is.
3. In MetaEditor open the file and press **F7** (Compile). There must be 0 errors.
4. Back in the terminal, drag **CopyMaster** from the Navigator onto any chart (the symbol does
   not matter). In the dialog tick **Allow Algo/Auto Trading** is *not* required for the master;
   it only writes a file.
5. Make sure the **AutoTrading** button in the toolbar is on anyway if you also run EAs there.

The chart comment shows `MetaTraderCopy MASTER ... Positions published: N`. The file
`MTC_master.txt` now appears in `C:\Users\<you>\AppData\Roaming\MetaQuotes\Terminal\Common\Files`.

### 2. Every slave terminal (the accounts that should follow)

1. Install a **separate terminal** for each slave account (one terminal = one login). Different
   brokers are fine. Keep them on the same machine as the master.
2. Copy `CopySlave.mq5` / `CopySlave.mq4` into that terminal's `MQL5\Experts` / `MQL4\Experts`
   folder and compile it (F7) in that terminal's MetaEditor.
3. Drag **CopySlave** onto one chart. In the dialog:
   * **Common tab**: tick *Allow Algo Trading* (MT5) / *Allow live trading* (MT4).
   * **Inputs tab**: set lot sizing and, if the broker uses symbol suffixes, the mapping (see below).
4. Turn on the **AutoTrading / Algo Trading** toolbar button.
5. The chart comment must read `Status: OK` and show the master login and signal age well under
   a second. Anything else is explained in *Troubleshooting*.

Repeat for every slave account. All slaves read the same file, so adding accounts costs nothing.

### 3. Test on demo first

1. Run master and slaves on **demo accounts** for a session.
2. Open a small trade on the master. Within ~0.5 s the slaves should open it (check the *Experts*
   log tab: `CopySlave: opened EURUSD BUY 0.10 #12345 <- master 100001`).
3. Change SL/TP on the master, partially close, then close. Confirm each is mirrored.
4. Restart a slave terminal while trades are open. It must reconnect to its copies
   (`recovered link` / `loaded N links`) and not open duplicates.
5. Only then switch to live accounts.

## Settings (CopySlave)

### Signal source

| Input                | Default          | Meaning |
|----------------------|------------------|---------|
| `InpSignalFile`      | `MTC_master.txt` | File name in `Common\Files`. Must match the master's `InpSignalFile`. Use different names to run several masters. |
| `InpMasterAccount`   | `0`              | If non-zero, only accept signals from this master login (safety against picking the wrong file). |
| `InpPollMs`          | `250`            | How often the file is read. 100–500 ms is sensible. |
| `InpMaxSignalAgeSec` | `15`             | If the file is older than this, the master is considered offline and the slave does nothing. |
| `InpMaxTradeAgeSec`  | `120`            | Only copy master trades opened within the last N seconds. `0` copies everything, including old positions, at the current price. |

### Lot sizing

| `InpLotMode`     | Copy size |
|------------------|-----------|
| `LOT_MULTIPLIER` | master lots × `InpLotMultiplier` (default, 1.0 = identical size) |
| `LOT_FIXED`      | always `InpFixedLots` |
| `LOT_BALANCE`    | master lots × (slave balance ÷ master balance) × `InpLotMultiplier` — same risk *proportion* on accounts of different size |
| `LOT_EQUITY`     | same as above using equity |

The result is rounded **down** to the symbol's lot step, raised to the broker minimum if it is
smaller, and capped by `InpMaxLots` (0 = broker maximum). Balance/equity ratio ignores currency
differences between accounts (a 10 000 EUR master and 10 000 USD slave give ratio 1.0).

### Execution

| Input                | Default      | Meaning |
|----------------------|--------------|---------|
| `InpMagic`           | `776601`     | Magic number stamped on copies. The slave only ever touches positions with this magic, so your own manual trades on the slave account are never closed by it. |
| `InpSlippagePoints`  | `30`         | Max deviation for market orders, in points. |
| `InpMaxSpreadPoints` | `0`          | Do not open a copy while the spread is wider than this (0 = no check). Trades are retried on the next poll until `InpMaxOpenAttempts` is used up. |
| `InpSLTPMode`        | `SLTP_PRICE` | `SLTP_PRICE` copies and keeps SL/TP levels in sync; `SLTP_NONE` leaves copies without stops. |
| `InpReverse`         | `false`      | Open the opposite direction (buy ↔ sell), swapping SL and TP. |
| `InpCloseWithMaster` | `true`       | Close the copy when the master closes. `false` keeps copies open and unlinks them. |
| `InpMaxOpenAttempts` | `3`          | Stop retrying a trade after this many rejected opens (logged in the Experts tab). |

### Symbol mapping

Brokers name symbols differently (`EURUSD`, `EURUSD.m`, `EURUSDpro`, `GOLD` vs `XAUUSD`).
The slave resolves a master symbol in this order:

1. strip `InpMasterPrefix` / `InpMasterSuffix` from the master name,
2. apply `InpSymbolMap` (`XAUUSD=GOLD;US30=DJ30;DE40=GER40`),
3. try `InpSlavePrefix + name + InpSlaveSuffix`, then the bare name, then the original name,
4. finally any symbol in the slave's Market Watch list that *starts with* the name.

Anything that cannot be resolved is logged once and skipped. `InpAllowedSymbols`
(`EURUSD,GBPUSD,XAUUSD`) restricts copying to a whitelist.

## How it works (for maintenance)

* **CopyMaster** runs on a 250 ms timer plus every trade event. It writes all open market
  positions to `MTC_master.txt.tmp` and then atomically renames it over `MTC_master.txt`, so a
  reader never sees a half-written file. Format:

  ```
  HDR|1|<login>|<currency>|<balance>|<equity>|<serverTime>|<gmtTime>|MT5
  POS|<ticket>|<symbol>|<0=buy,1=sell>|<lots>|<open>|<sl>|<tp>|<openTime>|<magic>|<comment>
  END
  ```

* **CopySlave** keeps two small tables: *links* (master ticket → slave ticket) and *state*
  (last known volume, symbol, type, open time and open price of each master ticket). Each poll it
  1. drops links whose copy is no longer open,
  2. handles master tickets that vanished: closes their copies, or, if a ticket with the same
     symbol/type/open time/open price and smaller volume appeared, treats it as an MT4-style
     partial close and re-links,
  3. opens copies for new master tickets, partially closes / adds on volume changes, and syncs
     SL/TP.
  The tables are persisted to `MQL5\Files\MTC_slave_<login>_<magic>.txt` (`MQL4\Files` on MT4)
  after every change and reloaded on start; copies are additionally tagged with comment
  `MC<master ticket>` so links can be rebuilt if that file is lost.

* `tools/signal_monitor.py` prints and validates the signal file (`--follow` to watch live,
  `--check` for a health check that exits non-zero when the file is stale). `tools/test_signal_format.py`
  covers the parser.

## Troubleshooting

| Chart status / log line                          | Cause and fix |
|--------------------------------------------------|---------------|
| `signal file not readable`                       | CopyMaster is not running, or a different `InpSignalFile` name. Check `Common\Files` for the file. |
| `signal is N s old - master offline?`            | Master terminal closed, disconnected, or its EA was removed. The slave does nothing until it comes back. |
| `AutoTrading is disabled in the terminal`        | Press the AutoTrading / Algo Trading toolbar button on the slave. |
| `Algo trading not allowed for this EA`           | Re-open the EA properties, Common tab, tick *Allow Algo Trading*. |
| `no tradable symbol found for master symbol X`   | Set `InpMasterSuffix` / `InpSlaveSuffix` / `InpSymbolMap`. |
| `open FAILED ... retcode 10030 (unsupported filling)` | Rare broker quirk; the EA picks the filling mode from the symbol. Report the broker so a fallback can be added. |
| `modify FAILED ... invalid stops`                | Slave broker requires a larger stop distance than the master's SL/TP. Retried every 10 s; the copy stays open. |
| `giving up on master ticket N`                   | `InpMaxOpenAttempts` rejections in a row (spread filter, margin, market closed). See the preceding log lines. |
| `WARNING - this is a NETTING account`            | MT5 netting slaves merge same-symbol trades into one position, so per-trade tracking breaks. Use a hedging account. |

Both EAs log everything to the **Experts** tab of the terminal (`Toolbox → Experts`).

## Limitations and possible next steps

* Pending orders (limit/stop) are not copied; only their execution is, once they become positions.
* Master and slaves must share a machine. For separate machines, the simplest extension is to
  have the master POST the same text to a tiny HTTP/WebSocket relay and the slaves fetch it
  (`WebRequest` in MQL); the file format and the slave logic stay unchanged.
* MT5 netting slave accounts are supported only loosely (see warning above).
* Lot sizing by balance/equity does not convert account currencies.
* Latency is one poll interval (default 250 ms) plus execution time at the slave broker; price
  differences between brokers are not compensated.

## Risk notice

This copies real money trades automatically. Test on demo, start with `LOT_FIXED` and the minimum
lot, keep `InpMaxLots` set, and monitor the Experts log for the first days. Use at your own risk.
