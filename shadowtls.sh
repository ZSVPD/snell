#!/bin/bash
# Этот файл сгенерирован с помощью tools/build.sh из src/shadowtls.sh и src/lib: вносите изменения в файлы в каталоге src/ и генерируйте заново.
# =========================================
# Автор: jinqians
# Дата: 16 марта 2025 г.
# Сайт: jinqians.com
# Описание: Этот скрипт используется для установки и управления ShadowTLS V3
# =========================================

# Общая часть (src/lib, объединяется через tools/build.sh при релизе): цвета, файрвол,
# пути и информация о ветках версий Snell (первая строка каждого конфига пользователя "#version-choice = vX" указывает, какая версия запущена на этом порту)
# ── lib/common.sh ─────────────────────────────────────────────────────────────
# Общее для всех скриптов: цвета, проверка root, система и пакетный менеджер, адреса публикации скриптов.
# Используется только синтаксис POSIX sh: версии скриптов для Alpine / Docker должны работать в ash и dash.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Адреса публикации скриптов. Короткие домены (*.jinqians.com) перенаправляются через Cloudflare на файлы в репозитории:
# snell / snell-centos / snell-alpine → корневой каталог, menu / snell-docker / install → scripts/.
# Дочерние скрипты, вызываемые из меню, берутся из scripts/ и docker/ по адресу SNELL_RAW_BASE.
# Обновление самих скриптов и команды управления идут через короткие домены для учёта статистики запусков.
# Можно заменить на адрес зеркала через одноимённые переменные окружения (при тестировании — указать на локальные файлы).
SNELL_RAW_BASE="${SNELL_RAW_BASE:-https://raw.githubusercontent.com/jinqians/snell/main}"
SNELL_SCRIPT_URL="${SNELL_SCRIPT_URL:-https://snell.jinqians.com}"                     # snell.sh (Debian / Ubuntu / CentOS / RHEL)
SNELL_ALPINE_SCRIPT_URL="${SNELL_ALPINE_SCRIPT_URL:-https://snell-alpine.jinqians.com}" # snell-alpine.sh
SNELL_DOCKER_SCRIPT_URL="${SNELL_DOCKER_SCRIPT_URL:-https://snell-docker.jinqians.com}" # snell-docker.sh
SNELL_MENU_SCRIPT_URL="${SNELL_MENU_SCRIPT_URL:-https://menu.jinqians.com}"             # menu.sh

# Проверка запуска с правами root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        printf '%b\n' "${RED}Пожалуйста, запустите этот скрипт с правами root${RESET}"
        exit 1
    fi
}

# Определение ОС: OS_FAMILY = debian | rhel | alpine | unknown, PKG = apt | dnf | yum | apk
OS_FAMILY=""
PKG=""
detect_os() {
    [ -n "$OS_FAMILY" ] && return 0
    OS_FAMILY="unknown"
    if [ -f /etc/os-release ]; then
        # Чтение в подоболочке (subshell), чтобы переменные NAME / VERSION из os-release не перезаписали переменные скрипта
        case " $(. /etc/os-release; echo "$ID $ID_LIKE" | tr '[:upper:]' '[:lower:]') " in
            *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
            *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*) OS_FAMILY="rhel" ;;
            *" alpine "*) OS_FAMILY="alpine" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS_FAMILY="rhel"
    fi
    if command -v apt-get >/dev/null 2>&1; then PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG="yum"
    elif command -v apk >/dev/null 2>&1; then PKG="apk"
    fi
}

# Ожидание завершения других процессов apt
wait_for_apt() {
    command -v fuser >/dev/null 2>&1 || return 0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
        printf '%b\n' "${YELLOW}Ожидание завершения других процессов apt...${RESET}"
        sleep 2
    done
}

# Установка пакетов с помощью системного пакетного менеджера
pkg_install() {
    detect_os
    case "$PKG" in
        apt)
            wait_for_apt
            DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
        *)
            printf '%b\n' "${RED}Неизвестный пакетный менеджер, пожалуйста, установите вручную: $*${RESET}"
            return 1
            ;;
    esac
}

# Сопоставление команды с именем пакета (различия между дистрибутивами указываются здесь)
pkg_for_cmd() {
    detect_os
    case "$1" in
        ip|ss) if [ "$OS_FAMILY" = "rhel" ]; then echo "iproute"; else echo "iproute2"; fi ;;
        nft) echo "nftables" ;;
        fuser) echo "psmisc" ;;
        gpg) if [ "$OS_FAMILY" = "rhel" ]; then echo "gnupg2"; else echo "gnupg"; fi ;;
        sysctl) if [ "$OS_FAMILY" = "rhel" ]; then echo "procps-ng"; else echo "procps"; fi ;;
        modprobe) echo "kmod" ;;
        *) echo "$1" ;;
    esac
}

# Установка недостающих пакетов для команд; при неудаче возвращает ненулевой код, решение о выходе принимает вызывающая сторона
ensure_cmds() {
    _ec_missing=""
    for _ec_cmd in "$@"; do
        command -v "$_ec_cmd" >/dev/null 2>&1 || _ec_missing="${_ec_missing} $(pkg_for_cmd "$_ec_cmd")"
    done
    [ -z "$_ec_missing" ] && return 0
    printf '%b\n' "${YELLOW}Установка зависимостей: ${_ec_missing# }${RESET}"
    # shellcheck disable=SC2086 # Имена пакетов передаются через пробел
    pkg_install $_ec_missing || return 1
    for _ec_cmd in "$@"; do
        if ! command -v "$_ec_cmd" >/dev/null 2>&1; then
            printf '%b\n' "${RED}После установки команда ${_ec_cmd} всё ещё не найдена, установите $(pkg_for_cmd "$_ec_cmd") вручную${RESET}"
            return 1
        fi
    done
}

# Скачивание удалённого скрипта и проверка целостности: остановка при сбое передачи, проверка на непустой файл и проверка синтаксиса.
# Гарантирует только целостность передачи; от компрометации самого репозитория защищает только подпись релиза.
fetch_verified_script() {   # <url> <dest>
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$1" -o "$2"; then
        printf '%b\n' "${RED}Ошибка скачивания: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    if [ ! -s "$2" ]; then
        printf '%b\n' "${RED}Скачанный файл пуст и был отброшен: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    # bash может парсить синтаксис sh; в системах без bash (Alpine) для проверки используется sh
    if command -v bash >/dev/null 2>&1; then
        _fv_shell=bash
    else
        _fv_shell=sh
    fi
    if ! "$_fv_shell" -n "$2" 2>/dev/null; then
        printf '%b\n' "${RED}Скачанный скрипт не прошёл проверку синтаксиса и был отброшен: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    return 0
}

# ── lib/release.sh ────────────────────────────────────────────────────────────
# Официальные версии Snell: получение последних номеров основных версий со страницы релизов и генерация ссылок для скачивания. POSIX sh.

# Резервные номера версий на случай сбоя парсинга или отсутствия ссылки на основную версию на странице релизов.
# После выхода релизной версии v6.0.0 со страницы убрали ссылки на скачивание v5 (оставив только описание изменений), поэтому v5 теперь опирается только на указанную здесь v5.0.1
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0"

# Официальная страница релизов Snell (старая manual.nssurge.com/others/snell.html отключена)
SNELL_RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
SNELL_RELEASE_NOTES_URL_ZH="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"

# Получение содержимого официальной страницы релизов
fetch_snell_release_notes() {
    local notes
    notes=$(curl -sL --max-time 15 "$SNELL_RELEASE_NOTES_URL")
    if [ -z "$notes" ]; then
        notes=$(curl -sL --max-time 15 "$SNELL_RELEASE_NOTES_URL_ZH")
    fi
    echo "$notes"
}

# Преобразование номера версии в ключ фиксированной длины для сортировки; приоритет: beta < rc < релиз
# 6.0.0b4 -> 006.000.000.1.0004; 6.0.0rc -> 006.000.000.2.0000; 6.0.0rc2 -> 006.000.000.2.0002; 6.0.0 -> 006.000.000.3.0000
snell_version_sort_key() {
    echo "${1#[vV]}" | awk '{
        ver = $0
        suffix = ""
        if (match(ver, /[a-zA-Z]+[0-9]*$/)) {
            suffix = tolower(substr(ver, RSTART))
            ver = substr(ver, 1, RSTART - 1)
        }
        split(ver, part, ".")
        stage = 3
        seq = 0
        if (suffix != "") {
            stage = (suffix ~ /^rc/) ? 2 : 1
            digits = suffix
            gsub(/[^0-9]/, "", digits)
            if (digits != "") seq = digits + 0
        }
        printf "%03d.%03d.%03d.%d.%04d", part[1], part[2], part[3], stage, seq
    }'
}

# Выбор последней версии указанной основной ветки со страницы релизов (порядок на странице не гарантирует новизну, необходима сортировка)
pick_latest_snell_version() {
    local major="$1"
    local notes="$2"

    echo "$notes" \
        | grep -oE "snell-server-v${major}\.[0-9]+\.[0-9]+[a-zA-Z0-9]*" \
        | sed 's/^snell-server-v//' \
        | sort -u \
        | while read -r ver; do
              echo "$(snell_version_sort_key "$ver") ${ver}"
          done \
        | sort \
        | tail -n 1 \
        | awk '{print $2}'
}

# Получение последней версии Snell v4
get_latest_snell_v4_version() {
    local ver
    ver=$(pick_latest_snell_version 4 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V4_FALLBACK}"
    fi
}

# Получение последней версии Snell v5
get_latest_snell_v5_version() {
    local ver
    ver=$(pick_latest_snell_version 5 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V5_FALLBACK}"
    fi
}

# Получение последней версии Snell v6
get_latest_snell_v6_version() {
    local ver
    ver=$(pick_latest_snell_version 6 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V6_FALLBACK}"
    fi
}

# Определение последнего номера версии для указанной ветки (при неудаче используется встроенная константа)
resolve_latest_version_for_channel() {
    case "$1" in
        v6) get_latest_snell_v6_version ;;
        v5) get_latest_snell_v5_version ;;
        v4) get_latest_snell_v4_version ;;
        *)  return 1 ;;
    esac
}

# Генерация ссылки на скачивание для указанной ветки и версии; для неподдерживаемых архитектур возвращает ненулевой код (без exit, чтобы вызывающая сторона могла продолжить работу)
snell_download_url_for() {
    local version_choice="$1"
    local resolved_version="$2"
    local arch
    arch=$(uname -m)

    case "$version_choice" in
        v4|v5|v6) ;;
        *)
            printf '%b\n' "${RED}Неподдерживаемая ветка Snell: ${version_choice}${RESET}" >&2
            return 1
            ;;
    esac

    if [ "$version_choice" = "v6" ] && { [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; }; then
        printf '%b\n' "${RED}Для Snell v6 пока не предоставляются сборки под armv7l${RESET}" >&2
        return 1
    fi

    case "$arch" in
        "x86_64"|"amd64")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-amd64.zip" ;;
        "i386"|"i686")     echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-i386.zip" ;;
        "aarch64"|"arm64") echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-aarch64.zip" ;;
        "armv7l"|"armv7")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-armv7l.zip" ;;
        *)
            printf '%b\n' "${RED}Неподдерживаемая архитектура: ${arch}${RESET}" >&2
            return 1
            ;;
    esac
}

# ── lib/firewall.sh ───────────────────────────────────────────────────────────
# Открытие / закрытие портов: firewalld, ufw, iptables + ip6tables, nftables — настраивается и сохраняется то, что используется в системе.
# Этот модуль общий для всех скриптов (раньше в каждом скрипте была своя копия: только версия для CentOS распознавала firewalld,
# Docker-версия открывала только TCP, а повторная установка дублировала правила). POSIX sh.

# firewalld запущен
_fw_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

# ufw включён (-w: чтобы не принять inactive за active)
_fw_ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"
}

