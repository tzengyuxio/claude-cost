#!/bin/bash
# claude-cost-common.sh — Shared configuration and helpers for claude-cost

# Defaults
TIMEZONE="${TIMEZONE:-UTC}"
CCUSAGE_VERSION="${CCUSAGE_VERSION:-18.0.10}"
CCUSAGE_CODEX_VERSION="${CCUSAGE_CODEX_VERSION:-18.0.10}"
ENABLED_PROVIDERS="${ENABLED_PROVIDERS:-claude}"
CODEX_OFFLINE="${CODEX_OFFLINE:-1}"
CODEX_ROLLOUT_WARN_BYTES="${CODEX_ROLLOUT_WARN_BYTES:-200000000}"
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

# Minutes to add to a stored (TIMEZONE-bucketed) timestamp to display it in
# REPORT_TIMEZONE. Used by the hour-of-day reports as a SQLite datetime shift.
report_tz_shift_minutes() {
    echo $(( $(tz_offset_minutes "${REPORT_TIMEZONE:-UTC}") - $(tz_offset_minutes "${TIMEZONE:-UTC}") ))
}
