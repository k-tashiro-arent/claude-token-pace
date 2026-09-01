# claude-token-pace

*[日本語](README.md) | English* ・ version **0.2.0** (SemVer)

[![CI](https://github.com/k-tashiro-arent/claude-token-pace/actions/workflows/ci.yml/badge.svg)](https://github.com/k-tashiro-arent/claude-token-pace/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/k-tashiro-arent/claude-token-pace)](https://github.com/k-tashiro-arent/claude-token-pace/releases)
[![license: MIT](https://img.shields.io/github/license/k-tashiro-arent/claude-token-pace)](LICENSE)

An interactive, browser-based viewer for your Claude Code **token consumption pace** (the 5-hour and 7-day rate-limit `used%`). It serves a small page over local HTTP and shows how far you are **ahead of or behind the even pace**, in both color and numbers.

![Token consumption pace viewer](docs/token-pace.gif)

- **used line**: rate-limit usage (%). Colored by pace deviation: blue (behind) → gray (on pace) → red (ahead).
- **even pace (dotted)**: the standard consumption pace. Linear for 5h, a business-hours staircase for 7d.
- **now line**: current time (updated every second). Hover to read used / even / pace deviation at any point.

Top panel = 5h window (the 5 hours until the next 5h reset), bottom panel = 7d window (the 7 days until the next 7d reset). **On accounts with a monthly usage-credit allowance (extra usage), a third panel** (until the next month-start reset) is shown as well.

## Why
- **Runs on your existing Claude subscription** — no API key, no extra cost. It just reads the rate-limit data Claude Code already has.
- **Business-hours-aware pace** — the 7-day even pace follows your working hours (a staircase), not a flat line, so "am I burning too fast?" is actually meaningful.
- **Local & private** — bound to `127.0.0.1` only; your usage data accumulates on your own machine and is never exposed to the LAN or anywhere else. The only outbound traffic is the read-only requests that fetch the limits themselves: the monthly panel goes straight to the Anthropic API, and the Codex panel goes through `codex`'s own app-server — see [Monthly usage credits](#monthly-usage-credits-extra-usage) and [Codex rate limits](#codex-rate-limits-optional).

## Requirements
- **OS**: Linux / macOS / WSL2 (**native Windows is not supported**)
- **Dependencies**: `python3`, `jq`, and a web browser
- Rate-limit (5h/7d window) data is available on **Claude.ai subscription plans that have the 5-hour / 7-day usage limits (Pro / Max / Team, …)**, and only **once Claude Code has that data** (i.e. after your first model response; until then the viewer shows "collecting…").

## Install
### Option A: one-liner (curl → bash, recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/k-tashiro-arent/claude-token-pace/main/bootstrap.sh | bash
```
It clones the repo into a temp dir and runs the installer (needs `git`, `python3`, `jq`). To pin a version:
```bash
curl -fsSL https://raw.githubusercontent.com/k-tashiro-arent/claude-token-pace/main/bootstrap.sh | TOKEN_PACE_REF=v0.1.0 bash
```

### Option B: git clone (if you want to update via `git pull`)
```bash
git clone https://github.com/k-tashiro-arent/claude-token-pace.git
cd claude-token-pace
./install.sh
```

Either way, the installer:
1. Places scripts/viewer under `~/.claude/token-pace/`
2. Installs default `config.json` / `biz-hours.json` (existing files are kept)
3. Adds the `/tpw` slash command to `~/.claude/commands/`
4. **Wraps your statusLine** (backing up `settings.json`). The wrapper feeds the statusLine JSON to the sampler **while passing your existing statusLine output through unchanged**.

> To install elsewhere: `TOKEN_PACE_DIR=/path/to/dir ./install.sh`

## Update
- **curl method**: just re-run the same one-liner (it re-clones and re-installs each time).
- **git clone method**: refresh the clone and re-run:
  ```bash
  cd claude-token-pace
  git pull
  ./install.sh
  ```

`install.sh` is idempotent: it overwrites the program (`bin/`, `index.html`), keeps your settings (`config.json`, `biz-hours.json`), and leaves the statusLine untouched if it is already wrapped. On update it prints `vOLD → vNEW` (the installed version is recorded in `~/.claude/token-pace/.version`).

## Usage
In Claude Code:
```
/tpw
```
A local HTTP server (`127.0.0.1`) starts and the viewer opens in your default browser. The viewer auto-refreshes every few seconds.

## Data collection & accumulation
- Usage is recorded **automatically while you use Claude Code** (on each update of Claude Code's status line / `statusLine`). Sampling is throttled to about once per 30 s, and the graph (`pace.json`) is regenerated about every 3 minutes.
- Recording begins **once Claude Code has the rate-limit data** — i.e. after your first model response (until then the viewer shows "collecting…"); nothing is recorded while idle, because usage does not change then.
- The 5h/7d limits are **per account (user), not per session**. With several concurrent sessions, each session's status line writes to the **same** `pace.jsonl`, so the recorded value is always your account-wide usage (more sessions just means more frequent sampling).
- Data accumulates **locally, per installed environment** (`~/.claude/token-pace/pace.jsonl`). History is not shared across machines — each environment builds its own. Right after install there is no history, so the panels (especially the 7-day one) fill in as you keep using Claude Code.

## Monthly usage credits (extra usage)

Spend beyond your plan limits (usage credits) is **not present in the statusLine JSON**, so it cannot be collected the way the 5h/7d values are. This one panel is therefore fetched from the same endpoint Claude Code itself uses.

- Fetch: `GET https://api.anthropic.com/api/oauth/usage`, roughly **once every 5 minutes** (`bin/credits-fetch.py`)
- Auth: **reads** the OAuth access token from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`). If the token is expired it does nothing — refreshing is left to Claude Code itself
- Storage: `~/.claude/token-pace/credits.jsonl` (`{ts, used, limit, m1r}`; amounts in the API's minor units, i.e. cents for USD)
- **The allowance resets at the start of the month in UTC**, not local time. The API exposes no `resets_at` for this window, so the boundary comes from observation (full at 2026-08-31 23:40 UTC, zero at 2026-09-01 00:05 UTC; still un-reset 8h40m after the local month start)
- Where this isn't available (macOS Keychain-stored credentials, plans without extra usage, …) **nothing is recorded and the panel is not shown** — 5h/7d keep working as before

**Note**: 100% on this panel is `monthly_limit`, a **spend ceiling** — unlike the 5h/7d windows, which are allowances you are meant to consume. Sitting exactly on the even pace (gray) means you are on track to spend the entire ceiling.

## Codex rate limits (optional)

If you also use the [Codex CLI](https://github.com/openai/codex), its usage can be shown in the same view. Codex has no statusLine-style hook, so it is collected through **two paths** (both write to the same `codex.jsonl`).

**1. Ask the app-server (`bin/codex-fetch.py`)**

- Sends `initialize` then `account/rateLimits/read` to `codex app-server` (JSON-RPC over stdio) and takes only the used% / window length / reset time from the reply
- This is the same path the TUI's `/status` uses, so **the current values are available even when you haven't been talking to Codex**. No conversation happens, so no tokens are spent (about 1 second in practice)
- Does nothing where `codex` isn't on PATH (`CODEX_BIN` overrides the path)

**2. Read the rollout logs (`bin/codex-scan.py`)**

- Source: `$CODEX_HOME` (default `~/.codex`) `/sessions/**/rollout-*.jsonl`, the `token_count` events — each carries the rate limits returned with that response
- Only **`timestamp` and the `rate_limits` numbers** are extracted. Conversation content and tool output are never read or copied
- Bytes already read are tracked in `.codex_scan.json`, so only **appended data** is parsed (a full pass happens once, going back 60 days by default)
- Limits are only attached when a conversation happens, so on its own this path goes stale while you aren't using Codex

Common:

- Storage: `~/.claude/token-pace/codex.jsonl` (`{ts, u, w, r}` = used% / window length in minutes / resets_at; `u2, w2, r2` added when a secondary limit exists)
- Both run about once every 2 minutes
- Where Codex isn't installed, nothing is recorded and no panel is shown

Window length comes from the observed window length rather than a constant, so it follows changes in the limit structure (5h+7d vs. 7d only). Windows of a day or less use the linear even pace (like 5h); longer windows use the business-hours staircase (like 7d).

**Limitation**: the Codex credit balance cannot be obtained (`credits.balance` is always `null`). There is no equivalent of the monthly panel. Also, **while usage is at 0% the reset time keeps reporting "one window from now", so the window slides forward and the panel shows only the latest single point** (once usage begins the reset time pins down and points accumulate). When a limit is exhausted, the window numbers stop being returned at all and nothing is recorded meanwhile. Note also that both the rollout log and the app-server protocol are Codex CLI internals and may change between versions (if they become unreadable, the panel is simply not shown).

## Configuration
### Port (`~/.claude/token-pace/config.json`)
```json
{ "port": 8799 }
```
Resolution order: env `TOKEN_PACE_PORT` > `config.json` `port` > default `8799`. The preferred port is tried first; if busy, nearby ports are scanned automatically.

### Business hours (`~/.claude/token-pace/biz-hours.json`)
The basis for the 7d panel's even pace.
```json
{ "biz_days": [1, 2, 3, 4, 5], "biz_start_hour": 9, "biz_end_hour": 18 }
```
- `biz_days`: working days (1=Mon … 7=Sun)
- `biz_start_hour` / `biz_end_hour`: working hours (JST, decimals allowed)

## Data location
`~/.claude/token-pace/` (`pace.jsonl` = records, `credits.jsonl` = monthly usage-credit records, `codex.jsonl` = Codex rate-limit records, `pace.json` = viewer input, `index.html`, config/state files). Bound to `127.0.0.1`, so it is never exposed to the LAN.

## Uninstall
```bash
bash ~/.claude/token-pace/uninstall.sh
```
Restores your statusLine, removes the `/tpw` command, and stops the running server (recorded data is kept; remove it fully with `rm -rf ~/.claude/token-pace`).

## Troubleshooting
- **Browser doesn't open**: uses `xdg-open` (Linux), `open` (macOS), `powershell.exe` (WSL). If none exist, open the printed URL manually.
- **Stuck on "collecting…"**: recording hasn't started yet (Claude Code hasn't received a response yet, or rate-limit data isn't available). Send a turn in Claude Code, wait a few minutes, and confirm your plan is supported (see Requirements).
- **Port in use**: the preferred port plus nearby ports are scanned automatically. Pin it via `config.json` `port`.

## License
[MIT](LICENSE)