# both | tcp | udp → список протоколов
_fw_protos() {
    case "$1" in
        tcp) echo "tcp" ;;
        udp) echo "udp" ;;
        *) echo "tcp udp" ;;
    esac
}

# Сохранение правил iptables: /etc/iptables в Debian, iptables-services в RHEL, init-скрипт в Alpine
_fw_iptables_save() {
    if [ -x /etc/init.d/iptables ] && command -v rc-update >/dev/null 2>&1; then
        /etc/init.d/iptables save >/dev/null 2>&1 || true
        rc-update add iptables boot >/dev/null 2>&1 || true
        if [ -x /etc/init.d/ip6tables ]; then
            /etc/init.d/ip6tables save >/dev/null 2>&1 || true
            rc-update add ip6tables boot >/dev/null 2>&1 || true
        fi
    elif [ -f /etc/sysconfig/iptables ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        [ -f /etc/sysconfig/ip6tables ] && ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

# iptables / ip6tables: вставка правила только при отсутствии аналогичного
_fw_iptables_open() {   # <port> <protos>
    _fio_changed=false
    for _fio_t in iptables ip6tables; do
        command -v "$_fio_t" >/dev/null 2>&1 || continue
        "$_fio_t" -L INPUT -n >/dev/null 2>&1 || continue   # Недоступно в ядре или контейнере
        for _fio_p in $2; do
            if ! "$_fio_t" -C INPUT -p "$_fio_p" --dport "$1" -j ACCEPT 2>/dev/null; then
                "$_fio_t" -I INPUT -p "$_fio_p" --dport "$1" -j ACCEPT 2>/dev/null && _fio_changed=true
            fi
        done
    done
    if [ "$_fio_changed" = true ]; then
        printf '%b\n' "${CYAN}Открытие порта $1 в iptables${RESET}"
        _fw_iptables_save
    fi
}

_fw_iptables_close() {   # <port>
    _fic_changed=false
    for _fic_t in iptables ip6tables; do
        command -v "$_fic_t" >/dev/null 2>&1 || continue
        for _fic_p in tcp udp; do
            while "$_fic_t" -C INPUT -p "$_fic_p" --dport "$1" -j ACCEPT 2>/dev/null; do
                "$_fic_t" -D INPUT -p "$_fic_p" --dport "$1" -j ACCEPT 2>/dev/null || break
                _fic_changed=true
            done
        done
    done
    [ "$_fic_changed" = true ] && _fw_iptables_save
    return 0
}

# Сохранение правил nftables (при наличии конфигурационного файла для постоянного хранения)
save_nftables_rules() {
    command -v nft >/dev/null 2>&1 || return 0
    for _snr_f in /etc/nftables.conf /etc/sysconfig/nftables.conf /etc/nftables.nft; do
        [ -f "$_snr_f" ] || continue
        nft list ruleset > "$_snr_f" 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables >/dev/null 2>&1 || true
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update add nftables boot >/dev/null 2>&1 || true
        fi
        printf '%b\n' "${GREEN}Правила nftables сохранены${RESET}"
        return 0
    done
    return 0
}

# Цепочки фильтрации в nftables с хуком на input (по одной записи "семейство таблица цепочка" на строку).
# Таблицы filter для ip/ip6 от iptables-nft уже обрабатываются через iptables, пропускаем их во избежание дублирования правил.
_fw_nft_input_chains() {
    nft -a list ruleset 2>/dev/null | awk -v skip_ipt="$1" '
        $1 == "table" { family = $2; table = $3; gsub(/[{}]/, "", table) }
        $1 == "chain" { chain = $2; gsub(/[{}]/, "", chain); in_chain = 1; next }
        in_chain && /type filter/ && /hook input/ {
            if (!(skip_ipt == "1" && (family == "ip" || family == "ip6") && table == "filter")) print family " " table " " chain
        }
        in_chain && /^[[:space:]]*}/ { in_chain = 0 }
    '
}

# Разрешение порта в существующих цепочках input в nftables (ничего не делает при отсутствии файрвола nftables)
open_nftables_port() {   # <port> [both|tcp|udp]
    command -v nft >/dev/null 2>&1 || return 0
    _onp_skip=0
    command -v iptables >/dev/null 2>&1 && _onp_skip=1
    _onp_chains=$(_fw_nft_input_chains "$_onp_skip")
    [ -n "$_onp_chains" ] || return 0
    _onp_changed=false
    _onp_protos=$(_fw_protos "${2:-both}")
    while read -r _onp_family _onp_table _onp_chain; do
        [ -n "$_onp_family" ] || continue
        for _onp_p in $_onp_protos; do
            if ! nft list chain "$_onp_family" "$_onp_table" "$_onp_chain" 2>/dev/null | grep -q "$_onp_p dport $1 .*accept"; then
                nft insert rule "$_onp_family" "$_onp_table" "$_onp_chain" "$_onp_p" dport "$1" accept 2>/dev/null && _onp_changed=true
            fi
        done
    done <<EOF
$_onp_chains
EOF
    if [ "$_onp_changed" = true ]; then
        printf '%b\n' "${CYAN}Открытие порта $1 в nftables${RESET}"
        save_nftables_rules
    fi
}

# Удаление правил, разрешающих данный порт в nftables
close_nftables_port() {   # <port>
    command -v nft >/dev/null 2>&1 || return 0
    _cnp_rules=$(nft -a list ruleset 2>/dev/null | awk -v port="$1" '
        $1 == "table" { family = $2; table = $3; gsub(/[{}]/, "", table) }
        $1 == "chain" { chain = $2; gsub(/[{}]/, "", chain) }
        ($0 ~ "(tcp|udp) dport " port " .*accept") && /# handle/ { print family " " table " " chain " " $NF }
    ')
    [ -n "$_cnp_rules" ] || return 0
    while read -r _cnp_family _cnp_table _cnp_chain _cnp_handle; do
        [ -n "$_cnp_handle" ] || continue
        nft delete rule "$_cnp_family" "$_cnp_table" "$_cnp_chain" handle "$_cnp_handle" 2>/dev/null || true
    done <<EOF
$_cnp_rules
EOF
    save_nftables_rules
}

# Открытие порта: если запущен firewalld — используем только его; если включён ufw — только его; иначе настраиваем iptables и nftables
open_port() {   # <port> [both|tcp|udp]
    _op_protos=$(_fw_protos "${2:-both}")
    if _fw_firewalld_active; then
        printf '%b\n' "${CYAN}Открытие порта $1 в firewalld${RESET}"
        for _op_p in $_op_protos; do
            firewall-cmd --permanent --add-port="$1/${_op_p}" >/dev/null 2>&1 || true
            firewall-cmd --add-port="$1/${_op_p}" >/dev/null 2>&1 || true
        done
        return 0
    fi
    # Если ufw установлен, но не включён, всё равно добавляем правило: при последующем включении ufw порт останется открытым
    if command -v ufw >/dev/null 2>&1; then
        printf '%b\n' "${CYAN}Открытие порта $1 в UFW${RESET}"
        for _op_p in $_op_protos; do
            ufw allow "$1/${_op_p}" >/dev/null 2>&1 || true
        done
        _fw_ufw_active && return 0
    fi
    _fw_iptables_open "$1" "$_op_protos"
    open_nftables_port "$1" "${2:-both}"
    return 0
}

# Закрытие порта: удаление разрешающих правил для этого порта во всех файрволах
close_port() {   # <port>
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for _cp_p in tcp udp; do
            firewall-cmd --permanent --remove-port="$1/${_cp_p}" >/dev/null 2>&1 || true
            firewall-cmd --remove-port="$1/${_cp_p}" >/dev/null 2>&1 || true
        done
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$1/tcp" >/dev/null 2>&1 || true
        ufw delete allow "$1/udp" >/dev/null 2>&1 || true
        ufw delete allow "$1" >/dev/null 2>&1 || true
    fi
    _fw_iptables_close "$1"
    close_nftables_port "$1"
    return 0
}

# Проверка, разрешён ли порт в текущем файрволе (для тестирования и отображения статуса): достаточно разрешения в любом из firewalld / ufw / iptables / nftables
port_allowed() {   # <port> <tcp|udp>
    if _fw_firewalld_active; then
        firewall-cmd --query-port="$1/$2" >/dev/null 2>&1
        return
    fi
    if _fw_ufw_active; then
        ufw status 2>/dev/null | grep -Eq "^$1(/$2)?[[:space:]]+ALLOW"
        return
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -C INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null; then
        return 0
    fi
    command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "$2 dport $1 .*accept"
}

# Проверка, прослушивается ли порт каким-либо процессом (TCP или UDP)
is_port_in_use() {   # <port>
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "( sport = :$1 )" 2>/dev/null | grep -q . && return 0
        ss -H -lun "( sport = :$1 )" 2>/dev/null | grep -q . && return 0
        return 1
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
        lsof -nP -iUDP:"$1" >/dev/null 2>&1
        return
    fi
    return 1
}

# Отображение процесса, занимающего указанный порт
show_port_occupier() {   # <port>
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp "( sport = :$1 )" 2>/dev/null | sed 's/^/  /'
        ss -lunp "( sport = :$1 )" 2>/dev/null | sed 's/^/  /'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sed 's/^/  /'
        lsof -nP -iUDP:"$1" 2>/dev/null | sed 's/^/  /'
    fi
}

# ── lib/channels.sh ───────────────────────────────────────────────────────────
# Структура установки systemd и сосуществование нескольких версий (v4 / v5 / v6). Общее для snell.sh, multi-user.sh,
# shadowtls.sh (bash).
#
# Структура бинарных файлов:
#   ${INSTALL_DIR}/snell-server-v4|v5|v6   Реальные файлы каждой ветки, юнит systemd указывает напрямую на них
#   ${INSTALL_DIR}/snell-server            Символическая ссылка, указывающая на ветку основного пользователя (сохранена для старой логики определения)
#
# Маркер версии:
#   В первой строке каждого пользовательского конфига пишется "#version-choice = vX". Формат комментария не парсится самим snell-server,
#   и сохраняется/восстанавливается вместе с .conf без необходимости в дополнительных сопутствующих файлах. Конфиги, создаваемые PSM, также содержат этот маркер.

# Системные пути
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
USERS_DIR="${SNELL_CONF_DIR}/users"
SNELL_CONF_FILE="${USERS_DIR}/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"
SYSTEMD_SOCKET_FILE="${SYSTEMD_DIR}/snell.socket"
SYSTEMD_NETNS_FILE="${SYSTEMD_DIR}/snell-netns.service"
NETNS_SETUP_SCRIPT="${INSTALL_DIR}/snell-netns-setup.sh"

# Старые пути к конфигурационным файлам (используются для проверки совместимости)
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

SNELL_VERSION_MARKER_KEY="version-choice"
SNELL_ALL_VERSIONS="v4 v5 v6"

# Определение текущей установленной версии Snell
detect_installed_snell_version() {
    if command -v snell-server &> /dev/null; then
        local version_output=$(snell-server --v 2>&1)
        if echo "$version_output" | grep -q "v6"; then
            echo "v6"
        elif echo "$version_output" | grep -q "v5"; then
            echo "v5"
        else
            echo "v4"
        fi
    else
        echo "unknown"
    fi
}

# Номер версии -> путь к бинарному файлу
snell_binary_for_version() {
    case "$1" in
        v4|v5|v6) echo "${INSTALL_DIR}/snell-server-$1" ;;
        *)        echo "${INSTALL_DIR}/snell-server" ;;
    esac
}

# Определение собственной версии указанного бинарного файла; если файл не исполняемый — возвращает unknown
probe_snell_binary_version() {
    local binary="$1"
    if [ ! -x "$binary" ]; then
        echo "unknown"
        return 1
    fi

    local version_output
    version_output=$("$binary" --v 2>&1)
    if echo "$version_output" | grep -q "v6"; then
        echo "v6"
    elif echo "$version_output" | grep -q "v5"; then
        echo "v5"
    else
        # В ранних версиях v4 вывод --v не содержал основного номера версии; для совместимости со старым поведением считаем это v4
        echo "v4"
    fi
}

