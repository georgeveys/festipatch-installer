#!/bin/bash
# =============================================================================
#  FestiPatch Network Fallback
#
#  Reads the fallback IP/prefix/gateway saved via FestiPatch's own
#  Admin -> Settings -> General page (server/network-fallback-config.json,
#  written by server/src/routes/settings.js's PUT /network-fallback-config)
#  and maintains a low-priority NetworkManager connection profile for it.
#
#  This is purely additive: it never touches the machine's normal DHCP
#  connection. NetworkManager only ever activates a lower-priority profile
#  on its own if the higher-priority one (DHCP, the default) fails to get a
#  lease — so the fallback only kicks in when DHCP genuinely isn't working,
#  and `nmcli connection delete festipatch-fallback-static` (or just letting
#  this script see an empty config again) undoes it completely.
#
#  Installed to /usr/local/bin by festipatch-setup.sh, run as root every 5
#  minutes via /etc/cron.d/festipatch-network-fallback — same pattern as
#  festipatch-backup.sh. Idempotent: only touches nmcli when the desired
#  state doesn't already match reality, safe to run repeatedly.
#
#  Usage: festipatch-network-fallback.sh [--dry-run]
#    --dry-run   Log what would change without touching nmcli. Also echoes
#                to stdout, for testing by hand before trusting the cron job.
# =============================================================================

CONFIG_FILE="/var/www/festipatch/server/network-fallback-config.json"
PROFILE_NAME="festipatch-fallback-static"
LOG="/var/log/festipatch-network-fallback.log"

DRY_RUN=false
[ "$1" = "--dry-run" ] && DRY_RUN=true

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$line" >> "$LOG"
    [ "$DRY_RUN" = true ] && echo "$line"
}

# Runs a mutating nmcli command for real, or just logs it under --dry-run.
run() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] would run: $*"
    else
        "$@" >> "$LOG" 2>&1
    fi
}

profile_exists() {
    nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$PROFILE_NAME"
}

# --- No config saved (or file missing/empty): ensure no fallback profile exists ---
if [ ! -s "$CONFIG_FILE" ]; then
    if profile_exists; then
        run nmcli connection delete "$PROFILE_NAME"
        log "Config file missing/empty — removed existing $PROFILE_NAME profile"
    fi
    exit 0
fi

if ! command -v jq &>/dev/null; then
    log "ERROR: jq is not installed — cannot parse $CONFIG_FILE. Install with: apt-get install -y jq"
    exit 1
fi

IP=$(jq -r '.ip // empty' "$CONFIG_FILE" 2>/dev/null)
PREFIX=$(jq -r '.prefix // empty' "$CONFIG_FILE" 2>/dev/null)
GATEWAY=$(jq -r '.gateway // empty' "$CONFIG_FILE" 2>/dev/null)

if [ -z "$IP" ] || [ -z "$PREFIX" ] || [ -z "$GATEWAY" ]; then
    log "ERROR: config file present but incomplete or unparsable (ip='$IP' prefix='$PREFIX' gateway='$GATEWAY') — leaving any existing profile untouched"
    exit 1
fi

# Defence in depth — FestiPatch's own PUT handler already validates these
# before writing the file, but never trust a file blindly before it's about
# to feed a privileged command.
IP_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
if ! [[ "$IP" =~ $IP_RE ]] || ! [[ "$GATEWAY" =~ $IP_RE ]]; then
    log "ERROR: ip ('$IP') or gateway ('$GATEWAY') is not a valid-looking IPv4 address — refusing to apply"
    exit 1
fi
if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] || [ "$PREFIX" -lt 0 ] || [ "$PREFIX" -gt 32 ]; then
    log "ERROR: prefix ('$PREFIX') is not a whole number between 0 and 32 — refusing to apply"
    exit 1
fi

# --- Find the primary interface: whichever device currently owns the
#     default route, falling back to the first ethernet device NetworkManager
#     knows about if there's no default route at all right now (e.g. DHCP is
#     already down and nothing has taken over yet). ---
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [ -z "$IFACE" ]; then
    IFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="ethernet"{print $1; exit}')
fi
if [ -z "$IFACE" ]; then
    log "ERROR: could not determine a primary network interface — refusing to apply"
    exit 1
fi

DESIRED_ADDR="${IP}/${PREFIX}"

if profile_exists; then
    CURRENT_ADDR=$(nmcli -g ipv4.addresses connection show "$PROFILE_NAME" 2>/dev/null)
    CURRENT_GW=$(nmcli -g ipv4.gateway connection show "$PROFILE_NAME" 2>/dev/null)
    CURRENT_DEV=$(nmcli -g connection.interface-name connection show "$PROFILE_NAME" 2>/dev/null)

    if [ "$CURRENT_ADDR" = "$DESIRED_ADDR" ] && [ "$CURRENT_GW" = "$GATEWAY" ] && [ "$CURRENT_DEV" = "$IFACE" ]; then
        [ "$DRY_RUN" = true ] && log "$PROFILE_NAME already matches desired config ($IFACE $DESIRED_ADDR via $GATEWAY) — nothing to do"
        exit 0
    fi

    log "Existing $PROFILE_NAME profile doesn't match desired config — updating (was: $CURRENT_DEV $CURRENT_ADDR via $CURRENT_GW)"
    run nmcli connection modify "$PROFILE_NAME" \
        connection.interface-name "$IFACE" \
        ipv4.method manual \
        ipv4.addresses "$DESIRED_ADDR" \
        ipv4.gateway "$GATEWAY" \
        connection.autoconnect-priority -10 \
        connection.autoconnect yes
else
    log "Creating $PROFILE_NAME profile on $IFACE ($DESIRED_ADDR via $GATEWAY)"
    run nmcli connection add type ethernet con-name "$PROFILE_NAME" ifname "$IFACE" \
        ipv4.method manual \
        ipv4.addresses "$DESIRED_ADDR" \
        ipv4.gateway "$GATEWAY" \
        connection.autoconnect-priority -10 \
        connection.autoconnect yes
fi

log "Fallback profile reconciled: $IFACE $DESIRED_ADDR via $GATEWAY (priority -10, only activates if DHCP fails)"
