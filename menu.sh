#!/usr/bin/env bash
#
# menu.sh — interactive menu for all scripts in jorasssip/scripts.
#
# Author:  jorasssip — https://github.com/jorasssip/scripts
# License: MIT (see LICENSE).
#
# Pick one or several scripts, answer their questions up front, confirm once —
# the menu runs them in the recommended order and prints a summary.
#
# Usage:
#   bash <(curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/menu.sh)
#   curl -fsSL raw.githubusercontent.com/jorasssip/scripts/main/menu.sh | sudo bash
#   bash menu.sh [--ref BRANCH] [--help]

set -Euo pipefail
shopt -s extglob

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

MENU_VERSION="1.0.0"
REPO="jorasssip/scripts"
REF="main"
LOG_DIR="/var/log/jorasssip-scripts"
LOG_FILE=""
WORK_DIR=""
LOCAL_DIR=""

# Items in execution order. id -> file / title
IDS=(1 2 3 4 5)
declare -A FILE=([1]=swapfile.sh [2]=ipv6.sh [3]=netplan-primary-ip.sh [4]=ufw.sh [5]=fail2ban.sh)
declare -A TITLE=([1]="Swapfile" [2]="IPv6" [3]="Netplan primary IP" [4]="ufw" [5]="fail2ban")
declare -A DESC=(
    [1]="swap-файл и vm.swappiness"
    [2]="включить / выключить IPv6"
    [3]="сменить основной исходящий IPv4"
    [4]="файрвол: SSH, 443, порт ноды для панели"
    [5]="защита SSH от перебора"
)
PRESET=(1 2 4 5) # "a" — quick node setup

SELECTED=() SKIPPED=()
declare -A ARGS=()  # id -> space separated arguments (values never contain spaces)
declare -A RESULT=() DURATION=()

# ---------- colors / output ----------

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    R=$'\033[0m' B=$'\033[1m'
    RED=$'\033[1;31m' GRN=$'\033[1;32m' YLW=$'\033[1;33m' BLU=$'\033[1;34m'
    MAG=$'\033[1;35m' CYN=$'\033[1;36m' GRY=$'\033[0;90m'
else
    R="" B="" RED="" GRN="" YLW="" BLU="" MAG="" CYN="" GRY=""
fi

