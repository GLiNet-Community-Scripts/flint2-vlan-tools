#!/bin/sh
# vlan-wizard.sh — Native VLANs on GL.iNet Flint 2 (DSA)
#
# Inspiration: https://ryan-pope.com/posts/flint2-vlans/
#
# WHY REBOOT:
#   GL.iNet firmware (4.8.x / OpenWrt 21.02-SNAPSHOT) crashes if you try to
#   activate vlan_filtering via 'network reload' on a running br-lan. A clean
#   reboot lets all hardware acceleration (MTK flow, packet steering) initialize
#   in the correct order AFTER the bridge-VLAN config is in place. This is
#   exactly what LuCI Save & Apply does.
#
# VLAN STRATEGY:
#   * VLAN 1: all existing br-lan ports as untagged+PVID (LAN untouched)
#   * New VLANs: wifi-only (no physical ports initially)
#               → physical trunk port can be added later with the 'port' command
#
# COMMANDS:
#   ./vlan-wizard.sh add              # add a new VLAN interactively
#   ./vlan-wizard.sh list             # list all VLANs
#   ./vlan-wizard.sh remove <id>      # remove a VLAN
#   ./vlan-wizard.sh port add <id> <lanX> [tagged|untagged]  # add trunk/port
#   ./vlan-wizard.sh rollback         # restore backup + reboot
#   ./vlan-wizard.sh status           # show current bridge-VLAN state

CMD="${1:-}"
BACKUP="/root/vlan_wizard_backup"

info() { echo "[*] $*"; }
warn() { echo "[!] $*"; }
ok()   { echo "[+] $*"; }
die()  { warn "$*"; exit 1; }

# ─── FIND br-lan DEVICE INDEX ────────────────────────────────────────────────
find_br_idx() {
    IDX=0
    while uci -q get "network.@device[$IDX]" >/dev/null 2>&1; do
        N="$(uci -q get "network.@device[$IDX].name" 2>/dev/null || true)"
        T="$(uci -q get "network.@device[$IDX].type" 2>/dev/null || true)"
        [ "$N" = "br-lan" ] && [ "$T" = "bridge" ] && { echo "$IDX"; return; }
        IDX=$((IDX+1))
    done
    echo ""
}

# ─── FIND bridge-vlan INDEX FOR A GIVEN VLAN ID ──────────────────────────────
find_bv_idx() {
    TARGET="$1"
    IDX=0
    while uci -q get "network.@bridge-vlan[$IDX]" >/dev/null 2>&1; do
        V="$(uci -q get "network.@bridge-vlan[$IDX].vlan" 2>/dev/null || true)"
        D="$(uci -q get "network.@bridge-vlan[$IDX].device" 2>/dev/null || true)"
        [ "$V" = "$TARGET" ] && [ "$D" = "br-lan" ] && { echo "$IDX"; return; }
        IDX=$((IDX+1))
    done
    echo ""
}

# ─── NEXT AVAILABLE WIFI IFNAME ──────────────────────────────────────────────
next_ifname() {
    PREFIX="$1"   # ra or rax
    i=0
    while [ $i -lt 4 ]; do
        TAKEN=0
        for SEC in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
            IF="$(uci -q get "wireless.${SEC}.ifname" 2>/dev/null || true)"
            [ "$IF" = "${PREFIX}${i}" ] && TAKEN=1
        done
        [ "$TAKEN" = "0" ] && { echo "${PREFIX}${i}"; return; }
        i=$((i+1))
    done
    echo ""
}

# ─── ENSURE VLAN 1 BASELINE (run on first VLAN addition) ─────────────────────
ensure_vlan1_and_filtering() {
    BR_IDX="$(find_br_idx)"
    [ -z "$BR_IDX" ] && die "Cannot find br-lan bridge"

    FILTER="$(uci -q get "network.@device[$BR_IDX].vlan_filtering" 2>/dev/null || true)"
    if [ "$FILTER" = "1" ]; then
        info "vlan_filtering already active"
        return
    fi

    BR_PORTS="$(uci -q get "network.@device[$BR_IDX].ports" 2>/dev/null || true)"
    [ -z "$BR_PORTS" ] && die "No ports on br-lan"

    info "Enabling vlan_filtering and creating VLAN 1 with: $BR_PORTS"
    uci set "network.@device[${BR_IDX}].vlan_filtering=1"

    uci add network bridge-vlan >/dev/null
    uci set network.@bridge-vlan[-1].device='br-lan'
    uci set network.@bridge-vlan[-1].vlan='1'
    for P in $BR_PORTS; do
        uci add_list network.@bridge-vlan[-1].ports="${P}:u*"
    done

    # With vlan_filtering ON the lan interface must point to br-lan.1 (VLAN 1 sub-interface)
    # instead of raw br-lan — otherwise existing LAN + wifi loses DHCP after reboot.
    info "Updating network.lan.device to br-lan.1"
    uci set network.lan.device='br-lan.1'
}

