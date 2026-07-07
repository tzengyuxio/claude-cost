# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

Local CLI tool for tracking Claude Code and Codex CLI token usage and costs via SQLite. Collects daily data from [ccusage](https://github.com/ryoppippi/ccusage) (Claude provider) and [@ccusage/codex](https://www.npmjs.com/package/@ccusage/codex) (Codex provider), with pinned versions in config, and stores everything in `~/.local/share/claude-cost/usage.db`.

## Development

```bash
make lint    # shellcheck --severity=warning on all scripts
make test    # smoke tests (mock ccusage, isolated temp dir, no real data touched)
```

Scripts are plain bash. No build step. `bin/` scripts source `lib/claude-cost-common.sh` via relative path from `$SCRIPT_DIR`.

## Architecture

Two entry points, one shared library, and a fetcher layer:

- `bin/claude-cost-collect` — Runs enabled provider fetchers, filters by per-provider date watermark, inserts into SQLite in a single transaction per provider. Uses directory-based locking (`$TRACKING_DIR/.lock` via `mkdir`). Designed for launchd/systemd cron; handles backfill for missed days automatically. After the daily fetch, if a `fetch_${PROVIDER}_hourly` function exists, also runs hourly collection into `hourly_usage`.
- `bin/claude-cost-report` — Read-only queries against the DB. Subcommands: `daily`, `daily-total`, `weekly`, `monthly`, `by-hour`, `by-weekday-hour`, `summary`, `csv`. All formatted output goes through `render_table` (awk function that auto-detects numeric columns for right-alignment). The `summary` command includes a "Cost by Provider" breakdown. `daily-total` / `weekly` / `monthly` accept `--by-provider` to split rows per provider, and `--provider P` to filter to a single provider; `daily` is always per-model so only `--provider` applies. `by-hour` / `by-weekday-hour` query `hourly_usage` (currently claude-only) and re-project stored hours into `REPORT_TIMEZONE` at query time (a fixed-offset SQLite `datetime(...)` shift), labelling the display zone in the section header.
- `lib/claude-cost-common.sh` — Config loading, path definitions (`DB`, `LOG`, `LOCK_DIR`), `yesterday()` portable date helper (computes "yesterday" under `TZ=$TIMEZONE`, so the watermark only advances past days fully elapsed in the bucketing zone — otherwise an early-morning run in a zone ahead of `TIMEZONE` drops the in-progress day's later hours), and `report_tz_shift_minutes()` (offset between `TIMEZONE` and `REPORT_TIMEZONE` for the hour-of-day reports). Defaults: `ENABLED_PROVIDERS="claude"`, `CODEX_OFFLINE=1`, `REPORT_TIMEZONE=$TIMEZONE`.
- `lib/fetchers/claude.sh` — `fetch_claude()`: calls `npx ccusage@VERSION daily --json`, parses `modelBreakdowns[]`, outputs TSV rows. `fetch_claude_hourly()`: calls `npx ccusage@VERSION blocks --json -n 1` (online, no `--offline`, so ccusage looks up pricing and fills `costUSD` per block — matching daily; `--offline` would leave most hours at $0), converts UTC `startTime` to local date+hour via jq `strflocaltime` (with `TZ=$TIMEZONE`), filters `isGap`/`isActive` blocks, outputs TSV rows (no model column — `blocks` doesn't break tokens down per-model).
- `lib/fetchers/codex.sh` — `fetch_codex()`: calls `npx -y @ccusage/codex@VERSION daily --json [--offline]`, parses `models{}` object, converts "Jan 15, 2026" dates to ISO format, distributes `costUSD` proportionally by token ratio. No hourly equivalent — `@ccusage/codex` has no `blocks` subcommand.

Data flow:
```
for each PROVIDER in ENABLED_PROVIDERS:
  fetch_${PROVIDER}() → TSV (date, provider, model, input, output, cache_create, cache_read, cost)
  → INSERT OR REPLACE into daily_usage (single transaction)
  → update collect_metadata[last_collected_date:${PROVIDER}]
  if fetch_${PROVIDER}_hourly exists:
    fetch_${PROVIDER}_hourly() → TSV (date, hour, provider, input, output, cache_create, cache_read, cost, entries)
    → INSERT OR REPLACE into hourly_usage (single transaction)
    → update collect_metadata[last_collected_hour:${PROVIDER}]
```

### Windows Support

On Windows (Git Bash), `lib/claude-cost-common.sh` detects `$APPDATA` and switches paths:
- Config: `%APPDATA%/claude-cost/config`
- Data: `%LOCALAPPDATA%/claude-cost/data/`

`install.bat` / `uninstall.bat` handle file copying and Task Scheduler (`schtasks`) setup. The bash scripts themselves run unmodified under Git Bash.

### SQLite Schema

- `daily_usage` — Primary key: `(date, provider, model)`. Columns: input/output/cache_creation/cache_read tokens, cost_usd. The `provider` column distinguishes rows from different sources (e.g. `claude`, `codex`).
- `hourly_usage` — Primary key: `(date, hour, provider)`. Columns: tokens, cost_usd, entries (number of session events in that hour). `date` and `hour` are stored bucketed in the configured `TIMEZONE`; the hour-of-day reports apply a further fixed-offset shift to `REPORT_TIMEZONE` only at display time (storage is never re-bucketed). **No model column** — ccusage `blocks` doesn't break down tokens per-model within a block.
- `collect_metadata` — Key-value store. Watermark keys are namespaced per provider: `last_collected_date:claude`, `last_collected_date:codex`, `last_collected_hour:claude`.

### Schema Migration

When the collect script runs against an old DB (no `provider` column, single PK `(date, model)`):
1. Creates `daily_usage_new` with the new schema.
2. Copies existing rows, setting `provider='claude'` for all.
3. Drops old table and renames new one.
4. Renames watermark key from `last_collected_date` → `last_collected_date:claude`.

## Configuration

User config: `~/.config/claude-cost/config` (shell-sourceable key=value, not TOML/INI). On Windows: `%APPDATA%\claude-cost\config`.

Key variables:

| Variable | Default | Description |
|---|---|---|
| `TIMEZONE` | `UTC` | Timezone for date grouping (storage) |
| `REPORT_TIMEZONE` | `$TIMEZONE` | Display timezone for `by-hour` / `by-weekday-hour` only (re-projected at query time, no re-bucketing) |
| `CCUSAGE_VERSION` | `18.0.10` | Pinned ccusage (Claude) npm version |
| `CCUSAGE_CODEX_VERSION` | `18.0.10` | Pinned @ccusage/codex npm version |
| `ENABLED_PROVIDERS` | `claude` | Space-separated list of active providers |
| `CODEX_OFFLINE` | `1` | Pass `--offline` to codex fetcher |
| `SCHEDULE_HOUR` | `2` | Collection start time — hour |
| `SCHEDULE_MINUTE` | `0` | Collection start time — minute |
| `SCHEDULE_INTERVAL_HOURS` | `6` | Re-run cadence: every N hours from `SCHEDULE_HOUR` (24 = once daily) |

## Key Design Decisions

- Collection uses single SQLite transaction per provider (not per-row inserts)
- `INSERT OR REPLACE` on `(date, provider, model)` makes collection idempotent
- Per-provider watermark keys (`last_collected_date:${PROVIDER}`) allow independent backfill per provider
- Codex cost is distributed across models proportionally by `totalTokens` ratio (Codex API only returns per-day cost, not per-model)
- Report formatting uses awk `render_table` because macOS `column` lacks `-R` for right-alignment
- launchd plist label is `com.claude-cost.collect` (no username in it)
- Schedule fires every `SCHEDULE_INTERVAL_HOURS` (default 6), not once daily: `yesterday()` is computed in `TIMEZONE`, so a single run at local 02:00 while `TIMEZONE=UTC` and the host is east of UTC fires before the UTC day ends and the watermark lags ~2 days. Idempotent re-runs (launchd `StartCalendarInterval` array / systemd `OnCalendar=H/N`) let it catch up within hours without changing storage or `TIMEZONE`. Tuning is purely a scheduler concern — `collect` is unaware of cadence.
- `render_table` auto-detects right-aligned columns by header name pattern (tok, cost, avg, etc.)
- Windows paths use `APPDATA`/`LOCALAPPDATA` (detected via `$APPDATA` env var in Git Bash)
- `install.bat` locates bash.exe via `git --exec-path` parent traversal

## Testing

`tests/smoke.sh` creates an isolated environment: temp HOME, mock `npx` in PATH (dispatches to Claude or Codex mock JSON based on arguments), its own config with `ENABLED_PROVIDERS="claude codex"`.

Tests 1–5: core collect/report behaviour
- Test 1: First collection inserts 6 rows (3 claude + 3 codex)
- Test 2: Idempotent re-run — row count unchanged
- Test 3: Summary total cost = $5.95 (claude $4.25 + codex $1.70)
- Test 4: Weekly report shows ISO week 2026-W03
- Test 5: CSV export has 7 lines (1 header + 6 data)

Tests 6–8: codex-specific behaviour
- Test 6: 3 codex rows in DB (1 + 2 models across 2 days)
- Test 7: Codex Jan 16 cost allocation ≈ $1.20 (within ±0.01)
- Test 8: Summary output contains "Cost by Provider"

Tests 9–12: hourly behaviour (claude only)
- Test 9: 3 hourly rows in DB (4 mock blocks minus 1 `isGap=true`)
- Test 10: `last_collected_hour:claude` watermark = 2026-01-16
- Test 11: `by-hour` report shows expected hour buckets (09:00 / 10:00 / 14:00)
- Test 11b: `REPORT_TIMEZONE=Asia/Taipei` re-projects by-hour buckets (+8 → 17:00 / 18:00 / 22:00) and labels the display timezone
- Test 12: `by-weekday-hour` heatmap renders 7 weekday rows + legend

Test 13: Migration
- Creates old-schema DB (no provider column, old watermark key)
- Runs collect, verifies provider column added, old data migrated as `provider='claude'`, watermark key renamed

## Upstream Dependencies

- ccusage daily JSON schema: `{ daily: [{ date, modelBreakdowns: [{ modelName, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cost }] }] }`
- ccusage blocks (`-n 1` for hourly) JSON schema: `{ blocks: [{ id, startTime (UTC ISO), endTime, actualEndTime, isActive, isGap, entries, tokenCounts: { inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens }, totalTokens, costUSD, models: [<name>...] }] }` — `models` is a name list only; no per-model token breakdown
- @ccusage/codex JSON schema: `{ daily: [{ date, totalTokens, costUSD, models: { <name>: { inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens, totalTokens, isFallback } } }] }` — dates in "Jan 15, 2026" format
