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
- `lib/fetchers/claude.sh` — parameterised over (provider name, `CLAUDE_CONFIG_DIR`) so one machine's several Claude subscriptions each become their own provider; `CLAUDE_EXTRA_ACCOUNTS="<provider>:<config-dir> ..."` generates `fetch_<provider>` / `fetch_<provider>_hourly` for the extra accounts (the override is exported inside a subshell so it never leaks into the next provider). `fetch_claude()`: calls `npx ccusage@VERSION daily --json`, parses `modelBreakdowns[]`, outputs TSV rows. `fetch_claude_hourly()`: calls `npx ccusage@VERSION blocks --json -n 1` (online, no `--offline`, so ccusage looks up pricing and fills `costUSD` per block — matching daily; `--offline` would leave most hours at $0), converts UTC `startTime` to local date+hour via jq `strflocaltime` (with `TZ=$TIMEZONE`), filters `isGap`/`isActive` blocks, outputs TSV rows (no model column — `blocks` doesn't break tokens down per-model).
- `lib/fetchers/codex.sh` — `fetch_codex()`: calls `npx -y @ccusage/codex@VERSION daily --json [--offline]`, parses `models{}` object, converts "Jan 15, 2026" dates to ISO format, distributes `costUSD` proportionally by token ratio. No hourly equivalent — `@ccusage/codex` has no `blocks` subcommand. Also runs `warn_oversized_rollouts()` first, which warns (to stderr, so it lands in the collect log) about any rollout `.jsonl` larger than `CODEX_ROLLOUT_WARN_BYTES` — see "Oversized rollout files" below.

- `lib/fetchers/litellm.sh` — `fetch_litellm()`: queries `LiteLLM_SpendLogs` in the `litellm-db` PostgreSQL container via `docker exec … psql -t -A -F$'\t'` (the host has no `psql`). Groups by date-in-`TIMEZONE` and `COALESCE(NULLIF(model_group,''), model)`; `WHERE total_tokens > 0` drops rate-limited/failed requests, which are numerous and carry an empty `model`. `cache_*` and `cost` are always `0`, and `spend` is deliberately not read — see "Self-hosted inference providers" below. No hourly equivalent.
- `lib/fetchers/openwebui.sh` — `fetch_openwebui()`: queries `chat_message` in Open WebUI's SQLite DB with `sqlite3 -readonly` (the app writes to it concurrently). Buckets `created_at` (unix epoch) using the `tz_offset_minutes` shift for `TIMEZONE` rather than SQLite's `'localtime'`, so dates line up with the litellm fetcher even when the host's system zone differs. Strips the `:latest` tag from `model_id`. No hourly equivalent.

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
| `ENABLED_PROVIDERS` | `claude` | Space-separated list of active providers (`claude`, `codex`, `litellm`, `openwebui`, plus any from `CLAUDE_EXTRA_ACCOUNTS`) |
| `CLAUDE_EXTRA_ACCOUNTS` | *(unset)* | Additional Claude subscriptions, `<provider>:<config-dir>`, space-separated. Each becomes its own provider reading that `CLAUDE_CONFIG_DIR` |
| `LITELLM_DB_CONTAINER` | `litellm-db` | Container holding LiteLLM's PostgreSQL |
| `LITELLM_DB_USER` | `litellm` | PostgreSQL user for the litellm fetcher |
| `LITELLM_DB_NAME` | `litellm` | PostgreSQL database for the litellm fetcher |
| `OPENWEBUI_DB` | `/srv/data/webui/webui.db` | Path to Open WebUI's SQLite database |
| `CLOUD_RATES` | *(unset)* | `<model-glob>:<input $/M>:<output $/M>`, space-separated, first match wins. Unset ⇒ no cloud-equivalent columns |
| `CLOUD_RATE_DEFAULT` | *(unset)* | `<input $/M>:<output $/M>` for models no glob matched |
| `SELF_HOSTED_PROVIDERS` | `litellm openwebui` | Providers priced from `CLOUD_RATES`; all others use their real `cost_usd` |
| `CODEX_OFFLINE` | `1` | Pass `--offline` to codex fetcher |
| `CODEX_ROLLOUT_WARN_BYTES` | `200000000` | Warn when a Codex rollout `.jsonl` exceeds this size (see "Oversized rollout files") |
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