# ─── STATUS ───────────────────────────────────────────────────────────────────
cmd_status() {
    echo "=== bridge-vlan (UCI config) ==="
    uci show network 2>/dev/null | grep -E "bridge-vlan" || echo "(none)"
    echo
    echo "=== bridge vlan (kernel, if vlan_filtering is on) ==="
    bridge vlan show 2>/dev/null || echo "(vlan_filtering is off — normal before reboot)"
    echo
    echo "=== Interfaces ==="
    for IF in $(uci show network 2>/dev/null | grep "=interface" | cut -d. -f2 | cut -d= -f1); do
        IP="$(uci -q get "network.${IF}.ipaddr" 2>/dev/null || true)"
        DEV="$(uci -q get "network.${IF}.device" 2>/dev/null || true)"
        [ -n "$IP" ] && printf "  %-15s %s  (%s)\n" "$IF" "$IP" "$DEV"
    done
    echo
    echo "=== SSIDs ==="
    for SEC in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
        N="$(uci -q get "wireless.${SEC}.network"  2>/dev/null || true)"
        S="$(uci -q get "wireless.${SEC}.ssid"     2>/dev/null || true)"
        D="$(uci -q get "wireless.${SEC}.device"   2>/dev/null || true)"
        I="$(uci -q get "wireless.${SEC}.ifname"   2>/dev/null || true)"
        printf "  %-20s ssid='%s'  net=%s  %s  ifname=%s\n" "$SEC" "$S" "$N" "$D" "$I"
    done
}

# ─── LIST ─────────────────────────────────────────────────────────────────────
cmd_list() {
    echo "VLAN  Interface          Subnet             SSIDs"
    echo "───────────────────────────────────────────────────────────────────"
    IDX=0
    while uci -q get "network.@bridge-vlan[$IDX]" >/dev/null 2>&1; do
        V="$(uci -q get "network.@bridge-vlan[$IDX].vlan" 2>/dev/null || true)"
        D="$(uci -q get "network.@bridge-vlan[$IDX].device" 2>/dev/null || true)"
        if [ "$D" = "br-lan" ]; then
            IF_NAME=""
            for IF in $(uci show network 2>/dev/null | grep "=interface" | cut -d. -f2 | cut -d= -f1); do
                DEV="$(uci -q get "network.${IF}.device" 2>/dev/null || true)"
                [ "$DEV" = "br-lan.${V}" ] && IF_NAME="$IF"
            done
            IP="$(uci -q get "network.${IF_NAME}.ipaddr" 2>/dev/null || true)"
            SSIDS=""
            for SEC in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
                N="$(uci -q get "wireless.${SEC}.network" 2>/dev/null || true)"
                [ "$N" = "$IF_NAME" ] && SSIDS="$SSIDS $(uci -q get "wireless.${SEC}.ssid" 2>/dev/null || true)"
            done
            printf "%-6s %-18s %-18s %s\n" "$V" "${IF_NAME:-–}" "${IP:-–}" "${SSIDS:- (no wifi)}"
        fi
        IDX=$((IDX+1))
    done
}

