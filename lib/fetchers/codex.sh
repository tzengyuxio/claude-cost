#!/bin/bash
# lib/fetchers/codex.sh — Fetcher for OpenAI Codex usage via @ccusage/codex

# fetch_codex <last_watermark> <yesterday>
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
# @ccusage/codex silently skips rollout files it cannot read (observed between
# 202MB and 693MB, likely Node's max string length), exiting 0 with that
# session's usage missing entirely. Warn so the gap shows up in the log instead
# of being discovered later as an unexplained dip in the numbers.
warn_oversized_rollouts() {
    local sessions_dir="${CODEX_HOME:-$HOME/.codex}/sessions"
    local limit="${CODEX_ROLLOUT_WARN_BYTES:-200000000}"
    [[ -d "$sessions_dir" ]] || return 0

    find "$sessions_dir" -type f -name '*.jsonl' -size +$((limit / 512)) 2>/dev/null \
        | while read -r rollout; do
            echo "WARN: rollout exceeds ${limit} bytes and may be silently skipped by @ccusage/codex: ${rollout}" >&2
        done
}

fetch_codex() {
    local last="$1"
    local yesterday="$2"
    local tmpfile errfile
    tmpfile=$(mktemp)
    errfile=$(mktemp)

    warn_oversized_rollouts

    local offline_flag=""
    if [[ "${CODEX_OFFLINE:-1}" == "1" ]]; then
        offline_flag="--offline"
    fi

    # shellcheck disable=SC2086
    if ! npx -y "@ccusage/codex@${CCUSAGE_CODEX_VERSION}" daily --json --timezone "$TIMEZONE" $offline_flag > "$tmpfile" 2> "$errfile"; then
        echo "ERROR: @ccusage/codex failed" >&2
        [[ -s "$errfile" ]] && sed 's/^/  | /' "$errfile" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    rm -f "$errfile"

    if ! jq empty "$tmpfile" 2>/dev/null; then
        echo "ERROR: @ccusage/codex output is not valid JSON" >&2
        head -c 200 "$tmpfile" | sed 's/^/  | /' >&2
        rm -f "$tmpfile"
        return 1
    fi

    jq -r --arg yesterday "$yesterday" --arg last "${last:-}" '
        .daily[]
        | select(
            (.date | strptime("%b %d, %Y") | strftime("%Y-%m-%d")) <= $yesterday
            and ($last == "" or (.date | strptime("%b %d, %Y") | strftime("%Y-%m-%d")) > $last)
          )
        | (.date | strptime("%b %d, %Y") | strftime("%Y-%m-%d")) as $d
        | .costUSD as $day_cost
        | .totalTokens as $day_total
        | .models | to_entries[]
        | .key as $model
        | .value as $m
        | [$d, "codex", $model,
           (($m.inputTokens // 0) - ($m.cachedInputTokens // 0)),
           ($m.outputTokens // 0),
           0,
           ($m.cachedInputTokens // 0),
           (if $day_total > 0 then $m.totalTokens * $day_cost / $day_total else 0 end)]
        | @tsv
    ' "$tmpfile"
    rm -f "$tmpfile"
}
