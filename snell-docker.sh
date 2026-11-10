#!/bin/sh
# Этот файл сгенерирован с помощью tools/build.sh из src/snell-docker.sh и src/lib: вносите изменения в файлы в каталоге src/ и генерируйте заново.
# =========================================
# Автор: jinqians (Docker-версия)
# Дата создания: 5 марта 2026 г.
# Описание: Установка и управление прокси Snell с помощью Docker на Alpine | Debian | CentOS... Linux
#           Избегает проблем совместимости с хост-системой, поддерживает Snell v4/v5/v6
# =========================================

# --- Общая часть (src/lib, объединяется через tools/build.sh при релизе; всё на POSIX sh) ---
# Цвета, проверка root, официальные версии и ссылки на скачивание Snell, внешний IP и страна, файрвол
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

# ── lib/netinfo.sh ────────────────────────────────────────────────────────────
# Публичный IP-адрес хоста и страна расположения (используется при генерации конфигурации клиента). POSIX sh.

# Публичный IPv4 / IPv6 хоста (пусто, если получить не удалось)
get_public_ipv4() { curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null; }
get_public_ipv6() { curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null; }

# Запрос кода страны для IP (резервирование через несколько API, чтобы избежать возврата ошибки при лимите запросов на одном из них)
get_ip_country() {
    local target="$1"
    local api=""
    local raw=""
    local result=""

    if [ -z "$target" ]; then
        echo "Unknown"
        return 1
    fi

    for api in "https://ipinfo.io/${target}/country" \
               "http://ip-api.com/line/${target}?fields=countryCode" \
               "https://ipwho.is/${target}?fields=country_code" \
               "https://ipapi.co/${target}/country/"; do
        raw=$(curl -s --connect-timeout 5 --max-time 10 "$api" 2>/dev/null)
        result=$(echo "$raw" | tr -d ' \t\r\n')
        case "$result" in
            [A-Za-z][A-Za-z]) ;;
            *) result=$(echo "$raw" | sed -n 's/.*"country_code"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -n 1) ;;
        esac
        case "$result" in
            [A-Za-z][A-Za-z])
                echo "$result" | tr '[:lower:]' '[:upper:]'
                return 0
                ;;
        esac
    done

    echo "Unknown"
    return 1
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

BLUE='\033[0;34m'

# --- Версия скрипта ---
current_version="1.7"

# Режим шифрования Snell v6: default / unshaped / unsafe-raw (на клиенте должен совпадать с сервером)
SNELL_MODE="default"


# --- Глобальные переменные ---
SNELL_VERSION_CHOICE=""
SNELL_VERSION=""
CONTAINER_NAME="snell-server"
IMAGE_NAME="my-snell"
# Каталог, в котором находится скрипт (определяется до перехода во временный рабочий каталог, чтобы create_dockerfile мог найти entrypoint.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Базовые функции ---

# В минимальной установке Alpine по умолчанию нет curl; при его отсутствии запросы внешнего IP и версий будут молча завершаться ошибкой
ensure_curl() {
    command -v curl >/dev/null 2>&1 && return 0
    echo -e "${YELLOW}curl не обнаружен, выполняется установка...${RESET}"
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl >/dev/null 2>&1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}Не удалось установить curl, установите его вручную и повторите попытку.${RESET}"
        exit 1
    fi
}

# Точное совпадение по имени контейнера; прямой grep по выводу docker ps может ошибочно среагировать на имя образа jinqians/snell-server
container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"
}

# Автозапуск Docker при загрузке системы
# В Alpine скрипт /etc/init.d/docker объявляет зависимость need net, которая предоставляется службой networking,
# а в облачных образах networking находится на уровне запуска (runlevel) default. Если поместить docker на уровень boot,
# при загрузке зависимость не будет выполнена, служба не запустится, и после перезагрузки все контейнеры будут недоступны; поэтому его нужно добавлять в default.
enable_docker_on_boot() {
    if [ -f /etc/alpine-release ]; then
        if rc-update show boot 2>/dev/null | grep -qw docker; then
            rc-update del docker boot >/dev/null 2>&1
            echo -e "${YELLOW}Служба docker перемещена с уровня запуска boot на default (иначе она не будет автоматически запускаться после перезагрузки)${RESET}"
        fi
        rc-update add docker default >/dev/null 2>&1
    else
        systemctl enable docker >/dev/null 2>&1
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}Docker не обнаружен. Установить автоматически?${RESET}"
        printf "Введите y для установки, любую другую клавишу для выхода: "
        read -r install_docker
        if [ "$install_docker" != "y" ] && [ "$install_docker" != "Y" ]; then
            echo -e "${RED}Установка отменена.${RESET}"
            exit 1
        fi
        
        echo -e "${CYAN}Установка Docker...${RESET}"
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache docker docker-cli-compose
        else
            echo -e "${YELLOW}Сейчас будет скачан официальный скрипт установки Docker с https://get.docker.com и выполнен напрямую через конвейер (pipe).${RESET}"
            echo -e "${YELLOW}Внимание: выполнение удалённых скриптов через pipe несёт риски для цепочки поставок. Убедитесь, что вы доверяете этому источнику.${RESET}"
            printf "Подтверждаете продолжение установки Docker? [y/N]: "
            read -r confirm_pipe_install
            if [ "$confirm_pipe_install" != "y" ] && [ "$confirm_pipe_install" != "Y" ]; then
                echo -e "${RED}Установка Docker отменена.${RESET}"
                exit 1
            fi
            curl -fsSL https://get.docker.com | sh
        fi

        if ! command -v docker >/dev/null 2>&1; then
            echo -e "${RED}Не удалось установить Docker, пожалуйста, установите его вручную.${RESET}"
            exit 1
        fi
        echo -e "${GREEN}✓ Docker успешно установлен${RESET}"
    fi

    # Проверяем и корректируем автозапуск при каждом вызове, чтобы исправить настройку даже на тех машинах, где Docker уже был установлен ранее
    enable_docker_on_boot

    if ! docker info >/dev/null 2>&1; then
        echo -e "${YELLOW}Служба Docker не запущена, попытка запуска...${RESET}"
        if [ -f /etc/alpine-release ]; then
            rc-service docker start
        else
            systemctl start docker
        fi
        # Сразу после запуска dockerd сокет ещё не готов, ждём максимум 30 секунд
        local i=0
        while ! docker info >/dev/null 2>&1 && [ "$i" -lt 30 ]; do
            sleep 1
            i=$((i + 1))
        done
        if ! docker info >/dev/null 2>&1; then
            echo -e "${RED}Не удалось запустить службу Docker, запустите её вручную.${RESET}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✓ Проверка окружения Docker пройдена${RESET}"
}

# --- Выбор и получение версии ---

select_snell_version() {
    echo -e "${CYAN}Выберите версию Snell для установки:${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6"

    while true; do
        printf "Введите вариант [1-3]: "
        read -r version_choice
        case "$version_choice" in
            1) SNELL_VERSION_CHOICE="v4"; echo -e "${GREEN}Выбран Snell v4${RESET}"; break ;;
            2) SNELL_VERSION_CHOICE="v5"; echo -e "${GREEN}Выбран Snell v5${RESET}"; break ;;
            3) SNELL_VERSION_CHOICE="v6"; echo -e "${GREEN}Выбран Snell v6${RESET}"; echo -e "${YELLOW}v6 принимает только клиентов с version = 6 (клиенты v4 / v5 подключиться не смогут), параметр mode на клиенте также должен совпадать с сервером${RESET}"; echo -e "${YELLOW}В v6 удалены режим проксирования QUIC и obfs, а также не предоставляются сборки под armv7l${RESET}"; echo -e "${YELLOW}Режим шифрования: mode = ${SNELL_MODE} (на клиенте должен быть настроен такой же mode)${RESET}"; break ;;
            *) echo -e "${RED}Пожалуйста, введите корректный вариант [1-3]${RESET}" ;;
        esac
    done
}

