#!/bin/bash
# claude-cost-common.sh — Shared configuration and helpers for claude-cost

# Defaults
TIMEZONE="${TIMEZONE:-UTC}"
CCUSAGE_VERSION="${CCUSAGE_VERSION:-18.0.10}"
CCUSAGE_CODEX_VERSION="${CCUSAGE_CODEX_VERSION:-18.0.10}"
ENABLED_PROVIDERS="${ENABLED_PROVIDERS:-claude}"
CODEX_OFFLINE="${CODEX_OFFLINE:-1}"
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

# Derived paths (used by sourcing scripts)
# shellcheck disable=SC2034
DB="$TRACKING_DIR/usage.db"
# shellcheck disable=SC2034
LOG="$TRACKING_DIR/logs/collect.log"
# shellcheck disable=SC2034
LOCK_DIR="$TRACKING_DIR/.lock"

# Portable date helper (macOS vs GNU coreutils)
yesterday() {
    date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d'
}
