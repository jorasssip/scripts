#!/usr/bin/env bash
#
# fail2ban.sh — install and configure fail2ban to protect SSH (Debian/Ubuntu).
#
# Author:  jorasssip — https://github.com/jorasssip/scripts
# License: MIT (see LICENSE). Based on hteppl/sh.
#
# Usage:
#   bash fail2ban.sh                                   # interactive wizard
#   bash fail2ban.sh --maxretry 2 --bantime 30d        # non-interactive
#   bash fail2ban.sh --status | --unban IP | --uninstall | --help

set -Eeuo pipefail

JAIL_FILE="/etc/fail2ban/jail.d/zz-sshd-hardening.local"
CORE_FILE="/etc/fail2ban/fail2ban.d/zz-sshd-hardening.local"
LEGACY_JAIL="/etc/fail2ban/jail.local"

DEF_MAXRETRY=2
DEF_BANTIME="30d"
DEF_FINDTIME="1h"
DEF_MAXTIME="1y"
DEF_INCREMENT=1
BASE_IGNOREIP="127.0.0.1/8 ::1"

# ---------- output helpers ----------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: fail2ban.sh [options]

Without options an interactive wizard asks for every setting.
With any setting flag the script runs non-interactively (missing values = defaults).

Settings:
  --maxretry N        Failed attempts before ban                (default: ${DEF_MAXRETRY})
  --bantime T         Ban duration, e.g. 10m, 12h, 30d, 1w, 1y,
                      or -1 for a permanent ban                 (default: ${DEF_BANTIME})
  --findtime T        Window in which attempts are counted      (default: ${DEF_FINDTIME})
  --no-increment      Disable incremental bans (enabled by default:
                      every repeated ban of the same IP is twice as long)
  --maxtime T         Upper limit for incremental bans          (default: ${DEF_MAXTIME})
  --ignoreip "LIST"   Extra IPs/CIDRs never banned, space/comma separated
                      (localhost is always ignored; your SSH IP is NOT added)
  --port LIST         SSH ports, comma separated                (default: auto-detect)

Actions:
  --status            Show fail2ban and sshd jail status
  --unban IP          Unban an IP address
  --uninstall         Remove this configuration and the fail2ban package
  -h, --help          Show this help

Time units: s, m, h, d, w, mo (30d), y (365d). A plain number means seconds.

Examples:
  fail2ban.sh --maxretry 2 --bantime 30d
  fail2ban.sh --maxretry 3 --bantime 1d --findtime 10m --no-increment
  fail2ban.sh --unban 203.0.113.7
EOF
}

# ---------- parsing / validation ----------

# Convert a fail2ban-like duration to seconds. -1 stays -1 (permanent).
to_seconds() {
    local raw="$1" name="$2" n unit
    if [[ $raw == "-1" ]]; then
        echo -1
        return
    fi
    [[ $raw =~ ^([0-9]+)(s|m|h|d|w|mo|y)?$ ]] || die "Invalid $name: '$raw' (examples: 600, 10m, 12h, 30d, 1w, 1y)."
    n=$((10#${BASH_REMATCH[1]}))
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        "" | s) ;;
        m) n=$((n * 60)) ;;
        h) n=$((n * 3600)) ;;
        d) n=$((n * 86400)) ;;
        w) n=$((n * 604800)) ;;
        mo) n=$((n * 2592000)) ;;
        y) n=$((n * 31536000)) ;;
    esac
    ((n > 0)) || die "$name must be greater than 0."
    echo "$n"
}

# Seconds -> short human readable string.
human_time() {
    local s="$1"
    if ((s == -1)); then echo "permanent"; return; fi
    if ((s % 86400 == 0)); then echo "$((s / 86400))d"
    elif ((s % 3600 == 0)); then echo "$((s / 3600))h"
    elif ((s % 60 == 0)); then echo "$((s / 60))m"
    else echo "${s}s"; fi
}

