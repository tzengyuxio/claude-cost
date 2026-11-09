#!/bin/bash
# lib/fetchers/claude.sh — Fetcher for Claude Code usage via ccusage
#
# One machine can hold more than one Claude subscription: a directory tree can
# set CLAUDE_CONFIG_DIR to a separate config dir, and that account's session
# JSONL lands there instead of ~/.claude. ccusage reads whatever
# CLAUDE_CONFIG_DIR points at, so each account is fetched by pointing the same
# code at a different dir and labelling the rows with a different provider —
# see CLAUDE_EXTRA_ACCOUNTS at the bottom of this file.

# _ccusage <config_dir> <outfile> <errfile> <ccusage args...>
# Runs ccusage under the given config dir (empty ⇒ ccusage's default).
_ccusage() {
    local config_dir="$1" out="$2" err="$3"
    shift 3
    # Subshell so the CLAUDE_CONFIG_DIR override does not leak into the next provider.
    (
        if [[ -n "$config_dir" ]]; then export CLAUDE_CONFIG_DIR="$config_dir"; fi
        npx "ccusage@${CCUSAGE_VERSION}" "$@"
    ) > "$out" 2> "$err"
}

# _retry_once <label> <cmd> [args...]
# Runs a whole fetch, retrying once when it fails. Both failures it guards are
# usually gone on a second pass: ccusage lists the session JSONL up front and
# reads them later, so a session deleted in between (e.g. by another Claude Code
# process) aborts the run with ENOENT; and a failed price download makes
# _check_priced reject the rows.
_retry_once() {
    local label="$1" out attempt
    shift
    for attempt in 1 2; do
        if out=$("$@"); then
            if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
            return 0
        fi
        if [[ $attempt -eq 1 ]]; then echo "WARN: ${label} failed, retrying once" >&2; fi
    done
    return 1
}

# _check_priced <label> <tsv>
# Fails when a row carries tokens but costs $0. ccusage prices from a table it
# downloads at run time; when the download fails it falls back to the table
# bundled with the pinned version, which lacks newer models, and still exits 0
# without a warning. Such a row would be written once and never revisited, so it
# is refused and the watermark stays put. Both TSV shapes (daily and hourly) keep
# the four token columns at 4-7 and the cost at 8.
_check_priced() {
    local unpriced
    unpriced=$(awk -F'\t' '($4 + $5 + $6 + $7) > 0 && $8 == 0 { print "  | " $1 " " $2 " " $3 }' <<< "$2")
    [[ -z "$unpriced" ]] && return 0
    echo "ERROR: $1 priced tokens at \$0 (price download failed?)" >&2
    echo "$unpriced" >&2
    return 1
}

# _claude_daily <provider> <config_dir> <last_watermark> <yesterday>
# config_dir empty ⇒ ccusage's own default (~/.claude).
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
_claude_daily() { _retry_once "ccusage daily (${1})" _claude_daily_once "$@"; }

_claude_daily_once() {
    local provider="$1"
    local config_dir="$2"
    local last="$3"
    local yesterday="$4"
    local tmpfile errfile
    tmpfile=$(mktemp)
    errfile=$(mktemp)

    if ! _ccusage "$config_dir" "$tmpfile" "$errfile" daily --json --timezone "$TIMEZONE"; then
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

    local rows
    rows=$(jq -r --arg yesterday "$yesterday" --arg last "${last:-}" --arg provider "$provider" '
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
    ' "$tmpfile") || { rm -f "$tmpfile"; return 1; }
    rm -f "$tmpfile"
    _check_priced "ccusage (${provider})" "$rows" || return 1
    if [[ -n "$rows" ]]; then printf '%s\n' "$rows"; fi
}

# _claude_hourly <provider> <config_dir> <last_watermark> <yesterday>
# Calls ccusage blocks -n 1 (one-hour buckets), converts UTC startTime to
# local (TIMEZONE) date+hour via jq strflocaltime, filters out gap/active blocks.
# Outputs TSV: date, hour, provider, input, output, cache_creation, cache_read, cost, entries
# Runs online (no --offline) so ccusage looks up the pricing table and fills
# costUSD for every block — matching the daily fetch. With --offline, blocks
# reports only the sparse pre-embedded JSONL costs, leaving most hours at $0.
_claude_hourly() { _retry_once "ccusage blocks (${1} hourly)" _claude_hourly_once "$@"; }

_claude_hourly_once() {
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

    # shellcheck disable=SC2086  # intentional word-splitting for optional flag
    if ! _ccusage "$config_dir" "$tmpfile" "$errfile" blocks --json -n 1 \
        --timezone "$TIMEZONE" $since_args; then
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
    local rows
    rows=$(TZ="$TIMEZONE" jq -r --arg yesterday "$yesterday" --arg last "${last:-}" --arg provider "$provider" '
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
    ' "$tmpfile") || { rm -f "$tmpfile"; return 1; }
    rm -f "$tmpfile"
    _check_priced "ccusage blocks (${provider} hourly)" "$rows" || return 1
    if [[ -n "$rows" ]]; then printf '%s\n' "$rows"; fi
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
