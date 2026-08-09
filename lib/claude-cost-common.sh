#!/bin/bash
# claude-cost-common.sh — Shared configuration and helpers for claude-cost

# Defaults
TIMEZONE="${TIMEZONE:-UTC}"
CCUSAGE_VERSION="${CCUSAGE_VERSION:-18.0.10}"
CCUSAGE_CODEX_VERSION="${CCUSAGE_CODEX_VERSION:-18.0.10}"
ENABLED_PROVIDERS="${ENABLED_PROVIDERS:-claude}"
CODEX_OFFLINE="${CODEX_OFFLINE:-1}"
CODEX_ROLLOUT_WARN_BYTES="${CODEX_ROLLOUT_WARN_BYTES:-200000000}"
LITELLM_DB_CONTAINER="${LITELLM_DB_CONTAINER:-litellm-db}"
LITELLM_DB_USER="${LITELLM_DB_USER:-litellm}"
LITELLM_DB_NAME="${LITELLM_DB_NAME:-litellm}"
OPENWEBUI_DB="${OPENWEBUI_DB:-/srv/data/webui/webui.db}"
SELF_HOSTED_PROVIDERS="${SELF_HOSTED_PROVIDERS:-litellm openwebui}"
CLOUD_RATES="${CLOUD_RATES:-}"
CLOUD_RATE_DEFAULT="${CLOUD_RATE_DEFAULT:-}"
SCHEDULE_HOUR="${SCHEDULE_HOUR:-2}"
SCHEDULE_MINUTE="${SCHEDULE_MINUTE:-0}"

# Detect Windows (Git Bash / MSYS2) vs Unix
if [[ -n "${APPDATA:-}" && -n "${LOCALAPPDATA:-}" ]]; then
    # Windows: use APPDATA for config, LOCALAPPDATA for data
    _CC_APPDATA="${APPDATA//\\//}"
    _CC_LOCALAPPDATA="${LOCALAPPDATA//\\//}"
    _CC_CONFIG="$_CC_APPDATA/claude-cost/config"
    TRACKING_DIR="$_CC_LOCALAPPDATA/claude-cost/data"
else
    # Unix: XDG conventions
    _CC_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-cost/config"
    TRACKING_DIR="$HOME/.local/share/claude-cost"
fi

# Load user config (shell-sourceable key=value)
if [ -f "$_CC_CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$_CC_CONFIG"
fi

# Display timezone for the hour-of-day reports (by-hour / by-weekday-hour).
# Storage is bucketed in TIMEZONE; these reports re-project hours into
# REPORT_TIMEZONE at query time (no re-bucketing of stored rows). Defaults to
# TIMEZONE → no shift. Resolved after config load so it tracks a config override.
# shellcheck disable=SC2034
REPORT_TIMEZONE="${REPORT_TIMEZONE:-$TIMEZONE}"

# Derived paths (used by sourcing scripts)
# shellcheck disable=SC2034
DB="$TRACKING_DIR/usage.db"
# shellcheck disable=SC2034
LOG="$TRACKING_DIR/logs/collect.log"
# shellcheck disable=SC2034
LOCK_DIR="$TRACKING_DIR/.lock"

# Portable date helper (macOS vs GNU coreutils).
# Computes "yesterday" in the configured TIMEZONE, not the system-local zone:
# data is bucketed by date in TIMEZONE, so the watermark must advance only past
# days that are fully elapsed in TIMEZONE. If we used the local zone and it ran
# ahead of TIMEZONE (e.g. system in UTC+8 but TIMEZONE=UTC), an early-morning
# collection would treat an in-progress TIMEZONE day as "yesterday", advance the
# watermark past it, and permanently drop that day's later hours.
yesterday() {
    TZ="${TIMEZONE:-UTC}" date -v-1d '+%Y-%m-%d' 2>/dev/null \
        || TZ="${TIMEZONE:-UTC}" date -d 'yesterday' '+%Y-%m-%d'
}

# Minutes east of UTC for a named zone, sampled at the current instant.
# Note: a single snapshot, so DST-free zones (UTC, Asia/Taipei) are exact;
# zones with DST are off by an hour for rows on the other side of a transition.
tz_offset_minutes() {
    local z sign h m v
    z=$(TZ="$1" date '+%z')   # e.g. +0800 / -0500
    sign="${z:0:1}"; h="${z:1:2}"; m="${z:3:2}"
    v=$(( 10#$h * 60 + 10#$m ))
    [[ "$sign" == "-" ]] && v=$(( -v ))
    printf '%d' "$v"
}

# SQL expression (usable per-row or inside SUM) giving a row's cloud-equivalent
# cost in USD: what the same tokens would have cost against a hosted API.
#
# Self-hosted rows store cost_usd = 0 — local inference costs no money per token,
# the real cost is electricity — so "how much did self-hosting save" cannot be
# answered from stored data alone. Rates are applied here at query time rather
# than stored at collection time, so adjusting them re-values the whole history
# consistently instead of leaving old rows priced at whatever was configured the
# day they were collected (the exact trap LiteLLM's own `spend` column falls into).
#
# Providers that genuinely are cloud services keep their real cost_usd, so the
# equivalent figure is comparable across a mixed database.
# Returns 1 (empty) when no rates are configured, which keeps the extra columns
# out of the reports entirely.
cloud_equiv_expr() {
    [[ -n "${CLOUD_RATES}${CLOUD_RATE_DEFAULT}" ]] || return 1

    local expr="CASE" list="" p entry pat rest rin rout
    for p in $SELF_HOSTED_PROVIDERS; do
        list="${list:+$list, }'${p//\'/\'\'}'"
    done
    [[ -n "$list" ]] && expr="$expr WHEN provider NOT IN ($list) THEN cost_usd"

    # <model-glob>:<input $/M>:<output $/M>, first match wins (SQLite GLOB, so
    # the patterns are shell-style: qwen* , claude-* ).
    for entry in $CLOUD_RATES; do
        pat="${entry%%:*}"; rest="${entry#*:}"
        rin="${rest%%:*}"; rout="${rest##*:}"
        if [[ ! "$rin" =~ ^[0-9]+(\.[0-9]+)?$ || ! "$rout" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "WARN: ignoring malformed CLOUD_RATES entry '$entry' (want glob:in:out)" >&2
            continue
        fi
        expr="$expr WHEN model GLOB '${pat//\'/\'\'}' THEN (input_tokens * $rin + output_tokens * $rout) / 1000000.0"
    done

    rin="${CLOUD_RATE_DEFAULT%%:*}"; rout="${CLOUD_RATE_DEFAULT##*:}"
    if [[ "$rin" =~ ^[0-9]+(\.[0-9]+)?$ && "$rout" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        expr="$expr ELSE (input_tokens * $rin + output_tokens * $rout) / 1000000.0"
    else
        [[ -n "$CLOUD_RATE_DEFAULT" ]] && echo "WARN: ignoring malformed CLOUD_RATE_DEFAULT '$CLOUD_RATE_DEFAULT' (want in:out)" >&2
        expr="$expr ELSE 0"
    fi

    echo "$expr END"
}

# Minutes to add to a stored (TIMEZONE-bucketed) timestamp to display it in
# REPORT_TIMEZONE. Used by the hour-of-day reports as a SQLite datetime shift.
report_tz_shift_minutes() {
    echo $(( $(tz_offset_minutes "${REPORT_TIMEZONE:-UTC}") - $(tz_offset_minutes "${TIMEZONE:-UTC}") ))
}
