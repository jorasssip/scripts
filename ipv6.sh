#!/usr/bin/env bash
#
# ipv6.sh — enable or disable IPv6 on a Linux server (persistent, via sysctl).
#
# Author:  jorasssip — https://github.com/jorasssip/scripts
# License: MIT (see LICENSE). Based on hteppl/sh.
#
# Usage:
#   bash ipv6.sh off [--force]
#   bash ipv6.sh on
#   bash ipv6.sh [status]
#   bash ipv6.sh --help

set -Eeuo pipefail

CONF="/etc/sysctl.d/99-disable-ipv6.conf"
LEGACY_CONF="/etc/sysctl.conf"
PROC6="/proc/sys/net/ipv6"
LEGACY_RE='^[[:space:]]*net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6'
FORCE=0

# ---------- output helpers ----------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: ipv6.sh [on|off|status] [--force]

  off       Disable IPv6 on all interfaces (persists across reboots)
  on        Enable IPv6 again
  status    Show current IPv6 state (default)

Options:
  --force   Disable even if the server has no IPv4 default route
            or there are SSH sessions over IPv6 (you may lose access!)
  -h, --help  Show this help
EOF
}

# ---------- checks ----------

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root (e.g. via sudo)."
}

kernel_has_ipv6() {
    [[ -d $PROC6 ]]
}

kernel_param_disabled() {
    grep -qw 'ipv6.disable=1' /proc/cmdline 2>/dev/null
}

require_writable() {
    [[ -w $PROC6/conf/all/disable_ipv6 ]] ||
        die "/proc/sys is read-only (container?). IPv6 must be configured on the host."
}

has_ipv4_default_route() {
    awk 'NR > 1 && $2 == "00000000" { found = 1 } END { exit !found }' /proc/net/route 2>/dev/null
}

ssh_ports() {
    local ports=""
    if command -v sshd >/dev/null 2>&1; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | tr '\n' ' ')
    fi
    echo "${ports:-22}"
}

# Count established TCP sessions to the local SSH port(s) over real IPv6
# (IPv4-mapped ::ffff:a.b.c.d sessions are ignored).
ssh_sessions_over_ipv6() {
    [[ -r /proc/net/tcp6 ]] || { echo 0; return; }
    local p hexports=""
    for p in $(ssh_ports); do
        hexports+=$(printf '%04X ' "$p")
    done
    awk -v ports="$hexports" '
        BEGIN { n = split(ports, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        NR > 1 && $4 == "01" {
            split($2, l, ":"); split($3, r, ":")
            if ((l[2] in want) && substr(r[1], 1, 24) != "0000000000000000FFFF0000") c++
        }
        END { print c + 0 }' /proc/net/tcp6
}

# The current session may also be visible through SSH_CONNECTION (if not stripped by sudo).
current_ssh_is_ipv6() {
    local server_ip
    server_ip=$(awk '{ print $3 }' <<<"${SSH_CONNECTION:-}")
    [[ $server_ip == *:* && $server_ip != ::ffff:* ]]
}

# ---------- state helpers ----------

ipv6_addr_count() {
    if [[ -r /proc/net/if_inet6 ]]; then
        awk 'END { print NR }' /proc/net/if_inet6
    else
        echo 0
    fi
}

# Compress a full 8-group IPv6 address (leading zeros already stripped) per RFC 5952.
compress_v6() {
    local IFS=: g i s=-1 l=0 best_s=-1 best_l=0 left right
    read -ra g <<<"$1"
    for i in "${!g[@]}"; do
        if [[ ${g[i]} == 0 ]]; then
            ((s < 0)) && s=$i && l=0
            l=$((l + 1))
            if ((l > best_l)); then best_l=$l best_s=$s; fi
        else
            s=-1
        fi
    done
    if ((best_l < 2)); then
        echo "${g[*]}"
        return
    fi
    left="${g[*]:0:best_s}"
    right="${g[*]:best_s+best_l}"
    echo "${left}::${right}"
}

print_ipv6_addrs() {
    local addr _idx plen scope _flags dev s
    # /proc files always report size 0, so count lines instead of using -s
    if (($(ipv6_addr_count) == 0)); then
        echo "  (no IPv6 addresses)"
        return
    fi
    while read -r addr _idx plen scope _flags dev; do
        case "$scope" in
            00) s="global" ;;
            20) s="link" ;;
            10) s="host" ;;
            *) s="scope 0x$scope" ;;
        esac
        addr=$(compress_v6 "$(sed -E 's/(....)/\1:/g; s/:$//; s/(^|:)0{1,3}([0-9a-f])/\1\2/g' <<<"$addr")")
        printf '  %-12s %s/%d (%s)\n' "$dev" "$addr" "$((16#$plen))" "$s"
    done </proc/net/if_inet6
}