# Список установленных на диске веток версий (через пробел, может быть пустым)
list_installed_snell_versions() {
    local version installed=""
    for version in $SNELL_ALL_VERSIONS; do
        if [ -x "$(snell_binary_for_version "$version")" ]; then
            installed="${installed}${version} "
        fi
    done
    echo "${installed% }"
}

# Чтение маркера версии из конфига; при отсутствии маркера возвращает ненулевой код
read_conf_snell_version() {
    local conf_file="$1"
    [ -f "$conf_file" ] || return 1

    local marked
    marked=$(grep -E "^[[:space:]]*#[[:space:]]*${SNELL_VERSION_MARKER_KEY}[[:space:]]*=" "$conf_file" \
        | head -n 1 | awk -F'=' '{print $2}' | tr -d '[:space:]')
    case "$marked" in
        v4|v5|v6) echo "$marked" ;;
        *)        return 1 ;;
    esac
}

# Ветка версии, соответствующая конфигу: приоритет у чтения маркера, при неудаче — откат к реальной версии по симлинку (совместимость со старыми установками до миграции)
get_conf_snell_version() {
    local conf_file="$1"
    local marked
    if marked=$(read_conf_snell_version "$conf_file"); then
        echo "$marked"
        return 0
    fi
    detect_installed_snell_version
}

# Идемпотентная запись маркера версии: если совпадает — пропуск, если отличается — замена, если отсутствует — вставка в первую строку.
# Перезапись через cat вместо mv сохраняет владельца и права исходного файла (служба читает файл от имени пользователя snell)
set_conf_snell_version() {
    local conf_file="$1"
    local version="$2"

    [ -f "$conf_file" ] || return 1
    case "$version" in
        v4|v5|v6) ;;
        *) return 1 ;;
    esac

    local current=""
    current=$(read_conf_snell_version "$conf_file" 2>/dev/null)
    if [ "$current" = "$version" ]; then
        return 0
    fi

    local tmp_conf="${conf_file}.vtmp.$$"
    if ! {
        echo "#${SNELL_VERSION_MARKER_KEY} = ${version}"
        grep -Ev "^[[:space:]]*#[[:space:]]*${SNELL_VERSION_MARKER_KEY}[[:space:]]*=" "$conf_file"
    } > "$tmp_conf"; then
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось сгенерировать маркер версии: ${conf_file}${RESET}" >&2
        return 1
    fi

    if ! cat "$tmp_conf" > "$conf_file"; then
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось записать маркер версии: ${conf_file}${RESET}" >&2
        return 1
    fi
    rm -f "$tmp_conf"
    return 0
}

# Получение порта Snell
get_snell_port() {
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
    fi
}

# Порт -> путь к конфигурационному файлу (основной порт использует основной конфиг)
snell_conf_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "$SNELL_CONF_FILE"
    else
        echo "${SNELL_CONF_DIR}/users/snell-${port}.conf"
    fi
}

# Порт -> ветка версии
get_port_snell_version() {
    get_conf_snell_version "$(snell_conf_for_port "$1")"
}

# Порт -> имя службы systemd
snell_service_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "snell"
    else
        echo "snell-${port}"
    fi
}

# Какими службами в данный момент используется указанная ветка версии (по одному имени службы systemd на строку)
list_services_using_version() {
    local version="$1"
    local conf_file port

    if [ -f "$SNELL_CONF_FILE" ] && [ "$(get_conf_snell_version "$SNELL_CONF_FILE")" = "$version" ]; then
        echo "snell"
    fi

    [ -d "${SNELL_CONF_DIR}/users" ] || return 0
    for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        [ -f "$conf_file" ] || continue
        case "$conf_file" in
            *snell-main.conf) continue ;;
        esac
        port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        [ -n "$port" ] || continue
        if [ "$(get_conf_snell_version "$conf_file")" = "$version" ]; then
            echo "snell-${port}"
        fi
    done
}

# Перенаправление симлинка snell-server на указанную ветку версии (старая логика определения и ShadowTLS всё ещё зависят от этого имени)
update_snell_symlink() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    # Если целевой файл не существует — ничего не трогаем, чтобы не превратить рабочий старый бинарник в битую ссылку
    if [ ! -x "$target" ]; then
        return 1
    fi

    if [ -e "${INSTALL_DIR}/snell-server" ] && [ ! -L "${INSTALL_DIR}/snell-server" ]; then
        rm -f "${INSTALL_DIR}/snell-server"
    fi
    ln -sfn "$target" "${INSTALL_DIR}/snell-server"
}

# Скачивание официального архива и распаковка <каталог>/snell-server. Вывод прогресса только в stderr
fetch_snell_release_binary() {   # <ветка> <версия> <каталог>
    local version="$1" resolved="$2" dir="$3" url
    if ! url=$(snell_download_url_for "$version" "$resolved"); then
        return 1
    fi

    echo -e "${CYAN}Скачивание Snell ${version} (${resolved})...${RESET}" >&2
    echo -e "${YELLOW}${url}${RESET}" >&2

    # Команды для скачивания и распаковки: если отсутствуют — сначала устанавливаем (для любого дистрибутива)
    ensure_cmds curl unzip >&2 || return 1

    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "${dir}/snell-server.zip" "$url"; then
        echo -e "${RED}Ошибка скачивания Snell ${version}: ${url}${RESET}" >&2
        return 1
    fi

    # Проверка целостности архива (официальные хеши не публикуются, возможна только проверка целостности передачи)
    if ! unzip -t -q "${dir}/snell-server.zip" >/dev/null 2>&1; then
        echo -e "${RED}Скачанный архив повреждён и был отброшен: ${url}${RESET}" >&2
        return 1
    fi

    if ! unzip -o -q "${dir}/snell-server.zip" -d "$dir"; then
        echo -e "${RED}Ошибка распаковки Snell ${version}${RESET}" >&2
        return 1
    fi

    if [ ! -f "${dir}/snell-server" ]; then
        echo -e "${RED}Исполняемый файл snell-server не найден в архиве${RESET}" >&2
        return 1
    fi
}

# Проверка, является ли локальный бинарный файл этой ветки той же сборкой, что и официально предоставляемая сейчас <версия>.
# Одного сравнения номеров версий недостаточно: релиз-кандидаты (rc) v6 также сообщают версию v6.0.0, и после выхода релиза будет казаться, что «уже установлена последняя версия».
# Возвращает 0: отличаются, стоит обновить; 1: совпадают; 2: не удалось скачать официальный файл, сравнение невозможно
snell_binary_differs_from_release() {   # <ветка> <версия>
    local version="$1" resolved="$2" target tmp_dir rc=2
    target=$(snell_binary_for_version "$version")
    [ -x "$target" ] || return 0
    tmp_dir=$(mktemp -d) || return 2
    if fetch_snell_release_binary "$version" "$resolved" "$tmp_dir" 2>/dev/null; then
        if [ "$(sha256sum < "$target")" = "$(sha256sum < "${tmp_dir}/snell-server")" ]; then
            rc=1
        else
            rc=0
        fi
    fi
    rm -rf "$tmp_dir"
    return $rc
}

# Скачивание бинарного файла указанной ветки по версионированному пути. При force=true скачивает заново, даже если файл уже существует.
# Прогресс выводится только в stderr, stdout остаётся для вызывающей стороны.
install_snell_binary_for_version() {
    local version="$1"
    local force="${2:-false}"
    local target
    target=$(snell_binary_for_version "$version")

    if [ -x "$target" ] && [ "$force" != "true" ]; then
        return 0
    fi

    local resolved
    resolved=$(resolve_latest_version_for_channel "$version")
    if [ -z "$resolved" ]; then
        echo -e "${RED}Не удалось определить номер версии для Snell ${version}${RESET}" >&2
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1
    if ! fetch_snell_release_binary "$version" "$resolved" "$tmp_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    # install выполняет атомарную замену: запущенный старый процесс удерживает старый inode и не затрагивается
    if ! install -m 755 "${tmp_dir}/snell-server" "$target"; then
        echo -e "${RED}Ошибка записи в ${target}${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    # Проверка после сохранения на диск: убеждаемся, что установлена именно эта ветка
    local actual
    actual=$(probe_snell_binary_version "$target")
    if [ "$actual" != "$version" ]; then
        echo -e "${YELLOW}Предупреждение: ${target} сообщает версию ${actual}, что не совпадает с ожидаемой ${version}${RESET}" >&2
    fi

    echo -e "${GREEN}✓ Snell ${version} (${resolved}) установлен: ${target}${RESET}" >&2
    return 0
}

# Проверка доступности указанной ветки; при отсутствии — автоматическое скачивание
ensure_snell_binary() {
    install_snell_binary_for_version "$1" "false"
}

# Путь к бинарному файлу для основной службы (при отсутствии маркера или бинарника — откат к симлинку)
main_snell_binary() {
    local version target
    version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    target=$(snell_binary_for_version "$version")
    if [ -x "$target" ]; then
        echo "$target"
    else
        echo "${INSTALL_DIR}/snell-server"
    fi
}

# Переключение ExecStart в юните с обычного snell-server на версионированный бинарный файл.
# Уже использующие версионированный путь пропускаются (шаблон содержит пробел в конце и не совпадёт с snell-server-v5), поэтому функцию можно вызывать повторно.
sync_service_units_to_versioned_binary() {
    local changed=false
    local conf_file port unit version target

    if [ -f "$SYSTEMD_SERVICE_FILE" ] && grep -q "ExecStart=${INSTALL_DIR}/snell-server " "$SYSTEMD_SERVICE_FILE"; then
        version=$(get_conf_snell_version "$SNELL_CONF_FILE")
        target=$(snell_binary_for_version "$version")
        if [ -x "$target" ]; then
            sed -i "s|ExecStart=${INSTALL_DIR}/snell-server |ExecStart=${target} |" "$SYSTEMD_SERVICE_FILE"
            changed=true
        fi
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            [ -f "$conf_file" ] || continue
            case "$conf_file" in
                *snell-main.conf) continue ;;
            esac
            port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            [ -n "$port" ] || continue
            unit="${SYSTEMD_DIR}/snell-${port}.service"
            [ -f "$unit" ] || continue
            grep -q "ExecStart=${INSTALL_DIR}/snell-server " "$unit" || continue

            version=$(get_conf_snell_version "$conf_file")
            target=$(snell_binary_for_version "$version")
            if [ -x "$target" ]; then
                sed -i "s|ExecStart=${INSTALL_DIR}/snell-server |ExecStart=${target} |" "$unit"
                changed=true
            fi
        done
    fi

    if [ "$changed" = "true" ]; then
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}✓ Службы systemd переключены на пути с версионированными бинарными файлами${RESET}"
    fi
}

# Направление ExecStart юнита на бинарный файл целевой ветки (используется при переключении версии пользователя)
point_service_unit_to_version() {
    local unit="$1"
    local version="$2"
    local target
    target=$(snell_binary_for_version "$version")

    [ -f "$unit" ] || return 1
    [ -x "$target" ] || return 1

    sed -i -E "s|ExecStart=${INSTALL_DIR}/snell-server(-v[456])? |ExecStart=${target} |" "$unit"
}