# Чтение параметра mode, используемого установленным контейнером v6 (при неудаче возвращается значение по умолчанию)
get_snell_mode() {
    local conf_file="/etc/snell-docker/snell-server.conf"
    local mode=""
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' ')
    fi
    if [ -z "$mode" ]; then
        mode="$SNELL_MODE"
    fi
    echo "$mode"
}

# Официальная страница релизов Snell (старая manual.nssurge.com/others/snell.html отключена)
SNELL_RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
SNELL_RELEASE_NOTES_URL_ZH="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"

get_latest_snell_version() {
    if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
        SNELL_VERSION=$(get_latest_snell_v6_version)
    elif [ "$SNELL_VERSION_CHOICE" = "v5" ]; then
        SNELL_VERSION=$(get_latest_snell_v5_version)
    else
        SNELL_VERSION=$(get_latest_snell_v4_version)
    fi
    echo -e "${GREEN}Получена версия: ${SNELL_VERSION}${RESET}"
}

# --- Порт и конфигурация ---

get_user_port() {
    while true; do
        printf "Введите номер используемого порта (1-65535), нажмите Enter для значения по умолчанию [случайный]: "
        read -r PORT
        if [ -z "$PORT" ]; then 
            PORT=$(shuf -i 20000-65000 -n 1)
            echo -e "${YELLOW}Используется случайный порт: $PORT${RESET}"
            break
        fi
        case "$PORT" in 
            ''|*[!0-9]*) 
                echo -e "${RED}Некорректный ввод, пожалуйста, введите только цифры.${RESET}"
                continue
                ;;
        esac
        if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then 
            echo -e "${GREEN}Выбран порт: $PORT${RESET}"
            break
        else 
            echo -e "${RED}Некорректный номер порта, введите число от 1 до 65535.${RESET}"
        fi
    done
}

# --- Функции для работы с Docker ---

create_dockerfile() {
    local snell_url
    snell_url=$(snell_download_url_for "$SNELL_VERSION_CHOICE" "$SNELL_VERSION") || exit 1
    local arch=$(uname -m)
    local gnu_lib_dir=""
    local ld_linker_cmd=""

    case ${arch} in
        "x86_64"|"amd64")
            gnu_lib_dir="x86_64-linux-gnu"
            ld_linker_cmd="mkdir -p /lib64 && ln -sf /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2"
            ;;
        "aarch64"|"arm64")
            gnu_lib_dir="aarch64-linux-gnu"
            ld_linker_cmd="ln -sf /usr/glibc-compat/lib/ld-linux-aarch64.so.1 /lib/ld-linux-aarch64.so.1"
            ;;
        "armv7l"|"armv7")
            gnu_lib_dir="arm-linux-gnueabihf"
            ld_linker_cmd="ln -sf /usr/glibc-compat/lib/ld-linux-armhf.so.3 /lib/ld-linux-armhf.so.3"
            ;;
    esac

    echo -e "${CYAN}Создание Dockerfile (многоэтапная сборка: извлечение glibc из Debian + запуск на Alpine)...${RESET}"

    # Подготовка entrypoint.sh: при первом запуске контейнера он автоматически генерирует конфигурацию и PSK,
    # чтобы больше не запекать конфигурационный файл с открытым PSK в слои образа.
    # При запуске из репозитория используется локальный docker/entrypoint.sh (сам скрипт находится в scripts/)
    if [ -f "${SCRIPT_DIR}/../docker/entrypoint.sh" ]; then
        cp "${SCRIPT_DIR}/../docker/entrypoint.sh" ./entrypoint.sh
        echo -e "${GREEN}✓ Использован локальный entrypoint.sh${RESET}"
    else
        echo -e "${CYAN}Скачивание entrypoint.sh...${RESET}"
        if ! curl -fsSL -o ./entrypoint.sh "${SNELL_RAW_BASE}/docker/entrypoint.sh"; then
            echo -e "${RED}✗ Ошибка скачивания entrypoint.sh${RESET}"
            return 1
        fi
        if [ ! -s ./entrypoint.sh ] || ! sh -n ./entrypoint.sh 2>/dev/null; then
            echo -e "${RED}✗ Проверка entrypoint.sh не пройдена (пустой файл или синтаксическая ошибка), файл отброшен${RESET}"
            rm -f ./entrypoint.sh
            return 1
        fi
        echo -e "${GREEN}✓ entrypoint.sh скачан и успешно проверен${RESET}"
    fi

    cat > Dockerfile << EOF
# Этап 1: использование Debian для скачивания бинарного файла и предоставления библиотек среды выполнения glibc
FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip ca-certificates && \\
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN curl -L -o snell.zip "${snell_url}" && \\
    unzip -o snell.zip && \\
    rm -f snell.zip && \\
    chmod +x /app/snell-server

# Этап 2: финальный образ Alpine с внедрением библиотек среды выполнения glibc
FROM alpine:3.19
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /app/snell-server /app/snell-server
COPY --from=builder /lib/${gnu_lib_dir}/ /usr/glibc-compat/lib/
# Snell может зависеть от libstdc++ и других библиотек времени выполнения в /usr/lib.
COPY --from=builder /usr/lib/${gnu_lib_dir}/ /usr/glibc-compat/lib/
RUN ${ld_linker_cmd}
ENV LD_LIBRARY_PATH=/usr/glibc-compat/lib
RUN mkdir -p /etc/snell
# Конфигурационный файл с открытым PSK больше не копируется через COPY: конфигурация и PSK автоматически генерируются скриптом entrypoint.sh при первом запуске контейнера
# и сохраняются на хосте через -v /etc/snell-docker:/etc/snell, чтобы секреты не попадали в слои образа
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
ENV SNELL_PORT=${PORT}
ENV SNELL_VER=${SNELL_VERSION_CHOICE}
ENV SNELL_MODE=${SNELL_MODE}
EXPOSE ${PORT}/tcp ${PORT}/udp
ENTRYPOINT ["/app/entrypoint.sh"]
EOF

    echo -e "${GREEN}✓ Создание Dockerfile завершено${RESET}"
}

create_config_file() {
    echo -e "${CYAN}Подготовка каталога конфигурации...${RESET}"

    # Каталог конфигурации монтируется в контейнер через -v; файл конфигурации и PSK автоматически генерируются внутри контейнера скриптом entrypoint.sh при первом запуске,
    # чтобы не запекать файл конфигурации с открытым PSK в слои образа
    mkdir -p /etc/snell-docker
    # Когда контейнер работает от имени nobody (uid 65534), монтируемый каталог должен быть доступен ему для записи, иначе entrypoint не сможет создать конфигурацию
    chown -R 65534:65533 /etc/snell-docker 2>/dev/null || \
        echo -e "${YELLOW}Подсказка: не удалось назначить владельца для /etc/snell-docker; при сбое запуска контейнера выполните вручную chown -R 65534:65533 /etc/snell-docker${RESET}"

    # Сохранение информации о конфигурации в переменную
    SNELL_PORT="$PORT"

    echo -e "${GREEN}✓ Каталог конфигурации готов: /etc/snell-docker${RESET}"
    echo -e "${YELLOW}Порт: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK будет сгенерирован автоматически при первом запуске контейнера; конфигурацию клиента можно посмотреть через docker logs${RESET}"
}