# ─── ADD ──────────────────────────────────────────────────────────────────────
cmd_add() {
    echo "=== Add new VLAN ==="
    echo

    # VLAN ID
    printf "VLAN ID (2-4094, e.g. 20 for IoT, 30 for work): "
    read VLAN_ID
    case "$VLAN_ID" in ''|*[!0-9]*) die "Invalid VLAN ID" ;; esac
    [ "$VLAN_ID" -lt 2 ] || [ "$VLAN_ID" -gt 4094 ] && die "Must be 2–4094"
    [ -n "$(find_bv_idx "$VLAN_ID")" ] && die "VLAN $VLAN_ID already exists"

    # Interface name
    printf "Interface name (e.g. 'work', 'iot', 'cameras'): "
    read IF_NAME
    case "$IF_NAME" in
        ''|*[!a-z0-9_]*) die "Invalid (a-z, 0-9, _ allowed)" ;;
        lan|wan|guest|loopback|wan6) die "'$IF_NAME' is reserved" ;;
    esac
    uci -q get "network.${IF_NAME}" >/dev/null 2>&1 && die "network.${IF_NAME} already exists"

    # Subnet
    printf "Subnet (192.168.X.0/24, enter X, e.g. 20): "
    read OCT
    case "$OCT" in ''|*[!0-9]*) die "Invalid" ;; esac
    [ "$OCT" -lt 2 ] || [ "$OCT" -gt 254 ] && die "Must be 2–254"
    for IF in $(uci show network 2>/dev/null | grep "=interface" | cut -d. -f2 | cut -d= -f1); do
        IP="$(uci -q get "network.${IF}.ipaddr" 2>/dev/null || true)"
        case "$IP" in 192.168.${OCT}.*) die "Subnet 192.168.${OCT} is used by '$IF'" ;; esac
    done
    SUBNET="192.168.${OCT}"

    # Wifi
    printf "Enable 2.4GHz wifi? [Y/n]: "; read R24
    printf "Enable 5GHz wifi?   [Y/n]: "; read R5
    USE_24=1; case "$R24" in n|N) USE_24=0 ;; esac
    USE_5=1;  case "$R5"  in n|N) USE_5=0 ;; esac

    SSID_24="" SSID_5=""
    if [ "$USE_24" = "1" ]; then
        printf "2.4GHz SSID: "; read SSID_24
        [ -z "$SSID_24" ] && die "SSID required"
        IFNAME_24="$(next_ifname ra)"
        [ -z "$IFNAME_24" ] && die "No free ra slots (max 4 per radio)"
    fi
    if [ "$USE_5" = "1" ]; then
        printf "5GHz SSID:   "; read SSID_5
        [ -z "$SSID_5" ] && die "SSID required"
        IFNAME_5="$(next_ifname rax)"
        [ -z "$IFNAME_5" ] && die "No free rax slots (max 4 per radio)"
    fi
    [ "$USE_24" = "0" ] && [ "$USE_5" = "0" ] && die "At least one radio must be enabled"

    printf "Wifi password (min 8 characters): "; read PASS
    [ "${#PASS}" -lt 8 ] && die "At least 8 characters required"

    printf "Client isolation? [y/N]: "; read ISO
    ISOLATE=0; case "$ISO" in y|Y) ISOLATE=1 ;; esac

    # Preview
    echo
    echo "=== PREVIEW ==="
    echo "  VLAN ID    : $VLAN_ID"
    echo "  Interface  : $IF_NAME (br-lan.$VLAN_ID)"
    echo "  Subnet     : ${SUBNET}.0/24"
    echo "  Gateway    : ${SUBNET}.1"
    echo "  DHCP       : ${SUBNET}.100–249"
    [ "$USE_24" = "1" ] && echo "  2.4GHz     : '$SSID_24' ($IFNAME_24)"
    [ "$USE_5"  = "1" ] && echo "  5GHz       : '$SSID_5' ($IFNAME_5)"
    echo "  Isolation  : $([ "$ISOLATE" = "1" ] && echo "on" || echo "off")"
    echo "  Firewall   : isolated from LAN, internet via WAN"
    echo
    echo "  NOTE: Router will reboot to activate VLAN config (~1-2 min downtime)"
    echo
    printf "Apply + reboot? [y/N]: "; read CONFIRM
    case "$CONFIRM" in y|Y) ;; *) echo "Aborted."; exit 0 ;; esac

    # Backup (once only)
    mkdir -p "$BACKUP"
    if [ ! -f "$BACKUP/network" ]; then
        for f in network wireless firewall dhcp; do
            uci export "$f" > "$BACKUP/$f"
        done
        ok "Backup saved: $BACKUP"
    else
        info "Backup already exists: $BACKUP"
    fi

    # VLAN 1 + filtering (if not already done)
    ensure_vlan1_and_filtering

    # bridge-vlan for new VLAN (no physical ports — wifi-only)
    uci add network bridge-vlan >/dev/null
    uci set network.@bridge-vlan[-1].device='br-lan'
    uci set network.@bridge-vlan[-1].vlan="$VLAN_ID"
    # No 'ports' list = bridge-local only (CPU/software), no physical ports

    # Interface
    uci set network.${IF_NAME}='interface'
    uci set network.${IF_NAME}.device="br-lan.${VLAN_ID}"
    uci set network.${IF_NAME}.proto='static'
    uci set network.${IF_NAME}.ipaddr="${SUBNET}.1"
    uci set network.${IF_NAME}.netmask='255.255.255.0'

    # DHCP
    uci set dhcp.${IF_NAME}='dhcp'
    uci set dhcp.${IF_NAME}.interface="$IF_NAME"
    uci set dhcp.${IF_NAME}.start='100'
    uci set dhcp.${IF_NAME}.limit='150'
    uci set dhcp.${IF_NAME}.leasetime='12h'
    uci add_list dhcp.${IF_NAME}.dhcp_option="6,${SUBNET}.1"

    # Firewall
    uci set firewall.${IF_NAME}='zone'
    uci set firewall.${IF_NAME}.name="$IF_NAME"
    uci set firewall.${IF_NAME}.network="$IF_NAME"
    uci set firewall.${IF_NAME}.input='REJECT'
    uci set firewall.${IF_NAME}.forward='REJECT'
    uci set firewall.${IF_NAME}.output='ACCEPT'

    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name="Allow-DHCP-${IF_NAME}"
    uci set firewall.@rule[-1].src="$IF_NAME"
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].dest_port='67-68'
    uci set firewall.@rule[-1].target='ACCEPT'

    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name="Allow-DNS-${IF_NAME}"
    uci set firewall.@rule[-1].src="$IF_NAME"
    uci set firewall.@rule[-1].proto='tcp udp'
    uci set firewall.@rule[-1].dest_port='53'
    uci set firewall.@rule[-1].target='ACCEPT'

    uci add firewall forwarding >/dev/null
    uci set firewall.@forwarding[-1].src="$IF_NAME"
    uci set firewall.@forwarding[-1].dest='wan'

    # Wifi
    if [ "$USE_24" = "1" ]; then
        uci set wireless.${IF_NAME}2g='wifi-iface'
        uci set wireless.${IF_NAME}2g.device='mt798611'
        uci set wireless.${IF_NAME}2g.network="$IF_NAME"
        uci set wireless.${IF_NAME}2g.mode='ap'
        uci set wireless.${IF_NAME}2g.ssid="$SSID_24"
        uci set wireless.${IF_NAME}2g.encryption='psk2'
        uci set wireless.${IF_NAME}2g.key="$PASS"
        uci set wireless.${IF_NAME}2g.ifname="$IFNAME_24"
        [ "$ISOLATE" = "1" ] && uci set wireless.${IF_NAME}2g.isolate='1'
    fi
    if [ "$USE_5" = "1" ]; then
        uci set wireless.${IF_NAME}5g='wifi-iface'
        uci set wireless.${IF_NAME}5g.device='mt798612'
        uci set wireless.${IF_NAME}5g.network="$IF_NAME"
        uci set wireless.${IF_NAME}5g.mode='ap'
        uci set wireless.${IF_NAME}5g.ssid="$SSID_5"
        uci set wireless.${IF_NAME}5g.encryption='psk2'
        uci set wireless.${IF_NAME}5g.key="$PASS"
        uci set wireless.${IF_NAME}5g.ifname="$IFNAME_5"
        [ "$ISOLATE" = "1" ] && uci set wireless.${IF_NAME}5g.isolate='1'
    fi

    # Commit everything
    uci commit network
    uci commit dhcp
    uci commit firewall
    uci commit wireless
    ok "All changes committed"

    warn "Rebooting in 10 seconds. Network will be down ~1-2 min."
    warn "If it does NOT come back: physical access + run './vlan-wizard.sh rollback'"
    sleep 10
    reboot
}

