#!/bin/bash
# lib/fetchers/codex.sh — Fetcher for OpenAI Codex usage via @ccusage/codex

# fetch_codex <last_watermark> <yesterday>
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
fetch_codex() {
    local last="$1"
    local yesterday="$2"
    local tmpfile
    tmpfile=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    local offline_flag=""
    if [[ "${CODEX_OFFLINE:-1}" == "1" ]]; then
        offline_flag="--offline"
    fi

    # shellcheck disable=SC2086
    if ! npx -y "@ccusage/codex@${CCUSAGE_CODEX_VERSION}" daily --json --timezone "$TIMEZONE" $offline_flag > "$tmpfile" 2>&2; then
        echo "ERROR: @ccusage/codex failed" >&2
        return 1
    fi

    if ! jq empty "$tmpfile" 2>/dev/null; then
        echo "ERROR: @ccusage/codex output is not valid JSON" >&2
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
           (($m.outputTokens // 0) + ($m.reasoningOutputTokens // 0)),
           0,
           ($m.cachedInputTokens // 0),
           (if $day_total > 0 then $m.totalTokens * $day_cost / $day_total else 0 end)]
        | @tsv
    ' "$tmpfile"
}
