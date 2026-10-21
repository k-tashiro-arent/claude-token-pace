# claude-token-pace

A browser graph of your Claude Code **usage** (the 5-hour, 7-day and other rate limits). It shows **how far you are from the standard pace**, in color and numbers, so you can see at a glance whether you are on course to exhaust a quota. **Everything runs locally, and the usage data it collects never leaves your machine.**

*[日本語](README.md) | English* ・ version **0.4.0** (SemVer)

[![CI](https://github.com/k-tashiro-arent/claude-token-pace/actions/workflows/ci.yml/badge.svg)](https://github.com/k-tashiro-arent/claude-token-pace/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/k-tashiro-arent/claude-token-pace)](https://github.com/k-tashiro-arent/claude-token-pace/releases)
[![license: MIT](https://img.shields.io/github/license/k-tashiro-arent/claude-token-pace)](LICENSE)

![Token consumption pace viewer](docs/token-pace.gif)

## Quick start
```bash
curl -fsSL https://raw.githubusercontent.com/k-tashiro-arent/claude-token-pace/main/bootstrap.sh | bash
```
Once installed, type `/tpw` in Claude Code and the viewer opens in your default browser. For supported environments and installation details, see [Requirements](#requirements) and [Install](#install).

This document uses four words in a specific sense.

- **quota** — one usage ceiling, paired with the stretch of time it covers. There is `5h` (five hours' worth) and `7d` (seven days' worth); depending on your setup, a monthly usage-credit quota `1mo` (one calendar month, where the ceiling is an amount of money) and Codex's quotas are added.
- **window** — the stretch from one reset of a quota to the next: five hours for `5h`, seven days for `7d`, one month for `1mo`. Usage returns to zero at each boundary. (Codex quotas derive theirs differently — see [Codex rate limits](#codex-rate-limits-optional).)
- **standard pace** — **the usage level** a quota should be at, at any given moment, for it to be used up exactly at the end of its window. Usage above that line means you are ahead (burning fast); below it means behind (room to spare).
  It rises in one of two ways: for quotas whose window is a day or less, in proportion to elapsed time; for longer ones, only during your **working hours** (9:00–18:00 JST on weekdays by default — see [Business hours](#business-hours-claudetoken-pacebiz-hoursjson)), in proportion to the working time elapsed.
- **panel** — the display for one quota: a graph plus the header above it.


## Reading the graph

- **used line**: the quota's usage (%), colored by its distance from the standard pace: blue (behind) → gray (on pace) → red (ahead). On Codex panels the behind end is green instead.
- **standard pace (dotted)**: the standard pace defined above.
- **now line**: the current time (updated every second). Hover to read usage, standard pace and the `pace` value at that point.
- **forecast band (optional)**: how far usage is likely to climb before the reset, drawn as a probability band. **It appears only where a separate tool is writing forecasts** (see [Usage forecast](#usage-forecast-optional)).
- **panel header**: `quota name  used NN%  pace ±NN%  →reset time`. A quota with no records yet shows "collecting…".

### The `pace` value and its colors

`pace` expresses how far usage has drifted from the standard pace, **as a share of the gap between the standard pace and 100%**.

```
pace = (usage − standard pace) ÷ (100 − standard pace) × 100
```

0% is exactly on pace, positive is ahead (burning fast), negative is behind. For example, with the standard pace at 40% and usage at 70%, you have spent 30 of the remaining 60 points (40%→100%) ahead of schedule, so it reads `pace +50%`. When the standard pace has reached 100% and there is no headroom left, it shows `-`.

The color is **gray at 0%, fully red at +50% or more, and fully blue at −50% or less** (green instead of blue on Codex panels), varying continuously in between — there are no step thresholds.

## The panels

`5h` and `7d` from the top. More appear depending on your setup.

- **`1mo`** — only on accounts with a monthly usage-credit allowance (extra usage). See [Monthly usage credits](#monthly-usage-credits-extra-usage-optional).
- **`codex 5h` / `codex 7d` / …** — only where Codex usage can be read (when a value can be read from either the `codex` command or its conversation logs). The set of quotas follows whatever Codex reports. See [Codex rate limits](#codex-rate-limits-optional).

Those two and the forecast band are all optional. Where they do not apply nothing is shown, so **you can skip the Monthly usage credits, Codex rate limits and Usage forecast sections entirely.**

Normally each panel draws its own window on the x axis (5 hours for `5h`, 7 days for `7d`, …). You can also put them all on **one shared time axis** (see [Align mode](#align-mode)).

## Why
- **Runs on your existing Claude subscription** — no API key, no extra cost. It just reads the rate-limit data Claude Code already has.
- **Business-hours-aware standard pace** — by default the long quotas' standard pace does not advance at night or on weekends, so "am I burning too fast?" is actually meaningful.
- **Local & private** — the viewer binds to `127.0.0.1` only. The only outbound traffic is the read-only requests that fetch the quota values. The 5h/7d quotas and the monthly usage-credit quota are fetched from the Anthropic API directly, and the Codex quotas through `codex` itself.

## Requirements
- **OS**: Linux / macOS / WSL2 (**native Windows is not supported**)
- **Assumed**: a working Claude Code setup
- **Dependencies**: `python3`, `jq`, and a web browser (install them with your OS package manager if you don't have them). **Method A** below also uses `curl` and `git`
- Rate-limit (5h/7d) data is available on **Claude.ai subscription plans that have the 5-hour / 7-day usage limits (Pro / Max / Team, …)**, and only where **Claude Code is logged in** (credentials live in `~/.claude/.credentials.json` on Linux/WSL, and in the Keychain on macOS).

## Install
### Option A: one-liner (curl → bash, recommended)
The command from [Quick start](#quick-start). It clones the repo into a temp dir and runs the installer.

To pin a version, change `| bash` to `| TOKEN_PACE_REF=v0.3.0 bash` (putting it before `curl` has no effect).

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
4. **Registers the recording job** (a systemd user timer, or cron where systemd is unavailable). It runs **every 5 minutes** by default — change it **in minutes** with `TOKEN_PACE_INTERVAL=10min`, or skip it with `TOKEN_PACE_NO_SCHEDULER=1`.
5. **Wraps Claude Code's statusLine** (your original setting is saved, and `settings.json` is backed up). **Your status line looks the same.** Recording also happens whenever the status line is shown (details in [Data collection & accumulation](#data-collection--accumulation)).

Nothing else is needed after installing. Whether recording has started shows in the viewer (see [Troubleshooting](#troubleshooting)).

> To install elsewhere: `TOKEN_PACE_DIR=/path/to/dir ./install.sh`
> Read `~/.claude/token-pace/` below as that directory, and **uninstall with the same variable set** — without it the periodic job is left behind.

## Update
- **curl method**: just re-run the same one-liner (it re-clones and re-installs each time).
- **git clone method**: refresh the clone and re-run:
  ```bash
  cd claude-token-pace
  git pull
  ./install.sh
  ```

Running `install.sh` again always produces the same result: it overwrites the program (`bin/`, `index.html`), keeps your settings (`config.json`, `biz-hours.json`), and re-registers the periodic job. If the statusLine already points to the wrapper it is left as is (the saved original is not overwritten). On update it prints `vOLD → vNEW`.

## Usage
In Claude Code:
```
/tpw
```
A local HTTP server (`127.0.0.1`) starts and the viewer opens in your default browser. `/tpw` prints the URL it opened and the server's PID in Claude Code. If a server is already running, `/tpw` reuses it, so the URL does not change. The server then stays running; to stop it, `kill` that PID or run the [uninstaller](#uninstall).

## Viewer controls

Three buttons sit at the top right. The theme and `Align` choices are remembered.

| Button | What it does |
|---|---|
| `☀` / `☾` | Switch between the dark and light theme (the button shows the theme it switches to) |
| `▶` | Fast-forward replay: sweeps the last 7 days in 15-minute steps, reproducing quota resets (about 6–11 seconds; **shorter while you have less than 7 days of history**) |
| `Align` | Put every panel on one shared time axis (below) |

### Align mode

`Align` puts **every panel on the same time axis** (right edge = now, 30 days wide) so you can compare consumption across the different quotas.

- **Past windows are shown too, not just the current one.** The value drops back near zero at every reset, so the series is a sawtooth (sampling is minutes apart, so the graph resumes near zero rather than exactly at it).
- **Segments where usage decreases are not drawn at all** — no line, no fill. A decrease only happens at a quota reset, which is not continuous consumption. (The same rule applies in normal mode.)
- **The standard-pace line (dotted) is drawn only for long quotas** (`7d`, `1mo`, `codex 7d`). The 5-hour ones would need well over a hundred baselines across 30 days, so they are left out.
- **The header shows just the quota name** — `used` / `pace` / `→reset` describe the current window, so they are omitted here.
- `▶` in this mode slides **a 30-day view from 60 days ago up to now**.
- Where the records do not go back that far, the axis shrinks to **the oldest record across all logs**. The axis is shared, so a panel whose records start later simply has an empty left side.

## Data collection & accumulation

- The 5h/7d percentages come from **the same endpoint Claude Code itself uses**, `GET https://api.anthropic.com/api/oauth/usage`. When it cannot be fetched (no token, expired, no network), nothing is recorded for that round and it is retried on the next one.
- **Recording has two triggers**: the periodic job and Claude Code showing its status line (intervals in the table below). Both fetch from the same API (the values passed to the statusLine are not recorded). Because of the periodic job, recording **keeps going whether or not Claude Code is running** — including the stretch where your quota recovers while you are away. No daemon is kept running (`/tpw` only starts the HTTP server that serves the page).
- **When the status line is shown, it also checks that the periodic job has not stopped**, and restarts it if it has. The result is written to `tick.log`.
- **With neither systemd nor cron available, recording happens only while you use Claude Code** — run `~/.claude/token-pace/bin/tick.sh` from any scheduler every few minutes to keep recording while you are away.
- **Intervals at a glance.** When a trigger arrives before a task's minimum interval has passed, that task is skipped.

  | What | Interval |
  |---|---|
  | Periodic job (trigger) | every 5 minutes by default (change in minutes with `TOKEN_PACE_INTERVAL`) |
  | Status line shown (trigger) | at most once a minute |
  | Checking / repairing the periodic job | at most once every 10 minutes (when the status line is shown) |
  | Usage (5h/7d) fetch | **at most once every 4 minutes** (pauses 15 minutes after a `429`) |
  | Codex fetch | at most once every 2 minutes |
  | Graph rebuild | at most once every 3 minutes |
  | Monthly quota fetch | at most once every 5 minutes |

  The usage fetch has a floor because polling faster makes the API answer `429` (measured at a 30-second interval).
- The 5h/7d quotas are **per account (user), not per session**, and so is the value the API returns. **Running any number of concurrent Claude Code sessions changes neither what is recorded nor how often** — and no two sessions can disagree about the number.
- Data accumulates **locally, per installed environment**. History is not shared across machines — each environment builds its own. Right after install there is no history, so the panels (especially the 7-day one) fill in as you keep using Claude Code.

## Monthly usage credits (extra usage, optional)

Spend beyond your plan limits (usage credits) comes from a different field of the same endpoint as the 5h/7d values (it is not present in the statusLine JSON).

- Fetch: `GET https://api.anthropic.com/api/oauth/usage`, roughly **once every 5 minutes**
- Auth: **reads** the OAuth access token from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`). **On macOS that file does not exist — the credentials sit in the Keychain, so they are read with the `security` command** (Claude Code offers no supported way to keep them in a file; some setups ask for Keychain permission, and without it nothing can be fetched). If the token is expired it does nothing — refreshing is left to Claude Code itself — and the panel stays frozen at the last value it managed to fetch (nothing on screen marks that value as stale)
- **The allowance resets at the start of the month in UTC**, not local time. The API exposes no reset time for this quota, so the boundary comes from observation
- Where this isn't available (plans without extra usage, credentials that cannot be read, …) **nothing is recorded and the panel is not shown** — the 5h/7d quotas use the same credentials, so where those cannot be read neither is recorded

**Note**: 100% on this panel is a **spend ceiling** — unlike the 5h/7d quotas, which are allowances you are meant to consume. Sitting exactly on the standard pace (gray) means you are on track to spend the entire ceiling.

## Codex rate limits (optional)

If you also use the [Codex CLI](https://github.com/openai/codex), its usage can be shown in the same view.

**These quotas derive their window differently.** It runs back from the reset time Codex reports, by the window length Codex reports. While usage sits at 0%, Codex keeps reporting a reset "one window from now", so the window slides along with it; once usage rises above 0% the reset time pins down and the window settles. That is why Codex windows can overlap the previous one. Codex usage is not part of the API above, so it is collected through **two paths** (both write to the same `codex.jsonl`).

**1. Ask the `codex` command** — taking only the usage %, window length and reset time. **The current values are available even when you haven't been talking to Codex** (the fetch itself runs only when a recording is triggered), and no conversation happens, so no tokens are spent. This path does nothing where `codex` isn't on PATH (`CODEX_BIN` overrides it).

**2. Read Codex's conversation logs** — from `$CODEX_HOME` (default `~/.codex`), taking **only the usage numbers and timestamps**. **Conversation content and tool output are never interpreted or stored** (the file is read in appended chunks and every line that isn't a usage/timestamp line is discarded). Limits are only attached when a conversation happens, so on its own this path goes stale while you aren't using Codex. It works even without the `codex` command.

Both paths run whenever a recording is triggered (at least 2 minutes apart). Where neither can obtain anything, nothing is recorded and no panel is shown. Window length comes from the observed length rather than a constant, so it follows changes in the quota structure (5h+7d vs. 7d only). The standard pace follows the same rule as every other quota.

**Limitations**:

- The Codex credit balance cannot be obtained, so there is no equivalent of the monthly panel.
- **While usage is at 0% the panel shows only the latest single point** (the window slides forward, as described above). Once usage begins, the window settles and points accumulate.
- When a quota is exhausted, its numbers stop being returned at all and nothing is recorded meanwhile. The panel **keeps showing the last value it recorded**, and once that window's reset time has passed with nothing new, it **stops being shown**.
- Because windows get re-anchored and overlap the previous one, the standard-pace line in [Align mode](#align-mode) is drawn only for the period each window was the current one.
- Both paths depend on Codex CLI internals and may change between versions (if they become unreadable, the panel is simply not shown).

## Usage forecast (optional)

**This appears only when the separate tool claude-codex-router is running on the same machine and writing forecasts.** Without it the band simply does not appear; nothing else changes.

How far usage is likely to climb before the reset is drawn as a probability band over the used line. **Darker areas are more likely**: the dark middle is the likely range, the pale outer edges are values that rarely happen.

- **Where it reads from**: `~/.claude/codex-router/data/forecast.json`. If the environment variable `CLAUDE_CODEX_ROUTER_DIR` is set, `data/forecast.json` under that directory is used instead; `FORECAST_JSON` points directly at a file and takes precedence over both.
- **Which panels get a band**: only the quotas the forecast side actually has. The 5h, 7d and Codex quotas get one; the **monthly usage-credit panel does not** (there is no month-long quota on the forecast side).
- **When the forecast no longer matches the current state**, the band is not removed but drawn **in yellow and fainter**. (Live display only: during replay the band shown is the forecast that belonged to that moment, so no such distinction is made.) That happens when usage at the time the forecast was made differs from current usage by more than 5 percentage points.
- **It also appears during fast-forward replay.** Forecasts are kept locally every 15 minutes for 7 days, and replay draws the forecast that belonged to the cursor's time. **Only what has been kept since you started is available, so early on there are stretches with no band; it fills in over up to 7 days.** Forecasts accumulate only while something is writing them, so hours with no forecast have no band.
- **Align mode does not draw it**, because that mode lines up the past and the current forecast does not apply there.

## Configuration
### Port (`~/.claude/token-pace/config.json`)
```json
{ "port": 8799 }
```
Resolution order: env `TOKEN_PACE_PORT` > `config.json` `port` > default `8799`. The preferred port is tried first; if busy, nearby ports are scanned automatically.

### Business hours (`~/.claude/token-pace/biz-hours.json`)
The basis for the standard pace of the long quotas (`7d`, `1mo`, and Codex quotas longer than a day).
```json
{ "biz_days": [1, 2, 3, 4, 5], "biz_start_hour": 9, "biz_end_hour": 18 }
```
- `biz_days`: working days (1=Mon … 7=Sun)
- `biz_start_hour` / `biz_end_hour`: working hours (decimals allowed)

The standard pace is computed each time the graph is drawn, so **changing these also redraws the dotted line for past periods** (from the next rebuild on).

**These hours are interpreted in JST (UTC+9).** Your machine's time zone is not consulted. Outside Japan, convert your working hours to JST before writing them here — for example 09:00–18:00 at UTC+1 becomes `17` and `26`. Values above 24 are accepted and mean the following day.

This is the only thing pinned to JST. **The now line and the x axis use the time zone of the machine viewing the page; `→reset` alone uses the time zone of the machine that recorded the data (where Claude Code runs).**

## Data location
Everything lives under `~/.claude/token-pace/`.

Records accumulate in `pace.jsonl` (5h/7d), `credits.jsonl` (monthly usage credits) and `codex.jsonl` (Codex). All three drop their oldest lines automatically, so none grows without bound. `forecast-hist.bin` holds the kept forecasts used for replay (about 3 MB for 7 days; not created when there are no forecasts). The viewer's input `pace.json`, the viewer itself `index.html`, and config/state files live in the same directory.

## Uninstall
```bash
bash ~/.claude/token-pace/uninstall.sh
```
Removes the `/tpw` command and the periodic job (systemd user timer / cron), restores your original statusLine, and stops the running server (recorded data is kept — remove it fully with `rm -rf ~/.claude/token-pace`).

## Troubleshooting
- **Browser doesn't open**: uses `xdg-open` (Linux), `open` (macOS), `powershell.exe` (WSL). If none exist, open the printed URL manually.
- **Stuck on "collecting…"**: recording hasn't started yet (see [Requirements](#requirements)). Check that the periodic job is running (`systemctl --user status claude-token-pace.timer`, or `crontab -l` for cron; `.scheduler` says which was installed). **Every run leaves a line in `~/.claude/token-pace/tick.log`**, including why a fetch failed and what the status-line check found or repaired in the periodic job.
- **Port in use**: a free port is found automatically, so there is nothing to do. To pin one, see [Port](#port-claudetoken-paceconfigjson).
- **No forecast band**: for the conditions and the file it reads, see [Usage forecast](#usage-forecast-optional). A missing band over part of a replay means no forecast was kept for that time yet.

## License
[MIT](LICENSE)