# Other sysctl files that disable IPv6 (they would fight with 'on').
other_disabling_files() {
    grep -lsE '^[[:space:]]*net\.ipv6\.conf\.[^[:space:]=]+\.disable_ipv6[[:space:]]*=[[:space:]]*1' \
        "$LEGACY_CONF" /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null |
        grep -vxF "$CONF" || true
}

# Remove lines written by the original hteppl script from /etc/sysctl.conf.
clean_legacy_conf() {
    [[ -f $LEGACY_CONF ]] || return 0
    grep -qE "$LEGACY_RE" "$LEGACY_CONF" || return 0
    info "Removing old disable_ipv6 lines from $LEGACY_CONF (backup: $LEGACY_CONF.bak.*)"
    cp -p "$LEGACY_CONF" "$LEGACY_CONF.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i --follow-symlinks -E "/$LEGACY_RE/d" "$LEGACY_CONF"
}

# Write a value to disable_ipv6 of all/default and every existing interface.
set_runtime() {
    local value="$1" f
    for f in "$PROC6/conf/default/disable_ipv6" "$PROC6/conf/all/disable_ipv6" "$PROC6"/conf/*/disable_ipv6; do
        [[ -w $f ]] || continue
        echo "$value" >"$f" 2>/dev/null || warn "Could not write $f"
    done
}

restart_hint() {
    if command -v netplan >/dev/null 2>&1 && compgen -G "/etc/netplan/*.yaml" >/dev/null; then
        echo "  netplan apply"
    elif [[ -f /etc/network/interfaces ]]; then
        echo "  systemctl restart networking"
    elif command -v nmcli >/dev/null 2>&1; then
        echo "  nmcli networking off && nmcli networking on"
    fi
    echo "  or simply reboot"
}

# ---------- actions ----------

do_status() {
    echo
    if ! kernel_has_ipv6; then
        if kernel_param_disabled; then
            info "IPv6: disabled in kernel (ipv6.disable=1 in boot parameters)"
        else
            info "IPv6: not available in this kernel"
        fi
        return 0
    fi

    local all
    all=$(cat "$PROC6/conf/all/disable_ipv6" 2>/dev/null || echo "?")
    case "$all" in
        1) printf 'IPv6:        \033[1;31mdisabled\033[0m\n' ;;
        0) printf 'IPv6:        \033[1;32menabled\033[0m\n' ;;
        *) printf 'IPv6:        unknown\n' ;;
    esac

    if [[ -f $CONF ]]; then
        echo "Persistent:  $CONF (disabled after reboot)"
    else
        echo "Persistent:  no config from this script"
    fi
    local others f
    others=$(other_disabling_files)
    if [[ -n $others ]]; then
        echo "Also disabling IPv6:"
        while read -r f; do echo "  $f"; done <<<"$others"
    fi

    # interfaces that differ from 'all'
    local dev v diff=""
    for f in "$PROC6"/conf/*/disable_ipv6; do
        dev=$(basename "$(dirname "$f")")
        [[ $dev == all ]] && continue
        v=$(cat "$f" 2>/dev/null || echo "?")
        if [[ $v != "$all" ]]; then diff+="$dev=$v "; fi
    done
    if [[ -n $diff ]]; then echo "Differs:     $diff"; fi

    echo "Addresses:"
    print_ipv6_addrs
    echo
}

