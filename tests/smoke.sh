#!/bin/bash
# Smoke test for claude-cost: mock ccusage output, collect, then verify reports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

echo "=== claude-cost smoke test ==="
echo "Temp dir: $TEST_DIR"

# --- Setup: override config to use test directory ---
export XDG_CONFIG_HOME="$TEST_DIR/config"
export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.local/share/claude-cost/logs"
mkdir -p "$XDG_CONFIG_HOME/claude-cost"
cat > "$XDG_CONFIG_HOME/claude-cost/config" <<'EOF'
TIMEZONE="UTC"
CCUSAGE_VERSION="18.0.10"
CCUSAGE_CODEX_VERSION="18.0.10"
ENABLED_PROVIDERS="claude codex"
CODEX_OFFLINE=1
EOF

# --- Create mock npx that dispatches based on args ---
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/npx" <<'MOCK'
#!/bin/bash
# Mock npx: dispatch to claude (daily/blocks) or codex mock based on arguments
is_blocks=0
for arg in "$@"; do
    [[ "$arg" == "blocks" ]] && is_blocks=1
done

for arg in "$@"; do
    if [[ "$arg" == *"@ccusage/codex@"* ]]; then
        # Codex mock: "Jan 15, 2026" format, models object, costUSD, cost split by token ratio
        cat <<'JSON'
{
  "daily": [
    {
      "date": "Jan 15, 2026",
      "inputTokens": 500,
      "cachedInputTokens": 200,
      "outputTokens": 100,
      "reasoningOutputTokens": 20,
      "totalTokens": 600,
      "costUSD": 0.50,
      "models": {
        "gpt-test-model": {
          "inputTokens": 500,
          "cachedInputTokens": 200,
          "outputTokens": 100,
          "reasoningOutputTokens": 20,
          "totalTokens": 600,
          "isFallback": false
        }
      }
    },
    {
      "date": "Jan 16, 2026",
      "inputTokens": 1000,
      "cachedInputTokens": 400,
      "outputTokens": 200,
      "reasoningOutputTokens": 50,
      "totalTokens": 1200,
      "costUSD": 1.20,
      "models": {
        "gpt-test-model": {
          "inputTokens": 700,
          "cachedInputTokens": 300,
          "outputTokens": 140,
          "reasoningOutputTokens": 35,
          "totalTokens": 840,
          "isFallback": false
        },
        "gpt-other-model": {
          "inputTokens": 300,
          "cachedInputTokens": 100,
          "outputTokens": 60,
          "reasoningOutputTokens": 15,
          "totalTokens": 360,
          "isFallback": false
        }
      }
    }
  ]
}
JSON
        exit 0
    fi
done

# Claude blocks mock (hourly)
if [ "$is_blocks" -eq 1 ]; then
    cat <<'JSON'
{
  "blocks": [
    {
      "id": "2026-01-15T09:00:00.000Z",
      "startTime": "2026-01-15T09:00:00.000Z",
      "endTime": "2026-01-15T10:00:00.000Z",
      "actualEndTime": "2026-01-15T09:45:00.000Z",
      "isActive": false,
      "isGap": false,
      "entries": 5,
      "tokenCounts": {
        "inputTokens": 400,
        "outputTokens": 200,
        "cacheCreationInputTokens": 800,
        "cacheReadInputTokens": 2000
      },
      "totalTokens": 3400,
      "costUSD": 0.60,
      "models": ["claude-test-model"]
    },
    {
      "id": "2026-01-15T14:00:00.000Z",
      "startTime": "2026-01-15T14:00:00.000Z",
      "endTime": "2026-01-15T15:00:00.000Z",
      "actualEndTime": "2026-01-15T14:30:00.000Z",
      "isActive": false,
      "isGap": false,
      "entries": 3,
      "tokenCounts": {
        "inputTokens": 600,
        "outputTokens": 300,
        "cacheCreationInputTokens": 1200,
        "cacheReadInputTokens": 3000
      },
      "totalTokens": 5100,
      "costUSD": 0.90,
      "models": ["claude-test-model"]
    },
    {
      "id": "2026-01-15T15:00:00.000Z",
      "startTime": "2026-01-15T15:00:00.000Z",
      "endTime": "2026-01-15T20:00:00.000Z",
      "actualEndTime": null,
      "isActive": false,
      "isGap": true,
      "entries": 0,
      "tokenCounts": {
        "inputTokens": 0,
        "outputTokens": 0,
        "cacheCreationInputTokens": 0,
        "cacheReadInputTokens": 0
      },
      "totalTokens": 0,
      "costUSD": 0,
      "models": []
    },
    {
      "id": "2026-01-16T10:00:00.000Z",
      "startTime": "2026-01-16T10:00:00.000Z",
      "endTime": "2026-01-16T11:00:00.000Z",
      "actualEndTime": "2026-01-16T10:55:00.000Z",
      "isActive": false,
      "isGap": false,
      "entries": 8,
      "tokenCounts": {
        "inputTokens": 1000,
        "outputTokens": 500,
        "cacheCreationInputTokens": 2000,
        "cacheReadInputTokens": 5000
      },
      "totalTokens": 8500,
      "costUSD": 1.25,
      "models": ["claude-test-model", "claude-other-model"]
    }
  ]
}
JSON
    exit 0
