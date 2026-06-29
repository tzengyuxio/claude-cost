#!/bin/bash
# lib/fetchers/claude.sh — Fetcher for Claude Code usage via ccusage

# fetch_claude <last_watermark> <yesterday>
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
fetch_claude() {
    local last="$1"
    local yesterday="$2"
    local tmpfile errfile
    tmpfile=$(mktemp)
    errfile=$(mktemp)

    if ! npx "ccusage@${CCUSAGE_VERSION}" daily --json --timezone "$TIMEZONE" > "$tmpfile" 2> "$errfile"; then
        echo "ERROR: ccusage (claude) failed" >&2
        [[ -s "$errfile" ]] && sed 's/^/  | /' "$errfile" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    rm -f "$errfile"

    if ! jq empty "$tmpfile" 2>/dev/null; then
        echo "ERROR: ccusage (claude) output is not valid JSON" >&2
        head -c 200 "$tmpfile" | sed 's/^/  | /' >&2
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

# fetch_claude_hourly <last_watermark> <yesterday>
# Calls ccusage blocks -n 1 (one-hour buckets), converts UTC startTime to
# local (TIMEZONE) date+hour via jq strflocaltime, filters out gap/active blocks.
# Outputs TSV: date, hour, provider, input, output, cache_creation, cache_read, cost, entries
# Runs online (no --offline) so ccusage looks up the pricing table and fills
# costUSD for every block — matching fetch_claude (daily). With --offline, blocks
# reports only the sparse pre-embedded JSONL costs, leaving most hours at $0.
fetch_claude_hourly() {
    local last="$1"
    local yesterday="$2"
    local tmpfile errfile since_arg
    tmpfile=$(mktemp)
    errfile=$(mktemp)

    # ccusage blocks --since takes YYYYMMDD. If no watermark, omit to fetch all.
    local since_args=""
    if [[ -n "$last" ]]; then
        since_arg="${last//-/}"
        since_args="--since $since_arg"
    fi

    # shellcheck disable=SC2086  # intentional word-splitting for optional flag
    if ! npx "ccusage@${CCUSAGE_VERSION}" blocks --json -n 1 \
            --timezone "$TIMEZONE" $since_args > "$tmpfile" 2> "$errfile"; then
        echo "ERROR: ccusage blocks (claude hourly) failed" >&2
        [[ -s "$errfile" ]] && sed 's/^/  | /' "$errfile" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    rm -f "$errfile"

    if ! jq empty "$tmpfile" 2>/dev/null; then
        echo "ERROR: ccusage blocks (claude hourly) output is not valid JSON" >&2
        head -c 200 "$tmpfile" | sed 's/^/  | /' >&2
        rm -f "$tmpfile"
        return 1
    fi

    # strflocaltime uses $TZ; export so the subshell inherits it.
    TZ="$TIMEZONE" jq -r --arg yesterday "$yesterday" --arg last "${last:-}" '
        .blocks[]
        | select(.isGap == false and .isActive == false)
        | (.startTime | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $epoch
        | ($epoch | strflocaltime("%Y-%m-%d")) as $d
        | ($epoch | strflocaltime("%H") | tonumber) as $h
        | select($d <= $yesterday)
        | select($last == "" or $d > $last)
        | [$d, $h, "claude",
           (.tokenCounts.inputTokens // 0),
           (.tokenCounts.outputTokens // 0),
           (.tokenCounts.cacheCreationInputTokens // 0),
           (.tokenCounts.cacheReadInputTokens // 0),
           (.costUSD // 0),
           (.entries // 0)]
        | @tsv
    ' "$tmpfile"
    rm -f "$tmpfile"
}