# ─── REMOVE ───────────────────────────────────────────────────────────────────
cmd_remove() {
    VLAN_ID="$1"
    [ -z "$VLAN_ID" ] && die "Usage: $0 remove <VLAN-ID>"
    case "$VLAN_ID" in ''|*[!0-9]*) die "Invalid VLAN ID" ;; esac
    [ "$VLAN_ID" = "1" ] && die "Cannot remove VLAN 1"

    IF_NAME=""
    for IF in $(uci show network 2>/dev/null | grep "=interface" | cut -d. -f2 | cut -d= -f1); do
        DEV="$(uci -q get "network.${IF}.device" 2>/dev/null || true)"
        [ "$DEV" = "br-lan.${VLAN_ID}" ] && IF_NAME="$IF"
    done

    echo "Removing VLAN $VLAN_ID${IF_NAME:+ ($IF_NAME)}"
    printf "Confirm? [y/N]: "; read C
    case "$C" in y|Y) ;; *) echo "Aborted."; exit 0 ;; esac

    # Backup
    mkdir -p "$BACKUP"
    STAMP="$(date +%s)"
    for f in network wireless firewall dhcp; do
        uci export "$f" > "${BACKUP}/${STAMP}_before_remove_vlan${VLAN_ID}_${f}"
    done

    # bridge-vlan
    BV_IDX="$(find_bv_idx "$VLAN_ID")"
    [ -n "$BV_IDX" ] && uci delete "network.@bridge-vlan[$BV_IDX]"

    if [ -n "$IF_NAME" ]; then
        # Interface + DHCP
        uci -q delete "network.${IF_NAME}"  2>/dev/null || true
        uci -q delete "dhcp.${IF_NAME}"     2>/dev/null || true

        # Firewall zone
        uci -q delete "firewall.${IF_NAME}" 2>/dev/null || true

        # Firewall rules + forwardings
        for TYPE in rule forwarding; do
            IDX=0
            while uci -q get "firewall.@${TYPE}[$IDX]" >/dev/null 2>&1; do IDX=$((IDX+1)); done
            IDX=$((IDX-1))
            while [ "$IDX" -ge 0 ]; do
                SRC="$(uci -q get "firewall.@${TYPE}[$IDX].src"  2>/dev/null || true)"
                NM="$(uci -q get  "firewall.@${TYPE}[$IDX].name" 2>/dev/null || true)"
                case "$SRC$NM" in
                    *${IF_NAME}*) uci delete "firewall.@${TYPE}[$IDX]" ;;
                esac
                IDX=$((IDX-1))
            done
        done

        # Wifi interfaces
        for SEC in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
            N="$(uci -q get "wireless.${SEC}.network" 2>/dev/null || true)"
            [ "$N" = "$IF_NAME" ] && uci delete "wireless.${SEC}"
        done
    fi

    uci commit network dhcp firewall wireless
    ok "Committed. Rebooting in 10 seconds."
    sleep 10
    reboot
}