fi

# Default: Claude mock
cat <<'JSON'
{
  "daily": [
    {
      "date": "2026-01-15",
      "inputTokens": 1000,
      "outputTokens": 500,
      "cacheCreationTokens": 2000,
      "cacheReadTokens": 5000,
      "totalTokens": 8500,
      "totalCost": 1.50,
      "modelsUsed": ["claude-test-model"],
      "modelBreakdowns": [
        {
          "modelName": "claude-test-model",
          "inputTokens": 1000,
          "outputTokens": 500,
          "cacheCreationTokens": 2000,
          "cacheReadTokens": 5000,
          "cost": 1.50
        }
      ]
    },
    {
      "date": "2026-01-16",
      "inputTokens": 2000,
      "outputTokens": 800,
      "cacheCreationTokens": 3000,
      "cacheReadTokens": 7000,
      "totalTokens": 12800,
      "totalCost": 2.75,
      "modelsUsed": ["claude-test-model", "claude-other-model"],
      "modelBreakdowns": [
        {
          "modelName": "claude-test-model",
          "inputTokens": 1500,
          "outputTokens": 600,
          "cacheCreationTokens": 2500,
          "cacheReadTokens": 6000,
          "cost": 2.00
        },
        {
          "modelName": "claude-other-model",
          "inputTokens": 500,
          "outputTokens": 200,
          "cacheCreationTokens": 500,
          "cacheReadTokens": 1000,
          "cost": 0.75
        }
      ]
    }
  ]
}
JSON
MOCK
chmod +x "$MOCK_BIN/npx"

# Put mock npx first in PATH
export PATH="$MOCK_BIN:$PATH"

DB="$HOME/.local/share/claude-cost/usage.db"

# --- Test 1: First collection ---
echo ""
echo "[1/18] Testing first collection (claude + codex)..."
bash "$REPO_DIR/bin/claude-cost-collect"
ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM daily_usage;")
# claude: 3 rows (jan15×1 model + jan16×2 models); codex: 3 rows (jan15×1 + jan16×2) = 6 total
if [ "$ROWS" -eq 6 ]; then
    echo "  PASS: 6 rows inserted (3 claude + 3 codex)"
else
    echo "  FAIL: Expected 6 rows, got $ROWS"
    exit 1
fi

# --- Test 2: Idempotent re-run ---
echo "[2/18] Testing idempotent re-run..."
bash "$REPO_DIR/bin/claude-cost-collect"
ROWS2=$(sqlite3 "$DB" "SELECT COUNT(*) FROM daily_usage;")
if [ "$ROWS2" -eq 6 ]; then
    echo "  PASS: Still 6 rows (idempotent)"
else
    echo "  FAIL: Expected 6 rows, got $ROWS2"
    exit 1
fi

# --- Test 3: Report summary ---
echo "[3/18] Testing report summary (claude total \$4.25)..."
OUTPUT=$(bash "$REPO_DIR/bin/claude-cost-report" summary 2>&1)
# Claude cost: 1.50 + 2.00 + 0.75 = 4.25; Codex cost: 0.50 + 1.20 = 1.70; Grand total: 5.95
if echo "$OUTPUT" | grep -q '\$5.95'; then
    echo "  PASS: Total cost \$5.95 found in summary"
