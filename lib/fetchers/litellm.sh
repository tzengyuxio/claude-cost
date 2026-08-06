#!/bin/bash
# lib/fetchers/litellm.sh — Fetcher for LiteLLM proxy usage (PostgreSQL SpendLogs)
#
# Data source is the `LiteLLM_SpendLogs` table in the litellm-db container. The
# host has no psql, so queries go through `docker exec`. Local inference has no
# prompt-cache concept and LiteLLM is configured with zero per-token costs
# (raising them would break its budget accounting), so cache_* and cost are 0.

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
                SUM(completion_tokens)::bigint,
                COALESCE(SUM(spend), 0)
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

    awk -F'\t' 'NF >= 5 && $1 != "" && $2 != "" {
        printf "%s\tlitellm\t%s\t%s\t%s\t0\t0\t%s\n", $1, $2, $3, $4, $5
    }' "$tmpfile"
    rm -f "$tmpfile"
}