# Миграция со старой структуры (единственный реальный файл /usr/local/bin/snell-server) на раздельное хранение по веткам.
# Идемпотентно: если это уже симлинк и все конфиги размечены маркерами, ничего не делает.
migrate_snell_binary_layout() {
    local snell_bin="${INSTALL_DIR}/snell-server"
    local main_version=""

    if [ -e "$snell_bin" ] && [ ! -L "$snell_bin" ]; then
        local detected versioned
        detected=$(probe_snell_binary_version "$snell_bin")
        if [ "$detected" = "unknown" ]; then
            echo -e "${YELLOW}Не удалось определить версию ${snell_bin}, миграция структуры бинарных файлов пропущена${RESET}"
            return 1
        fi

        versioned=$(snell_binary_for_version "$detected")
        echo -e "${CYAN}Обнаружена старая одноверсионная структура, выполняется миграция на мультиверсионную...${RESET}"
        if [ ! -e "$versioned" ]; then
            if ! cp -a "$snell_bin" "$versioned"; then
                echo -e "${RED}Не удалось скопировать бинарный файл в ${versioned}, сохранена исходная структура${RESET}"
                return 1
            fi
        fi
        chmod 755 "$versioned" 2>/dev/null || true
        ln -sfn "$versioned" "$snell_bin"
        echo -e "${GREEN}✓ ${snell_bin} теперь указывает на ${versioned} (Snell ${detected})${RESET}"
        main_version="$detected"
    elif [ -L "$snell_bin" ]; then
        main_version=$(probe_snell_binary_version "$snell_bin")
    fi

    [ "$main_version" = "unknown" ] && main_version=""

    # Добавление маркера версии в конфиги, где его ещё нет (в старой установке все пользователи неизбежно имели одну версию)
    if [ -n "$main_version" ] && [ -d "${SNELL_CONF_DIR}/users" ]; then
        local conf_file
        for conf_file in "${SNELL_CONF_DIR}/users"/*.conf; do
            [ -f "$conf_file" ] || continue
            if read_conf_snell_version "$conf_file" >/dev/null 2>&1; then
                continue
            fi
            if set_conf_snell_version "$conf_file" "$main_version"; then
                echo -e "${GREEN}✓ Для $(basename "$conf_file") отмечена версия ${main_version}${RESET}"
            fi
        done
    fi

    sync_service_units_to_versioned_binary
    return 0
}

ensure_snell_service_user() {
    if ! getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${SNELL_SERVICE_GROUP}" 2>/dev/null || true
    fi

    if ! getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || \
        useradd -r -M -s /usr/sbin/nologin -g "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || true
    fi
}

ensure_snell_config_dir() {
    ensure_snell_service_user
    mkdir -p "${SNELL_CONF_DIR}/users"
    if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${SNELL_CONF_DIR}" "${SNELL_CONF_DIR}/users" 2>/dev/null || true
    # Конфигурационные файлы с PSK доступны для чтения и записи только владельцу
    find "${SNELL_CONF_DIR}/users" -maxdepth 1 -name "*.conf" -exec chmod 600 {} + 2>/dev/null || true
}

migrate_legacy_main_config_if_needed() {
    ensure_snell_config_dir

    if [ -f "$SNELL_CONF_FILE" ]; then
        return 0
    fi

    if [ -f "$OLD_SNELL_CONF_FILE" ]; then
        cp -a "$OLD_SNELL_CONF_FILE" "$SNELL_CONF_FILE"
        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$SNELL_CONF_FILE" 2>/dev/null || true
        fi
        chmod 644 "$SNELL_CONF_FILE"
        echo -e "${GREEN}Старая конфигурация перенесена в ${SNELL_CONF_FILE}${RESET}"
        return 0
    fi

    return 1
}

# Получение конфигураций всех пользователей Snell
get_all_snell_users() {
    # Проверка существования каталога конфигураций пользователей
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi
    
    # Сначала получаем конфигурацию основного пользователя
    local main_port=""
    local main_psk=""
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
        if [ ! -z "$main_port" ] && [ ! -z "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi
    
    # Получаем конфигурации остальных пользователей
    for user_conf in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
            local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
            if [ ! -z "$port" ] && [ ! -z "$psk" ]; then
                echo "${port}|${psk}"
            fi
        fi
    done
}

# =========================================
# Управление версиями Snell: обновление по веткам / добавление веток / переключение ветки пользователя
# =========================================
# Чтение конкретного номера версии, сообщаемого бинарным файлом ветки (например, v5.0.1)
get_channel_binary_version() {
    local version="$1"
    local binary
    binary=$(snell_binary_for_version "$version")
    [ -x "$binary" ] || return 1

    local detail
    detail=$("$binary" --v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9]*' | head -n 1)
    if [ -z "$detail" ]; then
        # Ранние сборки v4 не выводят номер версии через --v, используем встроенную константу
        case "$version" in
            v4) detail="$SNELL_V4_FALLBACK" ;;
            v5) detail="$SNELL_V5_FALLBACK" ;;
            v6) detail="$SNELL_V6_FALLBACK" ;;
        esac
    fi
    echo "$detail"
}

# Перезапуск службы и проверка, что она действительно запустилась; при сбое выводит конец журнала, чтобы пользователю не пришлось искать вручную
restart_and_verify_service() {
    local service="$1"
    local waited=0

    if ! systemctl restart "$service" 2>/dev/null; then
        echo -e "${RED}Команда systemctl restart ${service} завершилась с ошибкой${RESET}"
        journalctl -u "$service" -n 30 --no-pager 2>/dev/null | sed 's/^/   /'
        return 1
    fi

    while [ "$waited" -lt 10 ]; do
        if systemctl is-active --quiet "$service"; then
            return 0
        fi
        # При активации по сокету основная служба поднимается по требованию; если активен сокет — считаем, что всё в порядке
        if [ "$service" = "snell" ] && systemctl is-active --quiet snell.socket; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo -e "${RED}Служба ${service} не перешла в состояние active в течение ${waited} сек.${RESET}"
    journalctl -u "$service" -n 30 --no-pager 2>/dev/null | sed 's/^/   /'
    return 1
}

# Запись юнита systemd для пользователя, ExecStart указывает на бинарный файл выбранной пользователем ветки
write_user_service_unit() {
    local port="$1"
    local user_conf="$2"
    local version="$3"
    local snell_binary
    snell_binary=$(snell_binary_for_version "$version")

    cat > "${SYSTEMD_DIR}/snell-${port}.service" << EOF
[Unit]
Description=Snell Proxy Service (Port ${port}, ${version})
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
LimitNOFILE=32768
ExecStart=${snell_binary} -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server-${port}

[Install]
WantedBy=multi-user.target
EOF
}

# Резервные копии для переключения/отката централизованно хранятся в ${SNELL_CONF_DIR}/backup.
# Их нельзя помещать в users/ — многие циклы перебирают users/*, и файлы бэкапов будут приняты за реальных пользователей.
snell_backup_path() {
    local src="$1"
    local stamp="$2"
    local dir="${SNELL_CONF_DIR}/backup"
    mkdir -p "$dir" 2>/dev/null || return 1
    echo "${dir}/$(basename "$src").${stamp}"
}

# === Добавлено: функции резервного копирования и восстановления конфигурации ===
# Резервное копирование конфигурации Snell (хранятся только последние 10 копий во избежание накопления)
backup_snell_config() {
    local backup_dir="${SNELL_CONF_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "${SNELL_CONF_DIR}/users"/*.conf "$backup_dir"/ 2>/dev/null
    ls -dt "${SNELL_CONF_DIR}"/backup_* 2>/dev/null | tail -n +11 | xargs -r rm -rf
    echo "$backup_dir"
}



# Собственные пути ShadowTLS
CONFIG_DIR="/etc/shadowtls"
SERVICE_FILE="${SYSTEMD_DIR}/shadowtls.service"

# Адрес прослушивания: если ядро поддерживает dual-stack (есть IPv6 и bindv6only=0), слушаем ::0 (принимает и IPv4, и IPv6);
# если IPv6 отключён или bindv6only=1, то ::0 не принимает IPv4 (ss-2022 issue #13) — при наличии IPv4 слушаем 0.0.0.0
stls_listen_addr() {
    local v6=0 v4=0
    [ -f /proc/net/if_inet6 ] && v6=1
    ip -4 addr show scope global 2>/dev/null | grep -q "inet " && v4=1
    if [ "$v6" = 1 ] && { [ "$v4" = 0 ] || [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null)" != "1" ]; }; then
        echo "::0"
    else
        echo "0.0.0.0"
    fi
}

# Чтение параметров shadow-tls из файла службы (или stdin), независимо от того, указан ли адрес ::0, 0.0.0.0 или изменён вручную
# (используется sed вместо grep -P: в grep из BusyBox нет флага -P)
stls_listen_port() { sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$@" | head -n 1; }
stls_opt() {   # <имя_параметра> [файл]: значение после --<имя_параметра>
    local k="$1"; shift
    sed -n "s/.*--${k} \([^ ][^ ]*\).*/\1/p" "$@" | head -n 1
}

# Порт бэкенда -> mode для v6 (на клиенте должен совпадать с сервером)
get_port_snell_mode() {
    local conf_file mode=""
    conf_file=$(snell_conf_for_port "$1")
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    echo "${mode:-default}"
}

# Генерация строки прокси Surge для порта бэкенда (включая параметры ShadowTLS)
print_snell_shadowtls_line() {
    local label="$1"
    local server_ip="$2"
    local stls_port="$3"
    local psk="$4"
    local stls_password="$5"
    local stls_sni="$6"
    local backend_port="$7"

    local version stls_suffix
    version=$(get_port_snell_version "$backend_port")
    stls_suffix="reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"

    case "$version" in
        v6)
            echo -e "${label} (v6) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 6, mode = $(get_port_snell_mode "$backend_port"), ${stls_suffix}"
            ;;
        v5)
            echo -e "${label} (v4) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, ${stls_suffix}"
            echo -e "${label} (v5) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 5, ${stls_suffix}"
            ;;
        *)
            echo -e "${label} (v4) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, ${stls_suffix}"
            ;;
    esac
}

# Установка необходимых утилит
install_requirements() {
    ensure_cmds wget curl jq || exit 1
}

# Получение последней версии
SHADOWTLS_FALLBACK_VERSION="v0.2.25"

get_latest_version() {
    local latest_version=""

    # Приоритет через API; при ошибке jq может вернуть "null"
    latest_version=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)

    # При сбое API (например, превышении лимита запросов) — откат к результату перенаправления releases/latest
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        latest_version=$(curl -fsSL --connect-timeout 10 -o /dev/null -w '%{url_effective}' "https://github.com/ihciah/shadow-tls/releases/latest" 2>/dev/null | sed -E 's#.*/tag/##')
    fi

    # Если обе попытки не удались, используем встроенную проверенную версию
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        echo -e "${YELLOW}Не удалось получить последнюю версию с GitHub, используется встроенная версия ${SHADOWTLS_FALLBACK_VERSION}${RESET}" >&2
        latest_version="$SHADOWTLS_FALLBACK_VERSION"
    fi

    echo "$latest_version"
}

# Проверка, установлен ли SS
check_ssrust() {
    if [ ! -f "/usr/local/bin/ss-rust" ]; then
        return 1
    fi
    return 0
}

# Проверка, установлен ли Snell
check_snell() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        return 1
    fi
    return 0
}

migrate_legacy_snell_config() {
    ensure_snell_config_dir

    if [ -f "${SNELL_CONF_FILE}" ]; then
        return 0
    fi

    if [ -f "${OLD_SNELL_CONF_FILE}" ]; then
        cp -a "${OLD_SNELL_CONF_FILE}" "${SNELL_CONF_FILE}"
        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_FILE}" 2>/dev/null || true
        fi
        chmod 644 "${SNELL_CONF_FILE}"
        echo -e "${GREEN}Старая конфигурация Snell перенесена в ${SNELL_CONF_FILE}${RESET}"
        return 0
    fi

    return 1
}