else
    echo "  FAIL: Expected \$5.95 in summary output"
    echo "$OUTPUT"
    exit 1
fi

# --- Test 4: Weekly report ---
echo "[4/18] Testing weekly report..."
WEEKLY_OUTPUT=$(bash "$REPO_DIR/bin/claude-cost-report" weekly --last 520 2>&1)
if echo "$WEEKLY_OUTPUT" | grep -q '2026-W03'; then
    echo "  PASS: ISO week 2026-W03 found in weekly report"
else
    echo "  FAIL: Expected 2026-W03 in weekly output"
    echo "$WEEKLY_OUTPUT"
    exit 1
fi

# --- Test 5: CSV export ---
echo "[5/18] Testing CSV export..."
CSV_FILE="$TEST_DIR/export.csv"
bash "$REPO_DIR/bin/claude-cost-report" csv --output "$CSV_FILE"
CSV_LINES=$(wc -l < "$CSV_FILE" | tr -d ' ')
# 1 header + 6 data rows
if [ "$CSV_LINES" -eq 7 ]; then
    echo "  PASS: CSV has 7 lines (1 header + 6 data)"
else
    echo "  FAIL: Expected 7 CSV lines, got $CSV_LINES"
    exit 1
fi

# --- Test 6: Codex rows exist ---
echo "[6/18] Testing codex rows in DB..."
CODEX_ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM daily_usage WHERE provider='codex';")
if [ "$CODEX_ROWS" -eq 3 ]; then
    echo "  PASS: 3 codex rows (jan15×1 + jan16×2)"
else
    echo "  FAIL: Expected 3 codex rows, got $CODEX_ROWS"
    exit 1
fi

# --- Test 7: Codex cost allocation for Jan 16 ---
echo "[7/18] Testing codex cost allocation for Jan 16..."
CODEX_JAN16=$(sqlite3 "$DB" "SELECT SUM(cost_usd) FROM daily_usage WHERE provider='codex' AND date='2026-01-16';")
# Expected: gpt-test-model (840/1200 * 1.20 = 0.84) + gpt-other-model (360/1200 * 1.20 = 0.36) = 1.20
OK=$(awk -v val="$CODEX_JAN16" 'BEGIN { diff = val - 1.20; if (diff < 0) diff = -diff; print (diff <= 0.01) ? "yes" : "no" }')
if [ "$OK" = "yes" ]; then
    echo "  PASS: Codex Jan 16 cost ≈ \$1.20 (got \$$CODEX_JAN16)"
else
    echo "  FAIL: Expected codex Jan 16 cost ≈ \$1.20, got \$$CODEX_JAN16"
    exit 1
fi

# --- Test 8: Summary contains Cost by Provider ---
echo "[8/18] Testing summary contains 'Cost by Provider'..."
SUMMARY=$(bash "$REPO_DIR/bin/claude-cost-report" summary 2>&1)
if echo "$SUMMARY" | grep -q 'Cost by Provider'; then
    echo "  PASS: 'Cost by Provider' section found in summary"
else
    echo "  FAIL: 'Cost by Provider' not found in summary"
    echo "$SUMMARY"
    exit 1
fi

# --- Test 9: Hourly rows inserted ---
echo "[9/18] Testing hourly_usage rows (gap block filtered out)..."
HOURLY_ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM hourly_usage WHERE provider='claude';")
# Mock has 4 blocks; one is isGap=true → 3 real rows: jan15 09, jan15 14, jan16 10
if [ "$HOURLY_ROWS" -eq 3 ]; then
    echo "  PASS: 3 hourly rows inserted"
else
    echo "  FAIL: Expected 3 hourly rows, got $HOURLY_ROWS"
    sqlite3 "$DB" "SELECT * FROM hourly_usage;"
    exit 1
fi

# --- Test 10: Hourly watermark set ---
echo "[10/18] Testing hourly watermark set to 2026-01-16..."
HOURLY_WM=$(sqlite3 "$DB" "SELECT value FROM collect_metadata WHERE key='last_collected_hour:claude';")
if [ "$HOURLY_WM" = "2026-01-16" ]; then
    echo "  PASS: hourly watermark = $HOURLY_WM"
