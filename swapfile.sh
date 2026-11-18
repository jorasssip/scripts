#!/usr/bin/env bash
#
# swapfile.sh — create or remove a swap file on a Linux server.
#
# Author:  jorasssip — https://github.com/jorasssip/scripts
# License: MIT (see LICENSE). Based on hteppl/sh.
#
# Usage:
#   bash swapfile.sh                                  # interactive menu
#   bash swapfile.sh --enable [--size 2048|2G] [--swappiness 10]
#   bash swapfile.sh --disable
#   bash swapfile.sh --help

set -Eeuo pipefail

SWAPFILE="${SWAPFILE:-/swapfile}"
DEFAULT_SIZE_MB=2048
SYSCTL_CONF="/etc/sysctl.d/99-swapfile.conf"
FSTAB="/etc/fstab"
RESERVE_MB=256 # keep at least this much free disk space after creating swap

# ---------- output helpers ----------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Without options an interactive menu is shown.

Options:
  --enable              Create and enable swap file ($SWAPFILE)
  --size N              Swap size: MB by default, or with suffix M/G (e.g. 2048, 2G)
                        Default: ${DEFAULT_SIZE_MB} MB
  --swappiness N        Also set vm.swappiness (0-200) persistently
  --disable             Disable and remove swap file
  -h, --help            Show this help

Examples:
  $(basename "$0") --enable --size 2048
  $(basename "$0") --enable --size 4G --swappiness 10
  $(basename "$0") --disable
EOF
}

# ---------- checks ----------

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root (e.g. via sudo)."
}

require_cmds() {
    local c missing=()
    for c in mkswap swapon swapoff awk df stat; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    ((${#missing[@]} == 0)) || die "Missing required commands: ${missing[*]}"
}

check_not_container() {
    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt --container 2>/dev/null || true)
    fi
    if [[ -f /proc/user_beancounters ]]; then
        virt="openvz"
    fi
    if [[ -n $virt && $virt != "none" ]]; then
        die "Running inside a container ($virt): swap is managed by the host and cannot be enabled here."
    fi
}

# Parse size like "2048", "512M", "2G" into megabytes.
parse_size_mb() {
    local raw="$1" num unit
    if [[ $raw =~ ^([0-9]+)([MmGg]?)$ ]]; then
        num=$((10#${BASH_REMATCH[1]}))
        unit="${BASH_REMATCH[2]}"
        [[ $unit == [Gg] ]] && num=$((num * 1024))
        ((num > 0)) || die "Swap size must be greater than 0."
        echo "$num"
    else
        die "Invalid size: '$raw'. Use a number in MB (2048) or with suffix (512M, 2G)."
    fi
}

validate_swappiness() {
    if ! [[ $1 =~ ^[0-9]{1,3}$ ]] || ((10#$1 > 200)); then
        die "Invalid swappiness: '$1'. Expected 0-200."
    fi
}

# ---------- state helpers ----------

swap_is_active() {
    awk -v f="$SWAPFILE" 'NR > 1 && $1 == f { found = 1 } END { exit !found }' /proc/swaps
}

fstab_has_entry() {
    awk -v f="$SWAPFILE" '$1 == f { found = 1 } END { exit !found }' "$FSTAB"
}

fstab_add_entry() {
    fstab_has_entry && return 0
    # make sure the file ends with a newline before appending
    [[ -s $FSTAB && -n $(tail -c1 "$FSTAB") ]] && echo >>"$FSTAB"
    echo "$SWAPFILE none swap sw 0 0" >>"$FSTAB"
}

fstab_remove_entry() {
    fstab_has_entry || return 0
    local tmp
    tmp=$(mktemp)
    awk -v f="$SWAPFILE" '$1 != f' "$FSTAB" >"$tmp"
    cat "$tmp" >"$FSTAB" # keep original inode, owner and permissions
    rm -f "$tmp"
}

free_space_mb() {
    df -Pm "$(dirname "$SWAPFILE")" | awk 'NR == 2 { print $4 }'
}

show_status() {
    echo
    info "Current swap status:"
    if [[ $(awk 'NR > 1' /proc/swaps | wc -l) -gt 0 ]]; then
        swapon --show 2>/dev/null || cat /proc/swaps
    else
        echo "  (no active swap)"
    fi
    free -h 2>/dev/null || true
}

# ---------- cleanup on failure ----------

CREATING=0
cleanup() {
    local rc=$?
    if ((CREATING == 1)); then
        warn "Failed while creating swap file, cleaning up..."
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- swap file creation ----------

create_with_dd() {
    local size="$1"
    rm -f "$SWAPFILE"
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size" status=progress
}

fs_type() {
    local dir
    dir=$(dirname "$SWAPFILE")
    findmnt -n -o FSTYPE --target "$dir" 2>/dev/null || stat -f -c %T "$dir"
}

FORMATTED=0 # set to 1 when the file is already formatted as swap
create_swapfile() {
    local size="$1" fstype
    fstype=$(fs_type)
    info "Filesystem: $fstype"

    umask 077
    case "$fstype" in
        btrfs)
            # btrfs needs NOCOW, no compression and a contiguous file
            if btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
                btrfs filesystem mkswapfile --size "${size}m" "$SWAPFILE" >/dev/null
                FORMATTED=1
            else
                rm -f "$SWAPFILE"
                touch "$SWAPFILE"
                chattr +C "$SWAPFILE"
                create_with_dd "$size"
            fi
            ;;
        ext4 | ext3 | ext2 | ext2/ext3 | xfs)
            fallocate -l "${size}M" "$SWAPFILE" 2>/dev/null || create_with_dd "$size"
            ;;
        *)
            # fallocate'd files are not safe for swap on many filesystems — write real zeros
            create_with_dd "$size"
            ;;
    esac
    chmod 600 "$SWAPFILE"
}

activate_swapfile() {
    local size="$1"
    ((FORMATTED == 1)) || mkswap "$SWAPFILE" >/dev/null
    if ! swapon "$SWAPFILE" 2>/dev/null; then
        warn "swapon failed (file may have holes), recreating with dd..."
        create_with_dd "$size"
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE" >/dev/null
        swapon "$SWAPFILE"
    fi
}

set_swappiness() {
    local value="$1"
    info "Setting vm.swappiness=$value (persisted in $SYSCTL_CONF)"
    echo "vm.swappiness = $value" >"$SYSCTL_CONF"
    sysctl -q -w vm.swappiness="$value"
}

# ---------- actions ----------

enable_swap() {
    local size="$1" swappiness="${2:-}" free_mb

    if [[ -e $SWAPFILE ]]; then
        info "Swap file $SWAPFILE already exists, replacing it..."
        remove_swapfile
    fi

    free_mb=$(free_space_mb)
    if ((free_mb < size + RESERVE_MB)); then
        die "Not enough disk space: need ${size} MB + ${RESERVE_MB} MB reserve, available ${free_mb} MB."
    fi

    info "Creating swap file $SWAPFILE (${size} MB)..."
    CREATING=1
    create_swapfile "$size"
    activate_swapfile "$size"
    fstab_add_entry
    CREATING=0

    [[ -n $swappiness ]] && set_swappiness "$swappiness"

    ok "Swap enabled: ${size} MB"
    show_status
}

remove_swapfile() {
    if swap_is_active; then
        info "Disabling swap (may take a while if swap is in use)..."
        swapoff "$SWAPFILE" || die "swapoff failed — probably not enough free RAM to move swapped pages back."
    fi
    if fstab_has_entry; then
        info "Removing $SWAPFILE from $FSTAB..."
        fstab_remove_entry
    fi
    if [[ -e $SWAPFILE ]]; then
        info "Deleting $SWAPFILE..."
        rm -f "$SWAPFILE"
    fi
}

disable_swap() {
    remove_swapfile
    if [[ -f $SYSCTL_CONF ]]; then
        info "Removing $SYSCTL_CONF..."
        rm -f "$SYSCTL_CONF"
        # back to kernel default, then re-apply any other sysctl configs
        sysctl -q -w vm.swappiness=60 >/dev/null 2>&1 || true
        sysctl -q --system >/dev/null 2>&1 || true
    fi
    ok "Swap file disabled and removed"
    show_status
}

# ---------- interactive mode ----------

ask() {
    local prompt="$1" var
    read -rp "$prompt" var </dev/tty || var=""
    echo "$var"
}

interactive() {
    [[ -r /dev/tty ]] || { usage; die "No terminal available — pass options explicitly."; }
    echo "Choose an option:"
    echo "  [1] Enable swap (default: ${DEFAULT_SIZE_MB} MB)"
    echo "  [2] Disable swap"
    echo "  [0] Exit"
    case "$(ask 'Your choice: ')" in
        1)
            local input size_mb
            check_not_container
            input=$(ask "Enter swap size (MB or with M/G suffix) [${DEFAULT_SIZE_MB}]: ")
            size_mb=$(parse_size_mb "${input:-$DEFAULT_SIZE_MB}")
            enable_swap "$size_mb"
            ;;
        2) disable_swap ;;
        0) echo "Exiting..." ;;
        *) die "Invalid option" ;;
    esac
}