check_snell_config() {
    if ! check_snell; then
        return 1
    fi

    migrate_legacy_snell_config || true

    if [ ! -s "${SNELL_CONF_FILE}" ]; then
        echo -e "${RED}Основная конфигурация Snell не существует: ${SNELL_CONF_FILE}${RESET}"
        echo -e "${YELLOW}Сначала запустите установку/восстановление Snell или перенесите старую конфигурацию ${OLD_SNELL_CONF_FILE} в каталог users.${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*listen[[:space:]]*=' "${SNELL_CONF_FILE}"; then
        echo -e "${RED}В основной конфигурации Snell отсутствует параметр listen: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*psk[[:space:]]*=' "${SNELL_CONF_FILE}"; then
        echo -e "${RED}В основной конфигурации Snell отсутствует параметр psk: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    return 0
}

# Получение порта SS
get_ssrust_port() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local port=$(jq -r '.server_port' "$ssrust_conf" 2>/dev/null)
    echo "$port"
}

# Получение пароля SS
get_ssrust_password() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local password=$(jq -r '.password' "$ssrust_conf" 2>/dev/null)
    echo "$password"
}

# Получение метода шифрования SS
get_ssrust_method() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local method=$(jq -r '.method' "$ssrust_conf" 2>/dev/null)
    echo "$method"
}

# Получение PSK для Snell
get_snell_psk() {
    local snell_conf="${SNELL_CONF_FILE}"
    migrate_legacy_snell_config >/dev/null 2>&1 || true
    if [ ! -f "$snell_conf" ]; then
        return 1
    fi
    local psk=$(grep -E '^psk' "$snell_conf" | sed 's/psk = //')
    echo "$psk"
}

# Получение конфигурации Snell
get_snell_config() {
    local port=$1
    local snell_conf="${USERS_DIR}/snell-${port}.conf"
    local main_conf="${USERS_DIR}/snell-main.conf"
    local psk=""
    
    migrate_legacy_snell_config >/dev/null 2>&1 || true

    if [ -f "$snell_conf" ]; then
        psk=$(grep -E "^psk[[:space:]]*=" "$snell_conf" 2>/dev/null | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
    fi

    if [ -z "$psk" ] && [ -f "$main_conf" ]; then
        psk=$(grep -E "^psk[[:space:]]*=" "$main_conf" 2>/dev/null | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
    fi

    echo "$psk"
}

get_snell_config_file_by_port() {
    local target_port=$1
    local conf
    local port

    migrate_legacy_snell_config >/dev/null 2>&1 || true

    for conf in "${SNELL_CONF_FILE}" "${USERS_DIR}"/snell-*.conf; do
        [ -f "$conf" ] || continue
        port=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$conf" | head -n 1)
        if [ "$port" = "$target_port" ]; then
            echo "$conf"
            return 0
        fi
    done

    return 1
}

get_snell_service_name_by_config() {
    local conf=$1
    local filename

    if [ "$conf" = "${SNELL_CONF_FILE}" ]; then
        echo "snell"
        return 0
    fi

    filename=$(basename "$conf")
    case "$filename" in
        snell-[0-9]*.conf)
            echo "${filename%.conf}"
            return 0
            ;;
    esac

    return 1
}

restrict_snell_to_loopback() {
    local port=$1
    local conf
    local service_name

    conf=$(get_snell_config_file_by_port "$port") || {
        echo -e "${RED}Не найден конфигурационный файл для порта Snell ${port}${RESET}"
        return 1
    }

    service_name=$(get_snell_service_name_by_config "$conf") || {
        echo -e "${RED}Не удалось определить службу systemd для порта Snell ${port}${RESET}"
        return 1
    }

    if [ "$service_name" = "snell" ] && { systemctl is-active --quiet snell.socket 2>/dev/null || systemctl is-enabled --quiet snell.socket 2>/dev/null; }; then
        echo -e "${RED}Обнаружено использование snell.socket, автоматическое переключение основного Snell в режим бэкенда ShadowTLS пока невозможно${RESET}"
        echo -e "${YELLOW}Сначала отключите управление исходящим трафиком / режим активации по сокету в скрипте управления Snell, а затем настройте ShadowTLS.${RESET}"
        return 1
    fi

    if grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:${port}[[:space:]]*$" "$conf"; then
        echo -e "${GREEN}Порт Snell ${port} уже прослушивает только 127.0.0.1${RESET}"
    else
        # Бэкапы сохраняются в /etc/snell/backup: нельзя класть в users/, так как каждый файл там воспринимается как отдельный пользователь
        cp -a "$conf" "$(snell_backup_path "$conf" "$(date +%Y%m%d%H%M%S)")"
        sed -i "s|^[[:space:]]*listen[[:space:]]*=.*:${port}[[:space:]]*$|listen = 127.0.0.1:${port}|" "$conf"

        if ! grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:${port}[[:space:]]*$" "$conf"; then
            echo -e "${RED}Не удалось изменить адрес прослушивания Snell: ${conf}${RESET}"
            return 1
        fi

        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$conf" 2>/dev/null || true
        fi
        chmod 644 "$conf" 2>/dev/null || true

        echo -e "${GREEN}Порт Snell ${port} переключён на прослушивание только 127.0.0.1${RESET}"
    fi

    systemctl restart "$service_name"
    close_port "$port"
    echo -e "${GREEN}Правила публичного доступа для исходного порта Snell ${port} закрыты; подключайтесь клиентом к порту ShadowTLS${RESET}"
}

# Получение основного номера версии Snell (4 / 5 / 6) для указанного порта бэкенда.
# Если порт не передан, используется порт основного пользователя. Старая реализация распознавала только v4/v5 и выдавала один ответ для всех портов,
# из-за чего при сосуществовании нескольких версий порт v6 ошибочно определялся как v4.
get_snell_version() {
    local port="${1:-$(get_snell_port)}"
    local version

    if [ -z "$port" ]; then
        version=$(detect_installed_snell_version)
    else
        version=$(get_port_snell_version "$port")
    fi

    case "$version" in
        v6) echo "6" ;;
        v5) echo "5" ;;
        v4) echo "4" ;;
        *)  return 1 ;;
    esac
}

# Получение IP-адреса сервера
get_server_ip() {
    local ipv4
    local ipv6
    
    # Получение IPv4-адреса
    ipv4=$(curl -s -4 ip.sb 2>/dev/null)
    
    # Получение IPv6-адреса
    ipv6=$(curl -s -6 ip.sb 2>/dev/null)
    
    # Определение типа IP и возврат значения
    if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
        # Dual-stack, приоритет отдаётся IPv4
        echo "$ipv4"
    elif [ -n "$ipv4" ]; then
        # Только IPv4
        echo "$ipv4"
    elif [ -n "$ipv6" ]; then
        # Только IPv6
        echo "$ipv6"
    else
        echo -e "${RED}Не удалось получить IP-адрес сервера${RESET}"
        return 1
    fi
    
    return 0
}

# Проверка формата команды shadow-tls
check_shadowtls_command() {
    local help_output
    help_output=$($INSTALL_DIR/shadow-tls --help 2>&1)
    echo -e "${YELLOW}Справка по shadow-tls:${RESET}"
    echo "$help_output"
    return 0
}

# Генерация безопасного Base64-кодирования (URL-safe)
urlsafe_base64() {
    date=$(echo -n "$1"|base64|sed ':a;N;s/\n/ /g;ta'|sed 's/ //g;s/=//g;s/+/-/g;s/\//_/g')
    echo -e "${date}"
}

# Генерация случайного порта
generate_random_port() {
    local min_port=10000
    local max_port=65535
    echo $(shuf -i ${min_port}-${max_port} -n 1)
}

# Проверка, занят ли порт
check_port_usage() {
    local port=$1

    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":${port}\b"; then
            return 0  # Порт занят
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":${port}\b"; then
            return 0  # Порт занят
        fi
    fi

    return 1     # Порт свободен
}

# Получение уже используемых портов ShadowTLS
get_used_stls_ports() {
    local used_ports=()
    
    # Проверка службы SS
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    if [ -f "$ss_service" ]; then
        local ss_port=$(stls_listen_port "$ss_service")
        if [ ! -z "$ss_port" ]; then
            used_ports+=("$ss_port")
        fi
    fi
    
    # Проверка служб Snell
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port=$(stls_listen_port "$service_file")
            if [ ! -z "$port" ]; then
                used_ports+=("$port")
            fi
        done <<< "$snell_services"
    fi
    
    echo "${used_ports[@]}"
}

# Проверка и получение доступного порта
get_available_port() {
    local port=$1
    local used_ports=($(get_used_stls_ports))
    
    # Если пользователь указал порт
    if [ ! -z "$port" ]; then
        # Сначала проверяем, что порт — это число от 1 до 65535, для защиты от некорректных значений или инъекций
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}Некорректный порт, введите число от 1 до 65535${RESET}" >&2
            return 1
        fi

        # Проверка, используется ли порт другой службой ShadowTLS
        for used_port in "${used_ports[@]}"; do
            if [ "$port" = "$used_port" ]; then
                echo -e "${RED}Порт ${port} уже используется другой службой ShadowTLS${RESET}"
                return 1
            fi
        done
        
        # Проверка, занят ли порт другими службами
        if check_port_usage "$port"; then
            echo -e "${RED}Порт ${port} уже занят другой службой${RESET}"
            return 1
        fi
        
        echo "$port"
        return 0
    fi
    
    # Если пользователь не указал порт, генерируем случайный
    local attempts=0
    while [ $attempts -lt 10 ]; do
        local random_port=$(generate_random_port)
        local is_used=0
        
        # Проверка, используется ли он в ShadowTLS
        for used_port in "${used_ports[@]}"; do
            if [ "$random_port" = "$used_port" ]; then
                is_used=1
                break
            fi
        done
        
        # Если порт не используется и не занят
        if [ $is_used -eq 0 ] && ! check_port_usage "$random_port"; then
            echo "$random_port"
            return 0
        fi
        
        attempts=$((attempts + 1))
    done
    
    echo -e "${RED}Не удалось найти свободный порт${RESET}"
    return 1
}

# Проверка домена маскировки TLS по белому списку (защита от инъекции параметров и переводов строк в юнит systemd)
is_valid_tls_domain() {
    [[ "$1" =~ ^[A-Za-z0-9.-]{1,253}$ ]]
}

# Интерактивное чтение домена маскировки TLS; некорректный ввод отклоняется с запросом повторного ввода
prompt_tls_domain() {
    while true; do
        read -rp "Введите домен маскировки TLS (нажмите Enter для www.microsoft.com по умолчанию): " tls_domain
        if [ -z "$tls_domain" ]; then
            tls_domain="www.microsoft.com"
            return 0
        fi
        if is_valid_tls_domain "$tls_domain"; then
            return 0
        fi
        echo -e "${RED}Неверный формат домена: разрешены только буквы, цифры, точки и дефисы (максимум 253 символа). Пожалуйста, введите заново${RESET}"
    done
}