else
    echo "  FAIL: Expected watermark 2026-01-16, got '$HOURLY_WM'"
    exit 1
fi

# --- Test 11: by-hour report contains expected hour buckets ---
echo "[11/18] Testing by-hour report shows hours 09 / 10 / 14..."
BY_HOUR=$(bash "$REPO_DIR/bin/claude-cost-report" by-hour --last 9999 2>&1)
if echo "$BY_HOUR" | grep -q '09:00' \
   && echo "$BY_HOUR" | grep -q '10:00' \
   && echo "$BY_HOUR" | grep -q '14:00'; then
    echo "  PASS: by-hour shows expected hour buckets"
else
    echo "  FAIL: by-hour missing expected hours"
    echo "$BY_HOUR"
    exit 1
fi

# --- Test 11b: REPORT_TIMEZONE shifts by-hour buckets for display ---
# Storage is UTC; displaying in Asia/Taipei (+8) must move 09/10/14 → 17/18/22.
echo "[11b] Testing REPORT_TIMEZONE re-projects by-hour buckets..."
BY_HOUR_TPE=$(REPORT_TIMEZONE="Asia/Taipei" bash "$REPO_DIR/bin/claude-cost-report" by-hour --last 9999 2>&1)
if echo "$BY_HOUR_TPE" | grep -q '17:00' \
   && echo "$BY_HOUR_TPE" | grep -q '18:00' \
   && echo "$BY_HOUR_TPE" | grep -q '22:00' \
   && ! echo "$BY_HOUR_TPE" | grep -q '09:00' \
   && echo "$BY_HOUR_TPE" | grep -q 'times in Asia/Taipei'; then
    echo "  PASS: by-hour buckets shifted +8 and timezone labelled"
else
    echo "  FAIL: by-hour not re-projected to Asia/Taipei"
    echo "$BY_HOUR_TPE"
    exit 1
fi

# --- Test 12: by-weekday-hour heatmap renders 7 weekday rows ---
echo "[12/18] Testing by-weekday-hour heatmap has 7 weekday rows..."
HEATMAP=$(bash "$REPO_DIR/bin/claude-cost-report" by-weekday-hour --last 9999 2>&1)
WD_COUNT=$(echo "$HEATMAP" | grep -cE '^(Sun|Mon|Tue|Wed|Thu|Fri|Sat) \| ')
if [ "$WD_COUNT" -eq 7 ] && echo "$HEATMAP" | grep -q 'Legend'; then
    echo "  PASS: 7 weekday rows + legend"
else
    echo "  FAIL: Expected 7 weekday rows + legend, got $WD_COUNT rows"
    echo "$HEATMAP"
    exit 1
fi

# --- Test 13a: Hourly runs independently of daily watermark ---
# Regression: daily skipping (already up-to-date) must not skip hourly.
echo "[13a] Testing hourly fetches even when daily is already up to date..."
sqlite3 "$DB" "DELETE FROM hourly_usage; DELETE FROM collect_metadata WHERE key='last_collected_hour:claude';"
bash "$REPO_DIR/bin/claude-cost-collect"
HOURLY_AFTER_REFILL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM hourly_usage WHERE provider='claude';")
if [ "$HOURLY_AFTER_REFILL" -eq 3 ]; then
    echo "  PASS: hourly repopulated to 3 rows despite daily watermark being current"
else
    echo "  FAIL: Expected 3 hourly rows after refill, got $HOURLY_AFTER_REFILL"
    exit 1
fi

# --- Test 13: Migration from old schema ---
echo "[13/18] Testing schema migration from old (no provider column) schema..."

# Set up a separate isolated environment for migration test
MIGRATE_DIR="$TEST_DIR/migrate"
export HOME="$MIGRATE_DIR/home"
export XDG_CONFIG_HOME="$MIGRATE_DIR/config"
mkdir -p "$HOME/.local/share/claude-cost/logs"
mkdir -p "$XDG_CONFIG_HOME/claude-cost"
cat > "$XDG_CONFIG_HOME/claude-cost/config" <<'EOF'
TIMEZONE="UTC"
CCUSAGE_VERSION="18.0.10"
CCUSAGE_CODEX_VERSION="18.0.10"
ENABLED_PROVIDERS="claude"
CODEX_OFFLINE=1
EOF