build_docker_image() {
    echo -e "${CYAN}Сборка Docker-образа...${RESET}"
    
    if docker build -t "${IMAGE_NAME}:${SNELL_VERSION}" -t "${IMAGE_NAME}:latest" .; then
        echo -e "${GREEN}✓ Docker-образ успешно собран${RESET}"
    else
        echo -e "${RED}✗ Ошибка сборки Docker-образа${RESET}"
        return 1
    fi
}

start_snell_container() {
    echo -e "${CYAN}Запуск контейнера Snell...${RESET}"
    
    # Остановка и удаление старого контейнера, если он существует
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true
    
    # Шаг 1: тестовый запуск без флага --restart во избежание бесконечного цикла перезапусков при сбое
    echo -e "${CYAN}Тестовый запуск контейнера...${RESET}"
    local run_output
    # -v /etc/snell-docker:/etc/snell: конфигурация и PSK генерируются скриптом entrypoint при первом запуске и сохраняются на хосте
    run_output=$(docker run -d \
        --name "${CONTAINER_NAME}" \
        -p "${SNELL_PORT}:${SNELL_PORT}/tcp" \
        -p "${SNELL_PORT}:${SNELL_PORT}/udp" \
        -v /etc/snell-docker:/etc/snell \
        "${IMAGE_NAME}:latest" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Не удалось создать контейнер${RESET}"
        echo "   $run_output"
        return 1
    fi
    
    echo -e "${GREEN}✓ Контейнер создан${RESET}"
    
    # Ожидание запуска
    echo -e "${CYAN}Ожидание запуска службы...${RESET}"
    sleep 5
    
    # Проверка, работает ли контейнер
    local container_status=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)
    local exit_code=$(docker inspect --format='{{.State.ExitCode}}' "${CONTAINER_NAME}" 2>/dev/null)
    
    if [ "$container_status" = "running" ]; then
        # Ждём ещё несколько секунд для подтверждения стабильности
        sleep 3
        container_status=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)
    fi
    
    if [ "$container_status" != "running" ]; then
        echo -e "${RED}✗ Ошибка запуска контейнера, статус: $container_status, код выхода: $exit_code${RESET}"
        echo -e "${CYAN}Логи контейнера:${RESET}"
        docker logs "${CONTAINER_NAME}" 2>&1 | sed 's/^/   /'
        
        if [ "$exit_code" = "127" ]; then
            echo -e "${RED}Код выхода 127 = программа или команда не найдена${RESET}"
            echo -e "${YELLOW}Проверка содержимого образа...${RESET}"
            # Запуск временного контейнера с sh для проверки содержимого образа
            docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
            echo -e "${CYAN}Каталог /app внутри образа:${RESET}"
            docker run --rm --entrypoint sh "${IMAGE_NAME}:latest" -c "ls -la /app/ 2>&1" 2>&1 | sed 's/^/   /'
            echo -e "${CYAN}Каталог /etc/snell внутри образа:${RESET}"
            docker run --rm --entrypoint sh -v /etc/snell-docker:/etc/snell "${IMAGE_NAME}:latest" -c "ls -la /etc/snell/ 2>&1" 2>&1 | sed 's/^/   /'
            echo -e "${CYAN}Информация о бинарном файле:${RESET}"
            docker run --rm --entrypoint sh "${IMAGE_NAME}:latest" -c "file /app/snell-server 2>&1" 2>&1 | sed 's/^/   /'
            echo -e "${CYAN}Тест ручного запуска:${RESET}"
            docker run --rm --entrypoint sh -v /etc/snell-docker:/etc/snell "${IMAGE_NAME}:latest" -c "/app/snell-server -c /etc/snell/snell-server.conf" 2>&1 | head -5 | sed 's/^/   /'
        fi
        
        docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
        return 1
    fi
    
    echo -e "${GREEN}✓ Контейнер работает нормально${RESET}"
    
    # Проверка проброса портов
    local port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
    if [ -n "$port_mapping" ]; then
        echo -e "${GREEN}✓ Проброс портов: $port_mapping${RESET}"
    fi
    
    # Отображение логов контейнера
    echo -e "${CYAN}Логи контейнера:${RESET}"
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -5 | sed 's/^/   /'
    
    # Тест прошёл успешно, включаем политику автоматического перезапуска
    echo -e "${CYAN}Включение политики автоматического перезапуска...${RESET}"
    docker update --restart unless-stopped "${CONTAINER_NAME}" 2>/dev/null || true
    
    echo -e "${GREEN}✓ Контейнер Snell успешно запущен${RESET}"
    return 0
}

# --- Функции установки ---

install_snell() {
    check_root
    ensure_curl
    check_docker
    
    # Проверка наличия уже существующего контейнера
    if container_exists; then
        echo -e "${YELLOW}Обнаружен уже существующий контейнер Snell. Переустановить его?${RESET}"
        printf "Введите y для продолжения, любую другую клавишу для отмены: "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            return
        fi
        uninstall_snell
    fi
    
    select_snell_version

    # v6 не поддерживает armv7l
    local _arch=$(uname -m)
    if [ "$SNELL_VERSION_CHOICE" = "v6" ] && { [ "$_arch" = "armv7l" ] || [ "$_arch" = "armv7" ]; }; then
        echo -e "${RED}Snell v6 пока не поддерживает архитектуру armv7l, пожалуйста, выберите v4 или v5.${RESET}"
        return 1
    fi

    get_latest_snell_version
    get_user_port
    
    # Создание временного рабочего каталога
    WORK_DIR="/tmp/snell-docker-$(date +%s)"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    echo -e "${CYAN}Начало установки Snell ${SNELL_VERSION} через Docker...${RESET}"
    
    # Создание файла конфигурации
    if ! create_config_file; then
        echo -e "${RED}Ошибка установки!${RESET}"
        cd - >/dev/null
        rm -rf "$WORK_DIR"
        return 1
    fi

    # Создание Dockerfile
    if ! create_dockerfile; then
        echo -e "${RED}Ошибка установки!${RESET}"
        cd - >/dev/null
        rm -rf "$WORK_DIR"
        return 1
    fi

    # Сборка образа
    if ! build_docker_image; then
        echo -e "${RED}Ошибка установки!${RESET}"
        cd - >/dev/null
        rm -rf "$WORK_DIR"
        return 1
    fi
    
    # Запуск контейнера
    if ! start_snell_container; then
        echo -e "${RED}Ошибка установки!${RESET}"
        cd - >/dev/null
        rm -rf "$WORK_DIR"
        return 1
    fi
    
    # Очистка временных файлов
    cd - >/dev/null
    rm -rf "$WORK_DIR"
    
    echo -e "${GREEN}🎉 Установка Snell Server завершена!${RESET}"
    
    # Настройка файрвола
    configure_firewall
    
    # Отображение информации о конфигурации
    show_information
}

# --- Функции управления ---

