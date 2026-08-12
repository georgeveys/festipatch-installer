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

# --- Find the primary interface: the ethernet device among those currently
#     owning a default route, falling back to the first ethernet device
#     NetworkManager knows about if none of the current default routes are
#     ethernet (e.g. DHCP is already down and nothing has taken over yet).
#     This is deliberately ethernet-only — a box may also have a WiFi
#     connection (e.g. for updates back at base) that owns a lower-metric
#     default route than the venue ethernet link; this fallback exists for
#     the wired connection, so a WiFi route must never make it the target. ---
IFACE=""
for dev in $(ip route show default 2>/dev/null | awk '{print $5}'); do
    if nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep -Fxq "$dev:ethernet"; then
        IFACE="$dev"
        break
    fi
done
if [ -z "$IFACE" ]; then
    IFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="ethernet"{print $1; exit}')
fi
if [ -z "$IFACE" ]; then
    log "ERROR: could not determine a primary ethernet interface — refusing to apply"
    exit 1
fi

# nmcli will happily create/modify a connection profile for a device it
# doesn't actually control (e.g. netplan's renderer is networkd, the Ubuntu
# Server default) — the commands below would report success while the
# profile silently never gets applied. Catch that here instead of failing
# quietly.
if nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -Fxq "$IFACE:unmanaged"; then
    log "ERROR: $IFACE is unmanaged by NetworkManager — nmcli cannot apply a fallback profile to it. Check /etc/netplan/*.yaml has 'renderer: NetworkManager' and run 'sudo netplan apply'. Refusing to apply."
    exit 1
fi

# Trim the primary DHCP profile's retry count so a genuine DHCP failure is
# detected in ~45s (one attempt) instead of NetworkManager's default of 4
# retries (~3 minutes) before it falls through to this fallback profile.
# Deliberately leaves the per-attempt timeout alone — many managed switches
# take 20-30s to start forwarding after link-up (Spanning Tree), and cutting
# the timeout itself risks a false fallback on a DHCP server that would have
# answered given a normal amount of time. netplan's generated profile name
# is always "netplan-<ifname>" for a plain interface-name match; skip
# quietly if that's not what's driving this device (e.g. a non-netplan
# setup) rather than fail the whole run over a pure timing optimisation.
DHCP_PROFILE="netplan-${IFACE}"
if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$DHCP_PROFILE"; then
    CURRENT_RETRIES=$(nmcli -g connection.autoconnect-retries connection show "$DHCP_PROFILE" 2>/dev/null)
    if [ "$CURRENT_RETRIES" != "1" ]; then
        log "Trimming $DHCP_PROFILE's autoconnect-retries to 1 (was '$CURRENT_RETRIES') so a genuine DHCP failure is detected in ~45s instead of ~3 minutes"
        run nmcli connection modify "$DHCP_PROFILE" connection.autoconnect-retries 1
    fi
fi

DESIRED_ADDR="${IP}/${PREFIX}"

# connection.autoconnect-priority only controls which profile NetworkManager
# picks to activate on THIS device — it has no effect on the kernel's route
# selection across devices. Without an explicit route-metric, a manual
# connection defaults to a metric (~100) that can outrank a real, working
# default route on another interface (e.g. WiFi used for updates back at
# base) the moment this profile activates, hijacking the box's actual
# default route into this gateway, which usually leads nowhere. Pin it to a
# metric worse than any real connection is ever likely to have, so it can
# only ever provide reachability on its own subnet unless it's genuinely the
# only interface up at all.
FALLBACK_ROUTE_METRIC=2000

if profile_exists; then
    CURRENT_ADDR=$(nmcli -g ipv4.addresses connection show "$PROFILE_NAME" 2>/dev/null)
    CURRENT_GW=$(nmcli -g ipv4.gateway connection show "$PROFILE_NAME" 2>/dev/null)
    CURRENT_DEV=$(nmcli -g connection.interface-name connection show "$PROFILE_NAME" 2>/dev/null)
    CURRENT_METRIC=$(nmcli -g ipv4.route-metric connection show "$PROFILE_NAME" 2>/dev/null)

    if [ "$CURRENT_ADDR" = "$DESIRED_ADDR" ] && [ "$CURRENT_GW" = "$GATEWAY" ] && [ "$CURRENT_DEV" = "$IFACE" ] && [ "$CURRENT_METRIC" = "$FALLBACK_ROUTE_METRIC" ]; then
        [ "$DRY_RUN" = true ] && log "$PROFILE_NAME already matches desired config ($IFACE $DESIRED_ADDR via $GATEWAY, metric $FALLBACK_ROUTE_METRIC) — nothing to do"
        exit 0
    fi

    log "Existing $PROFILE_NAME profile doesn't match desired config — updating (was: $CURRENT_DEV $CURRENT_ADDR via $CURRENT_GW, metric $CURRENT_METRIC)"
    run nmcli connection modify "$PROFILE_NAME" \
        connection.interface-name "$IFACE" \
        ipv4.method manual \
        ipv4.addresses "$DESIRED_ADDR" \
        ipv4.gateway "$GATEWAY" \
        ipv4.route-metric "$FALLBACK_ROUTE_METRIC" \
        connection.autoconnect-priority -10 \
        connection.autoconnect yes

    # `connection modify` only updates the saved profile — if this profile is
    # already the live connection on the device (i.e. we're already running
    # on the fallback), the interface keeps using the old address/gateway
    # until something reactivates it. Without this, a config change made
    # while already on the fallback would silently not take effect until the
    # next carrier change or reboot.
    if nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq "$PROFILE_NAME"; then
        log "$PROFILE_NAME is the live connection on $IFACE — reactivating so the new config takes effect now"
        run nmcli connection up "$PROFILE_NAME"
    fi
else
    log "Creating $PROFILE_NAME profile on $IFACE ($DESIRED_ADDR via $GATEWAY, metric $FALLBACK_ROUTE_METRIC)"
    run nmcli connection add type ethernet con-name "$PROFILE_NAME" ifname "$IFACE" \
        ipv4.method manual \
        ipv4.addresses "$DESIRED_ADDR" \
        ipv4.gateway "$GATEWAY" \
        ipv4.route-metric "$FALLBACK_ROUTE_METRIC" \
        connection.autoconnect-priority -10 \
        connection.autoconnect yes
fi

log "Fallback profile reconciled: $IFACE $DESIRED_ADDR via $GATEWAY (priority -10, only activates if DHCP fails)"
