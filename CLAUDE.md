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

- `bin/claude-cost-collect` — Runs enabled provider fetchers, filters by per-provider date watermark, inserts into SQLite in a single transaction per provider. Uses directory-based locking (`$TRACKING_DIR/.lock` via `mkdir`). Designed for launchd/systemd cron; handles backfill for missed days automatically.
- `bin/claude-cost-report` — Read-only queries against the DB. Subcommands: `daily`, `daily-total`, `weekly`, `monthly`, `summary`, `csv`. All formatted output goes through `render_table` (awk function that auto-detects numeric columns for right-alignment). The `summary` command includes a "Cost by Provider" breakdown. `daily-total` / `weekly` / `monthly` accept `--by-provider` to split rows per provider, and `--provider P` to filter to a single provider; `daily` is always per-model so only `--provider` applies.
- `lib/claude-cost-common.sh` — Config loading, path definitions (`DB`, `LOG`, `LOCK_DIR`), `yesterday()` portable date helper (macOS `date -v-1d` vs GNU `date -d`). Defaults: `ENABLED_PROVIDERS="claude"`, `CODEX_OFFLINE=1`.
- `lib/fetchers/claude.sh` — `fetch_claude()`: calls `npx ccusage@VERSION daily --json`, parses `modelBreakdowns[]`, outputs TSV rows.
- `lib/fetchers/codex.sh` — `fetch_codex()`: calls `npx -y @ccusage/codex@VERSION daily --json [--offline]`, parses `models{}` object, converts "Jan 15, 2026" dates to ISO format, distributes `costUSD` proportionally by token ratio.

Data flow:
```
for each PROVIDER in ENABLED_PROVIDERS:
  fetch_${PROVIDER}() → TSV (date, provider, model, input, output, cache_create, cache_read, cost)
  → INSERT OR REPLACE into daily_usage (single transaction)
  → update collect_metadata[last_collected_date:${PROVIDER}]
```

### Windows Support

On Windows (Git Bash), `lib/claude-cost-common.sh` detects `$APPDATA` and switches paths:
- Config: `%APPDATA%/claude-cost/config`
- Data: `%LOCALAPPDATA%/claude-cost/data/`

`install.bat` / `uninstall.bat` handle file copying and Task Scheduler (`schtasks`) setup. The bash scripts themselves run unmodified under Git Bash.

### SQLite Schema

- `daily_usage` — Primary key: `(date, provider, model)`. Columns: input/output/cache_creation/cache_read tokens, cost_usd. The `provider` column distinguishes rows from different sources (e.g. `claude`, `codex`).
- `collect_metadata` — Key-value store. Watermark keys are namespaced per provider: `last_collected_date:claude`, `last_collected_date:codex`.

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
| `TIMEZONE` | `UTC` | Timezone for date grouping |
| `CCUSAGE_VERSION` | `18.0.10` | Pinned ccusage (Claude) npm version |
| `CCUSAGE_CODEX_VERSION` | `18.0.10` | Pinned @ccusage/codex npm version |
| `ENABLED_PROVIDERS` | `claude` | Space-separated list of active providers |
| `CODEX_OFFLINE` | `1` | Pass `--offline` to codex fetcher |
| `SCHEDULE_HOUR` | `2` | Collection time — hour |
| `SCHEDULE_MINUTE` | `0` | Collection time — minute |

## Key Design Decisions

- Collection uses single SQLite transaction per provider (not per-row inserts)
- `INSERT OR REPLACE` on `(date, provider, model)` makes collection idempotent
- Per-provider watermark keys (`last_collected_date:${PROVIDER}`) allow independent backfill per provider
- Codex cost is distributed across models proportionally by `totalTokens` ratio (Codex API only returns per-day cost, not per-model)
- Report formatting uses awk `render_table` because macOS `column` lacks `-R` for right-alignment
- launchd plist label is `com.claude-cost.collect` (no username in it)
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

Test 9: Migration
- Creates old-schema DB (no provider column, old watermark key)
- Runs collect, verifies provider column added, old data migrated as `provider='claude'`, watermark key renamed

## Upstream Dependencies

- ccusage JSON schema: `{ daily: [{ date, modelBreakdowns: [{ modelName, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cost }] }] }`
- @ccusage/codex JSON schema: `{ daily: [{ date, totalTokens, costUSD, models: { <name>: { inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens, totalTokens, isFallback } } }] }` — dates in "Jan 15, 2026" format
