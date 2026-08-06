#!/bin/bash
# lib/fetchers/openwebui.sh — Fetcher for Open WebUI usage (SQLite webui.db)
#
# Open WebUI talks to Ollama directly, bypassing LiteLLM, so this usage never
# reaches LiteLLM_SpendLogs — hence a second fetcher. Messages live in the
# `chat_message` table (older versions embedded them in `chat` as JSON);
# `usage` is a JSON string and `created_at` is a unix epoch in seconds.
#
# Token fields: `usage` carries two pairs — input_tokens/output_tokens and
# prompt_tokens/completion_tokens — and the former run roughly 2x the latter.
# We use prompt_tokens/completion_tokens because LiteLLM_SpendLogs uses those
# same names, so numbers stay comparable across the two providers.

# fetch_openwebui <last_watermark> <yesterday>
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
fetch_openwebui() {
    local last="$1"
    local yesterday="$2"
    local tmpfile errfile sql shift_min

    if [[ ! -r "${OPENWEBUI_DB}" ]]; then
        echo "ERROR: openwebui DB not readable: ${OPENWEBUI_DB}" >&2
        return 1
    fi

    tmpfile=$(mktemp)
    errfile=$(mktemp)

    # created_at is epoch seconds; bucket it in TIMEZONE, not the system zone
    # ('localtime'), otherwise dates drift out of line with the litellm fetcher
    # whenever the host runs in a different zone (hikari is UTC, TIMEZONE is not).
    shift_min=$(tz_offset_minutes "${TIMEZONE:-UTC}")

    sql="SELECT date(created_at, 'unixepoch', '${shift_min} minutes') AS d,
                model_id,
                COALESCE(SUM(json_extract(usage, '\$.prompt_tokens')), 0),
                COALESCE(SUM(json_extract(usage, '\$.completion_tokens')), 0)
         FROM chat_message
         WHERE role = 'assistant' AND usage IS NOT NULL
         GROUP BY d, model_id
         HAVING d <= '${yesterday}'"
    if [[ -n "$last" ]]; then
        sql="${sql} AND d > '${last}'"
    fi
    sql="${sql} ORDER BY d, model_id;"

    if ! sqlite3 -readonly -separator $'\t' "${OPENWEBUI_DB}" "$sql" > "$tmpfile" 2> "$errfile"; then
        echo "ERROR: openwebui sqlite query failed" >&2
        [[ -s "$errfile" ]] && sed 's/^/  | /' "$errfile" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    rm -f "$errfile"

    # model_id holds the raw Ollama name (`qwen-unc:latest`); strip the `:latest`
    # tag so it lines up with the litellm fetcher's model_group naming.
    awk -F'\t' 'NF >= 4 && $1 != "" && $2 != "" {
        sub(/:latest$/, "", $2)
        printf "%s\topenwebui\t%s\t%s\t%s\t0\t0\t0\n", $1, $2, $3, $4
    }' "$tmpfile"
    rm -f "$tmpfile"
}