validate_maxretry() {
    if ! [[ $1 =~ ^[0-9]{1,3}$ ]] || ((10#$1 < 1 || 10#$1 > 100)); then
        die "Invalid maxretry: '$1'. Expected 1-100."
    fi
}

# Normalize and validate an IP/CIDR list. Prints space separated list.
normalize_iplist() {
    local raw="$1" item out=()
    for item in ${raw//,/ }; do
        [[ $item =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || die "Invalid IP/CIDR in ignore list: '$item'."
        out+=("$item")
    done
    echo "${out[*]:-}"
}

validate_ports() {
    local p
    [[ $1 =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Invalid port list: '$1' (example: 22,2222)."
    for p in ${1//,/ }; do
        ((10#$p >= 1 && 10#$p <= 65535)) || die "Invalid port: $p"
    done
}

# ---------- system checks ----------

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root (e.g. via sudo)."
}

require_debian() {
    if [[ ! -f /etc/debian_version ]] || ! command -v apt-get >/dev/null 2>&1; then
        die "Only Debian/Ubuntu (apt) are supported."
    fi
}

has_systemd() {
    [[ -d /run/systemd/system ]]
}

# Detect SSH ports from ssh.socket (socket activation, Ubuntu 22.10+) or sshd config.
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

# ---------- interactive helpers ----------

HAVE_TTY=0
if [[ -t 0 && -r /dev/tty ]]; then HAVE_TTY=1; fi

ask() {
    local prompt="$1" def="$2" var
    read -rp "$prompt [$def]: " var </dev/tty || var=""
    echo "${var:-$def}"
}

ask_yn() {
    local prompt="$1" def="$2" var
    read -rp "$prompt [$def]: " var </dev/tty || var=""
    var="${var:-$def}"
    [[ $var =~ ^[YyДд] ]]
}

# ---------- config generation ----------

backup_file() {
    local f="$1"
    [[ -f $f ]] || return 0
    cp -p "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
}

# The original hteppl script writes this jail.local; it conflicts with our
# backend (hardcoded auth.log) — back it up and remove it.
handle_legacy_jail() {
    [[ -f $LEGACY_JAIL ]] || return 0
    if grep -q '^logpath = /var/log/auth.log' "$LEGACY_JAIL" &&
        grep -q '^maxretry = 1' "$LEGACY_JAIL" &&
        grep -q '^bantime = -1' "$LEGACY_JAIL"; then
        warn "Found jail.local from the original hteppl script — backing it up and removing."
        backup_file "$LEGACY_JAIL"
        rm -f "$LEGACY_JAIL"
    else
        warn "$LEGACY_JAIL exists and is kept. Its [sshd] settings are overridden by $JAIL_FILE."
    fi
}

write_configs() {
    local backend="$1" banaction="$2" dbpurge
    mkdir -p "$(dirname "$JAIL_FILE")" "$(dirname "$CORE_FILE")"

    # Bans must stay in the DB at least as long as they (and the increment history) last,
    # otherwise they are lost after a restart.
    if ((BANTIME == -1)); then
        dbpurge=$((10 * 31536000))
    elif ((INCREMENT == 1)); then
        dbpurge=$((MAXTIME + 86400))
    else
        dbpurge=$((BANTIME + 86400))
    fi

    cat >"$CORE_FILE" <<EOF
# Managed by fail2ban.sh (github.com/jorasssip/scripts). Re-run the script to change.
[Definition]
# NOTICE logs only bans/unbans and errors (INFO would log every failed attempt)
loglevel = NOTICE
# silences "allowipv6 not defined" warning on fail2ban 1.0.x
allowipv6 = auto
dbpurgeage = ${dbpurge}
# keep only 1 log line per ban in the DB to keep it small
dbmaxmatches = 1
EOF

    {
        echo "# Managed by fail2ban.sh (github.com/jorasssip/scripts). Re-run the script to change."
        echo "[sshd]"
        echo "enabled = true"
        echo "port = ${PORTS}"
        echo "backend = ${backend}"
        if [[ $backend == "systemd" ]]; then
            # ssh.service on Debian/Ubuntu, sshd-session on OpenSSH 9.8+
            echo "journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session"
        else
            echo "logpath = %(sshd_log)s"
        fi
        echo "banaction = ${banaction}"
        echo "ignoreip = ${IGNOREIP}"
        echo "maxretry = ${MAXRETRY}"
        echo "# $(human_time "$FINDTIME")"
        echo "findtime = ${FINDTIME}"
        echo "# $(human_time "$BANTIME")"
        echo "bantime = ${BANTIME}"
        # keep at most maxretry matches per IP in memory
        echo "maxmatches = ${MAXRETRY}"
        if ((INCREMENT == 1)); then
            echo "bantime.increment = true"
            echo "bantime.factor = 1"
            echo "# $(human_time "$MAXTIME")"
            echo "bantime.maxtime = ${MAXTIME}"
        else
            echo "bantime.increment = false"
        fi
    } >"$JAIL_FILE"
    chmod 644 "$JAIL_FILE" "$CORE_FILE"
}

# ---------- actions ----------

wait_for_server() {
    local _
    for _ in $(seq 1 30); do
        fail2ban-client ping >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

show_status() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        die "fail2ban is not installed."
    fi
    fail2ban-client ping >/dev/null 2>&1 || die "fail2ban server is not running."
    fail2ban-client status
    echo
    fail2ban-client status sshd || true
    local pid="" rss_kb=""
    [[ -r /run/fail2ban/fail2ban.pid ]] && pid=$(cat /run/fail2ban/fail2ban.pid)
    [[ -n $pid && -r /proc/$pid/status ]] && rss_kb=$(awk '/^VmRSS/ { print $2 }' "/proc/$pid/status")
    if [[ -n $rss_kb ]]; then
        echo
        info "fail2ban-server memory (RSS): $((rss_kb / 1024)) MB"
    fi
}

do_unban() {
    local ip="$1"
    [[ $ip =~ ^[0-9A-Fa-f:.]+$ ]] || die "Invalid IP: '$ip'"
    fail2ban-client ping >/dev/null 2>&1 || die "fail2ban server is not running."
    if fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1; then
        ok "Unbanned $ip"
    else
        die "Failed to unban $ip (is it banned?)"
    fi
}

do_uninstall() {
    info "Removing fail2ban configuration and package..."
    if has_systemd; then
        systemctl disable --now fail2ban >/dev/null 2>&1 || true
    else
        fail2ban-client stop >/dev/null 2>&1 || true
    fi
    rm -f "$JAIL_FILE" "$CORE_FILE"
    if dpkg -s fail2ban >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq fail2ban >/dev/null
    fi
    ok "fail2ban removed. Existing bans are lifted."
}

configure_interactive() {
    echo "Configure SSH protection (press Enter to accept the default):"
    MAXRETRY=$(ask "  Failed attempts before ban" "$MAXRETRY")
    validate_maxretry "$MAXRETRY"
    BANTIME_RAW=$(ask "  Ban duration (10m, 12h, 30d, 1y, -1 = forever)" "$BANTIME_RAW")
    BANTIME=$(to_seconds "$BANTIME_RAW" "bantime")
    FINDTIME_RAW=$(ask "  Window for counting attempts" "$FINDTIME_RAW")
    FINDTIME=$(to_seconds "$FINDTIME_RAW" "findtime")
    if ((BANTIME != -1)); then
        if ask_yn "  Incremental bans (repeat offenders banned longer)?" "Y"; then
            INCREMENT=1
            MAXTIME_RAW=$(ask "  Maximum ban duration for repeat offenders" "$MAXTIME_RAW")
        else
            INCREMENT=0
        fi
    fi
    IGNORE_EXTRA=$(ask "  Extra IPs/CIDRs to never ban (empty = none)" "${IGNORE_EXTRA:-}")
    PORTS=$(ask "  SSH port(s)" "$PORTS")
}

print_summary() {
    echo
    info "Settings:"
    echo "  maxretry   = $MAXRETRY"
    echo "  findtime   = $(human_time "$FINDTIME")"
    echo "  bantime    = $(human_time "$BANTIME")"
    if ((INCREMENT == 1)); then
        echo "  increment  = on (x2 for every repeated ban, max $(human_time "$MAXTIME"))"
    else
        echo "  increment  = off"
    fi
    echo "  ignoreip   = $IGNOREIP"
    echo "  ssh ports  = $PORTS"
    echo
}

do_install() {
    local interactive="$1" backend banaction pkgs=(fail2ban) ver

    require_debian
    [[ -z $PORTS ]] && PORTS=$(detect_ssh_ports)

    if ((interactive == 1)); then
        configure_interactive
    fi

    # validate and normalize everything (flags or wizard)
    validate_maxretry "$MAXRETRY"
    MAXRETRY=$((10#$MAXRETRY))
    BANTIME=$(to_seconds "$BANTIME_RAW" "bantime")
    FINDTIME=$(to_seconds "$FINDTIME_RAW" "findtime")
    ((FINDTIME != -1)) || die "findtime cannot be -1."
    MAXTIME=$(to_seconds "$MAXTIME_RAW" "maxtime")
    ((MAXTIME != -1)) || die "maxtime cannot be -1."
    if ((BANTIME == -1 && INCREMENT == 1)); then
        INCREMENT=0 # permanent bans cannot grow
    fi
    if ((INCREMENT == 1 && MAXTIME < BANTIME)); then
        warn "maxtime is lower than bantime — using bantime as maxtime."
        MAXTIME=$BANTIME
    fi
    validate_ports "$PORTS"
    IGNOREIP=$(normalize_iplist "$BASE_IGNOREIP ${IGNORE_EXTRA:-}")

    print_summary
    if ((interactive == 1)) && ! ask_yn "Apply these settings?" "Y"; then
        echo "Aborted."
        exit 0
    fi

    # backend: systemd journal if systemd is running, otherwise log files
    if has_systemd; then
        backend="systemd"
        pkgs+=(python3-systemd)
    else
        backend="auto"
    fi

    # firewall: prefer nftables
    if command -v nft >/dev/null 2>&1; then
        banaction="nftables-multiport"
    elif command -v iptables >/dev/null 2>&1; then
        banaction="iptables-multiport"
    else
        banaction="nftables-multiport"
        pkgs+=(nftables)
    fi

    info "Installing packages: ${pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null

    ver=$(fail2ban-client --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    info "fail2ban version: ${ver:-unknown}"
    if ((INCREMENT == 1)) && [[ -n $ver ]] && ! printf '%s\n%s\n' "0.11" "$ver" | sort -VC; then
        warn "fail2ban $ver does not support incremental bans — disabling them."
        INCREMENT=0
    fi
    if [[ $backend == "auto" && ! -f /var/log/auth.log ]]; then
        die "No systemd journal and no /var/log/auth.log — fail2ban has nothing to read."
    fi

    handle_legacy_jail

    # write configs with rollback on invalid config
    local tmpdir
    tmpdir=$(mktemp -d)
    [[ -f $JAIL_FILE ]] && cp -p "$JAIL_FILE" "$tmpdir/jail"
    [[ -f $CORE_FILE ]] && cp -p "$CORE_FILE" "$tmpdir/core"

    info "Writing $JAIL_FILE and $CORE_FILE"
    write_configs "$backend" "$banaction"

    if ! fail2ban-client -t >/dev/null 2>&1; then
        warn "Configuration test failed:"
        fail2ban-client -t 2>&1 | tail -n 20 >&2 || true
        rm -f "$JAIL_FILE" "$CORE_FILE"
        [[ -f $tmpdir/jail ]] && cp -p "$tmpdir/jail" "$JAIL_FILE"
        [[ -f $tmpdir/core ]] && cp -p "$tmpdir/core" "$CORE_FILE"
        rm -rf "$tmpdir"
        die "Previous configuration restored. Nothing was restarted."
    fi
    rm -rf "$tmpdir"

    if has_systemd; then
        info "Enabling and restarting fail2ban..."
        systemctl enable fail2ban >/dev/null 2>&1
        systemctl restart fail2ban
    else
        warn "systemd is not running — start fail2ban manually: fail2ban-client start"
        ok "Configuration written."
        return 0
    fi

    wait_for_server || die "fail2ban did not start. Check: journalctl -u fail2ban -n 50"
    ok "fail2ban is running"
    echo
    show_status
    echo
    warn "Your current IP is NOT whitelisted: ${MAXRETRY} failed login(s) will ban you too."
    echo "Useful commands:"
    echo "  Status:     fail2ban-client status sshd"
    echo "  Unban IP:   fail2ban-client set sshd unbanip <IP>"
    echo "  Ban log:    journalctl -u fail2ban  (or /var/log/fail2ban.log)"
}

# ---------- main ----------

MAXRETRY="$DEF_MAXRETRY"
BANTIME_RAW="$DEF_BANTIME"
FINDTIME_RAW="$DEF_FINDTIME"
MAXTIME_RAW="$DEF_MAXTIME"
INCREMENT="$DEF_INCREMENT"
IGNORE_EXTRA=""
PORTS=""
BANTIME=0 FINDTIME=0 MAXTIME=0 IGNOREIP=""

main() {
    local action="install" settings=0 unban_ip=""

    need_val() { [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"; }

    while (($#)); do
        case "$1" in
            --maxretry) need_val "$@"; MAXRETRY="$2"; settings=1; shift ;;
            --bantime) need_val "$@"; BANTIME_RAW="$2"; settings=1; shift ;;
            --findtime) need_val "$@"; FINDTIME_RAW="$2"; settings=1; shift ;;
            --maxtime) need_val "$@"; MAXTIME_RAW="$2"; settings=1; shift ;;
            --ignoreip) need_val "$@"; IGNORE_EXTRA="$2"; settings=1; shift ;;
            --port) need_val "$@"; PORTS="$2"; settings=1; shift ;;
            --no-increment) INCREMENT=0; settings=1 ;;
            --maxretry=* | --bantime=* | --findtime=* | --maxtime=* | --ignoreip=* | --port=*)
                set -- "${1%%=*}" "${1#*=}" "${@:2}"
                continue
                ;;
            --status) action="status" ;;
            --unban) need_val "$@"; action="unban"; unban_ip="$2"; shift ;;
            --uninstall) action="uninstall" ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    printf '\n\033[1;35m✨ fail2ban SSH protection\033[0m\n\n'
    require_root

    case "$action" in
        status) show_status ;;
        unban) do_unban "$unban_ip" ;;
        uninstall) do_uninstall ;;
        install)
            if ((settings == 0 && HAVE_TTY == 1)); then
                do_install 1
            else
                do_install 0
            fi
            ;;
    esac
}

main "$@"