# Генерация ссылок и конфигурации SS
generate_ss_links() {
    local server_ip=$1
    local listen_port=$2
    local ssrust_password=$3
    local ssrust_method=$4
    local stls_password=$5
    local stls_sni=$6
    local backend_port=$7
    
    echo -e "\n${YELLOW}=== Конфигурация сервера ===${RESET}"
    echo -e "IP сервера: ${server_ip}"
    echo -e "\nКонфигурация Shadowsocks:"
    echo -e "  - Порт: ${backend_port}"
    echo -e "  - Метод шифрования: ${ssrust_method}"
    echo -e "  - Пароль: ${ssrust_password}"
    echo -e "\nКонфигурация ShadowTLS:"
    echo -e "  - Порт: ${listen_port}"
    echo -e "  - Пароль: ${stls_password}"
    echo -e "  - SNI: ${stls_sni}"
    echo -e "  - Версия: 3"
    
    # Генерация объединённой ссылки SS + ShadowTLS
    local userinfo=$(echo -n "${ssrust_method}:${ssrust_password}" | base64 | tr -d '\n')
    # shadow_tls_config = plugin=shadow-tls;host=${stls_sni};password=${stls_password};version=3
    local shadow_tls_config="plugin=shadow-tls;host=${stls_sni};password=${stls_password};version=3"
    local ss_url="ss://${userinfo}@${server_ip}:${listen_port}?${shadow_tls_config}"

    echo -e "\n${YELLOW}=== Конфигурация Surge ===${RESET}"
    echo -e "SS-${server_ip} = ss, ${server_ip}, ${listen_port}, encrypt-method=${ssrust_method}, password=${ssrust_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
    
    echo -e "\n${YELLOW}=== Инструкция по настройке Shadowrocket ===${RESET}"
    echo -e "1. Добавьте узел Shadowsocks:"
    echo -e "   - Тип: Shadowsocks"
    echo -e "   - Адрес: ${server_ip}"
    echo -e "   - Порт: ${backend_port}"
    echo -e "   - Метод шифрования: ${ssrust_method}"
    echo -e "   - Пароль: ${ssrust_password}"
    
    echo -e "\n2. Добавьте узел ShadowTLS:"
    echo -e "   - Тип: ShadowTLS"
    echo -e "   - Адрес: ${server_ip}"
    echo -e "   - Порт: ${listen_port}"
    echo -e "   - Пароль: ${stls_password}"
    echo -e "   - SNI: ${stls_sni}"
    echo -e "   - Версия: 3"

    echo -e "\n${YELLOW}=== Ссылка для импорта в Shadowrocket ===${RESET}"
    echo -e "${GREEN}Ссылка SS + ShadowTLS: ${RESET}${ss_url}"
    
    echo -e "\n${YELLOW}=== QR-код для Shadowrocket ===${RESET}"
    qrencode -t UTF8 "${ss_url}"
    
    echo -e "\n${YELLOW}=== Конфигурация Clash Meta ===${RESET}"
    echo -e "proxies:"
    echo -e "  - name: SS-${server_ip}"
    echo -e "    type: ss"
    echo -e "    server: ${server_ip}"
    echo -e "    port: ${listen_port}"
    echo -e "    cipher: ${ssrust_method}"
    echo -e "    password: \"${ssrust_password}\""
    echo -e "    plugin: shadow-tls"
    echo -e "    plugin-opts:"
    echo -e "      host: \"${stls_sni}\""
    echo -e "      password: \"${stls_password}\""
    echo -e "      version: 3"
}

# Генерация ссылок и конфигурации Snell
generate_snell_links() {
    local server_ip=$1
    local listen_port=$2
    local snell_psk=$3
    local stls_password=$4
    local stls_sni=$5
    local backend_port=$6
    
    # Версия берётся из собственной ветки этого порта бэкенда
    local snell_version=$(get_snell_version "$backend_port")
    
    echo -e "\n${YELLOW}=== Конфигурация сервера ===${RESET}"
    echo -e "IP сервера: ${server_ip}"
    echo -e "\nКонфигурация Snell:"
    echo -e "  - Порт: ${backend_port}"
    echo -e "  - PSK: ${snell_psk}"
    echo -e "  - Версия: ${snell_version}"
    echo -e "\nКонфигурация ShadowTLS:"
    echo -e "  - Порт: ${listen_port}"
    echo -e "  - Пароль: ${stls_password}"
    echo -e "  - SNI: ${stls_sni}"
    echo -e "  - Версия: 3"
    
    echo -e "\n${YELLOW}=== Конфигурация Surge ===${RESET}"
    
    # Для v5 выводятся оба варианта записи (v4 и v5); для v6 дополнительно указывается параметр mode
    print_snell_shadowtls_line "Snell + ShadowTLS" "$server_ip" "$listen_port" "$snell_psk" \
        "$stls_password" "$stls_sni" "$backend_port"
}

# Запрос на включение wildcard-sni (по умолчанию выключено)
prompt_wildcard_sni() {
    wildcard_sni="off"
    echo -e "${YELLOW}Включить ли wildcard-sni=authed?${RESET}"
    echo -e "После включения клиенты, прошедшие проверку пароля, смогут использовать домен маскировки (SNI), отличный от серверного"
    read -rp "Включить wildcard-sni=authed? [y/N]: " wildcard_choice
    case "$wildcard_choice" in
        [yY]|[yY][eE][sS])
            wildcard_sni="authed"
            echo -e "${GREEN}Включено: wildcard-sni=authed${RESET}"
            ;;
        *)
            echo -e "${GREEN}Оставлено значение по умолчанию (wildcard-sni выключен)${RESET}"
            ;;
    esac
}

# Включение TCP Fast Open
enable_tcp_fastopen() {
    # Немедленное применение
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1

    # Сохранение конфигурации, чтобы она действовала после перезагрузки
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.tcp_fastopen = 3" > /etc/sysctl.d/99-tcp-fastopen.conf
    elif ! grep -q "^net.ipv4.tcp_fastopen" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
    fi
}

# Шаблон создания файла службы
create_shadowtls_service() {
    local service_type=$1  # ss или snell
    local port=$2
    local listen_port=$3
    local tls_domain=$4
    local password=$5
    local service_file
    local description
    local identifier
    
    if [ "$service_type" = "ss" ]; then
        service_file="${SYSTEMD_DIR}/shadowtls-ss.service"
        description="Shadow-TLS Server Service for Shadowsocks"
        identifier="shadow-tls-ss"
    else
        service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
        description="Shadow-TLS Server Service for Snell (Port: ${port})"
        identifier="shadow-tls-snell-${port}"
    fi

    # Включение TCP Fast Open (параметр ядра)
    enable_tcp_fastopen

    # Параметр wildcard-sni (по умолчанию off, не добавляется)
    local wildcard_sni_flag=""
    if [ "$wildcard_sni" = "authed" ] || [ "$wildcard_sni" = "all" ]; then
        wildcard_sni_flag=" --wildcard-sni ${wildcard_sni}"
    fi

    cat > "$service_file" << EOF
[Unit]
Description=${description}
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=RUST_BACKTRACE=1
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 server --listen $(stls_listen_addr):${listen_port} --server 127.0.0.1:${port} --tls ${tls_domain} --password ${password}${wildcard_sni_flag}
StandardOutput=append:/var/log/shadowtls-${identifier}.log
StandardError=append:/var/log/shadowtls-${identifier}.log
SyslogIdentifier=${identifier}
Restart=always
RestartSec=3

# Параметры оптимизации производительности
LimitNOFILE=65535
CPUAffinity=0
Nice=0
IOSchedulingClass=realtime
IOSchedulingPriority=0
MemoryMax=512M
CPUQuota=50%
LimitCORE=infinity
LimitRSS=infinity
LimitNPROC=65535
LimitAS=infinity
SystemCallFilter=@system-service
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Параметры системной оптимизации
Environment=RUST_THREADS=1
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
Environment=RUST_LOG_LEVEL=info
Environment=RUST_LOG_TARGET=journal
Environment=RUST_LOG_FORMAT=json
Environment=RUST_LOG_FILTER=info,shadow_tls=info

[Install]
WantedBy=multi-user.target
EOF

    # Создание лог-файла и установка прав доступа
    touch "/var/log/shadowtls-${identifier}.log"
    chmod 640 "/var/log/shadowtls-${identifier}.log"
    chown root:root "/var/log/shadowtls-${identifier}.log"
}

# Запуск службы и проверка статуса работы; при сбое выводит ошибку и подсказку journalctl, больше не подавляя ошибки молча
start_and_verify_service() {
    local unit="$1"
    # Файл юнита только что записан, сначала делаем reload, чтобы systemd его увидел
    systemctl daemon-reload 2>/dev/null
    if ! systemctl start "$unit"; then
        echo -e "${RED}Не удалось запустить службу ${unit}${RESET}"
        echo -e "${YELLOW}Выполните journalctl -u ${unit} для просмотра подробной информации об ошибке${RESET}"
        return 1
    fi
    if ! systemctl enable "$unit" 2>/dev/null; then
        echo -e "${YELLOW}Не удалось включить автозапуск для службы ${unit}, вы можете выполнить systemctl enable ${unit} вручную${RESET}"
    fi
    if ! systemctl is-active --quiet "$unit"; then
        echo -e "${RED}Служба ${unit} не смогла продолжить работу после запуска${RESET}"
        echo -e "${YELLOW}Выполните journalctl -u ${unit} для просмотра подробной информации об ошибке${RESET}"
        return 1
    fi
    return 0
}