uninstall_snell() {
    check_root
    
    echo -e "${CYAN}Удаление Docker-контейнера Snell...${RESET}"
    
    # Остановка и удаление контейнера
    if docker stop "${CONTAINER_NAME}" 2>/dev/null; then
        echo -e "${GREEN}✓ Контейнер остановлен${RESET}"
    fi
    
    if docker rm "${CONTAINER_NAME}" 2>/dev/null; then
        echo -e "${GREEN}✓ Контейнер удалён${RESET}"
    fi
    
    # Запрос на удаление образа
    printf "Удалить также Docker-образ? [y/N]: "
    read -r remove_image
    if [ "$remove_image" = "y" ] || [ "$remove_image" = "Y" ]; then
        docker rmi "${IMAGE_NAME}:latest" 2>/dev/null || true
        docker rmi $(docker images "${IMAGE_NAME}" -q) 2>/dev/null || true
        echo -e "${GREEN}✓ Docker-образ удалён${RESET}"
    fi
    
    # Закрытие порта в файрволе (порт читается из конфига, поэтому выполняем до удаления конфига)
    if [ -f "/etc/snell-docker/snell-server.conf" ]; then
        old_port=$(grep 'listen' /etc/snell-docker/snell-server.conf | sed 's/.*://' | tr -d ' ')
        [ -n "$old_port" ] && close_port "$old_port"
    fi

    # Очистка конфигурационных файлов
    if [ -d "/etc/snell-docker" ]; then
        rm -rf /etc/snell-docker
        echo -e "${GREEN}✓ Файлы конфигурации удалены${RESET}"
    fi
    
    echo -e "${GREEN}🗑️  Snell полностью удалён${RESET}"
}

restart_snell() {
    check_root
    
    if ! container_exists; then
        echo -e "${RED}Ошибка: контейнер Snell не существует${RESET}"
        return 1
    fi
    
    echo -e "${CYAN}Перезапуск контейнера Snell...${RESET}"
    
    if docker restart "${CONTAINER_NAME}"; then
        sleep 2
        if container_running; then
            echo -e "${GREEN}✓ Контейнер Snell успешно перезапущен${RESET}"
        else
            echo -e "${RED}✗ Сбой в работе контейнера после перезапуска${RESET}"
            echo -e "${YELLOW}Просмотр логов: docker logs ${CONTAINER_NAME}${RESET}"
        fi
    else
        echo -e "${RED}✗ Не удалось перезапустить контейнер${RESET}"
    fi
}

check_status() {
    echo -e "${CYAN}=== Статус Docker-контейнера Snell ===${RESET}"
    
    if container_exists; then
        echo -e "\n${CYAN}Информация о контейнере:${RESET}"
        docker ps -a --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        
        echo -e "\n${CYAN}Использование ресурсов:${RESET}"
        docker stats "${CONTAINER_NAME}" --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
        
        echo -e "\n${CYAN}Логи контейнера (последние 10 строк):${RESET}"
        docker logs --tail 10 "${CONTAINER_NAME}"
    else
        echo -e "${RED}Контейнер Snell не существует${RESET}"
    fi
}

