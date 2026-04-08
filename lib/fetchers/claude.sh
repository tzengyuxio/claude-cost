#!/bin/bash
# lib/fetchers/claude.sh — Fetcher for Claude Code usage via ccusage

# fetch_claude <last_watermark> <yesterday>
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
fetch_claude() {
    local last="$1"
    local yesterday="$2"
    local tmpfile
    tmpfile=$(mktemp)

    if ! npx "ccusage@${CCUSAGE_VERSION}" daily --json --timezone "$TIMEZONE" > "$tmpfile" 2>/dev/null; then
        echo "ERROR: ccusage (claude) failed" >&2
        rm -f "$tmpfile"
        return 1
    fi

    if ! jq empty "$tmpfile" 2>/dev/null; then
        echo "ERROR: ccusage (claude) output is not valid JSON" >&2
        rm -f "$tmpfile"
        return 1
    fi

    jq -r --arg yesterday "$yesterday" --arg last "${last:-}" '
        .daily[]
        | select(.date <= $yesterday)
        | select($last == "" or .date > $last)
        | .date as $d
        | .modelBreakdowns[]
        | [$d, "claude", .modelName,
           (.inputTokens // 0),
           (.outputTokens // 0),
           (.cacheCreationTokens // 0),
           (.cacheReadTokens // 0),
           (.cost // 0)]
        | @tsv
    ' "$tmpfile"
    rm -f "$tmpfile"
}