# ---------- main ----------

main() {
    local action="" size="" swappiness=""

    while (($#)); do
        case "$1" in
            --enable) action="enable" ;;
            --disable) action="disable" ;;
            --size)
                [[ $# -ge 2 ]] || die "--size requires a value"
                size="$2"
                shift
                ;;
            --size=*) size="${1#*=}" ;;
            --swappiness)
                [[ $# -ge 2 ]] || die "--swappiness requires a value"
                swappiness="$2"
                shift
                ;;
            --swappiness=*) swappiness="${1#*=}" ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    # --size / --swappiness without an action imply --enable
    if [[ -z $action && (-n $size || -n $swappiness) ]]; then
        action="enable"
    fi
    if [[ $action == "disable" && (-n $size || -n $swappiness) ]]; then
        die "--size and --swappiness cannot be used with --disable"
    fi
    [[ -n $swappiness ]] && validate_swappiness "$swappiness"

    printf '\n\033[1;35m✨ Swapfile wizard\033[0m\n\n'

    require_root
    require_cmds

    case "$action" in
        enable)
            check_not_container
            if [[ -z $size ]]; then
                if [[ -t 0 && -r /dev/tty ]]; then
                    size=$(ask "Enter swap size (MB or with M/G suffix) [${DEFAULT_SIZE_MB}]: ")
                fi
                size="${size:-$DEFAULT_SIZE_MB}"
            fi
            local size_mb
            size_mb=$(parse_size_mb "$size")
            enable_swap "$size_mb" "$swappiness"
            ;;
        disable) disable_swap ;;
        *) interactive ;;
    esac
}

main "$@"