# Установка ShadowTLS
install_shadowtls() {
    echo -e "${CYAN}Установка ShadowTLS...${RESET}"

    install_requirements
    
    # Определение установленных протоколов
    local has_ss=false
    local has_snell=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}Обнаружен установленный Shadowsocks Rust${RESET}"
    fi
    
    if check_snell_config; then
        has_snell=true
        echo -e "${GREEN}Обнаружен установленный Snell${RESET}"
    elif check_snell; then
        echo -e "${YELLOW}Обнаружен бинарный файл Snell, но основная конфигурация недоступна; настройка ShadowTLS для Snell пока невозможна${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}Не обнаружен ни Shadowsocks Rust, ни Snell. Пожалуйста, сначала установите один из них${RESET}"
        return 1
    fi
    
    # Определение архитектуры системы, скачивание и установка ShadowTLS
    arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            arch="x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            arch="aarch64-unknown-linux-musl"
            ;;
        armv7l|armv7)
            arch="armv7-unknown-linux-musleabihf"
            ;;
        arm)
            arch="arm-unknown-linux-musleabi"
            ;;
        *)
            echo -e "${RED}Неподдерживаемая архитектура системы: $arch${RESET}"
            exit 1
            ;;
    esac

    # Получение последней версии
    version=$(get_latest_version)

    # Попытка скачивания: сначала напрямую с GitHub; ghproxy — недоверенное стороннее зеркало, используется только после явного подтверждения пользователем
    binary_name="shadow-tls-${arch}"
    github_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/${binary_name}"
    proxy_url="https://ghproxy.com/${github_url}"

    echo -e "${CYAN}Скачивание ShadowTLS ${version} (${arch})...${RESET}"
    echo -e "${YELLOW}Адрес скачивания: ${github_url}${RESET}"

    if ! wget --timeout=30 --tries=2 -q "$github_url" -O "/tmp/shadow-tls.tmp" 2>/dev/null; then
        echo -e "${YELLOW}Не удалось подключиться напрямую к GitHub.${RESET}"
        echo -e "${YELLOW}Внимание: ghproxy.com — это недоверенное стороннее зеркало. Происхождение скачанных через него бинарных файлов невозможно проверить, что несёт риски для цепочки поставок.${RESET}"
        read -rp "Продолжить скачивание через зеркало ghproxy? [y/N] " use_proxy
        if [[ ! "$use_proxy" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Скачивание отменено${RESET}"
            rm -f "/tmp/shadow-tls.tmp"
            exit 1
        fi
        echo -e "${YELLOW}Адрес зеркала: ${proxy_url}${RESET}"
        if ! wget --timeout=60 --tries=3 "$proxy_url" -O "/tmp/shadow-tls.tmp"; then
            echo -e "${RED}Не удалось скачать ShadowTLS, проверьте подключение к сети и повторите попытку${RESET}"
            rm -f "/tmp/shadow-tls.tmp"
            exit 1
        fi
    fi

    # Проверка, что скачанный файл не пуст (примечание: апстрим не публикует хеши/подписи, поэтому проверяется только непустой размер без проверки подлинности источника)
    if [ ! -s "/tmp/shadow-tls.tmp" ]; then
        echo -e "${RED}Скачанный файл пуст, повторите попытку${RESET}"
        rm -f "/tmp/shadow-tls.tmp"
        exit 1
    fi
    
    # Перемещение в конечное расположение и установка прав на выполнение
    mv "/tmp/shadow-tls.tmp" "$INSTALL_DIR/shadow-tls"
    chmod +x "$INSTALL_DIR/shadow-tls"
    
    # Генерация случайного пароля
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    
    # Получение домена маскировки TLS (проверка по белому списку для защиты от инъекций в юнит)
    prompt_tls_domain
    prompt_wildcard_sni
    
    # Выбор протокола, для которого нужно настроить ShadowTLS
    while true; do
        echo -e "\n${YELLOW}Выберите протокол для настройки:${RESET}"
        echo -e "1. Настроить ShadowTLS для Shadowsocks"
        echo -e "2. Настроить ShadowTLS для Snell"
        echo -e "3. Настроить ShadowTLS для обоих протоколов"
        echo -e "0. Выход"
        
        read -rp "Ваш выбор [0-3]: " protocol_choice
        
        case "$protocol_choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss; then
                    echo -e "${RED}Shadowsocks не установлен${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=false
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}Snell не установлен${RESET}"
                    continue
                fi
                configure_ss=false
                configure_snell=true
                break
                ;;
            3)
                if ! $has_ss || ! $has_snell; then
                    echo -e "${RED}Требуется, чтобы были установлены одновременно и Shadowsocks, и Snell${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=true
                break
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    done
    
    # Настройка Shadowsocks
    if $configure_ss; then
        echo -e "\n${YELLOW}Настройка ShadowTLS для Shadowsocks...${RESET}"
        while true; do
            read -rp "Введите порт прослушивания ShadowTLS (1-65535, нажмите Enter для случайного выбора): " ss_listen_port
            
            # Проверка и получение доступного порта
            ss_listen_port=$(get_available_port "$ss_listen_port")
            if [ $? -eq 0 ]; then
                break
            fi
            echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
        done
        
        echo -e "${GREEN}Будет использован порт: ${ss_listen_port}${RESET}"
        
        # Создание службы ShadowTLS для SS
        local ss_port=$(get_ssrust_port)
        create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
        open_port "$ss_listen_port" tcp
        start_and_verify_service "shadowtls-ss" || return 1
    fi
    
    # Настройка Snell
    if $configure_snell; then
        echo -e "\n${YELLOW}Настройка ShadowTLS для Snell...${RESET}"
        
        # Получение конфигураций всех пользователей Snell
        local user_configs=$(get_all_snell_users)
        if [ -z "$user_configs" ]; then
            echo -e "${RED}Не найдено действующих пользовательских конфигураций Snell${RESET}"
            return 1
        fi
        
        # Отображение всех портов Snell
        echo -e "\n${YELLOW}Текущий список портов Snell:${RESET}"
        local port_list=()
        while IFS='|' read -r port psk; do
            if [ ! -z "$port" ]; then
                port_list+=("$port")
                if [ "$port" = "$(get_snell_port)" ]; then
                    echo -e "${GREEN}${#port_list[@]}. ${port} (основной пользователь)${RESET}"
                else
                    echo -e "${GREEN}${#port_list[@]}. ${port}${RESET}"
                fi
            fi
        done <<< "$user_configs"
        
        # Выбор портов для настройки
        echo -e "\n${YELLOW}Выберите порт для настройки:${RESET}"
        echo -e "1-${#port_list[@]}. Выбрать один порт"
        echo -e "0. Настроить ShadowTLS для всех портов"
        
        read -rp "Ваш выбор: " port_choice
        
        if [ "$port_choice" = "0" ]; then
            # Настройка ShadowTLS для всех портов
            for port in "${port_list[@]}"; do
                echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${port}${RESET}"
                while true; do
                    read -rp "Введите порт прослушивания ShadowTLS (1-65535, нажмите Enter для случайного выбора): " stls_port
                    
                    # Проверка и получение доступного порта
                    stls_port=$(get_available_port "$stls_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                done
                
                echo -e "${GREEN}Будет использован порт: ${stls_port}${RESET}"
                
                restrict_snell_to_loopback "$port" || return 1

                # Создание файла службы
                create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                open_port "$stls_port" tcp
                start_and_verify_service "shadowtls-snell-${port}" || return 1
            done
        elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
            # Настройка ShadowTLS для выбранного порта
            local selected_port="${port_list[$((port_choice-1))]}"
            echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${selected_port}${RESET}"
            while true; do
                read -rp "Введите порт прослушивания ShadowTLS (1-65535, нажмите Enter для случайного выбора): " stls_port
                
                # Проверка и получение доступного порта
                stls_port=$(get_available_port "$stls_port")
                if [ $? -eq 0 ]; then
                    break
                fi
                echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
            done
            
            echo -e "${GREEN}Будет использован порт: ${stls_port}${RESET}"
            
            restrict_snell_to_loopback "$selected_port" || return 1

            # Создание файла службы
            create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
            open_port "$stls_port" tcp
            start_and_verify_service "shadowtls-snell-${selected_port}" || return 1
        else
            echo -e "${RED}Неверный выбор${RESET}"
            return 1
        fi
    fi
    
    # Перезагрузка конфигурации systemd
    systemctl daemon-reload
    
    # Получение IP сервера
    local server_ip=$(get_server_ip)
    
    echo -e "\n${GREEN}=== ShadowTLS успешно установлен ===${RESET}"
    
    # Отображение всех доступных конфигураций
    if $configure_ss; then
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        local ss_port=$(get_ssrust_port)
        generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
    fi
    
    if $configure_snell; then
        while IFS='|' read -r port psk; do
            if [ ! -z "$port" ]; then
                local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                if [ -f "$service_file" ]; then
                    local stls_port=$(stls_listen_port "$service_file")
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                fi
            fi
        done <<< "$user_configs"
    fi

    echo -e "\n${GREEN}Служба запущена и добавлена в автозагрузку${RESET}"
}

# Удаление ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}Удаление ShadowTLS...${RESET}"
    
    # Остановка и отключение службы SS
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        local ss_listen_port
        ss_listen_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "${SYSTEMD_DIR}/shadowtls-ss.service" | head -n 1)
        systemctl stop shadowtls-ss 2>/dev/null
        systemctl disable shadowtls-ss 2>/dev/null
        rm -f "${SYSTEMD_DIR}/shadowtls-ss.service"
        if [ -n "$ss_listen_port" ]; then
            close_port "$ss_listen_port"
        fi
    fi
    
    # Остановка и отключение всех служб ShadowTLS, связанных со Snell
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local service_name=$(basename "$service_file")
            local listen_port
            listen_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service_file"
            if [ -n "$listen_port" ]; then
                close_port "$listen_port"
            fi
        done <<< "$snell_services"
    fi
    
    # Удаление бинарного файла
    rm -f "$INSTALL_DIR/shadow-tls"

    # Очистка лог-файлов
    rm -f /var/log/shadowtls-*.log

    # Очистка файла параметров ядра TCP Fast Open (общесистемный, перед удалением запрашиваем подтверждение пользователя)
    if [ -f /etc/sysctl.d/99-tcp-fastopen.conf ]; then
        echo -e "${YELLOW}Обнаружен /etc/sysctl.d/99-tcp-fastopen.conf — это общесистемный файл параметров ядра (net.ipv4.tcp_fastopen). Удалить его? [y/N]${RESET}"
        read -r del_tfo_conf
        if [[ "$del_tfo_conf" =~ ^[Yy]$ ]]; then
            rm -f /etc/sysctl.d/99-tcp-fastopen.conf
            echo -e "${GREEN}Файл /etc/sysctl.d/99-tcp-fastopen.conf удалён${RESET}"
        else
            echo -e "${YELLOW}Файл /etc/sysctl.d/99-tcp-fastopen.conf сохранён${RESET}"
        fi
    fi

    # Очистка таблицы nftables (тихий пропуск при отсутствии)
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet shadowtls_filter 2>/dev/null || true
    fi

    # Перезагрузка конфигурации systemd
    systemctl daemon-reload

    echo -e "${GREEN}ShadowTLS успешно удалён${RESET}"
}

# Просмотр конфигурации
view_config() {
    echo -e "${CYAN}Получение информации о конфигурации...${RESET}"
    
    # Проверка, установлены ли службы
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    
    if [ ! -f "$ss_service" ] && [ -z "$snell_services" ]; then
        echo -e "${RED}ShadowTLS не установлен${RESET}"
        return 1
    fi
    
    # Получение IP сервера
    local server_ip=$(get_server_ip)
    
    # Проверка установки SS и получение конфигурации
    if [ -f "$ss_service" ] && check_ssrust; then
        echo -e "\n${YELLOW}=== Конфигурация Shadowsocks + ShadowTLS ===${RESET}"
        local ss_listen_port=$(stls_listen_port "$ss_service")
        local tls_domain=$(stls_opt tls "$ss_service")
        local password=$(stls_opt password "$ss_service")
        local ss_port=$(get_ssrust_port)
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        
        if [ ! -z "$ss_listen_port" ] && [ ! -z "$tls_domain" ] && [ ! -z "$password" ]; then
            generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
        else
            echo -e "${RED}Конфигурационный файл SS неполный или повреждён${RESET}"
        fi
    fi
    
    # Проверка установки Snell и получение конфигурации
    if [ ! -z "$snell_services" ] && check_snell; then
        echo -e "\n${YELLOW}=== Конфигурация Snell + ShadowTLS ===${RESET}"
        
        # Получение всех пользовательских конфигураций
        local user_configs=$(get_all_snell_users)
        if [ ! -z "$user_configs" ]; then
            # Создание ассоциативного массива для хранения уже обработанных портов
            declare -A processed_ports
            
            while IFS='|' read -r port psk; do
                if [ ! -z "$port" ] && [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    
                    # Получение соответствующей конфигурации службы ShadowTLS
                    local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                    if [ -f "$service_file" ]; then
                        local exec_line=$(grep "ExecStart=" "$service_file")
                        local stls_port=$(printf '%s\n' "$exec_line" | stls_listen_port)
                        local stls_password=$(printf '%s\n' "$exec_line" | stls_opt password)
                        local stls_domain=$(printf '%s\n' "$exec_line" | stls_opt tls)
                        
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "\n${GREEN}Конфигурация основного пользователя:${RESET}"
                        else
                            echo -e "\n${GREEN}Конфигурация пользователя (порт Snell: ${port}):${RESET}"
                        fi
                        
                        if [ ! -z "$stls_port" ] && [ ! -z "$stls_password" ] && [ ! -z "$stls_domain" ]; then
                            echo -e "${YELLOW}Конфигурация Snell:${RESET}"
                            echo -e "  - Порт: ${port}"
                            echo -e "  - PSK: ${psk}"
                            
                            echo -e "\n${YELLOW}Конфигурация ShadowTLS:${RESET}"
                            echo -e "  - Порт прослушивания: ${stls_port}"
                            echo -e "  - Пароль: ${stls_password}"
                            echo -e "  - SNI: ${stls_domain}"
                            echo -e "  - Версия: 3"
                            
                            echo -e "\n${GREEN}Конфигурация Surge:${RESET}"
                            echo -e "${YELLOW}Версия Snell: $(get_port_snell_version "$port")${RESET}"
                            print_snell_shadowtls_line "Snell + ShadowTLS" "$server_ip" "$stls_port" "$psk" \
                                "$stls_password" "$stls_domain" "$port"
                            
                            # Проверка статуса службы
                            local service_status=$(systemctl is-active "shadowtls-snell-${port}")
                            if [ "$service_status" = "active" ]; then
                                echo -e "\n${GREEN}Статус службы: работает${RESET}"
                                # Проверка занятости порта
                                local port_usage=$(netstat -tuln | grep ":${stls_port}")
                                local port_count=$(echo "$port_usage" | wc -l)
                                if [ "$port_count" -gt 1 ]; then
                                    echo -e "${RED}Предупреждение: порт ${stls_port} занят несколькими службами!${RESET}"
                                    echo -e "${YELLOW}Информация о занятости порта:${RESET}"
                                    netstat -tuln | grep ":${stls_port}"
                                fi
                            else
                                echo -e "\n${RED}Статус службы: не работает${RESET}"
                                echo -e "${YELLOW}Попробуйте перезапустить службу следующей командой:${RESET}"
                                echo -e "systemctl restart shadowtls-snell-${port}"
                            fi
                        else
                            echo -e "${RED}Конфигурационный файл неполный или повреждён${RESET}"
                        fi
                    else
                        echo -e "\n${YELLOW}Конфигурация ShadowTLS для пользователя (порт: ${port}) не найдена${RESET}"
                    fi
                fi
            done <<< "$user_configs"
        else
            echo -e "\n${YELLOW}Не найдено действующих пользовательских конфигураций Snell${RESET}"
        fi
    fi
    
    # Отображение статуса служб
    echo -e "\n${YELLOW}=== Статус служб ShadowTLS ===${RESET}"
    
    # Отображение статуса службы SS
    if [ -f "$ss_service" ]; then
        echo -e "\n${YELLOW}Статус службы SS:${RESET}"
        systemctl status shadowtls-ss --no-pager
        
        # Если служба не работает, выводим команду для перезапуска
        if [ "$(systemctl is-active shadowtls-ss)" != "active" ]; then
            echo -e "\n${YELLOW}Служба SS не работает, попробуйте перезапустить её следующей командой:${RESET}"
            echo -e "systemctl restart shadowtls-ss"
        fi
    fi
    
    # Отображение статуса всех служб Snell (без дублирования)
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}Статус служб Snell:${RESET}"
        declare -A shown_services
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            if [ -z "${shown_services[$port]}" ]; then
                shown_services[$port]=1
                echo -e "\n${GREEN}Статус службы ShadowTLS для порта Snell ${port}:${RESET}"
                systemctl status "shadowtls-snell-${port}" --no-pager
                
                # Если служба не работает, выводим команду для перезапуска
                if [ "$(systemctl is-active shadowtls-snell-${port})" != "active" ]; then
                    echo -e "\n${YELLOW}Служба не работает, попробуйте перезапустить её следующей командой:${RESET}"
                    echo -e "systemctl restart shadowtls-snell-${port}"
                fi
            fi
        done <<< "$snell_services"
    fi
}