MIGRATE_DB="$HOME/.local/share/claude-cost/usage.db"

# Create old-schema DB: no provider column, old watermark key
sqlite3 "$MIGRATE_DB" <<'SQL'
CREATE TABLE daily_usage (
    date       TEXT NOT NULL,
    model      TEXT NOT NULL,
    input_tokens          INTEGER DEFAULT 0,
    output_tokens         INTEGER DEFAULT 0,
    cache_creation_tokens INTEGER DEFAULT 0,
    cache_read_tokens     INTEGER DEFAULT 0,
    cost_usd              REAL DEFAULT 0.0,
    PRIMARY KEY (date, model)
);
INSERT INTO daily_usage VALUES ('2026-01-10', 'claude-old-model', 100, 50, 200, 500, 0.10);

CREATE TABLE collect_metadata (
    key   TEXT PRIMARY KEY,
    value TEXT
);
INSERT INTO collect_metadata VALUES ('last_collected_date', '2026-01-10');
SQL

# Run collect — should trigger migration
bash "$REPO_DIR/bin/claude-cost-collect"

# Verify provider column now exists
HAS_PROVIDER=$(sqlite3 "$MIGRATE_DB" "SELECT COUNT(*) FROM pragma_table_info('daily_usage') WHERE name='provider';")
if [ "$HAS_PROVIDER" -eq 1 ]; then
    echo "  PASS: provider column exists after migration"
else
    echo "  FAIL: provider column missing after migration"
    exit 1
fi

# Verify old data was migrated as provider='claude'
OLD_CLAUDE=$(sqlite3 "$MIGRATE_DB" "SELECT COUNT(*) FROM daily_usage WHERE provider='claude' AND model='claude-old-model';")
if [ "$OLD_CLAUDE" -eq 1 ]; then
    echo "  PASS: old data migrated with provider='claude'"
else
    echo "  FAIL: old data not migrated correctly (got $OLD_CLAUDE rows)"
    exit 1
fi

# Verify watermark key renamed
NEW_KEY=$(sqlite3 "$MIGRATE_DB" "SELECT COUNT(*) FROM collect_metadata WHERE key='last_collected_date:claude';")
OLD_KEY=$(sqlite3 "$MIGRATE_DB" "SELECT COUNT(*) FROM collect_metadata WHERE key='last_collected_date';")
if [ "$NEW_KEY" -ge 1 ] && [ "$OLD_KEY" -eq 0 ]; then
    echo "  PASS: watermark key renamed to 'last_collected_date:claude'"
else
    echo "  FAIL: watermark key migration failed (new=$NEW_KEY, old=$OLD_KEY)"
    exit 1
fi

# --- Test 14: Codex reasoning tokens are not double-counted ---
echo "[14/18] Testing codex reasoning tokens are not double-counted..."
# reasoningOutputTokens is a subset of outputTokens (totalTokens == inputTokens + outputTokens),
# so it must not be added on top. Jan 15 gpt-test-model: output=100, reasoning=20 -> expect 100.
CODEX_OUT=$(sqlite3 "$DB" "SELECT output_tokens FROM daily_usage WHERE provider='codex' AND date='2026-01-15' AND model='gpt-test-model';")
if [ "$CODEX_OUT" -eq 100 ]; then
    echo "  PASS: output_tokens = 100 (reasoning not added twice)"
else
    echo "  FAIL: Expected output_tokens 100, got $CODEX_OUT"
    exit 1
fi

