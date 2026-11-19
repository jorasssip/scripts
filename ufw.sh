#!/usr/bin/env bash
#
# ufw.sh — basic node firewall with ufw (Debian/Ubuntu, IPv4 only).
#
# Author:  jorasssip — https://github.com/jorasssip/scripts
# License: MIT (see LICENSE).
#
# Rules: deny all incoming, allow all outgoing, allow SSH and 443/tcp from anywhere,
# allow the node port (default 3001/tcp) only from the panel IP(s).
#
# Usage:
#   bash ufw.sh                                        # interactive (asks for panel IP)
#   bash ufw.sh --panel-ip 203.0.113.10 --yes          # non-interactive
#   bash ufw.sh --status | --disable | --help

set -Eeuo pipefail

# `su` without `-` on Debian does not add sbin dirs to PATH (ufw lives in /usr/sbin)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

DEF_NODE_PORT=3001
HTTPS_PORT=443
UFW_DEFAULTS="/etc/default/ufw"
APT_OPTS=(-y -qq -o DPkg::Lock::Timeout=180)

# ---------- output helpers ----------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: ufw.sh [options]

Without --panel-ip the script asks for the panel IP interactively.

Settings:
  --panel-ip LIST     Panel IPv4 address(es) or CIDR(s), comma separated.
                      Only these may connect to the node port.
  --node-port N       Node port opened for the panel          (default: ${DEF_NODE_PORT})
  --ssh-port LIST     SSH port(s), comma separated            (default: auto-detect)
  -y, --yes           Do not ask for confirmation

Actions:
  --status            Show ufw status
  --disable           Disable ufw (rules are kept)
  -h, --help          Show this help

Applied rules (all existing ufw rules are reset first, ufw backs them up):
  default deny incoming, default allow outgoing
  allow <ssh ports>/tcp            from anywhere
  allow ${HTTPS_PORT}/tcp                  from anywhere
  allow <node port>/tcp            from panel IP(s) only
IPv6 is disabled in ufw (IPV6=no): only IPv4 rules are created.

Examples:
  ufw.sh --panel-ip 203.0.113.10
  ufw.sh --panel-ip 203.0.113.10,198.51.100.0/24 --node-port 3001 --yes
EOF
}

# ---------- validation ----------

