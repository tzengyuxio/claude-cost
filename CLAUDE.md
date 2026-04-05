# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

Local CLI tool for tracking Claude Code token usage and costs via SQLite. Collects daily data from [ccusage](https://github.com/ryoppippi/ccusage) (npm package, pinned version in config) and stores it in `~/.local/share/claude-cost/usage.db`.

## Development

```bash
make lint    # shellcheck --severity=warning on all scripts
make test    # smoke tests (mock ccusage, isolated temp dir, no real data touched)
```

Scripts are plain bash. No build step. `bin/` scripts source `lib/claude-cost-common.sh` via relative path from `$SCRIPT_DIR`.

## Architecture

Two entry points, one shared library:

- `bin/claude-cost-collect` — Runs ccusage, filters by date watermark, inserts into SQLite in a single transaction. Uses directory-based locking (`$TRACKING_DIR/.lock` via `mkdir`). Designed for launchd/systemd cron; handles backfill for missed days automatically.
- `bin/claude-cost-report` — Read-only queries against the DB. Subcommands: `daily`, `daily-total`, `weekly`, `monthly`, `summary`, `csv`. All formatted output goes through `render_table` (awk function that auto-detects numeric columns for right-alignment).
- `lib/claude-cost-common.sh` — Config loading, path definitions (`DB`, `LOG`, `LOCK_DIR`), `yesterday()` portable date helper (macOS `date -v-1d` vs GNU `date -d`).

Data flow: `ccusage JSON → jq filter (watermark..yesterday) → INSERT OR REPLACE → update watermark in collect_metadata table`.

### Windows Support

On Windows (Git Bash), `lib/claude-cost-common.sh` detects `$APPDATA` and switches paths:
- Config: `%APPDATA%/claude-cost/config`
- Data: `%LOCALAPPDATA%/claude-cost/data/`

`install.bat` / `uninstall.bat` handle file copying and Task Scheduler (`schtasks`) setup. The bash scripts themselves run unmodified under Git Bash.

### SQLite Schema

- `daily_usage` — Primary key: `(date, model)`. Columns: input/output/cache_creation/cache_read tokens, cost_usd.
- `collect_metadata` — Key-value store. Currently only `last_collected_date` (watermark for incremental collection).

## Configuration

User config: `~/.config/claude-cost/config` (shell-sourceable key=value, not TOML/INI — 4 variables don't justify a parser). On Windows: `%APPDATA%\claude-cost\config`.

## Key Design Decisions

- Collection uses single SQLite transaction (not per-row inserts)
- `INSERT OR REPLACE` on `(date, model)` makes collection idempotent
- Report formatting uses awk `render_table` because macOS `column` lacks `-R` for right-alignment
- launchd plist label is `com.claude-cost.collect` (no username in it)
- `render_table` auto-detects right-aligned columns by header name pattern (tok, cost, avg, etc.)
- Windows paths use `APPDATA`/`LOCALAPPDATA` (detected via `$APPDATA` env var in Git Bash)
- `install.bat` locates bash.exe via `git --exec-path` parent traversal

## Testing

`tests/smoke.sh` creates an isolated environment: temp HOME, mock `npx` in PATH, its own config. Tests: first collection (3 rows from 2 days), idempotent re-run, report summary output, weekly report ISO week format, CSV export line count.

## Upstream Dependency

- ccusage JSON schema: `{ daily: [{ date, modelBreakdowns: [{ modelName, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cost }] }] }`