# --- Test 15: Oversized rollout files are warned about ---
echo "[15/18] Testing oversized rollout warning..."
# @ccusage/codex silently skips rollout files it cannot read, returning exit 0
# with that session's usage missing entirely. Warn so the gap is visible.
mkdir -p "$HOME/.codex/sessions/2026/01/15"
BIG_ROLLOUT="$HOME/.codex/sessions/2026/01/15/rollout-2026-01-15T00-00-00-deadbeef.jsonl"
head -c 4096 /dev/zero > "$BIG_ROLLOUT"
WARN_OUT=$(cd "$REPO_DIR" && CODEX_ROLLOUT_WARN_BYTES=1024 bash -c '
    source lib/claude-cost-common.sh
    source lib/fetchers/codex.sh
    fetch_codex "" "2026-01-16" >/dev/null' 2>&1 || true)
if echo "$WARN_OUT" | grep -q 'WARN.*rollout-2026-01-15T00-00-00-deadbeef.jsonl'; then
    echo "  PASS: oversized rollout warning emitted"
else
    echo "  FAIL: expected WARN naming the oversized rollout, got: $WARN_OUT"
    exit 1
fi

# A rollout under the threshold must stay silent (no false alarms).
rm -f "$BIG_ROLLOUT"
head -c 100 /dev/zero > "$BIG_ROLLOUT"
QUIET_OUT=$(cd "$REPO_DIR" && CODEX_ROLLOUT_WARN_BYTES=1024 bash -c '
    source lib/claude-cost-common.sh
    source lib/fetchers/codex.sh
    fetch_codex "" "2026-01-16" >/dev/null' 2>&1 || true)
if echo "$QUIET_OUT" | grep -q 'WARN'; then
    echo "  FAIL: warned about an under-threshold rollout: $QUIET_OUT"
    exit 1
else
    echo "  PASS: no warning for under-threshold rollout"
fi

# --- Tests 16-17: litellm + openwebui providers (isolated environment) ---
echo "[16/18] Testing litellm + openwebui collection..."

HIKARI_DIR="$TEST_DIR/hikari"
export HOME="$HIKARI_DIR/home"
export XDG_CONFIG_HOME="$HIKARI_DIR/config"
mkdir -p "$HOME/.local/share/claude-cost/logs"
mkdir -p "$XDG_CONFIG_HOME/claude-cost"

WEBUI_DB="$HIKARI_DIR/webui.db"
cat > "$XDG_CONFIG_HOME/claude-cost/config" <<EOF
TIMEZONE="UTC"
ENABLED_PROVIDERS="litellm openwebui"
LITELLM_DB_CONTAINER="litellm-db"
LITELLM_DB_USER="litellm"
LITELLM_DB_NAME="litellm"
OPENWEBUI_DB="$WEBUI_DB"
EOF

# Mock docker: stand in for `docker exec litellm-db psql ... -t -A -F<tab>`.
# Includes a blank trailing line, as psql -t emits, to exercise the awk guard.
cat > "$MOCK_BIN/docker" <<'MOCK'
#!/bin/bash
printf '2026-01-15\tqwen-tw\t100\t200\n2026-01-16\tclaude-sonnet-5\t300\t400\n\n'
MOCK
chmod +x "$MOCK_BIN/docker"

# Open WebUI database: two assistant messages on Jan 15 for the same model
# (must aggregate), one on Jan 16, plus a user row with no usage (must be ignored).
sqlite3 "$WEBUI_DB" <<'SQL'
CREATE TABLE chat_message (
    id TEXT, chat_id TEXT, user_id TEXT, role TEXT, content TEXT,
    model_id TEXT, usage TEXT, created_at INTEGER
);
INSERT INTO chat_message VALUES
  ('m1','c1','u1','assistant','hi','qwen-unc:latest',
   '{"input_tokens":120,"prompt_tokens":50,"output_tokens":30,"completion_tokens":10}',
   strftime('%s','2026-01-15 12:00:00')),
  ('m2','c1','u1','assistant','hi','qwen-unc:latest',
   '{"input_tokens":70,"prompt_tokens":30,"output_tokens":15,"completion_tokens":5}',
   strftime('%s','2026-01-15 18:00:00')),
  ('m3','c2','u1','assistant','hi','qwen-tw',
   '{"input_tokens":50,"prompt_tokens":20,"output_tokens":9,"completion_tokens":3}',
   strftime('%s','2026-01-16 09:00:00')),
  ('m4','c2','u1','user','ask',NULL,NULL,strftime('%s','2026-01-16 08:59:00'));
SQL

HIKARI_DB="$HOME/.local/share/claude-cost/usage.db"
bash "$REPO_DIR/bin/claude-cost-collect"

LITELLM_ROWS=$(sqlite3 "$HIKARI_DB" "SELECT COUNT(*) FROM daily_usage WHERE provider='litellm';")
OWUI_ROWS=$(sqlite3 "$HIKARI_DB" "SELECT COUNT(*) FROM daily_usage WHERE provider='openwebui';")
if [ "$LITELLM_ROWS" -eq 2 ] && [ "$OWUI_ROWS" -eq 2 ]; then
    echo "  PASS: 2 litellm + 2 openwebui rows inserted"
else
    echo "  FAIL: Expected 2 litellm + 2 openwebui rows, got $LITELLM_ROWS + $OWUI_ROWS"
    sqlite3 "$HIKARI_DB" "SELECT * FROM daily_usage;"
    exit 1
fi

# prompt_tokens/completion_tokens (not input_tokens/output_tokens), aggregated
# per day, with the `:latest` tag stripped from model_id.
OWUI_JAN15=$(sqlite3 "$HIKARI_DB" "SELECT input_tokens || '/' || output_tokens FROM daily_usage WHERE provider='openwebui' AND date='2026-01-15' AND model='qwen-unc';")
if [ "$OWUI_JAN15" = "80/15" ]; then
    echo "  PASS: openwebui Jan 15 aggregates to 80/15 for model 'qwen-unc'"
else
    echo "  FAIL: Expected 80/15 for qwen-unc on Jan 15, got '$OWUI_JAN15'"
    sqlite3 "$HIKARI_DB" "SELECT * FROM daily_usage WHERE provider='openwebui';"
    exit 1
fi

# --- Test 17: idempotent re-run, watermarks advanced, report survives $0 cost ---
echo "[17/18] Testing hikari providers re-run + watermarks + zero-cost report..."
bash "$REPO_DIR/bin/claude-cost-collect"
HIKARI_ROWS=$(sqlite3 "$HIKARI_DB" "SELECT COUNT(*) FROM daily_usage;")
LITELLM_WM=$(sqlite3 "$HIKARI_DB" "SELECT value FROM collect_metadata WHERE key='last_collected_date:litellm';")
OWUI_WM=$(sqlite3 "$HIKARI_DB" "SELECT value FROM collect_metadata WHERE key='last_collected_date:openwebui';")
if [ "$HIKARI_ROWS" -eq 4 ] && [ "$LITELLM_WM" = "2026-01-16" ] && [ "$OWUI_WM" = "2026-01-16" ]; then
    echo "  PASS: still 4 rows; both watermarks at 2026-01-16"
else
    echo "  FAIL: rows=$HIKARI_ROWS litellm_wm='$LITELLM_WM' openwebui_wm='$OWUI_WM'"
    exit 1
fi

# LiteLLM's `spend` is a cloud-equivalent figure, not money spent, so it must
# never reach cost_usd — every self-hosted row stays at 0.
HIKARI_COST=$(sqlite3 "$HIKARI_DB" "SELECT COALESCE(SUM(cost_usd), 0) FROM daily_usage;")
if [ "$HIKARI_COST" = "0" ] || [ "$HIKARI_COST" = "0.0" ]; then
    echo "  PASS: all self-hosted rows have cost_usd = 0"
else
    echo "  FAIL: expected cost_usd sum 0, got $HIKARI_COST"
    exit 1
fi

HIKARI_REPORT=$(bash "$REPO_DIR/bin/claude-cost-report" daily --last 9999 2>&1)
if echo "$HIKARI_REPORT" | grep -q 'qwen-unc' && echo "$HIKARI_REPORT" | grep -q 'qwen-tw'; then
    echo "  PASS: daily report renders with all costs at \$0"
else
    echo "  FAIL: daily report missing expected models"
    echo "$HIKARI_REPORT"
    exit 1
fi

# --- Test 18: cloud-equivalent cost is reported without touching cost_usd ---
echo "[18/18] Testing cloud-equivalent cost reporting..."

# Rates are $/M tokens. litellm 2026-01-16 claude-sonnet-5: 300 in / 400 out.
#   claude-* → 1.00/5.00  =>  300*1.00/1e6 + 400*5.00/1e6 = 0.0023
# openwebui 2026-01-15 qwen-unc: 80 in / 15 out.
#   qwen*    → 0.07/0.67  =>  80*0.07/1e6 + 15*0.67/1e6   = 0.0000156
EQ_ROW_COST=$(CLOUD_RATES="claude-*:1.00:5.00 qwen*:0.07:0.67" \
    sqlite3 "$HIKARI_DB" "SELECT ROUND(SUM(input_tokens * 1.00 + output_tokens * 5.00) / 1000000.0, 6) FROM daily_usage WHERE model='claude-sonnet-5';")

EQ_REPORT=$(CLOUD_RATES="claude-*:1.00:5.00 qwen*:0.07:0.67" CLOUD_RATE_DEFAULT="0.07:0.67" \
    bash "$REPO_DIR/bin/claude-cost-report" daily --last 9999 2>&1)
# The cost column carries the equivalent, marked, instead of a second column.
if echo "$EQ_REPORT" | grep -q '(eq.)' && ! echo "$EQ_REPORT" | grep -q 'cloud_eq'; then
    echo "  PASS: daily folds the equivalent into cost, marked (eq.) (row eq=$EQ_ROW_COST)"
else
    echo "  FAIL: daily should show a marked cost column and no separate cloud_eq"
    echo "$EQ_REPORT"
    exit 1
fi

# A genuinely $0 cloud row must stay unmarked — zero is not the same as unknown.
# The claude/codex rows in the main DB are real costs, so none may gain "(eq.)".
CLOUD_ONLY=$(HOME="$TEST_DIR/home" XDG_CONFIG_HOME="$TEST_DIR/config" \
    CLOUD_RATES="claude-*:1.00:5.00" CLOUD_RATE_DEFAULT="0.07:0.67" \
    bash "$REPO_DIR/bin/claude-cost-report" daily --last 9999 --provider claude 2>&1)
if echo "$CLOUD_ONLY" | grep -q '(eq.)'; then
    echo "  FAIL: real cloud-provider costs were marked as estimates"
    echo "$CLOUD_ONLY"
    exit 1
else
    echo "  PASS: cloud-provider rows keep their real cost unmarked"
fi

# The headline number: summary must show a non-zero equivalent and the savings,
# while real spend stays $0.
EQ_SUMMARY=$(CLOUD_RATES="claude-*:1.00:5.00 qwen*:0.07:0.67" CLOUD_RATE_DEFAULT="0.07:0.67" \
    bash "$REPO_DIR/bin/claude-cost-report" summary 2>&1)
if echo "$EQ_SUMMARY" | grep -q 'cloud_eq' \
   && echo "$EQ_SUMMARY" | grep -q 'saved' \
   && echo "$EQ_SUMMARY" | grep -qE '\$0\.0[0-9]'; then
    echo "  PASS: summary reports cloud_eq + saved"
else
    echo "  FAIL: summary missing cloud-equivalent columns"
    echo "$EQ_SUMMARY"
    exit 1
fi

# cost_usd itself must be untouched — the equivalent figure is report-only.
EQ_STORED=$(sqlite3 "$HIKARI_DB" "SELECT COALESCE(SUM(cost_usd), 0) FROM daily_usage;")
if [ "$EQ_STORED" = "0" ] || [ "$EQ_STORED" = "0.0" ]; then
    echo "  PASS: stored cost_usd still 0 (equivalent cost is not persisted)"
else
    echo "  FAIL: cost_usd was modified: $EQ_STORED"
    exit 1
fi

# With no rates configured — the Mac case — reports must be byte-identical to before.
PLAIN_BEFORE=$(bash "$REPO_DIR/bin/claude-cost-report" daily --last 9999 2>&1)
if echo "$PLAIN_BEFORE" | grep -q 'cloud_eq'; then
    echo "  FAIL: cloud_eq column appeared without CLOUD_RATES set"
    echo "$PLAIN_BEFORE"
    exit 1
else
    echo "  PASS: no cloud_eq column when CLOUD_RATES is unset"
fi

# A malformed rate entry must warn and be skipped, not break the SQL.
BAD_OUT=$(CLOUD_RATES="qwen*:abc:0.67" bash "$REPO_DIR/bin/claude-cost-report" summary 2>&1)
if echo "$BAD_OUT" | grep -q "WARN: ignoring malformed CLOUD_RATES" && echo "$BAD_OUT" | grep -q 'Overview'; then
    echo "  PASS: malformed rate warns and the report still renders"
else
    echo "  FAIL: malformed rate handling"
    echo "$BAD_OUT"
    exit 1
fi

echo ""
echo "=== All 18 tests passed ==="
