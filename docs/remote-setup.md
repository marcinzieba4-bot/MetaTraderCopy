# Master and slaves on different machines

When the master terminal and the slave terminals do not run on the same computer (your PC and a
VPS, two AWS instances, two different clouds), they cannot share the `Common\Files` folder.
Instead the master **POSTs** its signal to a small relay server over HTTPS and every slave
**GETs** it from there. The signal format, the slave logic and all lot/symbol settings are
identical to the local mode; only the transport changes.

```
 Machine A (anywhere)          Relay (tiny Linux box, public HTTPS)         Machine B, C, ... (anywhere)
 ┌──────────────────┐  POST    ┌────────────────────────────────┐   GET    ┌──────────────────┐
 │ MetaTrader       │ ───────► │ relay.py                       │ ◄─────── │ MetaTrader       │
 │  CopyMaster EA   │  2x/s    │  keeps newest signal per       │  4x/s    │  CopySlave EA    │
 │  InpSignalUrl=…  │          │  channel, checks API key       │          │  InpSignalUrl=…  │
 └──────────────────┘          └────────────────────────────────┘          └──────────────────┘
```

Latency is one slave poll interval plus two internet round trips, typically 0.3 to 0.8 s.

## 1. Run the relay

You need one always-on host with a public address. Any of these works:

| Option | Fits when | Monthly cost (approx.) |
|--------|-----------|------------------------|
| **AWS Lightsail** Linux, smallest plan, or EC2 `t3.nano`/`t4g.nano` | You are already on AWS | 3 to 5 USD |
| Any 1 GB Linux VPS (Hetzner, DigitalOcean, ...) | Cheapest | 4 to 6 USD |
| The master's own Windows machine | Master is on a cloud Windows box with a fixed IP | 0 USD extra |

The relay is a single Python file with no dependencies (`relay/relay.py`), so it runs anywhere
Python 3.8+ exists. Pick keys now: one for reading (slaves) and one for writing (master).

```
python3 -c "import secrets; print('read ', secrets.token_urlsafe(24)); print('write', secrets.token_urlsafe(24))"
```

### Option A: Docker with automatic HTTPS (recommended on Linux)

1. Create a DNS `A` record, e.g. `relay.example.com`, pointing to the host.
2. Open inbound TCP ports **80 and 443** in the security group / firewall.
3. On the host:
   ```
   git clone https://github.com/marcinzieba4-bot/MetaTraderCopy && cd MetaTraderCopy/relay
   sed -i 's/relay.example.com/YOUR.DNS.NAME/' Caddyfile
   MTC_API_KEY=<read key> MTC_WRITE_KEY=<write key> docker compose up -d
   curl https://YOUR.DNS.NAME/health        # -> {"ok": true, "channels": 0}
   ```
   Caddy obtains and renews the certificate from Let's Encrypt by itself.

### Option B: plain systemd service (Linux, no Docker)

```
sudo mkdir -p /opt/mtc-relay && sudo cp relay/relay.py /opt/mtc-relay/
sudo cp relay/mtc-relay.service /etc/systemd/system/
sudo nano /etc/systemd/system/mtc-relay.service      # set MTC_API_KEY and MTC_WRITE_KEY
sudo systemctl enable --now mtc-relay
```
This serves plain HTTP on port 8080. Put Caddy or nginx in front of it for HTTPS, or restrict
port 8080 to the master's and slaves' IP addresses in the firewall if you accept unencrypted
traffic on a private path.

### Option C: on the master's Windows machine

Install Python from python.org, then run from a command prompt (or as a Scheduled Task at logon):
```
set MTC_API_KEY=<read key>
set MTC_WRITE_KEY=<write key>
set MTC_DATA_DIR=C:\mtc-relay
python relay\relay.py --port 8080
```
Allow inbound TCP 8080 in Windows Firewall and in the AWS security group, **restricted to the
slaves' IP addresses**. The master then posts to `http://127.0.0.1:8080/signal/<channel>` and the
slaves to `http://<master public IP>:8080/signal/<channel>`.

## 2. Allow WebRequest in every terminal

MetaTrader blocks all outgoing HTTP from EAs until the address is whitelisted. In **each**
terminal (master and every slave):

`Tools → Options → Expert Advisors → tick "Allow WebRequest for listed URL" → add` the relay
origin, e.g. `https://relay.example.com` (no path). Restart the EA afterwards.

Without this the EA logs `WebRequest error 4014` and the chart says so.

## 3. Configure the master

In CopyMaster's inputs:

| Input | Value |
|-------|-------|
| `InpSignalUrl` | `https://relay.example.com/signal/mymaster` (choose any channel name: letters, digits, `-`, `_`) |
| `InpApiKey` | the **write** key |
| `InpPostMs` | `500` (2 posts per second; every trade event posts immediately regardless) |
| `InpSignalFile` | leave as is if you also have local slaves, or empty to disable the file |

The chart comment gains a line `Relay: https://... posts N` and shows an error text if the relay
rejects the request.

## 4. Configure each slave

In CopySlave's inputs:

| Input | Value |
|-------|-------|
| `InpSignalUrl` | the same URL as the master |
| `InpApiKey` | the **read** key |
| `InpPollMs` | `250` to `500`. Each poll is one HTTPS request; 4 per second is fine for the relay |
| `InpMaxSignalAgeSec` | `15` is a good default. The age comes from the relay's clock, so the machines' clocks need not agree |

Everything else (lots, symbol mapping, reverse, filters) is unchanged.

## 5. Verify

* `curl -H "X-Api-Key: <read key>" https://relay.example.com/signal/mymaster` prints the current
  signal, or `no signal published on channel ... yet` if the master has not posted.
* `python tools/signal_monitor.py --url https://relay.example.com/signal/mymaster --key <read key> --follow`
  shows the live signal and its age.
* Each slave's chart comment must show `Status: OK` and an age under 2 s.
* Run the demo test plan from the README once with the remote setup before going live.

## Security notes

* Use HTTPS whenever the relay is reachable from the internet; the API key travels in a header.
* Give slaves only the read key. A leaked read key lets someone see your positions, a leaked
  write key lets them *inject trades into your slaves*. Rotate keys by restarting the relay.
* Restrict the relay's inbound ports to the master's and slaves' IPs when they are fixed.
* The relay stores nothing but the latest signal per channel; there is no history.

## Failure behaviour

| Situation | What happens |
|-----------|--------------|
| Relay down or unreachable | Master logs the HTTP error and keeps trading. Slaves show the error and **do nothing**, they never close positions on a lost signal. Copies resume when the relay is back. |
| Master terminal down | Relay keeps the last signal; its age grows past `InpMaxSignalAgeSec`; slaves freeze. |
| Slave down for a while | On restart it reloads its links, closes copies whose master trades are gone, and skips master trades older than `InpMaxTradeAgeSec`. |
| Relay restarted | With `MTC_DATA_DIR` (set in Docker and the systemd unit) the last signal survives; otherwise slaves see 404 until the master posts again, at most `InpPostMs` later. |