# ─── PORT: add physical port to a VLAN ───────────────────────────────────────
cmd_port_add() {
    VLAN_ID="$2"
    PORT="$3"            # e.g. lan1, lan2
    MODE="${4:-tagged}"  # tagged (t) or untagged (u*)
    [ -z "$VLAN_ID" ] || [ -z "$PORT" ] && die "Usage: $0 port add <VLAN-ID> <lanX> [tagged|untagged]"

    BV_IDX="$(find_bv_idx "$VLAN_ID")"
    [ -z "$BV_IDX" ] && die "VLAN $VLAN_ID does not exist"

    case "$MODE" in
        tagged)   TAG="t"  ;;
        untagged) TAG="u*" ;;
        *) die "Mode must be 'tagged' or 'untagged'" ;;
    esac

    # If making this port untagged in another VLAN, its PVID will change from VLAN 1.
    if [ "$TAG" = "u*" ]; then
        V1_IDX="$(find_bv_idx 1)"
        if [ -n "$V1_IDX" ]; then
            warn "Port $PORT will have PVID in VLAN $VLAN_ID, not VLAN 1."
            warn "You may want to update the VLAN 1 entry manually in LuCI afterwards."
        fi
    fi

    uci add_list "network.@bridge-vlan[$BV_IDX].ports=${PORT}:${TAG}"
    uci commit network
    ok "Port ${PORT} (${MODE}) added to VLAN ${VLAN_ID}. Rebooting in 10 sec."
    sleep 10
    reboot
}

# ─── ROLLBACK ─────────────────────────────────────────────────────────────────
cmd_rollback() {
    [ ! -f "$BACKUP/network" ] && die "No backup found in $BACKUP. Run factory reset (hold reset button 10 sec)."
    warn "Restoring from $BACKUP and rebooting in 5 seconds..."
    sleep 5
    for f in network wireless firewall dhcp; do
        uci import "$f" < "$BACKUP/$f"
    done
    uci commit
    reboot
}

# ─── DISPATCH ─────────────────────────────────────────────────────────────────
case "$CMD" in
    add)      cmd_add ;;
    list)     cmd_list ;;
    remove)   cmd_remove "$2" ;;
    port)     cmd_port_add "$@" ;;
    rollback) cmd_rollback ;;
    status)   cmd_status ;;
    *)
        echo "Usage:"
        echo "  $0 add                                          # add a VLAN"
        echo "  $0 list                                         # list VLANs"
        echo "  $0 remove <VLAN-ID>                             # remove a VLAN"
        echo "  $0 port add <VLAN-ID> <lanX> [tagged|untagged]  # add physical port"
        echo "  $0 status                                       # show current state"
        echo "  $0 rollback                                     # restore backup + reboot"
        echo
        echo "IMPORTANT:"
        echo "  * Every VLAN change triggers a reboot (~1-2 min downtime)"
        echo "  * Backup is saved automatically to $BACKUP"
        echo "  * Rollback requires physical access if you lose connectivity"
        ;;
esac
