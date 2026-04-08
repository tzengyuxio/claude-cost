# claude-cost

Persistent local tracking of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex CLI](https://github.com/openai/codex) token usage and costs.

Collects daily usage data from [ccusage](https://github.com/ryoppippi/ccusage) and [@ccusage/codex](https://www.npmjs.com/package/@ccusage/codex) into a local SQLite database, so your cost history survives session JSONL rotation and cleanup.

## Why

`ccusage` reads usage directly from Claude Code's session JSONL files. These files get rotated and cleaned up over time — so the further back you look, the more data has already been discarded. Historical usage figures become increasingly understated the longer you wait to check them.

`claude-cost` solves this by collecting each day's totals into a persistent SQLite database before the JSONL files disappear. Once captured, the numbers never change — your cost history stays accurate regardless of how long ago an event occurred.

## Features

- **Multi-provider** — tracks Claude Code and Codex CLI usage in one database
- **Incremental collection** — only fetches new data since the last run
- **Automatic backfill** — if your laptop was off for days, it catches up on wake
- **Idempotent** — safe to run multiple times; same data won't duplicate
- **Formatted reports** — daily, monthly, summary views with right-aligned numbers, broken down by provider
- **CSV export** — for spreadsheets or further analysis
- **Zero daemon** — scheduled via launchd (macOS) or systemd timer (Linux)

## Prerequisites

- `sqlite3` (macOS built-in; `apt install sqlite3` on Linux)
- `jq` (`brew install jq` / `apt install jq`)
- `npx` / Node.js (for running ccusage)
- On Windows: [Git for Windows](https://git-scm.com/download/win) (provides Git Bash)

## Install

```bash
git clone https://github.com/anthropics/claude-cost.git  # or your fork
cd claude-cost
make install
```

This will:

1. Copy scripts to `~/.local/bin/`
2. Create config at `~/.config/claude-cost/config` (if not exists)
3. Set up a daily schedule (launchd on macOS, systemd on Linux)

### Windows (Git Bash)

Requires [Git for Windows](https://git-scm.com/download/win), plus `sqlite3`, `jq`, and `npx` in your PATH.

```cmd
git clone https://github.com/anthropics/claude-cost.git
cd claude-cost
install.bat
```

This will:

1. Copy scripts to `%LOCALAPPDATA%\claude-cost\`
2. Create config at `%APPDATA%\claude-cost\config` (if not exists)
3. Set up a daily Task Scheduler job

To uninstall:

```cmd
uninstall.bat
```

### First collection

Then run the first collection:

```bash
claude-cost-collect
```

## Configuration

Edit `~/.config/claude-cost/config`:

```sh
TIMEZONE="Asia/Taipei"           # Timezone for date grouping (default: UTC)
CCUSAGE_VERSION="18.0.10"        # Pinned ccusage (Claude) version
CCUSAGE_CODEX_VERSION="18.0.10"  # Pinned @ccusage/codex version
ENABLED_PROVIDERS="claude codex" # Space-separated list of active providers
CODEX_OFFLINE=1                  # Pass --offline to codex fetcher (default: 1)
SCHEDULE_HOUR=2                  # Collection time — hour (default: 2)
SCHEDULE_MINUTE=0                # Collection time — minute (default: 0)
```

To collect only Claude Code usage (no Codex), set:

```sh
ENABLED_PROVIDERS="claude"
```

After changing schedule settings, reload:

```bash
make reload-schedule
```

## Usage

```bash
# Last 30 days, per-model breakdown
claude-cost-report daily

# Last 7 days, aggregated per day
claude-cost-report daily-total --last 7

# Weekly summary (ISO weeks)
claude-cost-report weekly

# Last 4 weeks
claude-cost-report weekly --last 4

# Monthly summary
claude-cost-report monthly

# Overall summary with top models
claude-cost-report summary

# Export to CSV
claude-cost-report csv --output costs.csv
```

### Shell aliases

Add to your `~/.zshrc` for quick access to the most common reports:

```zsh
if command -v claude-cost-report &> /dev/null; then
    alias ccr-monthly='claude-cost-report monthly'
    alias ccr-weekly='claude-cost-report weekly'
    alias ccr-daily='claude-cost-report daily-total'
fi
```

### Example output

```
  Monthly Usage (last 6 months)

month    input_tok  output_tok  cache_create  cache_read     total_cost  avg_daily_cost  active_days
-------  ---------  ----------  ------------  -------------  ----------  --------------  -----------
2026-04    670,814     285,691  11,761,527    241,229,057       $169.98          $42.50            4
2026-03    581,786   3,994,823  82,513,138    2,434,271,327    $1688.48          $54.47           31
2026-02    236,628      47,021  6,399,105     47,788,790         $38.84           $2.59           15
```

## How it works

```
launchd / systemd timer (daily, e.g. 02:00)
  → claude-cost-collect
    → for each provider in ENABLED_PROVIDERS:
        claude: npx ccusage@VERSION daily --json --timezone $TIMEZONE
        codex:  npx -y @ccusage/codex@VERSION daily --json [--offline]
    → filters dates between per-provider watermark and yesterday
    → normalises to common TSV format (date, provider, model, tokens…, cost)
    → INSERT OR REPLACE into SQLite (single transaction per provider)
    → updates per-provider watermark
```

Data is stored at `~/.local/share/claude-cost/usage.db`. You can query it directly:

```bash
sqlite3 ~/.local/share/claude-cost/usage.db "SELECT * FROM daily_usage ORDER BY date DESC LIMIT 10;"
```

## Uninstall

```bash
make uninstall
```

This removes scripts and the schedule but **preserves your data and config**.

To fully remove everything:

```bash
rm -rf ~/.local/share/claude-cost ~/.config/claude-cost
```

## Migrating from manual setup

If you previously had scripts in `~/.claude/usage-tracking/`:

1. Copy your existing database: `cp ~/.claude/usage-tracking/usage.db ~/.local/share/claude-cost/usage.db`
2. Run `make install`
3. Unload the old schedule: `launchctl unload ~/Library/LaunchAgents/com.user.cc-usage-collect.plist`
4. Remove old plist: `rm ~/Library/LaunchAgents/com.user.cc-usage-collect.plist`

## Troubleshooting

### Report shows no recent data

Check the collect log first:

```bash
tail -20 ~/.local/share/claude-cost/logs/collect.log
```

Common errors and fixes:

#### `npx: command not found`

launchd (and systemd) run with a minimal `PATH` that typically excludes Homebrew and Node.js. The scheduled job can't find `npx` even though it works in your terminal.

**Fix:** add an `EnvironmentVariables` block to the launchd plist so it includes the full path to `npx`:

```bash
# Edit the plist
nano ~/Library/LaunchAgents/com.claude-cost.collect.plist
```

Add inside the root `<dict>`:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
</dict>
```

Then reload and trigger a manual collection:

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-cost.collect.plist
launchctl load  ~/Library/LaunchAgents/com.claude-cost.collect.plist
launchctl start com.claude-cost.collect

# Confirm it worked
tail -5 ~/.local/share/claude-cost/logs/collect.log
```

You should see a line like `INFO: Upserted data (N new rows ...). Watermark updated to YYYY-MM-DD.`

> **Note:** today's data is always collected *tomorrow* — the watermark stops at "yesterday" to avoid partial-day counts. So after a successful run, the latest date in the report will be yesterday.

#### `Another instance is running (lock exists)`

A previous run crashed without releasing the lock directory. Remove it manually:

```bash
rmdir ~/.local/share/claude-cost/.lock
```

#### Watermark is stuck far in the past

If `last_collected_date` is very old and the scheduled job kept failing silently, run a manual collection once the underlying issue is fixed — it will automatically backfill all missed days in a single run.

```bash
claude-cost-collect
```

## License

MIT
