#!/bin/bash
# lib/fetchers/claude.sh — Fetcher for Claude Code usage via ccusage
#
# One machine can hold more than one Claude subscription: a directory tree can
# set CLAUDE_CONFIG_DIR to a separate config dir, and that account's session
# JSONL lands there instead of ~/.claude. ccusage reads whatever
# CLAUDE_CONFIG_DIR points at, so each account is fetched by pointing the same
# code at a different dir and labelling the rows with a different provider —
# see CLAUDE_EXTRA_ACCOUNTS at the bottom of this file.

# _claude_daily <provider> <config_dir> <last_watermark> <yesterday>
# config_dir empty ⇒ ccusage's own default (~/.claude).
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
_claude_daily() {
    local provider="$1"
    local config_dir="$2"
    local last="$3"
    local yesterday="$4"
    local tmpfile errfile
    tmpfile=$(mktemp)
    errfile=$(mktemp)

    # Subshell so the CLAUDE_CONFIG_DIR override does not leak into the next provider.
    if ! (
        if [[ -n "$config_dir" ]]; then export CLAUDE_CONFIG_DIR="$config_dir"; fi
        npx "ccusage@${CCUSAGE_VERSION}" daily --json --timezone "$TIMEZONE"
    ) > "$tmpfile" 2> "$errfile"; then
        echo "ERROR: ccusage (${provider}) failed" >&2
        [[ -s "$errfile" ]] && sed 's/^/  | /' "$errfile" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    rm -f "$errfile"

    if ! jq empty "$tmpfile" 2>/dev/null; then
        echo "ERROR: ccusage (${provider}) output is not valid JSON" >&2
        head -c 200 "$tmpfile" | sed 's/^/  | /' >&2
        rm -f "$tmpfile"
        return 1
    fi

    jq -r --arg yesterday "$yesterday" --arg last "${last:-}" --arg provider "$provider" '
        .daily[]
        | select(.date <= $yesterday)
        | select($last == "" or .date > $last)
        | .date as $d
        | .modelBreakdowns[]
        | [$d, $provider, .modelName,
           (.inputTokens // 0),
           (.outputTokens // 0),
           (.cacheCreationTokens // 0),
           (.cacheReadTokens // 0),
           (.cost // 0)]
        | @tsv
    ' "$tmpfile"
    rm -f "$tmpfile"
}

# _claude_hourly <provider> <config_dir> <last_watermark> <yesterday>
# Calls ccusage blocks -n 1 (one-hour buckets), converts UTC startTime to
# local (TIMEZONE) date+hour via jq strflocaltime, filters out gap/active blocks.
# Outputs TSV: date, hour, provider, input, output, cache_creation, cache_read, cost, entries
# Runs online (no --offline) so ccusage looks up the pricing table and fills
# costUSD for every block — matching the daily fetch. With --offline, blocks
# reports only the sparse pre-embedded JSONL costs, leaving most hours at $0.
_claude_hourly() {
    local provider="$1"
    local config_dir="$2"
    local last="$3"
    local yesterday="$4"
    local tmpfile errfile since_arg
    tmpfile=$(mktemp)
    errfile=$(mktemp)

    # ccusage blocks --since takes YYYYMMDD. If no watermark, omit to fetch all.
    local since_args=""
    if [[ -n "$last" ]]; then
        since_arg="${last//-/}"
        since_args="--since $since_arg"
    fi

    if ! (
        if [[ -n "$config_dir" ]]; then export CLAUDE_CONFIG_DIR="$config_dir"; fi
        # shellcheck disable=SC2086  # intentional word-splitting for optional flag
        npx "ccusage@${CCUSAGE_VERSION}" blocks --json -n 1 \
            --timezone "$TIMEZONE" $since_args
    ) > "$tmpfile" 2> "$errfile"; then
        echo "ERROR: ccusage blocks (${provider} hourly) failed" >&2
        [[ -s "$errfile" ]] && sed 's/^/  | /' "$errfile" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    rm -f "$errfile"

    if ! jq empty "$tmpfile" 2>/dev/null; then
        echo "ERROR: ccusage blocks (${provider} hourly) output is not valid JSON" >&2
        head -c 200 "$tmpfile" | sed 's/^/  | /' >&2
        rm -f "$tmpfile"
        return 1
    fi

    # strflocaltime uses $TZ; export so the subshell inherits it.
    TZ="$TIMEZONE" jq -r --arg yesterday "$yesterday" --arg last "${last:-}" --arg provider "$provider" '
        .blocks[]
        | select(.isGap == false and .isActive == false)
        | (.startTime | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $epoch
        | ($epoch | strflocaltime("%Y-%m-%d")) as $d
        | ($epoch | strflocaltime("%H") | tonumber) as $h
        | select($d <= $yesterday)
        | select($last == "" or $d > $last)
        | [$d, $h, $provider,
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

# The default account: ccusage's own config-dir resolution, provider "claude".
fetch_claude() { _claude_daily claude "" "$1" "$2"; }
fetch_claude_hourly() { _claude_hourly claude "" "$1" "$2"; }

# Additional subscriptions, from CLAUDE_EXTRA_ACCOUNTS="<provider>:<config-dir> ...".
# Each entry defines fetch_<provider> / fetch_<provider>_hourly reading that dir,
# so adding the provider to ENABLED_PROVIDERS is all it takes to collect it. Rows
# carry the given provider name, so the reports can split or combine the accounts.
for _cc_acct in ${CLAUDE_EXTRA_ACCOUNTS:-}; do
    _cc_name="${_cc_acct%%:*}"
    _cc_dir="${_cc_acct#*:}"
    if [[ "$_cc_dir" == "$_cc_acct" || -z "$_cc_dir" ]] \
        || [[ ! "$_cc_name" =~ ^[A-Za-z0-9_-]+$ ]] || [[ "$_cc_dir" == *"'"* ]]; then
        echo "WARN: ignoring malformed CLAUDE_EXTRA_ACCOUNTS entry '$_cc_acct' (want provider:config-dir)" >&2
        continue
    fi
    eval "fetch_${_cc_name}() { _claude_daily '${_cc_name}' '${_cc_dir}' \"\$1\" \"\$2\"; }"
    eval "fetch_${_cc_name}_hourly() { _claude_hourly '${_cc_name}' '${_cc_dir}' \"\$1\" \"\$2\"; }"
done
unset _cc_acct _cc_name _cc_dir