# Strict IPv4 or IPv4/CIDR check. Rejects leading zeros, octets > 255,
# "everything" (/0, 0.0.0.0) and loopback — they make no sense as a panel address.
valid_ipv4() {
    local ip="$1" addr prefix="" o
    if [[ $ip == */* ]]; then
        addr="${ip%/*}"
        prefix="${ip#*/}"
        [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && ((prefix >= 1 && prefix <= 32)) || return 1
    else
        addr="$ip"
    fi
    [[ $addr =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && ((o <= 255)) || return 1
    done
    [[ $addr == "0.0.0.0" || $addr == "255.255.255.255" || $addr == 127.* ]] && return 1
    return 0
}

# Validate and normalize a comma/space separated IPv4 list. Prints space separated list.
normalize_panel_ips() {
    local raw="$1" item out=() seen=" "
    for item in ${raw//,/ }; do
        if ! valid_ipv4 "$item"; then
            if [[ $item == *:* ]]; then
                warn "'$item' is IPv6 — only IPv4 is supported (IPv6 is disabled in ufw)."
            else
                warn "Invalid IPv4 address/CIDR: '$item'."
            fi
            return 1
        fi
        [[ $seen == *" $item "* ]] && continue
        seen+="$item "
        out+=("$item")
    done
    ((${#out[@]} > 0)) || { warn "Panel IP is empty."; return 1; }
    echo "${out[*]}"
}

valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535))
}

validate_port_list() {
    local p
    [[ $1 =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Invalid port list: '$1' (example: 22,2222)."
    for p in ${1//,/ }; do
        valid_port "$p" || die "Invalid port: '$p'."
    done
}

# ---------- system checks ----------

require_debian() {
    if [[ ! -f /etc/debian_version ]] || ! command -v apt-get >/dev/null 2>&1; then
        die "Only Debian/Ubuntu (apt) are supported."
    fi
}

has_systemd() {
    [[ -d /run/systemd/system ]]
}

os_name() {
    local name=""
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && name=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
    echo "${name:-Debian-based}"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# Install ufw (and sudo, if missing). Runs apt-get update only when something is missing.
install_packages() {
    local pkgs=() p
    for p in ufw sudo; do
        pkg_installed "$p" || pkgs+=("$p")
    done
    if ((${#pkgs[@]} == 0)); then
        ok "ufw and sudo are already installed"
        return 0
    fi
    info "Installing: ${pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get "${APT_OPTS[@]}" update >/dev/null || die "apt-get update failed."
    apt-get "${APT_OPTS[@]}" install --no-install-recommends "${pkgs[@]}" >/dev/null ||
        die "Failed to install: ${pkgs[*]}"
    command -v ufw >/dev/null 2>&1 || die "ufw is not available after installation."
    ok "Installed: ${pkgs[*]}"
}

# SSH ports sshd listens on: ssh.socket (socket activation, Ubuntu 22.10+) or sshd config.
detect_ssh_ports() {
    local ports=""
    if has_systemd && systemctl is-active --quiet ssh.socket 2>/dev/null; then
        ports=$(systemctl show ssh.socket -p Listen --value 2>/dev/null |
            grep -oE ':[0-9]+ ' | tr -d ': ' | sort -un | paste -sd, -)
    fi
    if [[ -z $ports ]] && command -v sshd >/dev/null 2>&1; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd, -)
    fi
    echo "${ports:-22}"
}

# Local ports of currently established SSH sessions (so we never lock ourselves out).
# Uses $SSH_CONNECTION (lost under sudo) and established sockets owned by sshd.
active_ssh_ports() {
    local ports=() conn
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r _ _ _ conn <<<"$SSH_CONNECTION"
        [[ -n $conn ]] && ports+=("$conn")
    fi
    if command -v ss >/dev/null 2>&1; then
        while read -r conn; do
            [[ -n $conn ]] && ports+=("$conn")
        done < <(ss -Htnp state established 2>/dev/null |
            awk '/"sshd/ { n = split($3, a, ":"); print a[n] }')
    fi
    ((${#ports[@]})) && printf '%s\n' "${ports[@]}" | sort -un | paste -sd, -
    return 0
}

# Build the final SSH port list and make sure the current session's port is in it.
resolve_ssh_ports() {
    local active p list
    [[ -z $SSH_PORTS ]] && SSH_PORTS=$(detect_ssh_ports)
    validate_port_list "$SSH_PORTS"
    active=$(active_ssh_ports)
    list=",${SSH_PORTS},"
    for p in ${active//,/ }; do
        valid_port "$p" || continue
        if [[ $list != *",$p,"* ]]; then
            warn "Active SSH session on port $p is not in the SSH port list — adding it to avoid a lockout."
            SSH_PORTS+=",$p"
            list+="$p,"
        fi
    done
    SSH_PORTS=$(tr ',' '\n' <<<"$SSH_PORTS" | sort -un | paste -sd, -)
}

check_firewalld() {
    has_systemd || return 0
    systemctl is-active --quiet firewalld 2>/dev/null || return 0
    warn "firewalld is active and conflicts with ufw."
    if ((ASSUME_YES == 0)) && ! ask_yn "Stop and disable firewalld?" "Y"; then
        die "Aborted: ufw cannot work together with firewalld."
    fi
    systemctl disable --now firewalld >/dev/null 2>&1 || die "Failed to stop firewalld."
    ok "firewalld stopped and disabled"
}

# Docker publishes ports through its own iptables chains — ufw does NOT filter them.
check_docker() {
    local published line
    command -v docker >/dev/null 2>&1 || return 0
    published=$(docker ps --format '{{.Names}}  {{.Ports}}' 2>/dev/null |
        grep -E '(0\.0\.0\.0|\[::\]|:::):[0-9]+->' || true)
    [[ -n $published ]] || return 0
    echo
    warn "Docker containers with published ports detected:"
    while IFS= read -r line; do printf '      %s\n' "$line" >&2; done <<<"$published"
    warn "Docker bypasses ufw: these ports are reachable from ANY IP regardless of the rules above."
    warn "Use network_mode: host, or bind ports to 127.0.0.1 (e.g. \"127.0.0.1:8080:8080\")."
}

check_ipv6() {
    command -v ip >/dev/null 2>&1 || return 0
    if [[ -n $(ip -6 addr show scope global 2>/dev/null) ]]; then
        echo
        warn "This server has a global IPv6 address, but ufw is IPv4-only now — IPv6 traffic is NOT filtered."
        warn "Disable IPv6: bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/ipv6.sh) off"
    fi
}

# ---------- interactive helpers ----------

HAVE_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi

ask() {
    local prompt="$1" def="${2:-}" var
    if [[ -n $def ]]; then
        read -rp "$prompt [$def]: " var </dev/tty || var=""
    else
        read -rp "$prompt: " var </dev/tty || var=""
    fi
    echo "${var:-$def}"
}

ask_yn() {
    local prompt="$1" def="$2" var
    if ((HAVE_TTY == 0)); then
        [[ $def =~ ^[Yy] ]]
        return
    fi
    read -rp "$prompt [$def]: " var </dev/tty || var=""
    var="${var:-$def}"
    [[ $var =~ ^[YyДд] ]]
}

ask_panel_ips() {
    local raw normalized
    while true; do
        raw=$(ask "Panel IPv4 address (several: comma separated)")
        if normalized=$(normalize_panel_ips "$raw"); then
            PANEL_IPS="$normalized"
            return 0
        fi
    done
}

# ---------- actions ----------

require_ufw() {
    command -v ufw >/dev/null 2>&1 || die "ufw is not installed. Run the script without --status/--disable first."
}

show_status() {
    require_ufw
    ufw status verbose
}

do_disable() {
    require_ufw
    ufw disable
    ok "ufw disabled. Rules are kept: re-enable with 'ufw enable'."
}

# Turn off IPv6 handling in ufw so only iptables (IPv4) rules are managed.
set_ipv4_only() {
    if [[ -f $UFW_DEFAULTS ]] && grep -q '^IPV6=' "$UFW_DEFAULTS"; then
        sed -i 's/^IPV6=.*/IPV6=no/' "$UFW_DEFAULTS"
    else
        echo "IPV6=no" >>"$UFW_DEFAULTS"
    fi
}

print_summary() {
    local ip
    echo
    info "Rules to apply (IPv4 only):"
    echo "  default    deny incoming, allow outgoing"
    echo "  SSH        ${SSH_PORTS}/tcp  from anywhere"
    echo "  HTTPS      ${HTTPS_PORT}/tcp  from anywhere"
    for ip in $PANEL_IPS; do
        echo "  Node       ${NODE_PORT}/tcp  from ${ip}"
    done
    echo
}

apply_rules() {
    local p ip

    info "Resetting ufw rules (old rules are backed up by ufw to /etc/ufw/*.<date>)"
    ufw --force reset >/dev/null
    set_ipv4_only

    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    for p in ${SSH_PORTS//,/ }; do
        ufw allow in proto tcp from any to any port "$p" comment 'SSH' >/dev/null
    done
    ufw allow in proto tcp from any to any port "$HTTPS_PORT" comment 'HTTPS' >/dev/null
    for ip in $PANEL_IPS; do
        ufw allow in proto tcp from "$ip" to any port "$NODE_PORT" comment 'Panel -> node' >/dev/null
    done

    info "Enabling ufw"
    if ! ufw --force enable >/dev/null 2>&1; then
        ufw --force enable >&2 || true
        die "Failed to enable ufw (no iptables/netfilter support? containers need NET_ADMIN)."
    fi
    if has_systemd; then
        systemctl enable --quiet ufw >/dev/null 2>&1 || warn "Failed to enable ufw.service at boot."
    fi
    ufw status | grep -q '^Status: active' || die "ufw is not active after enabling."
    ok "ufw is active"
}

do_apply() {
    require_debian
    info "OS: $(os_name)"

    if [[ -n $PANEL_IPS ]]; then
        PANEL_IPS=$(normalize_panel_ips "$PANEL_IPS") || die "Fix --panel-ip and try again."
    elif ((HAVE_TTY == 1)); then
        ask_panel_ips
    else
        die "No terminal for input — pass the panel IP: --panel-ip 203.0.113.10"
    fi
    valid_port "$NODE_PORT" || die "Invalid node port: '$NODE_PORT'."

    install_packages
    resolve_ssh_ports
    check_firewalld

    if [[ $(ufw status 2>/dev/null | head -n1) == "Status: active" ]]; then
        echo
        warn "ufw is already active. ALL current rules will be replaced:"
        ufw status numbered 2>/dev/null | grep '^\[' | while IFS= read -r line; do
            printf '      %s\n' "$line" >&2
        done || true
    fi

    print_summary
    if ((ASSUME_YES == 0)) && ((HAVE_TTY == 1)) && ! ask_yn "Apply these rules?" "Y"; then
        echo "Aborted. Nothing was changed."
        exit 0
    fi

    apply_rules
    echo
    ufw status verbose
    check_docker
    check_ipv6
    echo
    echo "Useful commands:"
    echo "  Status:      ufw status verbose"
    echo "  Add panel:   ufw allow in proto tcp from <IP> to any port ${NODE_PORT} comment 'Panel -> node'"
    echo "  Disable:     ufw disable"
}

# ---------- main ----------

PANEL_IPS=""
NODE_PORT="$DEF_NODE_PORT"
SSH_PORTS=""
ASSUME_YES=0

main() {
    local action="apply" orig_args=("$@")

    need_val() { [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"; }

    while (($#)); do
        case "$1" in
            --panel-ip) need_val "$@"; PANEL_IPS="$2"; shift ;;
            --node-port) need_val "$@"; NODE_PORT="$2"; shift ;;
            --ssh-port) need_val "$@"; SSH_PORTS="$2"; shift ;;
            --panel-ip=* | --node-port=* | --ssh-port=*)
                set -- "${1%%=*}" "${1#*=}" "${@:2}"
                continue
                ;;
            -y | --yes) ASSUME_YES=1 ;;
            --status) action="status" ;;
            --disable) action="disable" ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    printf '\n\033[1;35m🛡  ufw node firewall\033[0m\n\n'

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1 && [[ -f $0 && -r $0 ]]; then
            info "Not root — restarting with sudo"
            exec sudo -- bash "$0" "${orig_args[@]}"
        fi
        if command -v sudo >/dev/null 2>&1; then
            die "Run as root: curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/ufw.sh | sudo bash"
        fi
        die "Run as root (sudo is not installed — log in as root or use 'su -'); the script will install sudo."
    fi

    case "$action" in
        status) show_status ;;
        disable) do_disable ;;
        apply) do_apply ;;
    esac
}

main "$@"