# Диагностика сетевого подключения
network_diagnosis() {
    echo -e "${CYAN}🔍 Запуск диагностики сетевого подключения Snell...${RESET}"
    echo -e "${CYAN}===========================================${RESET}"
    
    # Проверка существования файла конфигурации
    if [ ! -f "/etc/snell-docker/snell-server.conf" ]; then
        echo -e "${RED}❌ Файл конфигурации не существует, сначала установите Snell${RESET}"
        return 1
    fi
    
    # Чтение конфигурации
    local port=$(grep 'listen' /etc/snell-docker/snell-server.conf | sed 's/.*://')
    local psk=$(grep 'psk' /etc/snell-docker/snell-server.conf | sed 's/psk[[:space:]]*=[[:space:]]*//')
    local version_choice
    version_choice=$(grep 'version-choice' /etc/snell-docker/snell-server.conf 2>/dev/null | sed 's/version-choice[[:space:]]*=[[:space:]]*//')
    if [ -z "$version_choice" ]; then
        version_choice="v4"
        if docker images "${IMAGE_NAME}" --format '{{.Tag}}' 2>/dev/null | grep -q 'v6'; then
            version_choice="v6"
        elif docker images "${IMAGE_NAME}" --format '{{.Tag}}' 2>/dev/null | grep -q 'v5'; then
            version_choice="v5"
        fi
    fi
    
    echo -e "${YELLOW}📋 Информация о конфигурации службы:${RESET}"
    echo "   Порт: $port"
    echo "   Версия: $version_choice"
    echo "   PSK: $(printf '%s' "$psk" | cut -c 1-10)..."
    echo ""
    
    # 1. Проверка статуса контейнера
    echo -e "${CYAN}1️⃣  Проверка статуса контейнера...${RESET}"
    if container_running; then
        echo -e "   ${GREEN}✅ Контейнер работает${RESET}"
        local container_ports=$(docker port "${CONTAINER_NAME}")
        echo "   Проброс портов: $container_ports"
    else
        echo -e "   ${RED}❌ Контейнер не запущен${RESET}"
        if container_exists; then
            echo -e "   ${YELLOW}⚠️  Контейнер существует, но остановлен. Попытка запуска...${RESET}"
            docker start "${CONTAINER_NAME}"
            sleep 2
        else
            echo -e "   ${RED}❌ Контейнер не существует, выполните переустановку${RESET}"
            return 1
        fi
    fi
    echo ""
    
    # 2. Проверка проброса портов Docker
    echo -e "${CYAN}2️⃣  Проверка проброса портов Docker...${RESET}"
    local port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
    if [ -n "$port_mapping" ]; then
        echo -e "   ${GREEN}✅ Проброс портов Docker настроен${RESET}"
        echo "   $port_mapping" | sed 's/^/   /'
        
        # Проверка, прослушивается ли порт на хосте
        if netstat -tlnp 2>/dev/null | grep ":$port " | grep -q LISTEN; then
            echo -e "   ${GREEN}✅ Порт хоста $port прослушивается${RESET}"
            netstat -tlnp 2>/dev/null | grep ":$port " | head -1 | sed 's/^/   /'
        else
            echo -e "   ${RED}❌ Порт хоста $port не прослушивается${RESET}"
        fi
    else
        echo -e "   ${RED}❌ Проброс портов Docker отсутствует или работает некорректно${RESET}"
        echo -e "   ${YELLOW}Проверка подробного статуса контейнера...${RESET}"
        
        # Подробная проверка статуса контейнера
        local container_status=$(docker ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null)
        echo "   Статус контейнера: $container_status"
        
        # Проверка существования образа
        if ! docker images | grep -q "${IMAGE_NAME}"; then
            echo -e "   ${RED}❌ Docker-образ не существует, требуется переустановка${RESET}"
            echo -e "   ${YELLOW}Выберите пункт 1 в главном меню для переустановки Snell${RESET}"
            return 1
        fi
        
        echo -e "   ${YELLOW}Попытка пересоздания контейнера...${RESET}"
        
        # Остановка и удаление контейнера
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "${CONTAINER_NAME}" 2>/dev/null || true
        
        # Повторный запуск контейнера (конфигурация встроена в образ, монтирование не требуется)
        echo -e "   ${CYAN}Пересоздание контейнера...${RESET}"
        if docker run -d \
            --name "${CONTAINER_NAME}" \
            --restart unless-stopped \
            -p "${port}:${port}/tcp" \
            -p "${port}:${port}/udp" \
            "${IMAGE_NAME}:latest" 2>/dev/null; then
            echo -e "   ${GREEN}✅ Контейнер пересоздан${RESET}"
            sleep 5
            
            # Проверка нового контейнера
            local new_restarting=$(docker inspect --format='{{.State.Restarting}}' "${CONTAINER_NAME}" 2>/dev/null)
            if [ "$new_restarting" = "true" ]; then
                echo -e "   ${RED}❌ Контейнер продолжает перезапускаться, рекомендуется переустановка через пункт 1${RESET}"
                docker logs --tail 5 "${CONTAINER_NAME}" 2>&1 | sed 's/^/   /'
            else
                local new_port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
                if [ -n "$new_port_mapping" ]; then
                    echo -e "   ${GREEN}✅ Проброс портов восстановлен: $new_port_mapping${RESET}"
                else
                    echo -e "   ${RED}❌ Проблема с пробросом портов сохраняется${RESET}"
                fi
            fi
        else
            echo -e "   ${RED}❌ Не удалось пересоздать контейнер${RESET}"
            echo -e "   ${YELLOW}Возможна проблема с образом, рекомендуется переустановка${RESET}"
        fi
    fi
    echo ""
    
    # 3. Проверка правил файрвола
    echo -e "${CYAN}3️⃣  Проверка правил файрвола...${RESET}"
    if command -v iptables >/dev/null 2>&1; then
        if iptables -L INPUT -n | grep -q "dpt:$port"; then
            echo -e "   ${GREEN}✅ Правило iptables существует${RESET}"
            iptables -L INPUT -n | grep "dpt:$port" | head -1 | sed 's/^/   /'
        else
            echo -e "   ${RED}❌ Правило iptables отсутствует${RESET}"
            echo -e "   ${YELLOW}Попытка добавления правила...${RESET}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && \
            echo -e "   ${GREEN}✅ Правило iptables добавлено${RESET}" || \
            echo -e "   ${RED}❌ Не удалось добавить правило iptables${RESET}"
        fi
    else
        echo -e "   ${YELLOW}⚠️  iptables недоступен${RESET}"
    fi
    
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "$port"; then
            echo -e "   ${GREEN}✅ Правило UFW существует${RESET}"
        else
            echo -e "   ${YELLOW}⚠️  Правило UFW может отсутствовать${RESET}"
        fi
    fi
    echo ""
    
    # 4. Тест внешней доступности порта
    echo -e "${CYAN}4️⃣  Тестирование внешней доступности порта...${RESET}"
    local server_ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ -n "$server_ip" ]; then
        echo "   IP сервера: $server_ip"
        
        # Тестирование порта несколькими способами
        echo -e "   ${CYAN}Тестирование порта $port...${RESET}"
        
        # Способ 1: использование nc (netcat)
        if command -v nc >/dev/null 2>&1; then
            if timeout 5 nc -z "$server_ip" "$port" 2>/dev/null; then
                echo -e "   ${GREEN}✅ Тест nc пройден${RESET}"
            else
                echo -e "   ${RED}❌ Тест nc не пройден${RESET}"
            fi
        fi
        
        # Способ 2: использование telnet
        if command -v telnet >/dev/null 2>&1; then
            if timeout 5 sh -c "echo '' | telnet $server_ip $port" 2>/dev/null | grep -q Connected; then
                echo -e "   ${GREEN}✅ Тест telnet пройден${RESET}"
            else
                echo -e "   ${RED}❌ Тест telnet не пройден${RESET}"
            fi
        fi
        
        # Способ 3: использование онлайн-сервисов проверки портов
        echo -e "   ${YELLOW}💡 Онлайн-инструменты проверки портов:${RESET}"
        echo "   https://www.yougetsignal.com/tools/open-ports/"
        echo "   https://tool.chinaz.com/port/"
        echo "   Введите IP: $server_ip, порт: $port"
    else
        echo -e "   ${RED}❌ Не удалось получить IP сервера${RESET}"
    fi
    echo ""
    
    # 5. Подробная внутренняя проверка контейнера
    echo -e "${CYAN}5️⃣  Подробная внутренняя проверка контейнера...${RESET}"
    if container_running; then
        # Проверка портов внутри контейнера
        echo -e "   ${CYAN}Проверка прослушивания портов внутри контейнера...${RESET}"
        local container_netstat=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
        if [ -n "$container_netstat" ]; then
            echo -e "   ${GREEN}✅ Порт внутри контейнера нормально прослушивается${RESET}"
            echo "   $container_netstat" | sed 's/^/   /'
        else
            echo -e "   ${RED}❌ Порт внутри контейнера не прослушивается${RESET}"
        fi
        
        # Проверка процесса Snell
        echo -e "   ${CYAN}Проверка состояния процесса Snell...${RESET}"
        local snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
        if [ -n "$snell_process" ]; then
            echo -e "   ${GREEN}✅ Процесс Snell запущен${RESET}"
            echo "$snell_process" | sed 's/^/   /'
            
            # Проверка нормального состояния процесса
            if echo "$snell_process" | grep -q "\[snell-server\]"; then
                echo -e "   ${RED}⚠️  Обнаружен формат зомби-процесса, возможно, Snell не запустился должным образом${RESET}"
                echo -e "   ${YELLOW}Попытка перезапуска службы Snell...${RESET}"
                
                # Завершение возможных зомби-процессов
                docker exec "${CONTAINER_NAME}" pkill -f snell 2>/dev/null || true
                sleep 1
                
                # Повторный запуск Snell
                echo -e "   ${CYAN}Повторный запуск службы Snell...${RESET}"
                if docker exec -d "${CONTAINER_NAME}" sh -c "cd /app && exec ./snell-server -c /etc/snell/snell-server.conf" 2>/dev/null; then
                    sleep 3
                    local new_snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
                    if [ -n "$new_snell_process" ]; then
                        echo -e "   ${GREEN}✓ Служба Snell успешно перезапущена${RESET}"
                        echo "$new_snell_process" | sed 's/^/   RESTART: /'
                    else
                        echo -e "   ${RED}✗ Не удалось перезапустить службу Snell${RESET}"
                    fi
                else
                    echo -e "   ${RED}✗ Ошибка выполнения команды перезапуска${RESET}"
                fi
            fi
        else
            echo -e "   ${RED}❌ Процесс Snell не запущен${RESET}"
        fi
        
        # Проверка файла конфигурации
        echo -e "   ${CYAN}Проверка файла конфигурации...${RESET}"
        local ls_result=$(docker exec "${CONTAINER_NAME}" ls -la /etc/snell/ 2>/dev/null || echo "")
        if [ -n "$ls_result" ]; then
            echo -e "   ${GREEN}✅ Каталог конфигурации существует${RESET}"
            echo "$ls_result" | sed 's/^/   /'
            
            # Проверка содержимого файла конфигурации
            local config_content=$(docker exec "${CONTAINER_NAME}" cat /etc/snell/snell-server.conf 2>/dev/null || echo "")
            if [ -n "$config_content" ]; then
                echo -e "   ${GREEN}✅ Файл конфигурации существует и не пуст${RESET}"
                echo "$config_content" | sed 's/^/   /'
            else
                echo -e "   ${RED}❌ Файл конфигурации отсутствует или пуст${RESET}"
                echo -e "   ${YELLOW}Рекомендуется выбрать пункт 1 для переустановки${RESET}"
            fi
        else
            echo -e "   ${RED}❌ Каталог конфигурации не существует${RESET}"
            echo -e "   ${YELLOW}Это указывает на серьёзную проблему с монтированием тома контейнера${RESET}"
        fi
        
        # Проверка бинарного файла Snell
        echo -e "   ${CYAN}Проверка бинарного файла Snell...${RESET}"
        local snell_binary=$(docker exec "${CONTAINER_NAME}" ls -la /app/snell-server 2>/dev/null || echo "")
        if [ -n "$snell_binary" ]; then
            echo -e "   ${GREEN}✅ Бинарный файл Snell существует${RESET}"
            echo "$snell_binary" | sed 's/^/   /'
            
            # Попытка тестового запуска вручную
            echo -e "   ${CYAN}Тестирование бинарного файла Snell...${RESET}"
            local snell_test=$(docker exec "${CONTAINER_NAME}" timeout 3s /app/snell-server --help 2>&1 || echo "")
            if echo "$snell_test" | grep -q "usage\|help\|version"; then
                echo -e "   ${GREEN}✅ Бинарный файл Snell является исполняемым${RESET}"
            else
                echo -e "   ${RED}❌ Возможна проблема с бинарным файлом Snell${RESET}"
                echo "$snell_test" | sed 's/^/   /' | head -3
                
                # Проверка целостности бинарного файла
                echo -e "   ${CYAN}Проверка целостности бинарного файла...${RESET}"
                local file_info=$(docker exec "${CONTAINER_NAME}" file /app/snell-server 2>/dev/null || echo "")
                echo "   Информация о файле: $file_info"
                
                local file_size=$(docker exec "${CONTAINER_NAME}" stat -c%s /app/snell-server 2>/dev/null || echo "0")
                echo "   Размер файла: $file_size байт"
                
                if [ "$file_size" -lt 100000 ]; then
                    echo -e "   ${RED}❌ Ненормальный размер бинарного файла, возможно, он скачался не полностью${RESET}"
                fi
            fi
        else
            echo -e "   ${RED}❌ Бинарный файл Snell не существует${RESET}"
            echo -e "   ${YELLOW}Это означает, что сборка Docker-образа завершилась неудачей${RESET}"
            echo -e "   ${YELLOW}Требуется переустановка для пересборки образа${RESET}"
        fi
        
        # Проверка полных логов контейнера
        echo -e "   ${CYAN}Проверка полных логов контейнера...${RESET}"
        local full_logs=$(docker logs --tail 50 "${CONTAINER_NAME}" 2>&1)
        if [ -n "$full_logs" ]; then
            echo -e "   ${YELLOW}Последние логи (последние 10 строк):${RESET}"
            echo "$full_logs" | tail -10 | sed 's/^/   /'
            
            # Поиск конкретных ошибок
            local error_logs=$(echo "$full_logs" | grep -i "error\|failed\|refused\|cannot\|permission\|bind" || echo "")
            if [ -n "$error_logs" ]; then
                echo -e "   ${RED}Обнаружены ошибки в логах:${RESET}"
                echo "$error_logs" | sed 's/^/   /'
            fi
        else
            echo -e "   ${YELLOW}Вывод в логах отсутствует${RESET}"
        fi
        
        # Попытка восстановления
        local needs_fix=false
        if [ -z "$snell_process" ]; then
            needs_fix=true
        elif [ -z "$container_netstat" ]; then
            needs_fix=true
        fi
        
        if [ "$needs_fix" = "true" ]; then
            echo -e "   ${YELLOW}Попытка восстановления контейнера...${RESET}"
            echo -e "   ${CYAN}Перезапуск службы Snell внутри контейнера...${RESET}"
            
            # Очистка возможных зомби-процессов
            docker exec "${CONTAINER_NAME}" pkill -f snell 2>/dev/null || true
            docker exec "${CONTAINER_NAME}" pkill -f "sleep" 2>/dev/null || true
            sleep 2
            
            # Способ 1: попытка прямого запуска
            echo -e "   ${CYAN}Попытка прямого запуска службы Snell...${RESET}"
            if docker exec -d "${CONTAINER_NAME}" sh -c "cd /app && exec ./snell-server -c /etc/snell/snell-server.conf" 2>/dev/null; then
                sleep 5
                
                # Проверка успешности запуска
                local fixed_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
                local fixed_netstat=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
                
                if [ -n "$fixed_process" ] && [ -n "$fixed_netstat" ]; then
                    echo -e "   ${GREEN}✅ Служба Snell успешно восстановлена${RESET}"
                    echo "$fixed_process" | sed 's/^/   FIX: /'
                    echo "$fixed_netstat" | sed 's/^/   PORT: /'
                elif [ -n "$fixed_process" ]; then
                    echo -e "   ${YELLOW}⚠️  Процесс запущен, но порт всё ещё не прослушивается${RESET}"
                    echo "$fixed_process" | sed 's/^/   FIX: /'
                else
                    echo -e "   ${RED}❌ Ручной запуск не удался, рекомендуется пересоздать контейнер${RESET}"
                    
                    # Отображение ошибки запуска
                    echo -e "   ${CYAN}Проверка ошибок запуска...${RESET}"
                    local start_error=$(docker exec "${CONTAINER_NAME}" sh -c "cd /app && timeout 5s ./snell-server -c /etc/snell/snell-server.conf" 2>&1 || echo "")
                    if [ -n "$start_error" ]; then
                        echo "   Ошибка запуска: $start_error" | head -3
                    fi
                fi
            else
                echo -e "   ${RED}❌ Не удалось выполнить команду запуска${RESET}"
            fi
        fi
    fi
    echo ""
    
    # 6. Генерация клиентской конфигурации
    echo -e "${CYAN}6️⃣  Проверка конфигурации клиента...${RESET}"
    if [ -n "$server_ip" ]; then
        echo -e "   ${GREEN}Конфигурация Surge:${RESET}"
        if [ "$version_choice" = "v6" ]; then
            echo "   MySnell = snell, $server_ip, $port, psk=$psk, version=6, mode=$(get_snell_mode), reuse=true, tfo=true"
        elif [ "$version_choice" = "v5" ]; then
            echo "   MySnell_v4 = snell, $server_ip, $port, psk=$psk, version=4, reuse=true, tfo=true"
            echo "   MySnell_v5 = snell, $server_ip, $port, psk=$psk, version=5, reuse=true, tfo=true"
        else
            echo "   MySnell = snell, $server_ip, $port, psk=$psk, version=4, reuse=true, tfo=true"
        fi
        echo ""
        echo -e "   ${YELLOW}Убедитесь, что конфигурация на клиенте полностью совпадает с указанной выше${RESET}"
    fi
    echo ""
    
    # 7. Рекомендации и действия по автоматическому исправлению
    echo -e "${CYAN}🔧 Варианты автоматического исправления:${RESET}"
    echo -e "${YELLOW}Обнаруженные проблемы:${RESET}"
    
    local issues_found=0
    local port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
    local snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
    local container_listening=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
    
    if [ -z "$port_mapping" ]; then
        echo "   • Отсутствует проброс портов Docker"
        issues_found=$((issues_found + 1))
    fi
    
    if [ -z "$snell_process" ]; then
        echo "   • Процесс Snell не запущен"
        issues_found=$((issues_found + 1))
    elif echo "$snell_process" | grep -q "\[snell-server\]"; then
        echo "   • Процесс Snell может быть зомби-процессом"
        issues_found=$((issues_found + 1))
    fi
    
    if [ -z "$container_listening" ]; then
        echo "   • Порт внутри контейнера не прослушивается"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$issues_found" -gt 0 ]; then
        echo ""
        echo -e "${CYAN}Варианты исправления:${RESET}"
        echo -e "${YELLOW}1. Быстрое исправление (перезапуск контейнера):${RESET}"
        echo "   docker restart ${CONTAINER_NAME}"
        echo ""
        echo -e "${YELLOW}2. Пересоздание контейнера (рекомендуется):${RESET}"
        echo "   Выберите пункт 1 в главном меню скрипта для переустановки"
        echo ""
        echo -e "${YELLOW}3. Команды для ручного исправления:${RESET}"
        echo "   # Остановка и удаление текущего контейнера"
        echo "   docker stop ${CONTAINER_NAME}"
        echo "   docker rm ${CONTAINER_NAME}"
        echo ""
        echo "   # Повторное создание контейнера"
        echo "   docker run -d \\"
        echo "     --name ${CONTAINER_NAME} \\"
        echo "     --restart unless-stopped \\"
        echo "     -p ${port}:${port}/tcp \\"
        echo "     -p ${port}:${port}/udp \\"
        echo "     ${IMAGE_NAME}:latest"
        echo ""
        
        # Опция автоматического исправления в один клик
        echo -e "${GREEN}Выполнить автоматическое исправление? [y/N]:${RESET}"
        printf "   "
        read -r fix_choice
        if [ "$fix_choice" = "y" ] || [ "$fix_choice" = "Y" ]; then
            echo -e "${CYAN}Выполнение автоматического исправления...${RESET}"
            
            # Остановка и удаление контейнера
            docker stop "${CONTAINER_NAME}" 2>/dev/null || true
            docker rm "${CONTAINER_NAME}" 2>/dev/null || true
            
            # Повторное создание контейнера (конфигурация встроена в образ)
            if docker run -d \
                --name "${CONTAINER_NAME}" \
                --restart unless-stopped \
                -p "${port}:${port}/tcp" \
                -p "${port}:${port}/udp" \
                "${IMAGE_NAME}:latest" 2>/dev/null; then
                echo -e "   ${GREEN}✅ Контейнер успешно пересоздан${RESET}"
                sleep 8  # Даём больше времени на запуск
                
                # Проверка результатов исправления
                echo -e "   ${CYAN}Проверка результатов исправления...${RESET}"
                if container_running; then
                    local new_port_mapping=$(docker port "${CONTAINER_NAME}" 2>/dev/null)
                    if [ -n "$new_port_mapping" ]; then
                        echo -e "   ${GREEN}✅ Проброс портов восстановлен: $new_port_mapping${RESET}"
                        
                        # Ожидание запуска службы и проверка
                        sleep 5
                        local new_snell_process=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -v grep | grep snell || echo "")
                        local new_port_listen=$(docker exec "${CONTAINER_NAME}" netstat -tln 2>/dev/null | grep ":$port " || echo "")
                        
                        if [ -n "$new_snell_process" ] && [ -n "$new_port_listen" ]; then
                            echo -e "   ${GREEN}✅ Служба Snell запущена и прослушивает порт${RESET}"
                            echo "$new_snell_process" | sed 's/^/   PROCESS: /'
                            echo "$new_port_listen" | sed 's/^/   LISTEN: /'
                            echo -e "   ${GREEN}🎉 Исправление выполнено успешно! Проверьте подключение ещё раз${RESET}"
                        elif [ -n "$new_snell_process" ]; then
                            echo -e "   ${YELLOW}⚠️  Служба запущена, но порт не прослушивается${RESET}"
                            echo "$new_snell_process" | sed 's/^/   PROCESS: /'
                            echo -e "   ${YELLOW}Возможно, нужно подождать дольше или выполнить переустановку${RESET}"
                        else
                            echo -e "   ${YELLOW}⚠️  Контейнер запущен, но служба Snell, возможно, всё ещё запускается...${RESET}"
                            echo -e "   ${YELLOW}Подождите 10–20 секунд и запустите диагностику заново${RESET}"
                        fi
                    else
                        echo -e "   ${RED}❌ Проблема с пробросом портов сохраняется${RESET}"
                        echo -e "   ${YELLOW}Проверьте состояние контейнера:${RESET}"
                        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/   /'
                    fi
                else
                    echo -e "   ${RED}❌ Не удалось запустить контейнер${RESET}"
                    echo -e "   ${CYAN}Логи запуска контейнера:${RESET}"
                    docker logs --tail 10 "${CONTAINER_NAME}" 2>&1 | sed 's/^/   /'
                fi
            else
                echo -e "   ${RED}❌ Не удалось пересоздать контейнер${RESET}"
                echo -e "   ${YELLOW}Возможна проблема с образом, рекомендуется выбрать пункт 1 для переустановки${RESET}"
            fi
        fi
    else
        echo "   ${GREEN}✅ Явных проблем не обнаружено${RESET}"
        echo "   ${YELLOW}Если подключиться всё равно не удаётся, возможны ограничения файрвола на стороне VPS-провайдера${RESET}"
    fi
    echo ""
    
    echo -e "${CYAN}🔧 Решения частых проблем:${RESET}"
    echo -e "${CYAN}🔧 Общие решения:${RESET}"
    echo -e "${YELLOW}1. Файрвол VPS-провайдера:${RESET}"
    echo "   ▸ Войдите в панель управления VPS и откройте порт $port"
    echo "   ▸ В Alibaba Cloud / Tencent Cloud / AWS и др. необходимо открыть порт в группе безопасности (Security Group)"
    echo ""
    echo -e "${YELLOW}2. Ограничения интернет-провайдера:${RESET}"
    echo "   ▸ Некоторые порты могут блокироваться провайдером"
    echo "   ▸ Попробуйте сменить порт: docker stop snell-server && переустановите"
    echo ""
    echo -e "${YELLOW}3. Перезапуск контейнера:${RESET}"
    echo "   ▸ docker restart ${CONTAINER_NAME}"
    echo "   ▸ docker logs -f ${CONTAINER_NAME}"
    echo ""
    echo -e "${YELLOW}4. Повторное открытие порта:${RESET}"
    echo "   ▸ iptables -I INPUT -p tcp --dport $port -j ACCEPT"
    echo "   ▸ Проверьте, сохранены ли правила в /etc/iptables/rules.v4"
    echo ""
    echo -e "${CYAN}===========================================${RESET}"
    echo -e "${GREEN}✅ Диагностика завершена!${RESET}"
}

