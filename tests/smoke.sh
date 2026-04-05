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
EOF

# --- Create mock ccusage that returns known JSON ---
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/npx" <<'MOCK'
#!/bin/bash
# Mock npx: if called with ccusage, output test data
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

# --- Test 1: First collection ---
echo ""
echo "[1/5] Testing first collection..."
bash "$REPO_DIR/bin/claude-cost-collect"
ROWS=$(sqlite3 "$HOME/.local/share/claude-cost/usage.db" "SELECT COUNT(*) FROM daily_usage;")
if [ "$ROWS" -eq 3 ]; then
    echo "  PASS: 3 rows inserted (2 days, 3 model entries)"
else
    echo "  FAIL: Expected 3 rows, got $ROWS"
    exit 1
fi

# --- Test 2: Idempotent re-run ---
echo "[2/5] Testing idempotent re-run..."
bash "$REPO_DIR/bin/claude-cost-collect"
ROWS2=$(sqlite3 "$HOME/.local/share/claude-cost/usage.db" "SELECT COUNT(*) FROM daily_usage;")
if [ "$ROWS2" -eq 3 ]; then
    echo "  PASS: Still 3 rows (idempotent)"
else
    echo "  FAIL: Expected 3 rows, got $ROWS2"
    exit 1
fi

# --- Test 3: Report summary ---
echo "[3/5] Testing report summary..."
OUTPUT=$(bash "$REPO_DIR/bin/claude-cost-report" summary 2>&1)
if echo "$OUTPUT" | grep -q '\$4.25'; then
    echo "  PASS: Total cost \$4.25 found in summary"
else
    echo "  FAIL: Expected \$4.25 in summary output"
    echo "$OUTPUT"
    exit 1
fi

# --- Test 4: Weekly report ---
echo "[4/5] Testing weekly report..."
WEEKLY_OUTPUT=$(bash "$REPO_DIR/bin/claude-cost-report" weekly --last 520 2>&1)
if echo "$WEEKLY_OUTPUT" | grep -q '2026-W03'; then
    echo "  PASS: ISO week 2026-W03 found in weekly report"
else
    echo "  FAIL: Expected 2026-W03 in weekly output"
    echo "$WEEKLY_OUTPUT"
    exit 1
fi

# --- Test 5: CSV export ---
echo "[5/5] Testing CSV export..."
CSV_FILE="$TEST_DIR/export.csv"
bash "$REPO_DIR/bin/claude-cost-report" csv --output "$CSV_FILE"
CSV_LINES=$(wc -l < "$CSV_FILE" | tr -d ' ')
if [ "$CSV_LINES" -eq 4 ]; then
    echo "  PASS: CSV has 4 lines (1 header + 3 data)"
else
    echo "  FAIL: Expected 4 CSV lines, got $CSV_LINES"
    exit 1
fi

echo ""
echo "=== All tests passed ==="
