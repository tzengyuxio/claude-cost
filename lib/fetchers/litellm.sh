#!/bin/bash
# lib/fetchers/litellm.sh — Fetcher for LiteLLM proxy usage (PostgreSQL SpendLogs)
#
# Data source is the `LiteLLM_SpendLogs` table in the litellm-db container. The
# host has no psql, so queries go through `docker exec`. Local inference has no
# prompt-cache concept, so cache_* is 0.
#
# cost is 0 too, deliberately. LiteLLM's `spend` column is NOT money spent: since
# 2026-08-06 its config prices tokens at what the same traffic would have cost
# against a hosted API (rows before that date are 0, as LiteLLM computes spend at
# write time and never backfills). `cost_usd` means real money in this schema, so
# a cloud-equivalent figure cannot share the column without making both meanings
# unreadable — it needs a column of its own before it can be collected.

# fetch_litellm <last_watermark> <yesterday>
# Outputs TSV: date, provider, model, input, output, cache_creation, cache_read, cost
fetch_litellm() {
    local last="$1"
    local yesterday="$2"
    local tmpfile errfile sql date_expr
    tmpfile=$(mktemp)
    errfile=$(mktemp)

    # startTime is a `timestamp without time zone` holding UTC, so it needs both
    # legs of the conversion: label it UTC, then shift into TIMEZONE.
    date_expr="(\"startTime\" AT TIME ZONE 'UTC' AT TIME ZONE '${TIMEZONE}')::date"

    # total_tokens > 0 drops failed/rate-limited requests, which are numerous and
    # carry an empty model field. model_group is the client-facing name
    # (`qwen-tw`); model is the backend name (`ollama_chat/qwen-tw:latest`).
    sql="SELECT to_char(${date_expr}, 'YYYY-MM-DD') AS d,
                COALESCE(NULLIF(model_group, ''), model) AS m,
                SUM(prompt_tokens)::bigint,
                SUM(completion_tokens)::bigint
         FROM \"LiteLLM_SpendLogs\"
         WHERE total_tokens > 0
           AND ${date_expr} <= DATE '${yesterday}'"
    if [[ -n "$last" ]]; then
        sql="${sql} AND ${date_expr} > DATE '${last}'"
    fi
    sql="${sql} GROUP BY d, m ORDER BY d, m;"

    if ! docker exec "${LITELLM_DB_CONTAINER}" \
            psql -U "${LITELLM_DB_USER}" -d "${LITELLM_DB_NAME}" \
            -t -A -F$'\t' -c "$sql" > "$tmpfile" 2> "$errfile"; then
        echo "ERROR: litellm psql query failed" >&2
        [[ -s "$errfile" ]] && sed 's/^/  | /' "$errfile" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    rm -f "$errfile"

    awk -F'\t' 'NF >= 4 && $1 != "" && $2 != "" {
        printf "%s\tlitellm\t%s\t%s\t%s\t0\t0\t0\n", $1, $2, $3, $4
    }' "$tmpfile"
    rm -f "$tmpfile"
}