info() { printf '%s==>%s %s\n' "$BLU" "$R" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$R" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

clear_screen() { [[ -t 1 ]] && printf '\033[H\033[2J'; return 0; }

hr() { printf '%s%s%s\n' "$GRY" "  ──────────────────────────────────────────────────────" "$R"; }

usage() {
    cat <<EOF
Usage: menu.sh [options]

Interactive menu for all scripts of ${REPO}:
swapfile, ipv6, netplan-primary-ip, ufw, fail2ban.

Options:
  --ref BRANCH   Download scripts from this branch/tag/commit (default: main)
  -h, --help     Show this help

When started from a local clone, scripts next to menu.sh are used instead of GitHub.
Output of every run is also written to ${LOG_DIR}/<date>.log
EOF
}

# ---------- terminal input ----------

HAVE_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi

# ask "Prompt" "default" -> echoes answer (default on empty input)
ask() {
    local prompt="$1" def="${2:-}" var
    if [[ -n $def ]]; then
        printf '  %s%s%s %s[%s]%s: ' "$B" "$prompt" "$R" "$GRY" "$def" "$R" >/dev/tty
    else
        printf '  %s%s%s: ' "$B" "$prompt" "$R" >/dev/tty
    fi
    IFS= read -r var </dev/tty || var=""
    var="${var##+([[:space:]])}"
    var="${var%%+([[:space:]])}"
    echo "${var:-$def}"
}

ask_yn() {
    local var
    var=$(ask "$1" "$2")
    [[ $var =~ ^[YyДд] ]]
}

# ask_valid "Prompt" "default" validator_fn "error text"
ask_valid() {
    local prompt="$1" def="$2" fn="$3" err="$4" v
    while true; do
        v=$(ask "$prompt" "$def")
        if "$fn" "$v"; then
            echo "$v"
            return 0
        fi
        printf '  %s✘ %s%s\n' "$RED" "$err" "$R" >/dev/tty
    done
}

# ask_choice "Prompt" default "1|text" "2|text" ...
ask_choice() {
    local prompt="$1" def="$2" opt v
    shift 2
    for opt in "$@"; do
        printf '    %s%s)%s %s\n' "$CYN" "${opt%%|*}" "$R" "${opt#*|}" >/dev/tty
    done
    while true; do
        v=$(ask "$prompt" "$def")
        for opt in "$@"; do
            [[ $v == "${opt%%|*}" ]] && { echo "$v"; return 0; }
        done
        printf '  %s✘ Выберите один из вариантов%s\n' "$RED" "$R" >/dev/tty
    done
}

pause() {
    local _
    printf '\n  %sEnter — вернуться в меню%s ' "$GRY" "$R" >/dev/tty
    read -r _ </dev/tty || true
}

# ---------- validators ----------

v_ipv4() {
    local ip="$1" addr prefix o
    if [[ $ip == */* ]]; then
        addr="${ip%/*}" prefix="${ip#*/}"
        [[ $prefix =~ ^[1-9][0-9]?$ ]] && ((prefix <= 32)) || return 1
    else
        addr="$ip"
    fi
    [[ $addr =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && ((o <= 255)) || return 1
    done
    [[ $addr != "0.0.0.0" && $addr != "255.255.255.255" && $addr != 127.* ]]
}

v_host_ipv4() { [[ $1 != */* ]] && v_ipv4 "$1"; }

v_ipv4_list() {
    local item n=0
    for item in ${1//,/ }; do
        v_ipv4 "$item" || return 1
        n=$((n + 1))
    done
    ((n > 0))
}

v_ip_list_opt() { # empty or list of IPv4/IPv6 (with optional prefix)
    local item
    for item in ${1//,/ }; do
        [[ $item =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || return 1
    done
}

v_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); }

v_port_list_opt() {
    [[ -z $1 || $1 == "авто" ]] && return 0
    local p
    [[ $1 =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    for p in ${1//,/ }; do v_port "$p" || return 1; done
}

v_size() { [[ $1 =~ ^[0-9]+[MmGg]?$ && ! $1 =~ ^0+[MmGg]?$ ]]; }
v_swappiness() { [[ $1 =~ ^[0-9]{1,3}$ ]] && ((10#$1 <= 200)); }
v_maxretry() { [[ $1 =~ ^[0-9]{1,3}$ ]] && ((10#$1 >= 1 && 10#$1 <= 100)); }
v_duration() { [[ $1 == "-1" || $1 =~ ^[1-9][0-9]*(s|m|h|d|w|mo|y)?$ ]]; }

join_commas() { # "a, b  c" -> "a,b,c"
    local parts=()
    read -ra parts <<<"${1//,/ }"
    local IFS=,
    echo "${parts[*]}"
}

# ---------- server status ----------

has_systemd() { [[ -d /run/systemd/system ]]; }

os_name() {
    local name=""
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && name=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
    echo "${name:-Linux}"
}

primary_ipv4() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) { if ($i == "src") s = $(i + 1); if ($i == "dev") d = $(i + 1) }
    } END { if (s != "") printf "%s (%s)", s, d }'
}

mem_line() {
    awk '/^MemTotal/ { m = $2 } /^SwapTotal/ { s = $2 }
        END { printf "RAM %.1f GB · swap %.1f GB", m / 1048576, s / 1048576 }' /proc/meminfo 2>/dev/null
    df -h / 2>/dev/null | awk 'NR == 2 { printf " · диск %s/%s", $3, $2 }'
}

netplan_available() { command -v netplan >/dev/null 2>&1; }

# Each status_N prints "<color>|<text>"
status_1() {
    local size
    size=$(awk 'NR > 1 { s += $3 } END { if (s) printf "%d", s / 1024 }' /proc/swaps 2>/dev/null)
    if [[ -n $size ]]; then
        echo "$GRN|${size} MB, swappiness $(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
    else
        echo "$GRY|выключен"
    fi
}

status_2() {
    local v
    if [[ ! -d /proc/sys/net/ipv6 ]]; then
        echo "$GRN|выключен (ядро)"
        return
    fi
    v=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)
    if [[ $v == 1 ]]; then echo "$GRN|выключен"; else echo "$YLW|включён"; fi
}

status_3() {
    local from
    if ! netplan_available; then
        echo "$GRY|недоступно (нет netplan)"
        return
    fi
    from=$(ip -4 rule show 2>/dev/null | awk '/lookup (100|custom)/ { for (i = 1; i <= NF; i++) if ($i == "from") { print $(i + 1); exit } }')
    if [[ -n $from && $from != all ]]; then
        echo "$GRN|основной IP ${from}"
    else
        echo "$GRY|не настроен"
    fi
}

status_4() {
    local st n
    if ! command -v ufw >/dev/null 2>&1; then
        echo "$GRY|не установлен"
        return
    fi
    st=$(ufw status 2>/dev/null)
    if [[ $st == "Status: active"* ]]; then
        n=$(grep -c 'ALLOW' <<<"$st" || true)
        echo "$GRN|active · правил: ${n}"
    else
        echo "$YLW|установлен, выключен"
    fi
}

status_5() {
    local n
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "$GRY|не установлен"
        return
    fi
    if fail2ban-client ping >/dev/null 2>&1; then
        n=$(fail2ban-client status sshd 2>/dev/null | awk -F': *' '/Currently banned/ { print $2 }')
        echo "$GRN|работает · забанено: ${n:-0}"
    else
        echo "$YLW|установлен, не запущен"
    fi
}

item_available() {
    [[ $1 != 3 ]] || netplan_available
}

# ---------- screens ----------

draw_header() {
    printf '\n'
    printf '  %s╭──────────────────────────────────────────────────────╮%s\n' "$MAG" "$R"
    # inner width 54: "  " + 17 + " · " + 17 = 39, then padding, "v<version>", "  "
    printf '  %s│%s  %sjorasssip/scripts%s · настройка сервера%*s%sv%s%s  %s│%s\n' \
        "$MAG" "$R" "$B" "$R" $((54 - 39 - 1 - ${#MENU_VERSION} - 2)) "" "$GRY" "$MENU_VERSION" "$R" "$MAG" "$R"
    printf '  %s╰──────────────────────────────────────────────────────╯%s\n' "$MAG" "$R"
    printf '  %shost%s  %s · %s · %s\n' "$GRY" "$R" "$(hostname 2>/dev/null || echo '?')" "$(os_name)" "$(primary_ipv4)"
    printf '  %sres%s   %s\n\n' "$GRY" "$R" "$(mem_line)"
}

draw_menu() {
    local id st color text mark
    clear_screen
    draw_header
    for id in "${IDS[@]}"; do
        st=$("status_$id")
        color="${st%%|*}" text="${st#*|}"
        mark="●"
        [[ $color == "$GRY" ]] && mark="○"
        if item_available "$id"; then
            printf '  %s%s%s  %-20s %s%s %s%s\n' "$CYN$B" "$id" "$R" "${TITLE[$id]}" "$color" "$mark" "$text" "$R"
        else
            printf '  %s%s  %-20s %s %s%s\n' "$GRY" "$id" "${TITLE[$id]}" "$mark" "$text" "$R"
        fi
    done
    echo
    printf '  %sa%s  Быстрая настройка ноды %s(swap + IPv6 + ufw + fail2ban)%s\n' "$CYN$B" "$R" "$GRY" "$R"
    printf '  %ss%s  Подробный статус      %sh%s  Описание пунктов      %s0%s  Выход\n' \
        "$CYN$B" "$R" "$CYN$B" "$R" "$CYN$B" "$R"
    echo
}

show_descriptions() {
    local id
    clear_screen
    draw_header
    for id in "${IDS[@]}"; do
        printf '  %s%s%s  %s%-20s%s %s\n' "$CYN$B" "$id" "$R" "$B" "${TITLE[$id]}" "$R" "${DESC[$id]}"
    done
    echo
    printf '  %sВыбор: один пункт (4), несколько (1 4 5 или 1,4,5), диапазон (1-3), a — пресет.%s\n' "$GRY" "$R"
    printf '  %sПорядок выполнения всегда: swap → IPv6 → netplan → ufw → fail2ban.%s\n' "$GRY" "$R"
    pause
}

show_full_status() {
    clear_screen
    draw_header
    printf '%s── swap ──%s\n' "$MAG" "$R"
    swapon --show 2>/dev/null || echo "нет"
    printf '\n%s── IPv6 ──%s\n' "$MAG" "$R"
    if command -v ip >/dev/null 2>&1; then ip -6 addr show scope global 2>/dev/null | grep inet6 || echo "нет глобальных IPv6-адресов"; fi
    if netplan_available; then
        printf '\n%s── routing (netplan primary IP) ──%s\n' "$MAG" "$R"
        ip -4 rule show 2>/dev/null
        ip -4 route show default 2>/dev/null
    fi
    printf '\n%s── ufw ──%s\n' "$MAG" "$R"
    if command -v ufw >/dev/null 2>&1; then ufw status verbose 2>/dev/null; else echo "не установлен"; fi
    printf '\n%s── fail2ban ──%s\n' "$MAG" "$R"
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        fail2ban-client status sshd 2>/dev/null
    else
        echo "не запущен"
    fi
    pause
}

# ---------- selection ----------

# Parse "1 4,5 2-3 a" -> sorted unique ids in SELECTED. Returns 1 on invalid input.
parse_selection() {
    local raw="${1,,}" tok a b i
    local -A pick=()
    SELECTED=() SKIPPED=()
    for tok in ${raw//,/ }; do
        if [[ $tok == a ]]; then
            for i in "${PRESET[@]}"; do pick[$i]=1; done
        elif [[ $tok =~ ^([1-5])-([1-5])$ ]]; then
            a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
            ((a <= b)) || return 1
            for ((i = a; i <= b; i++)); do pick[$i]=1; done
        elif [[ $tok =~ ^[1-5]$ ]]; then
            pick[$tok]=1
        else
            return 1
        fi
    done
    for i in "${IDS[@]}"; do
        [[ -n ${pick[$i]:-} ]] || continue
        if ! item_available "$i"; then
            SKIPPED+=("${TITLE[$i]}")
            continue
        fi
        SELECTED+=("$i")
    done
    ((${#SELECTED[@]} > 0))
}

# ---------- per-script questions ----------

section() {
    printf '\n  %s▸ %s%s %s— %s%s\n' "$MAG" "${TITLE[$1]}" "$R" "$GRY" "${DESC[$1]}" "$R" >/dev/tty
}

configure_1() {
    local action size swp
    section 1
    action=$(ask_choice "Действие" 1 "1|включить / пересоздать swap" "2|выключить и удалить swap")
    if [[ $action == 2 ]]; then
        ARGS[1]="--disable"
        return
    fi
    size=$(ask_valid "Размер (МБ или с суффиксом M/G)" "2G" v_size "Пример: 2048, 512M, 2G")
    swp=$(ask_valid "vm.swappiness (0-200)" "10" v_swappiness "Число от 0 до 200")
    ARGS[1]="--enable --size $size --swappiness $swp"
}

configure_2() {
    local action
    section 2
    action=$(ask_choice "Действие" 1 "1|выключить IPv6" "2|включить IPv6")
    if [[ $action == 1 ]]; then ARGS[2]="off"; else ARGS[2]="on"; fi
}

configure_3() {
    local action ip
    section 3
    action=$(ask_choice "Действие" 1 "1|установить / заменить основной IPv4" "2|откатиться к исходному IPv4")
    if [[ $action == 2 ]]; then
        ARGS[3]="2"
        return
    fi
    ip=$(ask_valid "Новый основной IPv4" "" v_host_ipv4 "Нужен IPv4-адрес, например 203.0.113.20")
    ARGS[3]="1 $ip"
}

configure_4() {
    local action ips port ssh args
    section 4
    action=$(ask_choice "Действие" 1 "1|настроить правила (старые будут сброшены)" "2|выключить ufw")
    if [[ $action == 2 ]]; then
        ARGS[4]="--disable"
        return
    fi
    ips=$(ask_valid "IP панели (несколько — через запятую)" "" v_ipv4_list "Только IPv4 или IPv4/CIDR, например 203.0.113.10")
    port=$(ask_valid "Порт ноды для панели" "3001" v_port "Порт 1-65535")
    ssh=$(ask_valid "Порт(ы) SSH" "авто" v_port_list_opt "Например 22 или 22,2222")
    args="--panel-ip $(join_commas "$ips") --node-port $port"
    [[ $ssh != "авто" && -n $ssh ]] && args+=" --ssh-port $ssh"
    ARGS[4]="$args --yes"
}

configure_5() {
    local action maxretry bantime ignore args
    section 5
    action=$(ask_choice "Действие" 1 "1|установить / обновить настройки" "2|удалить fail2ban")
    if [[ $action == 2 ]]; then
        ARGS[5]="--uninstall"
        return
    fi
    maxretry=$(ask_valid "Неудачных попыток до бана" "2" v_maxretry "Число от 1 до 100")
    bantime=$(ask_valid "Длительность бана (10m, 12h, 30d, 1y, -1 = навсегда)" "30d" v_duration "Пример: 10m, 12h, 30d, 1y или -1")
    ignore=$(ask_valid "IP, которые никогда не банить (Enter — нет)" "" v_ip_list_opt "Список IP/CIDR через запятую")
    args="--maxretry $maxretry --bantime $bantime"
    [[ -n $ignore ]] && args+=" --ignoreip $(join_commas "$ignore")"
    ARGS[5]="$args"
}

# ---------- running ----------

script_path() { # download (or locate) script, print its path
    local file="$1" dst
    if [[ -n $LOCAL_DIR ]]; then
        echo "$LOCAL_DIR/$file"
        return 0
    fi
    dst="$WORK_DIR/$file"
    local url="https://raw.githubusercontent.com/${REPO}/${REF}/${file}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 10 -o "$dst" "$url" || return 1
    else
        wget -qO "$dst" "$url" || return 1
    fi
    [[ -s $dst && $(head -c 2 "$dst") == "#!" ]] || return 1
    echo "$dst"
}

ensure_downloader() {
    [[ -n $LOCAL_DIR ]] && return 0
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        return 0
    fi
    info "Устанавливаю curl..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get -y -qq -o DPkg::Lock::Timeout=180 update >/dev/null ||
        ! apt-get -y -qq -o DPkg::Lock::Timeout=180 install curl >/dev/null; then
        die "Не удалось установить curl."
    fi
}

print_queue() {
    local id n=0
    printf '\n  %sОчередь выполнения:%s\n' "$B" "$R"
    for id in "${SELECTED[@]}"; do
        n=$((n + 1))
        printf '    %s%d.%s %-20s %s%s %s%s\n' "$CYN" "$n" "$R" "${TITLE[$id]}" "$GRY" "${FILE[$id]}" "${ARGS[$id]}" "$R"
    done
    echo
}

run_one() { # id step total
    local id="$1" step="$2" total="$3" path rc start args=()
    read -ra args <<<"${ARGS[$id]}"
    printf '\n%s━━━ [%d/%d] %s ━━━%s %s%s %s%s\n' "$MAG" "$step" "$total" "${TITLE[$id]}" "$R" \
        "$GRY" "${FILE[$id]}" "${ARGS[$id]}" "$R"
    {
        echo
        echo "===== $(date '+%F %T') [${step}/${total}] ${FILE[$id]} ${ARGS[$id]}"
    } >>"$LOG_FILE"

    start=$SECONDS
    if ! path=$(script_path "${FILE[$id]}"); then
        warn "Не удалось скачать ${FILE[$id]} (${REF})."
        RESULT[$id]="fail" DURATION[$id]=0
        return 1
    fi
    if ! bash -n "$path" 2>/dev/null; then
        warn "${FILE[$id]}: синтаксическая ошибка в скачанном файле."
        RESULT[$id]="fail" DURATION[$id]=0
        return 1
    fi

    # stdin from the terminal, never from our own stdin (it may be the `curl | bash` pipe)
    local input=/dev/null
    ((HAVE_TTY == 1)) && input=/dev/tty
    bash "$path" "${args[@]}" <"$input" 2>&1 |
        tee >(sed -u -E 's/\x1B\[[0-9;]*[A-Za-z]//g' >>"$LOG_FILE")
    rc=${PIPESTATUS[0]}
    DURATION[$id]=$((SECONDS - start))
    if ((rc == 0)); then
        RESULT[$id]="ok"
    else
        RESULT[$id]="fail"
        echo "===== exit code $rc" >>"$LOG_FILE"
    fi
    return "$rc"
}

print_results() {
    local id
    local n_ok=0 n_fail=0
    printf '\n%s━━━ Итог ━━━%s\n' "$MAG" "$R"
    for id in "${SELECTED[@]}"; do
        case "${RESULT[$id]:-skip}" in
            ok)
                n_ok=$((n_ok + 1))
                printf '  %s✔%s  %-20s %s%4ss%s\n' "$GRN" "$R" "${TITLE[$id]}" "$GRY" "${DURATION[$id]}" "$R"
                ;;
            fail)
                n_fail=$((n_fail + 1))
                printf '  %s✘%s  %-20s %s%4ss  ошибка%s\n' "$RED" "$R" "${TITLE[$id]}" "$RED" "${DURATION[$id]}" "$R"
                ;;
            *) printf '  %s–  %-20s    не запускался%s\n' "$GRY" "${TITLE[$id]}" "$R" ;;
        esac
    done
    echo
    if ((n_fail == 0)); then
        ok "Готово: ${n_ok} из ${#SELECTED[@]}"
    else
        warn "Успешно: ${n_ok}, с ошибкой: ${n_fail} — подробности выше и в логе"
    fi
    printf '  %sЛог: %s%s\n' "$GRY" "$LOG_FILE" "$R"
}

run_queue() {
    local id step=0 total=${#SELECTED[@]}
    RESULT=() DURATION=()
    for id in "${SELECTED[@]}"; do
        step=$((step + 1))
        if ! run_one "$id" "$step" "$total"; then
            echo
            warn "${TITLE[$id]} завершился с ошибкой."
            ((step < total)) || break
            if [[ $id == 3 ]]; then
                warn "Сеть могла быть откачена — остальные шаги не выполняются."
                break
            fi
            ask_yn "Продолжить с остальными шагами?" "Y" || break
        fi
    done
    print_results
}

# ---------- main loop ----------

process_selection() {
    local id
    clear_screen
    draw_header
    if ((${#SKIPPED[@]})); then
        warn "Недоступно на этом сервере, пропускаю: ${SKIPPED[*]}"
    fi
    printf '  %sОтветьте на вопросы (Enter — значение по умолчанию).%s\n' "$GRY" "$R"
    ARGS=()
    for id in "${SELECTED[@]}"; do
        "configure_$id"
    done
    hr
    print_queue
    if ! ask_yn "Запустить?" "Y"; then
        info "Отменено, ничего не изменено."
        pause
        return
    fi
    run_queue
    pause
}

main_loop() {
    local choice
    while true; do
        draw_menu
        choice=$(ask "Выбор (например: 1 4 5, 1-3, a)" "")
        case "${choice,,}" in
            0 | q | exit | quit) echo; ok "Пока!"; return 0 ;;
            s) show_full_status ;;
            h | help | "?") show_descriptions ;;
            "") ;;
            *)
                if parse_selection "$choice"; then
                    process_selection
                elif ((${#SKIPPED[@]})); then
                    printf '  %s✘ Недоступно на этом сервере: %s%s\n' "$RED" "${SKIPPED[*]}" "$R"
                    sleep 2
                else
                    printf '  %s✘ Не понял выбор: %s%s\n' "$RED" "$choice" "$R"
                    sleep 1.5
                fi
                ;;
        esac
    done
}

cleanup() {
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf "$WORK_DIR"
    return 0
}

main() {
    local orig_args=("$@")
    while (($#)); do
        case "$1" in
            --ref) [[ $# -ge 2 && -n $2 ]] || die "--ref requires a value"; REF="$2"; shift ;;
            --ref=*) REF="${1#*=}" ;;
            -h | --help) usage; exit 0 ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
    [[ $REF =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid --ref: '$REF'"

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1 && [[ -f $0 && -r $0 ]]; then
            exec sudo -- bash "$0" "${orig_args[@]}"
        fi
        die "Запустите от root: curl -fsSL raw.githubusercontent.com/${REPO}/main/menu.sh | sudo bash"
    fi
    ((HAVE_TTY == 1)) || die "Нужен интерактивный терминал (/dev/tty). Для автоматизации запускайте скрипты напрямую."
    [[ -f /etc/debian_version ]] || die "Поддерживаются только Debian/Ubuntu."

    # local clone: use scripts next to menu.sh
    if [[ -f $0 ]]; then
        local dir
        dir=$(cd "$(dirname "$0")" && pwd)
        [[ -f $dir/ufw.sh && -f $dir/fail2ban.sh ]] && LOCAL_DIR="$dir"
    fi

    mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"
    LOG_FILE="$LOG_DIR/$(date +%F).log"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    WORK_DIR=$(mktemp -d)
    trap cleanup EXIT
    trap 'echo; exit 130' INT TERM

    ensure_downloader
    main_loop
}

main "$@"