# --- Вспомогательные функции ---

configure_firewall() {
    echo -e "${CYAN}Настройка файрвола...${RESET}"
    # TCP и UDP (для UDP-пересылки в Snell нужен UDP); поддерживаются firewalld / ufw / iptables / nftables
    open_port "$SNELL_PORT"
    echo -e "${YELLOW}Убедитесь, что порт ${SNELL_PORT} также открыт в файрволе панели управления вашего VPS-провайдера${RESET}"
}

show_information() {
    if [ ! -f "/etc/snell-docker/snell-server.conf" ]; then
        echo -e "${RED}Файл конфигурации не найден.${RESET}"
        return
    fi
    
    local port=$(grep 'listen' /etc/snell-docker/snell-server.conf | sed 's/.*://')
    local psk=$(grep 'psk' /etc/snell-docker/snell-server.conf | sed 's/psk[[:space:]]*=[[:space:]]*//')
    local version_choice
    version_choice=$(grep 'version-choice' /etc/snell-docker/snell-server.conf 2>/dev/null | sed 's/version-choice[[:space:]]*=[[:space:]]*//')
    if [ -z "$version_choice" ]; then
        version_choice="v4"
        if docker images "${IMAGE_NAME}" --format '{{.Tag}}' 2>/dev/null | grep -q 'v6'; then
            version_choice="v6"
        elif docker images "${IMAGE_NAME}" --format '{{.Tag}}' 2>/dev/null | grep -q 'v5'; then
            version_choice="v5"
        fi
    fi
    
    # Получение IP-адресов сервера
    local ipv4_addr=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    local ipv6_addr=$(curl -s6 --connect-timeout 5 https://api64.ipify.org 2>/dev/null)
    
    clear
    echo -e "${BLUE}============================================${RESET}"
    echo -e "${GREEN}🐳 Информация о конфигурации Snell Docker:${RESET}"
    echo -e "${BLUE}============================================${RESET}"

    if [ -n "$ipv4_addr" ]; then
        local ip_country_ipv4=$(get_ip_country "${ipv4_addr}")
        echo -e "${GREEN}--- Конфигурация Surge IPv4 (Snell ${version_choice}) ---${RESET}"
        if [ "$version_choice" = "v6" ]; then
            echo -e "${GREEN}${ip_country_ipv4} = snell, ${ipv4_addr}, ${port}, psk=${psk}, version=6, mode=$(get_snell_mode), reuse=true, tfo=true${RESET}"
        elif [ "$version_choice" = "v5" ]; then
            echo -e "${GREEN}${ip_country_ipv4}_v4 = snell, ${ipv4_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
            echo -e "${GREEN}${ip_country_ipv4}_v5 = snell, ${ipv4_addr}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
        else
            echo -e "${GREEN}${ip_country_ipv4} = snell, ${ipv4_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
        fi
    fi

    if [ -n "$ipv6_addr" ]; then
        local ip_country_ipv6=$(get_ip_country "${ipv6_addr}")
        echo -e "\n${GREEN}--- Конфигурация Surge IPv6 (Snell ${version_choice}) ---${RESET}"
        if [ "$version_choice" = "v6" ]; then
            echo -e "${GREEN}${ip_country_ipv6} = snell, ${ipv6_addr}, ${port}, psk=${psk}, version=6, mode=$(get_snell_mode), reuse=true, tfo=true${RESET}"
        elif [ "$version_choice" = "v5" ]; then
            echo -e "${GREEN}${ip_country_ipv6}_v4 = snell, ${ipv6_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
            echo -e "${GREEN}${ip_country_ipv6}_v5 = snell, ${ipv6_addr}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true${RESET}"
        else
            echo -e "${GREEN}${ip_country_ipv6} = snell, ${ipv6_addr}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true${RESET}"
        fi
    fi

    echo ""
    echo -e "${YELLOW}Порт сервера: ${RESET}${port}"
    echo -e "${YELLOW}Ключ PSK: ${RESET}${psk}"
    echo -e "${YELLOW}Имя контейнера: ${RESET}${CONTAINER_NAME}"
    echo -e "${YELLOW}Имя образа: ${RESET}${IMAGE_NAME}:latest"
    echo -e "\n${YELLOW}Файл конфигурации: ${RESET}/etc/snell-docker/snell-server.conf"
    echo -e "\n${CYAN}Команды управления Docker:${RESET}"
    echo -e "Просмотр логов: ${YELLOW}docker logs ${CONTAINER_NAME}${RESET}"
    echo -e "Вход в контейнер: ${YELLOW}docker exec -it ${CONTAINER_NAME} sh${RESET}"
    echo -e "Перезапуск контейнера: ${YELLOW}docker restart ${CONTAINER_NAME}${RESET}"
    echo -e "${BLUE}============================================${RESET}"
}

# --- Главное меню ---

show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}   🐳 Скрипт управления Snell Docker v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # Проверка статуса контейнера
    if container_exists; then
        if container_running; then
            echo -e "Статус службы: ${GREEN}Работает 🟢${RESET}"
        else
            echo -e "Статус службы: ${RED}Остановлена 🔴${RESET}"
        fi
    else
        echo -e "Статус службы: ${YELLOW}Не установлена ⚪${RESET}"
    fi
    
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${GREEN}1.${RESET} 🚀 Установить Snell (Docker)"
    echo -e "${GREEN}2.${RESET} 🗑️  Удалить Snell"
    echo -e "${GREEN}3.${RESET} 🔄 Перезапустить службу"
    echo -e "${GREEN}4.${RESET} 📋 Просмотреть конфигурацию"
    echo -e "${GREEN}5.${RESET} 📊 Просмотреть подробный статус"
    echo -e "${GREEN}6.${RESET} Диагностика сетевого подключения"
    echo -e "${GREEN}7.${RESET} Частые команды Docker"
    echo -e "${GREEN}0.${RESET} 🚪 Выйти из скрипта"
    echo -e "${CYAN}============================================${RESET}"
    printf "Введите вариант [0-7]: "
    read -r num
}