# Добавление новой конфигурации ShadowTLS
add_shadowtls_config() {
    echo -e "${CYAN}Добавление конфигурации ShadowTLS...${RESET}"
    
    # Определение установленных протоколов
    local has_ss=false
    local has_snell=false
    local has_ss_stls=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}Обнаружен установленный Shadowsocks Rust${RESET}"
        if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
            has_ss_stls=true
            echo -e "${YELLOW}Конфигурация ShadowTLS для Shadowsocks уже существует${RESET}"
        fi
    fi
    
    if check_snell_config; then
        has_snell=true
        echo -e "${GREEN}Обнаружен установленный Snell${RESET}"
    elif check_snell; then
        echo -e "${YELLOW}Обнаружен бинарный файл Snell, но основная конфигурация недоступна; добавление конфигурации ShadowTLS для Snell пока невозможно${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}Не обнаружен ни Shadowsocks Rust, ни Snell. Пожалуйста, сначала установите один из них${RESET}"
        return 1
    fi
    
    # Выбор протокола для добавления конфигурации ShadowTLS
    while true; do
        echo -e "\n${YELLOW}Выберите протокол для добавления конфигурации:${RESET}"
        if $has_ss && ! $has_ss_stls; then
            echo -e "1. Добавить конфигурацию ShadowTLS для Shadowsocks"
        fi
        if $has_snell; then
            echo -e "2. Добавить конфигурацию ShadowTLS для Snell"
        fi
        echo -e "0. Назад"
        
        read -rp "Ваш выбор: " choice
        
        case "$choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss || $has_ss_stls; then
                    echo -e "${RED}Неверный выбор${RESET}"
                    continue
                fi
                # Получение необходимой информации для настройки
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                # Получение домена маскировки TLS (проверка по белому списку для защиты от инъекций в юнит)
                prompt_tls_domain
                prompt_wildcard_sni
                
                # Настройка ShadowTLS для SS
                while true; do
                    read -rp "Введите порт прослушивания ShadowTLS (1-65535, нажмите Enter для случайного выбора): " ss_listen_port
                    
                    # Проверка и получение доступного порта
                    ss_listen_port=$(get_available_port "$ss_listen_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                done
                
                # Создание службы ShadowTLS для SS
                local ss_port=$(get_ssrust_port)
                create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
                open_port "$ss_listen_port" tcp
                start_and_verify_service "shadowtls-ss" || return 1
                
                # Отображение информации о конфигурации
                local server_ip=$(get_server_ip)
                local ssrust_password=$(get_ssrust_password)
                local ssrust_method=$(get_ssrust_method)
                generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}Неверный выбор${RESET}"
                    continue
                fi
                
                # Получение необходимой информации для настройки
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                # Получение домена маскировки TLS (проверка по белому списку для защиты от инъекций в юнит)
                prompt_tls_domain
                prompt_wildcard_sni
                
                # Получение конфигураций всех пользователей Snell
                local user_configs=$(get_all_snell_users)
                if [ -z "$user_configs" ]; then
                    echo -e "${RED}Не найдено действующих пользовательских конфигураций Snell${RESET}"
                    return 1
                fi
                
                # Отображение всех портов Snell без настроенного ShadowTLS
                echo -e "\n${YELLOW}Список портов Snell без настроенного ShadowTLS:${RESET}"
                local port_list=()
                local port_count=0
                while IFS='|' read -r port psk; do
                    if [ ! -z "$port" ] && [ ! -f "${SYSTEMD_DIR}/shadowtls-snell-${port}.service" ]; then
                        port_list+=("$port")
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "${GREEN}$((++port_count)). ${port} (основной пользователь)${RESET}"
                        else
                            echo -e "${GREEN}$((++port_count)). ${port}${RESET}"
                        fi
                    fi
                done <<< "$user_configs"
                
                if [ ${#port_list[@]} -eq 0 ]; then
                    echo -e "${YELLOW}Для всех портов Snell уже настроен ShadowTLS${RESET}"
                    return 0
                fi
                
                # Выбор портов для настройки
                echo -e "\n${YELLOW}Выберите порт для настройки:${RESET}"
                echo -e "1-${#port_list[@]}. Выбрать один порт"
                echo -e "0. Настроить ShadowTLS для всех ненастроенных портов"
                
                read -rp "Ваш выбор: " port_choice
                
                if [ "$port_choice" = "0" ]; then
                    # Настройка ShadowTLS для всех ненастроенных портов
                    for port in "${port_list[@]}"; do
                        echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${port}${RESET}"
                        while true; do
                            read -rp "Введите порт прослушивания ShadowTLS (1-65535, нажмите Enter для случайного выбора): " stls_port
                            
                            # Проверка и получение доступного порта
                            stls_port=$(get_available_port "$stls_port")
                            if [ $? -eq 0 ]; then
                                break
                            fi
                            echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                        done
                        
                        restrict_snell_to_loopback "$port" || return 1

                        # Создание файла службы
                        create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                        open_port "$stls_port" tcp
                        start_and_verify_service "shadowtls-snell-${port}" || return 1
                        
                        # Отображение информации о конфигурации
                        local server_ip=$(get_server_ip)
                        local psk=$(get_snell_config "$port")
                        generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                    done
                elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
                    # Настройка ShadowTLS для выбранного порта
                    local selected_port="${port_list[$((port_choice-1))]}"
                    echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${selected_port}${RESET}"
                    while true; do
                        read -rp "Введите порт прослушивания ShadowTLS (1-65535, нажмите Enter для случайного выбора): " stls_port
                        
                        # Проверка и получение доступного порта
                        stls_port=$(get_available_port "$stls_port")
                        if [ $? -eq 0 ]; then
                            break
                        fi
                        echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                    done
                    
                    restrict_snell_to_loopback "$selected_port" || return 1

                    # Создание файла службы
                    create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
                    open_port "$stls_port" tcp
                    start_and_verify_service "shadowtls-snell-${selected_port}" || return 1
                    
                    # Отображение информации о конфигурации
                    local server_ip=$(get_server_ip)
                    local psk=$(get_snell_config "$selected_port")
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${selected_port}"
                else
                    echo -e "${RED}Неверный выбор${RESET}"
                    continue
                fi
                break
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    done
    
    # Перезагрузка конфигурации systemd
    systemctl daemon-reload
    echo -e "\n${GREEN}Добавление конфигурации завершено${RESET}"
}

# Перезапуск служб ShadowTLS
restart_shadowtls_services() {
    echo -e "${CYAN}Перезапуск служб ShadowTLS...${RESET}"
    
    local has_services=false
    
    # Перезапуск службы SS
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        has_services=true
        echo -e "\n${YELLOW}Перезапуск службы ShadowTLS для Shadowsocks...${RESET}"
        systemctl restart shadowtls-ss
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Служба ShadowTLS для Shadowsocks успешно перезапущена${RESET}"
        else
            echo -e "${RED}Не удалось перезапустить службу ShadowTLS для Shadowsocks${RESET}"
        fi
    fi
    
    # Перезапуск всех служб Snell
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        has_services=true
        echo -e "\n${YELLOW}Перезапуск служб ShadowTLS для Snell...${RESET}"
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "Перезапуск службы для порта ${port}..."
            systemctl restart "shadowtls-snell-${port}"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Служба для порта ${port} успешно перезапущена${RESET}"
            else
                echo -e "${RED}Не удалось перезапустить службу для порта ${port}${RESET}"
            fi
        done <<< "$snell_services"
    fi
    
    if ! $has_services; then
        echo -e "${RED}Службы ShadowTLS не найдены${RESET}"
        return 1
    fi
    
    echo -e "\n${GREEN}Перезапуск всех служб завершён${RESET}"
    
    # Отображение статуса всех служб
    echo -e "\n${YELLOW}Статус служб:${RESET}"
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        echo -e "\n${CYAN}Статус службы ShadowTLS для Shadowsocks:${RESET}"
        systemctl status shadowtls-ss --no-pager
    fi
    
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "\n${CYAN}Статус службы ShadowTLS для порта Snell ${port}:${RESET}"
            systemctl status "shadowtls-snell-${port}" --no-pager
        done <<< "$snell_services"
    fi
}

# Главное меню
main_menu() {
    while true; do
        echo -e "\n${CYAN}Меню управления ShadowTLS${RESET}"
        echo -e "${YELLOW}1. Установить ShadowTLS${RESET}"
        echo -e "${YELLOW}2. Удалить ShadowTLS${RESET}"
        echo -e "${YELLOW}3. Просмотреть конфигурацию${RESET}"
        echo -e "${YELLOW}4. Добавить конфигурацию${RESET}"
        echo -e "${YELLOW}5. Перезапустить службы${RESET}"
        echo -e "${YELLOW}6. Вернуться в предыдущее меню${RESET}"
        echo -e "${YELLOW}0. Выход${RESET}"
        
        if ! read -rp "Выберите действие [0-6]: " choice; then
            echo
            echo -e "${YELLOW}Ввод не получен, выход из меню ShadowTLS.${RESET}"
            return 0
        fi
        
        case "$choice" in
            1)
                install_shadowtls
                ;;
            2)
                uninstall_shadowtls
                ;;
            3)
                view_config
                ;;
            4)
                add_shadowtls_config
                ;;
            5)
                restart_shadowtls_services
                ;;
            6)
                return 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    done
}

# Проверка прав root
check_root
# Миграция старого snell-server.conf в users/snell-main.conf (раньше была спрятана внутри get_snell_port и выполнялась при каждом чтении порта)
migrate_legacy_snell_config >/dev/null 2>&1 || true

# Если скрипт запущен напрямую, отображаем главное меню
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