Test 14: `reasoningOutputTokens` is not added on top of `outputTokens` (it is a subset)

Test 15: Oversized rollout warning fires above `CODEX_ROLLOUT_WARN_BYTES` and stays silent below it

Tests 16–17: self-hosted providers (isolated env with a mock `docker` and a real Open WebUI-shaped SQLite DB, `ENABLED_PROVIDERS="litellm openwebui"`)
- Test 16: 2 litellm + 2 openwebui rows; openwebui Jan 15 aggregates to 80/15 under model `qwen-unc` (proves `prompt_tokens`/`completion_tokens` are used and `:latest` is stripped)
- Test 17: idempotent re-run, both watermarks at 2026-01-16, `daily` report renders with every cost at $0

Test 18: cloud-equivalent cost — `cloud_eq` / `saved` columns appear with `CLOUD_RATES` set, stored `cost_usd` stays 0, no columns appear when unset, malformed rate entries warn and are skipped rather than breaking the SQL

Test 19: second Claude subscription — with `CLAUDE_EXTRA_ACCOUNTS` set, the mock `npx` keys off `CLAUDE_CONFIG_DIR` and returns different data, proving each account is fetched from its own dir, lands under its own provider with its own watermark, and splits under `--by-provider`; a malformed entry warns and is skipped

Test 13: Migration
- Creates old-schema DB (no provider column, old watermark key)
- Runs collect, verifies provider column added, old data migrated as `provider='claude'`, watermark key renamed

## Upstream Dependencies

- ccusage daily JSON schema: `{ daily: [{ date, modelBreakdowns: [{ modelName, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cost }] }] }`
- ccusage blocks (`-n 1` for hourly) JSON schema: `{ blocks: [{ id, startTime (UTC ISO), endTime, actualEndTime, isActive, isGap, entries, tokenCounts: { inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens }, totalTokens, costUSD, models: [<name>...] }] }` — `models` is a name list only; no per-model token breakdown
- @ccusage/codex JSON schema: `{ daily: [{ date, totalTokens, costUSD, models: { <name>: { inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens, totalTokens, isFallback } } }] }` — dates in "Jan 15, 2026" format

  Field semantics, verified against real data (getting these wrong silently inflates stored tokens):
  - `cachedInputTokens` ⊆ `inputTokens` — so uncached input is `inputTokens - cachedInputTokens`
  - `reasoningOutputTokens` ⊆ `outputTokens` — **do not add it on top**; `totalTokens == inputTokens + outputTokens` holds exactly, with reasoning never counted separately
  - No per-model cost field exists, which is why day cost is split by token ratio

### Oversized rollout files

`@ccusage/codex` silently skips Codex rollout `.jsonl` files it cannot read: it exits 0, prints nothing to stderr, and simply omits that session's usage. The threshold sits between 202MB (reads fine) and 693MB (dropped), consistent with Node's max string length — it appears to read the whole file into a single string.

A single long-running Codex session can cross this easily; one six-day session reached 750MB and vanished from reports entirely, making a day's cost read $0.06 instead of $38.53. Because collection is watermarked, the bad value is written once and never revisited.

`warn_oversized_rollouts()` in `lib/fetchers/codex.sh` scans `${CODEX_HOME:-$HOME/.codex}/sessions` on every codex fetch and warns about files over `CODEX_ROLLOUT_WARN_BYTES` (default 200MB). It only warns — it never touches the files.

To recover an affected session, split the rollout into chunks small enough to read. Each chunk needs the `session_meta` header line **and** the most recent preceding `turn_context` event prepended; `turn_context` carries the model name, and chunks missing it get their tokens misattributed to a default model (`gpt-5`) while daily totals still look correct. Verify a re-chunk per model, not just per day.