show_docker_commands() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       🐳 Частые команды управления Docker${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}Просмотр статуса контейнера:${RESET}"
    echo "  docker ps -a --filter \"name=${CONTAINER_NAME}\""
    echo ""
    echo -e "${GREEN}Просмотр логов в реальном времени:${RESET}"
    echo "  docker logs -f ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}Вход в оболочку (shell) контейнера:${RESET}"
    echo "  docker exec -it ${CONTAINER_NAME} sh"
    echo ""
    echo -e "${GREEN}Мониторинг ресурсов контейнера:${RESET}"
    echo "  docker stats ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}Ручной перезапуск контейнера:${RESET}"
    echo "  docker restart ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}Ручная остановка/запуск:${RESET}"
    echo "  docker stop ${CONTAINER_NAME}"
    echo "  docker start ${CONTAINER_NAME}"
    echo ""
    echo -e "${GREEN}Просмотр образов:${RESET}"
    echo "  docker images | grep ${IMAGE_NAME}"
    echo ""
    echo -e "${GREEN}Проброс портов контейнера:${RESET}"
    echo "  docker port ${CONTAINER_NAME}"
    echo -e "${CYAN}============================================${RESET}"
    printf "${CYAN}Нажмите Enter для возврата в главное меню...${RESET}"
    read -r dummy
}

# --- Основная программа ---

main() {
    while true; do
        show_menu
        case "$num" in
            1) install_snell ;;
            2) uninstall_snell ;;
            3) restart_snell ;;
            4) show_information ;;
            5) check_status ;;
            6) network_diagnosis ;;
            7) show_docker_commands ;;
            0) echo -e "${GREEN}Спасибо за использование, до свидания! 🎉${RESET}"; exit 0 ;;
            *) echo -e "${RED}Пожалуйста, введите корректный вариант [0-7]${RESET}";;
        esac
        if [ "$num" != "7" ]; then
            echo ""
            printf "${CYAN}Нажмите Enter для возврата в главное меню...${RESET}"
            read -r dummy
        fi
    done
}

# Запуск основной программы
main
