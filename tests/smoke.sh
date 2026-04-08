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
# Mock npx: dispatch to claude or codex mock based on arguments
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
echo "[1/9] Testing first collection (claude + codex)..."
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
echo "[2/9] Testing idempotent re-run..."
bash "$REPO_DIR/bin/claude-cost-collect"
ROWS2=$(sqlite3 "$DB" "SELECT COUNT(*) FROM daily_usage;")
if [ "$ROWS2" -eq 6 ]; then
    echo "  PASS: Still 6 rows (idempotent)"
else
    echo "  FAIL: Expected 6 rows, got $ROWS2"
    exit 1
fi

# --- Test 3: Report summary ---
echo "[3/9] Testing report summary (claude total \$4.25)..."
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
echo "[4/9] Testing weekly report..."
WEEKLY_OUTPUT=$(bash "$REPO_DIR/bin/claude-cost-report" weekly --last 520 2>&1)
if echo "$WEEKLY_OUTPUT" | grep -q '2026-W03'; then
    echo "  PASS: ISO week 2026-W03 found in weekly report"
else
    echo "  FAIL: Expected 2026-W03 in weekly output"
    echo "$WEEKLY_OUTPUT"
    exit 1
fi

# --- Test 5: CSV export ---
echo "[5/9] Testing CSV export..."
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
echo "[6/9] Testing codex rows in DB..."
CODEX_ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM daily_usage WHERE provider='codex';")
if [ "$CODEX_ROWS" -eq 3 ]; then
    echo "  PASS: 3 codex rows (jan15×1 + jan16×2)"
else
    echo "  FAIL: Expected 3 codex rows, got $CODEX_ROWS"
    exit 1
fi

# --- Test 7: Codex cost allocation for Jan 16 ---
echo "[7/9] Testing codex cost allocation for Jan 16..."
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
echo "[8/9] Testing summary contains 'Cost by Provider'..."
SUMMARY=$(bash "$REPO_DIR/bin/claude-cost-report" summary 2>&1)
if echo "$SUMMARY" | grep -q 'Cost by Provider'; then
    echo "  PASS: 'Cost by Provider' section found in summary"
else
    echo "  FAIL: 'Cost by Provider' not found in summary"
    echo "$SUMMARY"
    exit 1
fi

# --- Test 9: Migration from old schema ---
echo "[9/9] Testing schema migration from old (no provider column) schema..."

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

echo ""
echo "=== All 9 tests passed ==="