do_disable() {
    if ! kernel_has_ipv6; then
        ok "IPv6 is already disabled at kernel level — nothing to do."
        return 0
    fi
    require_writable

    if ((FORCE == 0)); then
        if ! has_ipv4_default_route; then
            die "No IPv4 default route — this server may be IPv6-only. Disabling IPv6 would cut it off. Use --force to override."
        fi
        local n
        if current_ssh_is_ipv6; then
            die "Your SSH session is over IPv6 and would be dropped. Reconnect over IPv4 or use --force."
        fi
        n=$(ssh_sessions_over_ipv6)
        if ((n > 0)); then
            die "There are $n SSH session(s) over IPv6 — they would be dropped. Reconnect over IPv4 or use --force."
        fi
    else
        warn "--force: safety checks skipped."
    fi

    info "Writing $CONF"
    clean_legacy_conf
    cat >"$CONF" <<EOF
# Managed by ipv6.sh (github.com/jorasssip/scripts). Run 'ipv6.sh on' to revert.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    chmod 644 "$CONF"

    info "Applying..."
    sysctl -q -p "$CONF" >/dev/null
    set_runtime 1

    if [[ $(cat "$PROC6/conf/all/disable_ipv6") != "1" ]]; then
        die "Failed to disable IPv6 (net.ipv6.conf.all.disable_ipv6 is not 1)."
    fi
    local left
    left=$(ipv6_addr_count)
    if ((left > 0)); then
        warn "IPv6 is disabled, but $left address(es) are still present (a network manager may re-enable it):"
        print_ipv6_addrs >&2
    fi
    ok "IPv6 disabled (persists across reboots)."
    if command -v ss >/dev/null 2>&1 && ss -Htln 'src [::1]' 2>/dev/null | grep -q .; then
        warn "Some services were listening on [::1] — they may need to be reconfigured to 127.0.0.1:"
        ss -Htlnp 'src [::1]' 2>/dev/null | awk '{ print "  " $4, $6 }' >&2 || true
    fi
}

do_enable() {
    if ! kernel_has_ipv6; then
        if kernel_param_disabled; then
            die "IPv6 is disabled by the kernel parameter ipv6.disable=1. Remove it from GRUB_CMDLINE_LINUX in /etc/default/grub, run update-grub and reboot."
        fi
        die "IPv6 is not available in this kernel."
    fi
    require_writable

    if [[ -f $CONF ]]; then
        info "Removing $CONF"
        rm -f "$CONF"
    fi
    clean_legacy_conf

    info "Applying..."
    set_runtime 0

    if [[ $(cat "$PROC6/conf/all/disable_ipv6") != "0" ]]; then
        die "Failed to enable IPv6 (net.ipv6.conf.all.disable_ipv6 is not 0)."
    fi

    local others f
    others=$(other_disabling_files)
    if [[ -n $others ]]; then
        warn "These files still disable IPv6 and will turn it off again after reboot:"
        while read -r f; do echo "  $f"; done <<<"$others" >&2
    fi
    ok "IPv6 enabled."
    echo "Auto-configured (SLAAC) addresses come back by themselves."
    echo "Static IPv6 addresses need a network restart:"
    restart_hint
}

# ---------- main ----------

main() {
    local action=""
    while (($#)); do
        case "${1,,}" in
            on | enable) action="enable" ;;
            off | disable) action="disable" ;;
            status) action="status" ;;
            --force) FORCE=1 ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "Unknown argument: $1" ;;
        esac
        shift
    done
    action="${action:-status}"

    case "$action" in
        status) do_status ;;
        enable | disable)
            printf '\n\033[1;35m✨ IPv6 %s\033[0m\n\n' "$([[ $action == enable ]] && echo on || echo off)"
            require_root
            "do_$action"
            do_status
            ;;
    esac
}

main "$@"