### Self-hosted inference providers (litellm / openwebui)

These two exist for a *separate installation* on a self-hosted inference box, with its own `usage.db`. They are not meant to be enabled alongside `claude`/`codex` in a personal database: there `cost_usd` is real money spent, and mixing in rows that are structurally $0 makes both halves of the report meaningless.

Why two fetchers for one machine: Open WebUI talks to Ollama directly and bypasses the LiteLLM proxy (deliberately — routing it through LiteLLM breaks Open WebUI's model management). So usage lands in two unrelated databases and no single upstream tool covers both.

- **Stored cost is always `0`.** Local inference costs no money per token (the real cost is electricity), so `cost_usd` — which means real money spent everywhere else in this schema — stays 0. LiteLLM's `spend` column is deliberately not read: it looks like a cost but since 2026-08-06 it prices tokens at what the same traffic *would* have cost on a hosted API, while rows before that date are 0 (LiteLLM computes spend at write time and never backfills). Reading it would mean the column means two different things depending on the date, and would put the rate table in two places at once.
- **Cloud-equivalent cost is computed at report time instead** — see below.

### Cloud-equivalent cost

Answers "what would this have cost on a hosted API, and so what did self-hosting save". Driven by `CLOUD_RATES` (`<model-glob>:<input $/M>:<output $/M>`, first match wins, SQLite `GLOB`) plus `CLOUD_RATE_DEFAULT`, both loaded from the config.

`cloud_equiv_expr()` in `lib/claude-cost-common.sh` builds the SQL `CASE` expression; `bin/claude-cost-report` turns it into the `cloud_eq` / `saved` columns. Rows from providers *not* in `SELF_HOSTED_PROVIDERS` keep their real `cost_usd` as their equivalent, since those already are cloud services — so the figure stays comparable in a mixed database.

Design points worth keeping:

- **Computed, never stored.** Rates change and estimates get revised; storing the product would freeze each row at whatever rate happened to be configured the day it was collected — the exact trap LiteLLM's own `spend` column fell into. Computing at query time re-values the whole history at once, and avoids a schema migration and a wider TSV contract.
- **Off unless configured.** With no `CLOUD_RATES` the extra columns do not appear at all; on a Claude/Codex-only database the equivalent would just duplicate `cost_usd` on every row.
- **Ranking follows the equivalent when it is on.** "Most expensive days" / "Cost by Model" / "Cost by Provider" rank by real cost normally, but that orders every self-hosted row at $0, so they switch to the equivalent figure and the section header says so.
- Only input/output tokens are priced — self-hosted rows have no cache tokens.
- **Token field choice (openwebui).** Open WebUI's `usage` JSON carries two pairs: `input_tokens`/`output_tokens` and `prompt_tokens`/`completion_tokens`, with the former running roughly 2× the latter and no documented explanation. The fetcher uses `prompt_tokens`/`completion_tokens` because `LiteLLM_SpendLogs` uses those same names, keeping the two providers comparable. This is an alignment argument, not a measurement — confirming it means comparing a known conversation against Ollama's `prompt_eval_count`/`eval_count`.
- **Model naming.** LiteLLM reports the client-facing `model_group` (`qwen-tw`); Open WebUI reports the raw Ollama name (`qwen-unc:latest`). The openwebui fetcher strips the trailing `:latest` so the same model does not appear as two rows.

### Known limitation: cost allocation across unpriced models

Day cost is split across models by token ratio, but ccusage assigns $0 to models it has no pricing for (e.g. `codex-auto-review`, which triggers a "Pricing not found" warning). Nothing in the JSON distinguishes these — `isFallback` stays `false` — so the fetcher cannot exclude them, and they absorb a share of cost that belongs to the priced models. Fixing this needs per-model cost from upstream, or a local pricing table; neither fits this tool's role as a thin wrapper.
