# claude-cost

Persistent local tracking of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) token usage and costs.

Collects daily usage data from [ccusage](https://github.com/ryoppippi/ccusage) into a local SQLite database, so your cost history survives session JSONL rotation and cleanup.

## Features

- **Incremental collection** — only fetches new data since the last run
- **Automatic backfill** — if your laptop was off for days, it catches up on wake
- **Idempotent** — safe to run multiple times; same data won't duplicate
- **Formatted reports** — daily, monthly, summary views with right-aligned numbers
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
TIMEZONE="Asia/Taipei"      # Timezone for date grouping (default: UTC)
CCUSAGE_VERSION="18.0.10"   # Pinned ccusage version
SCHEDULE_HOUR=2             # Collection time — hour (default: 2)
SCHEDULE_MINUTE=0           # Collection time — minute (default: 0)
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
    → npx ccusage daily --json --timezone $TIMEZONE
    → filters dates between watermark and yesterday
    → INSERT OR REPLACE into SQLite (single transaction)
    → updates watermark
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

## License

MIT
