#!/bin/bash
# Этот файл сгенерирован скриптом tools/build.sh из src/snell.sh и src/lib: вносите изменения в файлы внутри src/ и пересобирайте.
# =========================================
# Автор: jinqians
# Дата: Февраль 2025 г.
# Сайт: jinqians.com
# Описание: Скрипт для установки, удаления, просмотра и обновления прокси Snell
#           Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux / Fedora (systemd)
# =========================================

# Общая часть (src/lib). Публикуемый snell.sh — это единый файл, собранный через tools/build.sh,
# а при прямом запуске src/snell.sh библиотеки читаются из соседнего каталога lib.
# ── lib/common.sh ─────────────────────────────────────────────────────────────
# Общее для всех скриптов: цвета, проверка root, определение ОС и пакетного менеджера, URL публикации.
# Используется только синтаксис POSIX sh: версии для Alpine / Docker должны работать в ash и dash.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Адреса публикации скриптов. Короткие домены (*.jinqians.com) перенаправляются через Cloudflare на файлы в репозитории:
# snell / snell-centos / snell-alpine → корень репозитория, menu / snell-docker / install → scripts/.
# Дочерние скрипты, вызываемые из меню, берутся из scripts/ и docker/ по адресу SNELL_RAW_BASE.
# Обновление самого скрипта и команды управления идут через короткие домены для учета статистики запусков.
# Можно переопределить одноименными переменными окружения для использования зеркала (или локальных файлов при тестах).
SNELL_RAW_BASE="${SNELL_RAW_BASE:-https://raw.githubusercontent.com/jinqians/snell/main}"
SNELL_SCRIPT_URL="${SNELL_SCRIPT_URL:-https://raw.githubusercontent.com/ZSVPD/snell-script/main/install.sh}"                     # snell.sh (Debian / Ubuntu / CentOS / RHEL)
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
        # Читаем в подоболочке, чтобы переменные NAME / VERSION из os-release не перезаписали переменные скрипта
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

# Установка пакетов через системный пакетный менеджер
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
            printf '%b\n' "${RED}Неизвестный пакетный менеджер, установите вручную: $*${RESET}"
            return 1
            ;;
    esac
}

# Получение имени пакета для конкретной команды (здесь сопоставляются различия между дистрибутивами)
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

# Установка недостающих команд; при неудаче возвращает не 0, решение о выходе принимает вызывающая сторона
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
            printf '%b\n' "${RED}После установки команда ${_ec_cmd} всё ещё не найдена. Установите вручную: $(pkg_for_cmd "$_ec_cmd")${RESET}"
            return 1
        fi
    done
}

# Скачивание удаленного скрипта с проверкой целостности: остановка при ошибке передачи, проверка на пустоту и проверка синтаксиса.
# Гарантирует только целостность передачи; от подмены самого репозитория должна защищать подпись релиза.
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
    # bash может парсить синтаксис sh; в системах без bash (Alpine) проверяем через sh
    if command -v bash >/dev/null 2>&1; then
        _fv_shell=bash
    else
        _fv_shell=sh
    fi
    if ! "$_fv_shell" -n "$2" 2>/dev/null; then
        printf '%b\n' "${RED}Скачанный скрипт не прошел проверку синтаксиса и был отброшен: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    return 0
}

# ── lib/release.sh ────────────────────────────────────────────────────────────
# Официальные версии Snell: получение последних номеров основных версий со страницы релизов и генерация ссылок для скачивания. POSIX sh.

# Резервные номера версий на случай ошибки парсинга или отсутствия ссылки на основную версию на странице релизов.
# После выхода релиза v6.0.0 со страницы убрали ссылки на скачивание v5 (оставив только описание изменений), поэтому v5 теперь опирается только на здешний v5.0.1
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

# Преобразование номера версии в ключ фиксированной длины для сортировки. Приоритет: beta < rc < релиз
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

# Выбор последней версии для указанной основной ветки со страницы релизов (порядок на странице не гарантирует новизну, нужна сортировка)
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

# Генерация ссылки на скачивание для указанной ветки и версии; при неподдерживаемой архитектуре возвращает не 0 (без exit, чтобы вызывающий код мог продолжить)
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
# Внешний IP-адрес сервера и страна расположения (используется при генерации клиентских конфигов). POSIX sh.

# Внешний IPv4 / IPv6 этого сервера (пусто, если не удалось получить)
get_public_ipv4() { curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null; }
get_public_ipv6() { curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null; }

# Запрос кода страны для IP (с перебором нескольких API во избежание ошибок при лимитах запросов на одном сервисе)
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
# Открытие / закрытие портов: firewalld, ufw, iptables + ip6tables, nftables — настраивается то, что используется в системе,
# с сохранением правил. Единая реализация для всех скриптов (раньше в каждом скрипте была своя: только версия для CentOS знала про firewalld,
# версия для Docker открывала только TCP, а повторная установка плодила дубликаты правил). POSIX sh.

# firewalld запущен
_fw_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

# ufw включен (-w: чтобы не принять "inactive" за "active")
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

# iptables / ip6tables: добавляем правило только если такого еще нет
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

# Сохранение правил nftables (при наличии конфигурационного файла для автозагрузки)
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

# Цепочки фильтрации в nftables, привязанные к хуку input (по одной записи "семейство таблица цепочка" на строку).
# Собственные таблицы ip/ip6 filter от iptables-nft уже обработаны через iptables, пропускаем их во избежание дублирования.
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

# Разрешение порта в существующих цепочках input в nftables (ничего не делает, если файрвол nftables не используется)
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

# Удаление правил, разрешающих указанный порт в nftables
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

# Открытие порта: если запущен firewalld — поручаем только ему; если включен ufw — только ему; иначе настраиваем iptables и nftables
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
    # Если ufw установлен, но не включен, всё равно добавляем правило: при будущем включении ufw порт останется открытым
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

# Закрытие порта: удаляем разрешающие правила из всех файрволов
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

# Проверка, разрешен ли порт в текущем файрволе (для тестов и отображения статуса): достаточно разрешения в любом из firewalld / ufw / iptables / nftables
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
# Структура установки systemd и сосуществование нескольких версий (v4 / v5 / v6).
# Общее для snell.sh, multi-user.sh, shadowtls.sh (bash).
#
# Расположение бинарных файлов:
#   ${INSTALL_DIR}/snell-server-v4|v5|v6   Реальные файлы для каждой ветки, юнит systemd указывает напрямую на них
#   ${INSTALL_DIR}/snell-server            Символическая ссылка, указывающая на ветку основного пользователя (сохранена для старой логики определения)
#
# Метка версии:
#   В первой строке каждого пользовательского конфига пишется "#version-choice = vX". Это комментарий, snell-server его игнорирует,
#   при этом метка сохраняется и восстанавливается вместе с .conf без необходимости в дополнительных сопутствующих файлах. Конфиги от PSM также содержат эту метку.

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

# Старые пути к файлам конфигурации (для проверки обратной совместимости)
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
        # В ранних версиях v4 вывод --v не содержал основного номера версии; для совместимости считаем это v4
        echo "v4"
    fi
}

# Список установленных на диск веток (через пробел, может быть пустым)
list_installed_snell_versions() {
    local version installed=""
    for version in $SNELL_ALL_VERSIONS; do
        if [ -x "$(snell_binary_for_version "$version")" ]; then
            installed="${installed}${version} "
        fi
    done
    echo "${installed% }"
}

# Чтение метки версии из конфига; если метки нет — возвращает не 0
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

# Определение ветки для конфига: приоритет отдается метке, при отсутствии — возврат к реальной версии по симлинку (совместимость со старыми установками до миграции)
get_conf_snell_version() {
    local conf_file="$1"
    local marked
    if marked=$(read_conf_snell_version "$conf_file"); then
        echo "$marked"
        return 0
    fi
    detect_installed_snell_version
}

# Идемпотентная запись метки версии: если совпадает — пропуск, если отличается — замена, если отсутствует — вставка в первую строку.
# Используется перезапись через cat вместо mv для сохранения владельца и прав доступа (служба читает файл от имени пользователя snell)
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
        echo -e "${RED}Не удалось сгенерировать метку версии: ${conf_file}${RESET}" >&2
        return 1
    fi

    if ! cat "$tmp_conf" > "$conf_file"; then
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось записать метку версии: ${conf_file}${RESET}" >&2
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

# Порт -> путь к файлу конфигурации (основной порт использует основной конфиг)
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

# Какие службы сейчас используют указанную ветку (по одному имени службы systemd на строку)
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

# Направление симлинка snell-server на указанную ветку (старая логика определения и ShadowTLS всё ещё зависят от этого имени)
update_snell_symlink() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    # Если целевой файл не существует — ничего не трогаем, чтобы не удалить рабочий старый бинарник и не оставить битую ссылку
    if [ ! -x "$target" ]; then
        return 1
    fi

    if [ -e "${INSTALL_DIR}/snell-server" ] && [ ! -L "${INSTALL_DIR}/snell-server" ]; then
        rm -f "${INSTALL_DIR}/snell-server"
    fi
    ln -sfn "$target" "${INSTALL_DIR}/snell-server"
}

# Скачивание официального архива и распаковка в <каталог>/snell-server. Прогресс выводится только в stderr
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

    # Проверка целостности архива (разработчики не публикуют хеши, поэтому возможна только проверка целостности передачи)
    if ! unzip -t -q "${dir}/snell-server.zip" >/dev/null 2>&1; then
        echo -e "${RED}Скачанный архив поврежден и был отброшен: ${url}${RESET}" >&2
        return 1
    fi

    if ! unzip -o -q "${dir}/snell-server.zip" -d "$dir"; then
        echo -e "${RED}Ошибка распаковки Snell ${version}${RESET}" >&2
        return 1
    fi

    if [ ! -f "${dir}/snell-server" ]; then
        echo -e "${RED}В архиве не найден исполняемый файл snell-server${RESET}" >&2
        return 1
    fi
}

# Проверка, совпадает ли локальный бинарник этой ветки с текущей официальной сборкой <версия>.
# Простого сравнения номеров версий недостаточно: релиз-кандидат (rc) для v6 тоже сообщает версию v6.0.0, и после выхода финального релиза казалось бы, что «уже установлена последняя версия».
# Возвращает 0: отличаются, стоит обновить; 1: совпадают; 2: не удалось скачать официальную сборку, сравнить невозможно
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

# Скачивание бинарного файла указанной ветки по версионированному пути. При force=true скачивает заново даже при наличии файла.
# Прогресс выводится только в stderr, stdout остается для вызывающей стороны.
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

    # install выполняет атомарную замену: запущенные старые процессы удерживают старый inode и не затрагиваются
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
        echo -e "${YELLOW}Внимание: ${target} сообщает версию ${actual}, что не совпадает с ожидаемой ${version}${RESET}" >&2
    fi

    echo -e "${GREEN}✓ Snell ${version} (${resolved}) установлен: ${target}${RESET}" >&2
    return 0
}

# Гарантирует доступность указанной ветки; при отсутствии скачивает автоматически
ensure_snell_binary() {
    install_snell_binary_for_version "$1" "false"
}

# Путь к бинарному файлу для основной службы (при отсутствии метки или бинарника возвращается к симлинку)
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

# Переключение ExecStart в юните с обычного snell-server на версионированный бинарник.
# Уже переключенные пути пропускаются (шаблон содержит пробел в конце и не заденет snell-server-v5), поэтому функцию можно вызывать повторно.
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
        echo -e "${GREEN}✓ Службы systemd переключены на версионированные пути к бинарным файлам${RESET}"
    fi
}

# Направление ExecStart юнита на бинарный файл целевой ветки (используется при смене версии пользователя)
point_service_unit_to_version() {
    local unit="$1"
    local version="$2"
    local target
    target=$(snell_binary_for_version "$version")

    [ -f "$unit" ] || return 1
    [ -x "$target" ] || return 1

    sed -i -E "s|ExecStart=${INSTALL_DIR}/snell-server(-v[456])? |ExecStart=${target} |" "$unit"
}

# Миграция со старой структуры (единый физический файл /usr/local/bin/snell-server) на раздельное хранение по веткам.
# Идемпотентно: если это уже симлинк и все конфиги размечены, ничего не делает.
migrate_snell_binary_layout() {
    local snell_bin="${INSTALL_DIR}/snell-server"
    local main_version=""

    if [ -e "$snell_bin" ] && [ ! -L "$snell_bin" ]; then
        local detected versioned
        detected=$(probe_snell_binary_version "$snell_bin")
        if [ "$detected" = "unknown" ]; then
            echo -e "${YELLOW}Не удалось определить версию ${snell_bin}, пропуск миграции структуры бинарных файлов${RESET}"
            return 1
        fi

        versioned=$(snell_binary_for_version "$detected")
        echo -e "${CYAN}Обнаружена старая одноверсионная структура, выполняется миграция на мультиверсионную...${RESET}"
        if [ ! -e "$versioned" ]; then
            if ! cp -a "$snell_bin" "$versioned"; then
                echo -e "${RED}Не удалось скопировать бинарный файл в ${versioned}, сохранена прежняя структура${RESET}"
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

    # Добавляем метки версий в конфиги, где их еще нет (в старых установках все пользователи гарантированно были одной версии)
    if [ -n "$main_version" ] && [ -d "${SNELL_CONF_DIR}/users" ]; then
        local conf_file
        for conf_file in "${SNELL_CONF_DIR}/users"/*.conf; do
            [ -f "$conf_file" ] || continue
            if read_conf_snell_version "$conf_file" >/dev/null 2>&1; then
                continue
            fi
            if set_conf_snell_version "$conf_file" "$main_version"; then
                echo -e "${GREEN}✓ Для $(basename "$conf_file") добавлена метка версии ${main_version}${RESET}"
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
    # Проверяем существование каталога пользовательских конфигураций
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
# Чтение точного номера версии, который сообщает бинарник ветки (например, v5.0.1)
get_channel_binary_version() {
    local version="$1"
    local binary
    binary=$(snell_binary_for_version "$version")
    [ -x "$binary" ] || return 1

    local detail
    detail=$("$binary" --v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9]*' | head -n 1)
    if [ -z "$detail" ]; then
        # Ранние сборки v4 не выводили номер версии по флагу --v, используем встроенную константу как резерв
        case "$version" in
            v4) detail="$SNELL_V4_FALLBACK" ;;
            v5) detail="$SNELL_V5_FALLBACK" ;;
            v6) detail="$SNELL_V6_FALLBACK" ;;
        esac
    fi
    echo "$detail"
}

# Перезапуск службы с проверкой, что она действительно запустилась; при сбое выводит конец журнала, чтобы пользователю не пришлось искать вручную
restart_and_verify_service() {
    local service="$1"
    local waited=0

    if ! systemctl restart "$service" 2>/dev/null; then
        echo -e "${RED}Команда systemctl restart ${service} завершилась ошибкой${RESET}"
        journalctl -u "$service" -n 30 --no-pager 2>/dev/null | sed 's/^/   /'
        return 1
    fi

    while [ "$waited" -lt 10 ]; do
        if systemctl is-active --quiet "$service"; then
            return 0
        fi
        # При активации через сокет основная служба поднимается по требованию; если сокет активен — считаем, что всё в порядке
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

# Запись пользовательского юнита systemd; ExecStart указывает на бинарный файл выбранной пользователем ветки
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
# Их нельзя класть в users/ — многие циклы перебирают users/*, и резервные файлы были бы приняты за реальных пользователей.
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


# ── lib/conf.sh ───────────────────────────────────────────────────────────────
# Пользовательская конфигурация: выбор версии и параметров v6, запись и миграция конфигов, ввод порта / DNS / IPv6, строки конфигурации Surge.
# Общее для snell.sh и multi-user.sh (bash).

# Глобальная переменная: выбранная версия Snell
SNELL_VERSION_CHOICE=""

# Режим шифрования Snell v6: default / unshaped / unsafe-raw (на клиенте должен совпадать с сервером)
SNELL_MODE="default"

# Приоритет семейства адресов при DNS-резолвинге в Snell v6: default / prefer-ipv4 / prefer-ipv6 / ipv4-only / ipv6-only
# Если пусто — определяется автоматически на основе переключателя IPv6
SNELL_DNS_IP_PREFERENCE=""

# Флаг, указывающий, выбирал ли пользователь параметры v6 явно в текущей операции (влияет на перезапись существующего конфига при обновлении)
SNELL_V6_OPTIONS_SET="false"

IPV6_ENABLE="true"

# Длина PSK в Snell v6 должна быть от 12 до 255 байт, иначе snell-server откажется запускаться
SNELL_V6_PSK_MIN=12
SNELL_V6_PSK_MAX=255

# Однократное напоминание при выборе v6
snell_v6_notes() {
    echo -e "${YELLOW}v6 принимает только клиентов с version = 6 (клиенты v4 / v5 подключиться не смогут), параметр mode на клиенте также должен совпадать с серверным${RESET}"
    echo -e "${YELLOW}В v6 удалены режим проксирования QUIC и obfs, а также не предоставляются сборки под armv7l${RESET}"
}

# Проверка, подходит ли PSK из конфига для v6; если нет — выводит причину и возвращает 1
check_conf_psk_for_v6() {   # <conf>
    local psk len
    psk=$(grep -E '^[[:space:]]*psk[[:space:]]*=' "$1" 2>/dev/null | head -n 1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    len=$(printf '%s' "$psk" | LC_ALL=C wc -c | tr -d ' ')
    if [ "$len" -ge "$SNELL_V6_PSK_MIN" ] && [ "$len" -le "$SNELL_V6_PSK_MAX" ]; then
        return 0
    fi
    echo -e "${RED}Длина PSK этого пользователя составляет ${len} байт. Snell v6 требует от ${SNELL_V6_PSK_MIN} до ${SNELL_V6_PSK_MAX} байт, иначе служба не запустится${RESET}"
    echo -e "${YELLOW}Сначала смените ему PSK (в главном меню «Изменить порт / PSK / DNS», нажатие Enter сгенерирует случайные 20 символов), а затем переключайте на v6${RESET}"
    return 1
}

# Замена порта со <старого> на <новый> для каждого адреса в параметре listen.
# В v6 параметр listen может содержать несколько адресов через запятую (listen = 0.0.0.0:7177,[::]:7177); замена только последнего приведет к рассинхронизации портов
listen_replace_port() {   # <значение listen> <старый порт> <новый порт>
    printf '%s\n' "$1" | awk -v o="$2" -v n="$3" 'BEGIN { FS = OFS = "," }
        { for (i = 1; i <= NF; i++) sub(":" o "[[:space:]]*$", ":" n, $i); print }'
}

# === Добавлено: функция выбора версии ===
# Выбор версии Snell
select_snell_version() {
    echo -e "${CYAN}Выберите версию Snell для установки:${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6"

    while true; do
        read -rp "Введите вариант [1-3]: " version_choice
        case "$version_choice" in
            1)
                SNELL_VERSION_CHOICE="v4"
                echo -e "${GREEN}Выбран Snell v4${RESET}"
                break
                ;;
            2)
                SNELL_VERSION_CHOICE="v5"
                echo -e "${GREEN}Выбран Snell v5${RESET}"
                break
                ;;
            3)
                SNELL_VERSION_CHOICE="v6"
                echo -e "${GREEN}Выбран Snell v6${RESET}"
                snell_v6_notes
                break
                ;;
            *)
                echo -e "${RED}Пожалуйста, введите корректный вариант [1-3]${RESET}"
                ;;
        esac
    done
}

# === Выбор параметров Snell v6 ===
# Режим шифрования (mode): на клиенте должно быть указано точно такое же значение, иначе подключение невозможно
select_snell_v6_mode() {
    local current="$1"
    local default_choice="1"
    case "$current" in
        unshaped)   default_choice="2" ;;
        unsafe-raw) default_choice="3" ;;
    esac

    echo -e "\n${CYAN}=== Режим шифрования Snell v6 (mode) ===${RESET}"
    echo -e "${YELLOW}На клиенте должен быть настроен точно такой же mode, как и на сервере, иначе подключение не сработает${RESET}\n"
    echo -e "${GREEN}1.${RESET} default     Обфускация трафика + шифрование AES"
    echo -e "   Максимальная маскировка сигнатур, наилучшая устойчивость к DPI и блокировкам"
    echo -e "   ${CYAN}Рекомендация: выбирайте этот вариант в большинстве случаев, при наличии помех или QoS на линии${RESET}"
    echo -e "${GREEN}2.${RESET} unshaped    Без обфускации, только шифрование AES"
    echo -e "   Пропускная способность примерно на 10% выше, чем у default, но сигнатуры трафика заметнее"
    echo -e "   ${CYAN}Рекомендация: для чистых каналов с приоритетом скорости, либо при использовании внешней маскировки (например, ShadowTLS)${RESET}"
    echo -e "${GREEN}3.${RESET} unsafe-raw  Передача открытым текстом, без шифрования и обфускации"
    echo -e "   ${RED}Данные могут быть полностью перехвачены, ни в коем случае не используйте в публичных сетях${RESET}"
    echo -e "   ${CYAN}Рекомендация: только для тестирования производительности в локальной сети или полностью доверенных каналах${RESET}\n"

    while true; do
        read -rp "Выберите режим шифрования [1-3] (Enter для выбора ${default_choice}): " mode_choice
        [ -z "$mode_choice" ] && mode_choice="$default_choice"
        case "$mode_choice" in
            1) SNELL_MODE="default";    break ;;
            2) SNELL_MODE="unshaped";   break ;;
            3)
                SNELL_MODE="unsafe-raw"
                echo -e "${RED}Внимание: unsafe-raw передает данные открытым текстом. Убедитесь, что канал полностью доверенный!${RESET}"
                read -rp "Подтверждаете использование unsafe-raw? [y/N]: " raw_confirm
                case "$raw_confirm" in
                    [yY]|[yY][eE][sS]) break ;;
                    *) echo -e "${CYAN}Отменено, выберите заново${RESET}" ;;
                esac
                ;;
            *) echo -e "${RED}Пожалуйста, введите корректный вариант [1-3]${RESET}" ;;
        esac
    done
    echo -e "${GREEN}Выбран mode = ${SNELL_MODE}${RESET}"
}

# Приоритет семейства адресов при DNS-резолвинге (dns-ip-preference): влияет на то, какой адрес сервер использует для исходящих подключений после разрешения целевого домена
select_snell_v6_dns_preference() {
    local current="$1"
    local default_choice="1"

    # Если не указано, выводим значение по умолчанию на основе переключателя IPv6
    if [ -z "$current" ]; then
        [ "$IPV6_ENABLE" = "false" ] && default_choice="4"
    else
        case "$current" in
            default)     default_choice="1" ;;
            prefer-ipv4) default_choice="2" ;;
            prefer-ipv6) default_choice="3" ;;
            ipv4-only)   default_choice="4" ;;
            ipv6-only)   default_choice="5" ;;
        esac
    fi

    echo -e "\n${CYAN}=== Приоритет DNS-резолвинга Snell v6 (dns-ip-preference) ===${RESET}"
    echo -e "${YELLOW}Управляет тем, какое семейство адресов сервер предпочитает для исходящих соединений после разрешения домена (не зависит от адреса прослушивания)${RESET}\n"
    echo -e "${GREEN}1.${RESET} default       Следовать системному поведению по умолчанию"
    echo -e "   ${CYAN}Рекомендация: выбирайте, если не уверены — подходит для большинства VPS${RESET}"
    echo -e "${GREEN}2.${RESET} prefer-ipv4   При наличии обоих стеков предпочитать IPv4, при неудаче пробовать IPv6"
    echo -e "   ${CYAN}Рекомендация: если качество исходящего IPv6 хуже или целевые сайты плохо работают по IPv6${RESET}"
    echo -e "${GREEN}3.${RESET} prefer-ipv6   При наличии обоих стеков предпочитать IPv6, при неудаче пробовать IPv4"
    echo -e "   ${CYAN}Рекомендация: если маршрут IPv6 лучше или требуется разблокировка стримингов через IPv6${RESET}"
    echo -e "${GREEN}4.${RESET} ipv4-only     Использовать только результаты разрешения IPv4"
    echo -e "   ${CYAN}Рекомендация: если на VPS нет исходящего IPv6 (позволяет избежать таймаутов при подключении к IPv6-целям)${RESET}"
    echo -e "${GREEN}5.${RESET} ipv6-only     Использовать только результаты разрешения IPv6"
    echo -e "   ${CYAN}Рекомендация: для IPv6-Only VPS (без исходящего IPv4)${RESET}\n"

    while true; do
        read -rp "Выберите приоритет DNS-резолвинга [1-5] (Enter для выбора ${default_choice}): " dns_pref_choice
        [ -z "$dns_pref_choice" ] && dns_pref_choice="$default_choice"
        case "$dns_pref_choice" in
            1) SNELL_DNS_IP_PREFERENCE="default";     break ;;
            2) SNELL_DNS_IP_PREFERENCE="prefer-ipv4"; break ;;
            3) SNELL_DNS_IP_PREFERENCE="prefer-ipv6"; break ;;
            4) SNELL_DNS_IP_PREFERENCE="ipv4-only";   break ;;
            5) SNELL_DNS_IP_PREFERENCE="ipv6-only";   break ;;
            *) echo -e "${RED}Пожалуйста, введите корректный вариант [1-5]${RESET}" ;;
        esac
    done
    echo -e "${GREEN}Выбран dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}${RESET}"
}

# Единая точка входа: вызывается при установке v6 или обновлении до v6; можно передать существующий файл конфигурации для сохранения текущих значений
configure_snell_v6_options() {
    local conf_file="$1"
    local current_mode="" current_pref=""

    if [ -n "$conf_file" ] && [ -f "$conf_file" ]; then
        current_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
        current_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
        if [ -n "$current_mode" ] || [ -n "$current_pref" ]; then
            echo -e "${CYAN}Обнаружена текущая конфигурация: mode = ${current_mode:-не задано}, dns-ip-preference = ${current_pref:-не задано}${RESET}"
        fi
    fi

    select_snell_v6_mode "$current_mode"
    select_snell_v6_dns_preference "$current_pref"
    SNELL_V6_OPTIONS_SET="true"

    echo -e "\n${CYAN}=== Подтверждение параметров v6 ===${RESET}"
    echo -e "${GREEN}Серверный mode              : ${SNELL_MODE}${RESET}"
    echo -e "${GREEN}Серверный dns-ip-preference : ${SNELL_DNS_IP_PREFERENCE}${RESET}"
    echo -e "${YELLOW}Соответствующая настройка клиента: version = 6, mode = ${SNELL_MODE}${RESET}"
}

# Чтение используемого параметра mode установленного сервера v6 (при неудаче возвращает значение по умолчанию)
get_snell_mode() {
    local conf_file="${1:-${SNELL_CONF_DIR}/users/snell-main.conf}"
    local mode=""
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [ -z "$mode" ]; then
        mode="$SNELL_MODE"
    fi
    echo "$mode"
}

# Генерация файла конфигурации snell-server
# В v6 используются mode / dns-ip-preference; параметр ipv6 в v6 устарел (false эквивалентно ipv4-only)
write_snell_conf() {
    local conf_file="$1"
    local listen_addr="$2"
    local port="$3"
    local psk="$4"
    local ipv6_enable="$5"
    local dns="$6"
    local version_choice="$7"

    {
        case "$version_choice" in
            v4|v5|v6) echo "#${SNELL_VERSION_MARKER_KEY} = ${version_choice}" ;;
        esac
        echo "[snell-server]"
        echo "listen = ${listen_addr}:${port}"
        echo "psk = ${psk}"
        if [ "$version_choice" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            if [ -n "$SNELL_DNS_IP_PREFERENCE" ]; then
                echo "dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}"
            elif [ "$ipv6_enable" = "false" ]; then
                echo "dns-ip-preference = ipv4-only"
            else
                echo "dns-ip-preference = default"
            fi
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
        echo "dns = ${dns}"
    } > "$conf_file"

    # PSK — это общий секретный ключ: чтение и запись только для владельца, чтобы другие локальные пользователи не могли его прочитать
    chmod 600 "$conf_file" 2>/dev/null || true
    if getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$conf_file" 2>/dev/null || true
    fi
}

# Синхронизация параметров файла конфигурации после смены версии: v6 использует mode / dns-ip-preference, v4/v5 используют ipv6
migrate_snell_conf_for_version() {
    local conf_file="$1"
    local version_choice="$2"
    [ -f "$conf_file" ] || return 0

    local ipv6_enable="true"
    if grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$conf_file" \
        || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$conf_file"; then
        ipv6_enable="false"
    fi

    # Сохраняем существующие параметры v6 из конфига; перезаписываем только если пользователь явно выбирал их в этот раз
    local target_mode target_pref
    target_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    target_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')

    if [ "$SNELL_V6_OPTIONS_SET" = "true" ]; then
        target_mode="$SNELL_MODE"
        target_pref="$SNELL_DNS_IP_PREFERENCE"
    fi

    [ -z "$target_mode" ] && target_mode="$SNELL_MODE"
    if [ -z "$target_pref" ]; then
        if [ "$ipv6_enable" = "false" ]; then
            target_pref="ipv4-only"
        else
            target_pref="default"
        fi
    fi

    local tmp_conf="${conf_file}.tmp"
    {
        grep -Ev '^[[:space:]]*(ipv6|mode|dns-ip-preference)[[:space:]]*=' "$conf_file"
        if [ "$version_choice" = "v6" ]; then
            echo "mode = ${target_mode}"
            echo "dns-ip-preference = ${target_pref}"
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
    } > "$tmp_conf" || {
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось сгенерировать конфигурацию: ${conf_file}${RESET}" >&2
        return 1
    }

    # Перезапись через cat сохраняет владельца и права исходного файла (служба читает его от имени пользователя snell)
    cat "$tmp_conf" > "$conf_file" || {
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось записать конфигурацию: ${conf_file}${RESET}" >&2
        return 1
    }
    rm -f "$tmp_conf"

    # Принадлежность к ветке обновляется соответственно, дальнейшая работа опирается на эту метку
    set_conf_snell_version "$conf_file" "$version_choice"
}

# Генерация строки конфигурации в формате Surge
generate_surge_config() {
    local ip_addr=$1
    local port=$2
    local psk=$3
    local version=$4
    local country=$5
    local installed_version=$6

    if [ "$installed_version" = "v6" ]; then
        # Версия v6: протокол v6 (удалены режим QUIC и obfs), mode должен совпадать с серверным
        local mode
        mode=$(get_snell_mode "$(snell_conf_for_port "$port")")
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 6, mode = ${mode}, reuse = true, tfo = true${RESET}"
    elif [ "$installed_version" = "v5" ]; then
        # Для версии v5 выводим оба варианта конфигурации: v4 и v5
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        # Для версии v4 выводим только конфигурацию v4
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# Сравнение номеров версий (использует snell_version_sort_key, корректно обрабатывает b4 / rc / rc2 / релиз)
version_greater_equal() {
    local key1 key2
    key1=$(snell_version_sort_key "$1")
    key2=$(snell_version_sort_key "$2")

    [[ "$key1" > "$key2" || "$key1" == "$key2" ]]
}

# Ввод номера порта пользователем, диапазон 1-65535
get_user_port() {
    while true; do
        read -rp "Введите желаемый номер порта (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            if is_port_in_use "$PORT"; then
                echo -e "${YELLOW}Внимание: порт ${PORT} сейчас занят${RESET}"
                show_port_occupier "$PORT"
                read -rp "Всё равно использовать этот порт? [y/N]: " port_confirm
                case "$port_confirm" in
                    [yY]|[yY][eE][sS]) ;;
                    *)
                        echo -e "${CYAN}Пожалуйста, выберите другой порт${RESET}"
                        continue
                        ;;
                esac
            fi
            echo -e "${GREEN}Выбран порт: $PORT${RESET}"
            break
        else
            echo -e "${RED}Некорректный номер порта. Введите число от 1 до 65535.${RESET}"
        fi
    done
}

# Получение системных DNS
get_system_dns() {
    # Пытаемся получить системные DNS из resolv.conf
    if [ -f "/etc/resolv.conf" ]; then
        system_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        if [ ! -z "$system_dns" ]; then
            echo "$system_dns"
            return 0
        fi
    fi
    
    # Если не удалось получить из resolv.conf, используем публичные DNS
    echo "1.1.1.1,8.8.8.8"
}

# Получение DNS-серверов от пользователя
# Проверка одного узла DNS: IPv4 / IPv6 / доменное имя
validate_dns_host() {
    local host="$1"
    # IPv4: четыре группы цифр, каждая от 0 до 255
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local seg old_ifs="$IFS"
        IFS='.'
        for seg in $host; do
            if [ "$seg" -gt 255 ] 2>/dev/null; then
                IFS="$old_ifs"
                return 1
            fi
        done
        IFS="$old_ifs"
        return 0
    fi
    # IPv6: шестнадцатеричные группы с двоеточиями (мягкая проверка, на стороне snell будет дополнительный парсинг)
    if [[ "$host" == *:* ]] && [[ "$host" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        return 0
    fi
    # Доменное имя: буквы, цифры, точки и дефисы, не начинается и не заканчивается точкой/дефисом
    if [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
        return 0
    fi
    return 1
}

# Проверка ввода DNS: допускается несколько адресов, разделенных запятой
validate_dns_input() {
    local dns_input="$1" item
    dns_input="${dns_input//[[:space:]]/}"
    [ -n "$dns_input" ] || return 1
    local old_ifs="$IFS"
    IFS=','
    for item in $dns_input; do
        if ! validate_dns_host "$item"; then
            IFS="$old_ifs"
            return 1
        fi
    done
    IFS="$old_ifs"
    return 0
}

# Получение DNS-серверов от пользователя (проверка IPv4/IPv6/домена, при некорректном вводе запрашивает повторно)
get_dns() {
    while true; do
        read -rp "Введите адреса DNS-серверов (нажмите Enter для использования системных DNS): " custom_dns
        if [ -z "$custom_dns" ]; then
            DNS=$(get_system_dns)
            echo -e "${GREEN}Используются системные DNS-серверы: $DNS${RESET}"
            return 0
        fi
        if validate_dns_input "$custom_dns"; then
            DNS="${custom_dns//[[:space:]]/}"
            echo -e "${GREEN}Используются пользовательские DNS-серверы: $DNS${RESET}"
            return 0
        fi
        echo -e "${RED}Некорректный формат адреса DNS. Введите IPv4/IPv6-адрес или домен (несколько значений разделяйте запятой)${RESET}"
    done
}

# Включение или отключение IPv6
get_ipv6_choice() {
    IPV6_ENABLE="true"
    LISTEN_ADDR="::0"
    read -rp "Включить поддержку IPv6? [Y/n]: " ipv6_choice
    case "$ipv6_choice" in
        [nN]|[nN][oO])
            IPV6_ENABLE="false"
            LISTEN_ADDR="0.0.0.0"
            echo -e "${GREEN}IPv6 отключен, прослушивается только IPv4${RESET}"
            ;;
        *)
            echo -e "${GREEN}IPv6 включен${RESET}"
            ;;
    esac
}

# ── lib/routing.sh ────────────────────────────────────────────────────────────
# Маршрутизация по правилам: сервер Snell по-прежнему использует официальный snell-server, а его исходящий трафик направляется согласно наборам правил —
# напрямую (direct), блокируется (reject) или передается через другой выход (SOCKS5 / HTTP / Shadowsocks / WireGuard, например, домашний провайдер или WARP).
#
# Принцип работы: nftables перехватывает только новые соединения, инициированные пользователем snell (от его имени работают все службы Snell) — TCP через REDIRECT,
# UDP через TPROXY — и передает их локальному экземпляру sing-box (официальный релиз с фиксированной версией). sing-box распознает домен
# (по TLS SNI / HTTP Host / QUIC) и выбирает выход по правилам. Обратный трафик к клиенту, собственный трафик sing-box
# и DNS-запросы через него не проходят. Если sing-box остановлен (или упал), правила перехвата снимаются, и Snell возвращается к прямому подключению без потери сети.
# В режиме управления выходом (netns) трафик Snell инициируется не из основного сетевого пространства, поэтому эти два режима взаимоисключающие. (bash)

ROUTER_DIR="/etc/snell-router"                 # Состояние и сгенерированный конфиг (не кладем в /etc/snell, так как тот каталог целиком принадлежит пользователю snell)
ROUTER_STATE="${ROUTER_DIR}/state.json"
ROUTER_CONFIG="${ROUTER_DIR}/config.json"
ROUTER_BIN="${INSTALL_DIR}/snell-router"       # Отдельный бинарник sing-box, чтобы не затрагивать другие экземпляры sing-box на сервере (например, от PSM)
ROUTER_NET="${INSTALL_DIR}/snell-router-net"   # Скрипт поднятия / снятия (up / down) правил перехвата
ROUTER_UNIT="${SYSTEMD_DIR}/snell-router.service"
ROUTER_DROPIN_NAME="snell-router.conf"         # Переводит службы Snell, запущенные от root (например, установленные через PSM), на пользователя snell
ROUTER_TCP_PORT=17391
ROUTER_UDP_PORT=17392
ROUTER_MARK=0x736e                             # "sn"
ROUTER_TABLE=7391
# Протестированная версия sing-box (формат его конфигурации меняется между крупными релизами, поэтому не гонимся за самой новой; можно переопределить через переменную окружения)
ROUTER_SINGBOX_VERSION="${SNELL_ROUTER_SINGBOX_VERSION:-1.14.2}"
GEOSITE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
GEOIP_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set"

router_installed() { [ -f "$ROUTER_UNIT" ]; }
router_active() { systemctl is-active --quiet snell-router 2>/dev/null; }

# Состояние: {udp, rules: [правила sing-box + _label], outbounds: [...], endpoints: [...], rule_sets: {tag: url}}
router_state() {
    if [ -s "$ROUTER_STATE" ]; then cat "$ROUTER_STATE"
    else echo '{"udp": true, "rules": [], "outbounds": [], "endpoints": [], "rule_sets": {}}'; fi
}
router_save_state() {   # <json>
    mkdir -p "$ROUTER_DIR" && chmod 700 "$ROUTER_DIR"
    printf '%s\n' "$1" | jq '.' > "${ROUTER_STATE}.tmp" && mv "${ROUTER_STATE}.tmp" "$ROUTER_STATE"
}

# Тег набора правил → URL для скачивания (для geosite-* / geoip-* используются репозитории SagerNet, остальные ищутся в файле состояния)
router_rule_set_url() {   # <tag>
    case "$1" in
        geosite-*) echo "${GEOSITE_URL}/$1.srs" ;;
        geoip-*)   echo "${GEOIP_URL}/$1.srs" ;;
        *)         router_state | jq -r --arg t "$1" '.rule_sets[$t] // empty' ;;
    esac
}

# Описание одного правила: что совпало → куда направить
router_rule_text() {   # <JSON правила>
    printf '%s' "$1" | jq -r '
        (._label // ([.rule_set // [], .domain_suffix // [], .ip_cidr // []] | add | join(", "))) as $what
        | (if .action == "reject" then "Блокировать" elif .outbound == "direct" then "Напрямую" else "Выход " + .outbound end) as $to
        | "\($what) → \($to)"'
}

# Генерация конфигурации sing-box: сначала пишем во временный файл и проверяем через sing-box, заменяем только при успешной проверке
router_write_config() {
    local state tags tag url rule_sets tmp
    state=$(router_state)
    tags=$(printf '%s' "$state" | jq -r '[.rules[].rule_set // [] | .[]] | unique | .[]')
    rule_sets='[]'
    for tag in $tags; do
        url=$(router_rule_set_url "$tag")
        [ -n "$url" ] || { echo -e "${RED}Для набора правил ${tag} не указан URL скачивания${RESET}"; return 1; }
        rule_sets=$(printf '%s' "$rule_sets" | jq --arg t "$tag" --arg u "$url" \
            '. + [{type: "remote", tag: $t, format: "binary", url: $u, download_detour: "direct", update_interval: "1d"}]')
    done
    tmp="${ROUTER_CONFIG}.tmp"
    # На машинах с отключенным IPv6 прослушивание :: завершится ошибкой
    local listen="::"
    [ -s /proc/net/if_inet6 ] || listen="0.0.0.0"
    printf '%s' "$state" | jq --argjson rs "$rule_sets" --argjson tp "$ROUTER_TCP_PORT" --argjson up "$ROUTER_UDP_PORT" --arg cache "${ROUTER_DIR}/cache.db" --arg l "$listen" '
        {
          log: {level: "warn", timestamp: true},
          dns: {servers: [{type: "local", tag: "local"}]},
          inbounds: ([{type: "redirect", tag: "snell-tcp", listen: $l, listen_port: $tp}]
                     + (if .udp then [{type: "tproxy", tag: "snell-udp", listen: $l, listen_port: $up, network: "udp"}] else [] end)),
          outbounds: ([{type: "direct", tag: "direct"}] + .outbounds),
          route: {
            default_domain_resolver: "local",
            rules: ([{action: "sniff"}] + [.rules[] | with_entries(select(.key | startswith("_") | not))]),
            rule_set: $rs,
            final: "direct"
          },
          experimental: {cache_file: {enabled: true, path: $cache}}
        }
        + (if (.endpoints | length) > 0 then {endpoints: .endpoints} else {} end)' > "$tmp" || return 1
    if ! "$ROUTER_BIN" check -c "$tmp" 2>"${tmp}.err"; then
        echo -e "${RED}sing-box не принял сгенерированную конфигурацию:${RESET}"
        sed 's/^/   /' "${tmp}.err"
        rm -f "$tmp" "${tmp}.err"
        return 1
    fi
    rm -f "${tmp}.err"
    chmod 600 "$tmp"
    mv "$tmp" "$ROUTER_CONFIG"
}

# Скачивание фиксированной версии sing-box (официальный релиз)
router_install_singbox() {
    local arch tmp url
    if [ -x "$ROUTER_BIN" ] && "$ROUTER_BIN" version 2>/dev/null | grep -q "version ${ROUTER_SINGBOX_VERSION}\$"; then
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        i386|i686) arch="386" ;;
        *) echo -e "${RED}Неподдерживаемая архитектура: $(uname -m)${RESET}"; return 1 ;;
    esac
    ensure_cmds curl tar || return 1
    url="https://github.com/SagerNet/sing-box/releases/download/v${ROUTER_SINGBOX_VERSION}/sing-box-${ROUTER_SINGBOX_VERSION}-linux-${arch}.tar.gz"
    echo -e "${CYAN}Скачивание sing-box ${ROUTER_SINGBOX_VERSION}...${RESET}"
    tmp=$(mktemp -d) || return 1
    if ! curl -fL --retry 2 -o "${tmp}/sb.tar.gz" "$url" || ! tar -xzf "${tmp}/sb.tar.gz" -C "$tmp"; then
        echo -e "${RED}Ошибка скачивания sing-box: ${url}${RESET}"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "${tmp}/sing-box-${ROUTER_SINGBOX_VERSION}-linux-${arch}/sing-box" "$ROUTER_BIN"
    rm -rf "$tmp"
    "$ROUTER_BIN" version | head -1
}

# Скрипт поднятия / снятия (up / down) правил перехвата (вызывается через systemd при запуске и остановке службы)
router_write_net_script() {
    local udp
    udp=$(router_state | jq -r '.udp')
    cat > "$ROUTER_NET" <<EOF
#!/bin/bash
# Сгенерировано скриптом snell.sh: передает новые соединения, инициированные пользователем snell, в snell-router (sing-box).
# При вызове up сначала ждет начала прослушивания порта со стороны sing-box, затем включает перехват; вызов down снимает все правила, возвращая Snell к прямому соединению.
SNELL_UID=\$(id -u ${SNELL_SERVICE_USER} 2>/dev/null) || { echo "Пользователь ${SNELL_SERVICE_USER} не найден" >&2; exit 1; }
TCP_PORT=${ROUTER_TCP_PORT}; UDP_PORT=${ROUTER_UDP_PORT}; MARK=${ROUTER_MARK}; TABLE=${ROUTER_TABLE}; UDP=${udp}

down() {
    nft delete table inet snell_router 2>/dev/null
    ip rule del fwmark \$MARK lookup \$TABLE pref \$TABLE 2>/dev/null
    ip -6 rule del fwmark \$MARK lookup \$TABLE pref \$TABLE 2>/dev/null
    ip route flush table \$TABLE 2>/dev/null
    ip -6 route flush table \$TABLE 2>/dev/null
    return 0
}

up() {
    down
    for i in \$(seq 1 50); do ss -Hltn "sport = :\$TCP_PORT" | grep -q . && break; sleep 0.2; done
    # Локальную петлю (loopback) и DNS не перехватываем: собственный резолвинг доменов Snell работает как обычно; остальное (включая локальные сети) решается правилами
    nft -f - <<NFT || { down; exit 1; }
table inet snell_router {
    chain out_tcp {
        type nat hook output priority dstnat; policy accept;
        meta skuid \$SNELL_UID ct direction original meta l4proto tcp th dport 53 return
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv4 meta l4proto tcp ip daddr != 127.0.0.0/8 redirect to :\$TCP_PORT
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv6 meta l4proto tcp ip6 daddr != ::1 redirect to :\$TCP_PORT
    }
}
NFT
    [ "\$UDP" = true ] || return 0
    nft -f - <<NFT || { down; exit 1; }
table inet snell_router {
    chain out_udp {
        type route hook output priority mangle; policy accept;
        meta skuid \$SNELL_UID ct direction original meta l4proto udp th dport 53 return
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv4 meta l4proto udp ip daddr != 127.0.0.0/8 meta mark set \$MARK
        meta skuid \$SNELL_UID ct direction original meta nfproto ipv6 meta l4proto udp ip6 daddr != ::1 meta mark set \$MARK
    }
    chain pre_udp {
        type filter hook prerouting priority mangle; policy accept;
        meta mark \$MARK meta nfproto ipv4 meta l4proto udp tproxy ip to 127.0.0.1:\$UDP_PORT accept
        meta mark \$MARK meta nfproto ipv6 meta l4proto udp tproxy ip6 to [::1]:\$UDP_PORT accept
    }
}
NFT
    ip rule add fwmark \$MARK lookup \$TABLE pref \$TABLE
    ip route add local 0.0.0.0/0 dev lo table \$TABLE
    if [ -s /proc/net/if_inet6 ]; then
        ip -6 rule add fwmark \$MARK lookup \$TABLE pref \$TABLE
        ip -6 route add local ::/0 dev lo table \$TABLE
    fi
    return 0
}

case "\$1" in
    up) up ;;
    down) down ;;
    *) echo "Использование: \$0 up|down" >&2; exit 2 ;;
esac
EOF
    chmod 755 "$ROUTER_NET"
}

router_write_unit() {
    cat > "$ROUTER_UNIT" <<EOF
[Unit]
Description=Маршрутизация по правилам Snell (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ROUTER_BIN} run -c ${ROUTER_CONFIG}
ExecStartPost=${ROUTER_NET} up
ExecStopPost=${ROUTER_NET} down
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

# Все службы Snell (snell, snell-<порт>)
router_snell_units() {
    local f n
    for f in "${SYSTEMD_DIR}"/snell*.service; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .service)
        [[ "$n" =~ ^snell(-[0-9]+)?$ ]] && echo "$n"
    done
    return 0
}

# Для служб Snell, работающих не от пользователя snell (например, установленных через PSM): добавляем drop-in для перехода на пользователя snell,
# а перед запуском передаем права на чтение конфига пользователю snell (даже если PSM перезапишет конфиг, права восстановятся автоматически)
router_fix_service_users() {
    local unit user conf changed=false
    for unit in $(router_snell_units); do
        [ -f "${SYSTEMD_DIR}/${unit}.service.d/${ROUTER_DROPIN_NAME}" ] && continue
        user=$(systemctl show -p User --value "$unit" 2>/dev/null)
        [ "$user" = "$SNELL_SERVICE_USER" ] && continue
        conf=$(sed -n 's/^ExecStart=[^ ]* -c \([^ ]*\).*/\1/p' "${SYSTEMD_DIR}/${unit}.service" | head -n 1)
        ensure_snell_service_user
        mkdir -p "${SYSTEMD_DIR}/${unit}.service.d"
        {
            echo "# Добавлено маршрутизацией по правилам snell.sh: трафик Snell распознается по пользователю snell"
            echo "[Service]"
            echo "User=${SNELL_SERVICE_USER}"
            echo "Group=${SNELL_SERVICE_GROUP}"
            echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
            [ -n "$conf" ] && echo "ExecStartPre=+/bin/chown ${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP} ${conf}"
        } > "${SYSTEMD_DIR}/${unit}.service.d/${ROUTER_DROPIN_NAME}"
        echo -e "${YELLOW}Служба ${unit} ранее запускалась от ${user:-root}, переведена на пользователя ${SNELL_SERVICE_USER} (через drop-in, исходный файл службы не изменен)${RESET}"
        changed=true
        UNITS_TO_RESTART="${UNITS_TO_RESTART} ${unit}"
    done
    if [ "$changed" = true ]; then systemctl daemon-reload; fi
}

router_remove_dropins() {
    local d unit
    for d in "${SYSTEMD_DIR}"/snell*.service.d; do
        [ -f "${d}/${ROUTER_DROPIN_NAME}" ] || continue
        rm -f "${d}/${ROUTER_DROPIN_NAME}"
        rmdir "$d" 2>/dev/null || true
        unit=$(basename "$d" .service.d)
        systemctl daemon-reload
        systemctl is-active --quiet "$unit" && systemctl restart "$unit"
    done
    return 0
}

# Включение (или перегенерация конфига по текущим правилам с перезапуском)
router_enable() {
    if systemctl is-enabled --quiet snell.socket 2>/dev/null || systemctl is-active --quiet snell.socket 2>/dev/null; then
        echo -e "${RED}Включено управление выходом (netns): в этом режиме трафик Snell инициируется вне основной системы и не может быть перехвачен маршрутизатором. Сначала отключите управление выходом в пункте меню 11.${RESET}"
        return 1
    fi
    if [ -z "$(router_snell_units)" ]; then
        echo -e "${RED}Службы Snell не найдены. Сначала установите Snell.${RESET}"
        return 1
    fi
    ensure_cmds jq nft ip ss || return 1
    router_install_singbox || return 1
    [ -s "$ROUTER_STATE" ] || router_save_state "$(router_state)"
    router_write_config || return 1
    router_write_net_script
    router_write_unit
    UNITS_TO_RESTART=""
    router_fix_service_users
    systemctl daemon-reload
    systemctl enable snell-router >/dev/null 2>&1
    if ! restart_and_verify_service snell-router; then
        echo -e "${RED}Не удалось запустить snell-router. Правила перехвата сняты, Snell продолжает работать напрямую.${RESET}"
        return 1
    fi
    local unit
    for unit in $UNITS_TO_RESTART; do restart_and_verify_service "$unit" || true; done
    echo -e "${GREEN}✓ Маршрутизация по правилам включена (правил: $(router_state | jq '.rules | length'), остальной трафик идет напрямую)${RESET}"
}

# Отключение: служба, правила перехвата и drop-in удаляются, но сами правила и выходы сохраняются (восстановятся при повторном включении)
router_disable() {
    systemctl stop snell-router 2>/dev/null
    systemctl disable snell-router 2>/dev/null
    [ -x "$ROUTER_NET" ] && "$ROUTER_NET" down
    router_remove_dropins
    echo -e "${GREEN}✓ Маршрутизация по правилам отключена, Snell работает напрямую. Правила и выходы сохранены и восстановятся при повторном включении.${RESET}"
}

# Полная очистка при удалении Snell
router_remove() {
    router_installed || [ -d "$ROUTER_DIR" ] || return 0
    systemctl stop snell-router 2>/dev/null
    systemctl disable snell-router 2>/dev/null
    [ -x "$ROUTER_NET" ] && "$ROUTER_NET" down
    router_remove_dropins
    rm -f "$ROUTER_UNIT" "$ROUTER_NET" "$ROUTER_BIN"
    rm -rf "$ROUTER_DIR"
    systemctl daemon-reload 2>/dev/null || true
}

# При изменении правил: если служба запущена — перегенерируем конфиг и перезапускаем
router_apply_if_active() {
    if router_active || systemctl is-enabled --quiet snell-router 2>/dev/null; then
        router_write_config && restart_and_verify_service snell-router && echo -e "${GREEN}✓ Изменения применены${RESET}"
    else
        echo -e "${YELLOW}Сохранено. Маршрутизация еще не включена: выберите «Включить» в этом меню для применения.${RESET}"
    fi
}

router_pick_outbound() {   # → ROUTER_PICK (direct / reject / тег выхода)
    local state tags i=3 pick
    state=$(router_state)
    tags=$(printf '%s' "$state" | jq -r '(.outbounds + .endpoints)[].tag')
    echo -e "${CYAN}Действие для совпавшего трафика:${RESET}"
    echo -e "${GREEN}1.${RESET} Блокировать (reject)"
    echo -e "${GREEN}2.${RESET} Напрямую (direct)"
    local list=()
    for t in $tags; do
        echo -e "${GREEN}${i}.${RESET} Выход: ${t}"
        list+=("$t")
        i=$((i + 1))
    done
    read -rp "Выберите [1-$((i - 1))]: " pick
    case "$pick" in
        1) ROUTER_PICK="reject" ;;
        2) ROUTER_PICK="direct" ;;
        *)
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 3 ] && [ "$pick" -lt "$i" ]; then
                ROUTER_PICK="${list[$((pick - 3))]}"
            else
                echo -e "${RED}Некорректный выбор${RESET}"
                return 1
            fi
            ;;
    esac
}

# Строка со значениями через запятую → JSON-массив (удаление пробелов по краям и пустых элементов)
router_list_json() { printf '%s' "$1" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'; }

router_add_rule() {
    local pick match label value
    echo -e "\n${CYAN}=== Добавление правила: условие совпадения ===${RESET}"
    echo -e "${GREEN}1.${RESET} Реклама и трекеры (geosite category-ads-all)"
    echo -e "${GREEN}2.${RESET} Сайты и IP материкового Китая (geosite cn + geoip cn)"
    echo -e "${GREEN}3.${RESET} Локальные и частные адреса (защита от доступа клиентов к внутренней сети и метаданным облака)"
    echo -e "${GREEN}4.${RESET} Загрузки BitTorrent (BT)"
    echo -e "${GREEN}5.${RESET} ИИ-сервисы (OpenAI, Anthropic, Gemini, Perplexity)"
    echo -e "${GREEN}6.${RESET} Стриминги (Netflix, Disney+, HBO, Prime Video, Hulu)"
    echo -e "${GREEN}7.${RESET} Категория geosite (введите названия, например google, telegram; можно несколько)"
    echo -e "${GREEN}8.${RESET} Страна / регион geoip (введите коды, например cn, ir; можно несколько)"
    echo -e "${GREEN}9.${RESET} Доменные суффиксы (например example.com; можно несколько через запятую)"
    echo -e "${GREEN}10.${RESET} Подсети IP (например 1.2.3.0/24; можно несколько)"
    echo -e "${GREEN}11.${RESET} Удаленный набор правил (URL на файл .srs для sing-box)"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Выберите [0-11]: " pick
    case "$pick" in
        1) match='{"rule_set": ["geosite-category-ads-all"]}'; label="Реклама и трекеры" ;;
        2) match='{"rule_set": ["geosite-cn", "geoip-cn"]}'; label="Материковый Китай" ;;
        3) match='{"ip_is_private": true}'; label="Локальные адреса" ;;
        4) match='{"protocol": ["bittorrent"]}'; label="BitTorrent" ;;
        5) match='{"rule_set": ["geosite-openai", "geosite-anthropic", "geosite-google-gemini", "geosite-perplexity"]}'; label="ИИ (AI)" ;;
        6) match='{"rule_set": ["geosite-netflix", "geosite-disney", "geosite-hbo", "geosite-primevideo", "geosite-hulu"]}'; label="Стриминги" ;;
        7|8)
            local kind; [ "$pick" = 7 ] && kind="geosite" || kind="geoip"
            read -rp "Введите названия ${kind} (через запятую): " value
            match=$(router_list_json "$value" | jq -c --arg k "$kind" 'map(ascii_downcase | select(test("^[a-z0-9@!._-]+$")) | "\($k)-\(.)") | {rule_set: .}')
            label="${kind} ${value}"
            ;;
        9)
            read -rp "Введите доменные суффиксы (через запятую): " value
            match=$(router_list_json "$value" | jq -c '{domain_suffix: .}')
            label="Домен ${value}"
            ;;
        10)
            read -rp "Введите подсети IP (через запятую): " value
            match=$(router_list_json "$value" | jq -c '{ip_cidr: .}')
            label="IP ${value}"
            ;;
        11)
            read -rp "URL набора правил (https://…): " value
            if [[ ! "$value" =~ ^https://[^[:space:]]+$ ]]; then echo -e "${RED}Требуется адрес, начинающийся с https://${RESET}"; return 1; fi
            local tag="custom-$(printf '%s' "$value" | sha256sum | cut -c1-8)"
            router_save_state "$(router_state | jq --arg t "$tag" --arg u "$value" '.rule_sets[$t] = $u')"
            match=$(jq -nc --arg t "$tag" '{rule_set: [$t]}')
            label="Набор правил ${value##*/}"
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}Некорректный выбор${RESET}"; return 1 ;;
    esac
    if [ -z "$match" ] || printf '%s' "$match" | jq -e 'to_entries[0].value | (type == "array" and length == 0)' >/dev/null; then
        echo -e "${RED}Нет доступных условий для сопоставления${RESET}"
        return 1
    fi
    router_pick_outbound || return 1
    local rule
    if [ "$ROUTER_PICK" = "reject" ]; then
        rule=$(printf '%s' "$match" | jq -c --arg l "$label" '. + {action: "reject", _label: $l}')
    else
        rule=$(printf '%s' "$match" | jq -c --arg l "$label" --arg o "$ROUTER_PICK" '. + {outbound: $o, _label: $l}')
    fi
    router_save_state "$(router_state | jq --argjson r "$rule" '.rules += [$r]')"
    echo -e "${GREEN}✓ Добавлено: $(router_rule_text "$rule")${RESET}"
    router_apply_if_active
}

router_delete_rule() {
    local n pick
    n=$(router_state | jq '.rules | length')
    if [ "$n" -eq 0 ]; then echo -e "${YELLOW}Правил пока нет${RESET}"; return 0; fi
    router_list_rules
    read -rp "Какое по счету правило удалить [1-${n}] (0 для возврата): " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ] || return 0
    router_save_state "$(router_state | jq --argjson i "$((pick - 1))" 'del(.rules[$i])')"
    echo -e "${GREEN}✓ Удалено${RESET}"
    router_apply_if_active
}

router_list_rules() {
    local i=1 rule
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        echo -e "  ${GREEN}${i}.${RESET} $(router_rule_text "$rule")"
        i=$((i + 1))
    done < <(router_state | jq -c '.rules[]')
    echo -e "  ${CYAN}Остальной трафик → Напрямую${RESET}"
}

router_add_outbound() {
    local pick tag server port user pass method ob
    echo -e "\n${CYAN}=== Добавление выхода (Outbound) ===${RESET}"
    echo -e "${GREEN}1.${RESET} SOCKS5"
    echo -e "${GREEN}2.${RESET} HTTP-прокси"
    echo -e "${GREEN}3.${RESET} Shadowsocks"
    echo -e "${GREEN}4.${RESET} WireGuard (например Cloudflare WARP; укажите параметры от wgcf и т. п.)"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Выберите [0-4]: " pick
    [ "$pick" = "0" ] || [ -z "$pick" ] && return 0
    read -rp "Название выхода (буквы, цифры, - _): " tag
    if [[ ! "$tag" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || [ "$tag" = "direct" ]; then echo -e "${RED}Некорректное название${RESET}"; return 1; fi
    if router_state | jq -e --arg t "$tag" '(.outbounds + .endpoints) | any(.tag == $t)' >/dev/null; then
        echo -e "${RED}Выход с таким названием уже существует${RESET}"; return 1
    fi
    case "$pick" in
        1|2|3)
            read -rp "Адрес сервера: " server
            read -rp "Порт: " port
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo -e "${RED}Некорректный порт${RESET}"; return 1; }
            ;;
    esac
    case "$pick" in
        1|2)
            read -rp "Имя пользователя (Enter, если нет): " user
            read -rp "Пароль (Enter, если нет): " pass
            ob=$(jq -nc --arg ty "$([ "$pick" = 1 ] && echo socks || echo http)" --arg t "$tag" --arg s "$server" --argjson p "$port" --arg u "$user" --arg pw "$pass" '
                {type: $ty, tag: $t, server: $s, server_port: $p}
                + (if $ty == "socks" then {version: "5"} else {} end)
                + (if $u != "" then {username: $u, password: $pw} else {} end)')
            router_save_state "$(router_state | jq --argjson o "$ob" '.outbounds += [$o]')"
            ;;
        3)
            read -rp "Метод шифрования (например 2022-blake3-aes-128-gcm, aes-256-gcm): " method
            read -rp "Пароль: " pass
            ob=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" --arg m "$method" --arg pw "$pass" \
                '{type: "shadowsocks", tag: $t, server: $s, server_port: $p, method: $m, password: $pw}')
            router_save_state "$(router_state | jq --argjson o "$ob" '.outbounds += [$o]')"
            ;;
        4)
            local key addr peer_key endpoint reserved
            read -rp "Локальный приватный ключ (PrivateKey): " key
            read -rp "Локальный адрес (Address, несколько через запятую, например 172.16.0.2/32,2606:4700:110:8a36::1/128): " addr
            read -rp "Публичный ключ пира (PublicKey): " peer_key
            read -rp "Адрес:порт пира (Endpoint, например 162.159.192.1:2408): " endpoint
            read -rp "Поле reserved (для WARP, например 1,2,3; Enter, если нет): " reserved
            [[ "$endpoint" =~ ^(.+):([0-9]+)$ ]] || { echo -e "${RED}Endpoint должен быть в формате адрес:порт${RESET}"; return 1; }
            ob=$(jq -nc --arg t "$tag" --arg k "$key" --argjson a "$(router_list_json "$addr")" --arg pk "$peer_key" \
                    --arg h "$(echo "${BASH_REMATCH[1]}" | tr -d '[]')" --argjson p "${BASH_REMATCH[2]}" --argjson r "$(router_list_json "$reserved" | jq -c 'map(tonumber)')" '
                {type: "wireguard", tag: $t, address: $a, private_key: $k, mtu: 1280,
                 peers: [{address: $h, port: $p, public_key: $pk, allowed_ips: ["0.0.0.0/0", "::/0"]}
                         + (if ($r | length) == 3 then {reserved: $r} else {} end)]}')
            router_save_state "$(router_state | jq --argjson o "$ob" '.endpoints += [$o]')"
            ;;
        *) echo -e "${RED}Некорректный выбор${RESET}"; return 1 ;;
    esac
    echo -e "${GREEN}✓ Выход ${tag} добавлен. Выберите его при добавлении правила, чтобы направлять туда совпавший трафик.${RESET}"
    router_apply_if_active
}

router_delete_outbound() {
    local tags pick i=1 list=()
    tags=$(router_state | jq -r '(.outbounds + .endpoints)[].tag')
    [ -n "$tags" ] || { echo -e "${YELLOW}Выходов пока нет${RESET}"; return 0; }
    for t in $tags; do echo -e "  ${GREEN}${i}.${RESET} ${t}"; list+=("$t"); i=$((i + 1)); done
    read -rp "Какой по счету выход удалить (0 для возврата): " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -lt "$i" ] || return 0
    local tag="${list[$((pick - 1))]}"
    if router_state | jq -e --arg t "$tag" 'any(.rules[]; .outbound == $t)' >/dev/null; then
        echo -e "${RED}Выход ${tag} всё ещё используется в правилах. Сначала удалите эти правила.${RESET}"
        return 1
    fi
    router_save_state "$(router_state | jq --arg t "$tag" '.outbounds |= map(select(.tag != $t)) | .endpoints |= map(select(.tag != $t))')"
    echo -e "${GREEN}✓ Выход ${tag} удален${RESET}"
    router_apply_if_active
}

router_toggle_udp() {
    local udp
    udp=$(router_state | jq -r '.udp')
    if [ "$udp" = true ]; then udp=false; else udp=true; fi
    router_save_state "$(router_state | jq --argjson u "$udp" '.udp = $u')"
    echo -e "${GREEN}✓ Маршрутизация UDP: $([ "$udp" = true ] && echo "Вкл" || echo "Выкл (UDP идет напрямую)")${RESET}"
    if router_active; then router_enable; fi
}

# Меню маршрутизации
router_menu() {
    ensure_cmds jq || return 1
    while true; do
        echo -e "\n${CYAN}=============== Маршрутизация по правилам (sing-box) ===============${RESET}"
        echo -e "${YELLOW}Сам Snell остается официальным snell-server; его исходящий трафик идет по правилам ниже, а остальной — напрямую.${RESET}"
        if router_active; then
            echo -e "${GREEN}Статус: Активна (sing-box ${ROUTER_SINGBOX_VERSION}, UDP $(router_state | jq -r 'if .udp then "тоже по правилам" else "напрямую" end'))${RESET}"
        elif router_installed; then
            echo -e "${YELLOW}Статус: Отключена${RESET}"
        else
            echo -e "${YELLOW}Статус: Не включена${RESET}"
        fi
        echo -e "${CYAN}Правила (проверяются сверху вниз до первого совпадения):${RESET}"
        router_list_rules
        local obs
        obs=$(router_state | jq -r '[(.outbounds + .endpoints)[] | "\(.tag) (\(.type))"] | join(", ")')
        [ -n "$obs" ] && echo -e "${CYAN}Выходы: ${RESET}${obs}"
        echo -e "\n${GREEN}1.${RESET} Включить / Пересоздать конфиг и перезапустить"
        echo -e "${GREEN}2.${RESET} Добавить правило"
        echo -e "${GREEN}3.${RESET} Удалить правило"
        echo -e "${GREEN}4.${RESET} Добавить выход (SOCKS5 / HTTP / Shadowsocks / WireGuard)"
        echo -e "${GREEN}5.${RESET} Удалить выход"
        echo -e "${GREEN}6.${RESET} Маршрутизация UDP: Вкл / Выкл"
        echo -e "${GREEN}7.${RESET} Отключить маршрутизацию (вернуть прямое соединение)"
        echo -e "${GREEN}8.${RESET} Просмотр журнала (логов)"
        echo -e "${GREEN}0.${RESET} Назад"
        local choice
        read -rp "Выберите [0-8]: " choice || return 0
        case "$choice" in
            1) router_enable ;;
            2) router_add_rule ;;
            3) router_delete_rule ;;
            4) router_add_outbound ;;
            5) router_delete_outbound ;;
            6) router_toggle_udp ;;
            7) router_disable ;;
            8) journalctl -u snell-router -n 40 --no-pager 2>/dev/null ;;
            0|"") return 0 ;;
            *) echo -e "${RED}Некорректный выбор${RESET}" ;;
        esac
    done
}


# Текущий номер версии скрипта
current_version="6.3"

# Параметры по умолчанию для управления выходом (netns + socket activation)
EGRESS_FEATURE_ENABLED="false"
EGRESS_IFACE=""
EGRESS_NS="snell-egress"
EGRESS_HOST_IP=""
EGRESS_NS_IP=""
EGRESS_SUBNET=""
EGRESS_GW=""

validate_snell_main_config() {
    migrate_legacy_main_config_if_needed || true

    if [ ! -s "$SNELL_CONF_FILE" ]; then
        echo -e "${RED}Основной файл конфигурации не существует: ${SNELL_CONF_FILE}${RESET}"
        echo -e "${YELLOW}Сначала выполните установку или поместите старый конфиг по этому пути перед запуском службы.${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}В основной конфигурации отсутствует параметр listen: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*psk[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}В основной конфигурации отсутствует параметр psk: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    return 0
}

write_main_systemd_service() {
    ensure_snell_config_dir
    local snell_binary
    snell_binary=$(main_snell_binary)
    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main)
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
# Усиление безопасности службы: snell-server только читает конфиг и не пишет в файловую систему (аналогично netns-версии юнита)
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ReadOnlyPaths=/etc/snell
LimitNOFILE=32768
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

sync_existing_main_service_unit() {
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        return 0
    fi

    if systemctl is-enabled --quiet snell.socket 2>/dev/null; then
        return 0
    fi

    if grep -q "NetworkNamespacePath=" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if ! grep -Eq "ExecStart=${INSTALL_DIR}/snell-server(-v[456])? -c ${SNELL_CONF_FILE}" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if grep -q "StandardOutput=syslog\\|StandardError=syslog\\|User=nobody\\|Group=nogroup" "$SYSTEMD_SERVICE_FILE"; then
        write_main_systemd_service
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}Конфигурация systemd для snell.service обновлена.${RESET}"
    fi
}

# Генерация адресов host/ns и шлюза на основе подсети /30
apply_egress_subnet() {
    local subnet="$1"
    local base prefix

    base="${subnet%/30}"
    prefix="${base%.*}"

    EGRESS_SUBNET="$subnet"
    EGRESS_HOST_IP="${prefix}.1/30"
    EGRESS_NS_IP="${prefix}.2/30"
    EGRESS_GW="${prefix}.1"
}

# Автоматический выбор свободной подсети /30 (пул по умолчанию: 172.31.0.0/16)
auto_pick_egress_subnet() {
    local i candidate

    if ! command -v ip &> /dev/null; then
        apply_egress_subnet "172.31.0.0/30"
        return
    fi

    for i in $(seq 0 255); do
        candidate="172.31.${i}.0/30"
        if ip -o -4 addr show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi
        if ip -4 route show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi

        apply_egress_subnet "$candidate"
        return
    done

    apply_egress_subnet "172.31.0.0/30"
}

# Инициализация подсети по умолчанию
auto_pick_egress_subnet

# Автоматическое определение выходного сетевого интерфейса по умолчанию
auto_detect_egress_iface() {
    local detected_iface

    if command -v ip &> /dev/null; then
        detected_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    fi

    if [ -n "$detected_iface" ]; then
        EGRESS_IFACE="$detected_iface"
    elif [ -z "$EGRESS_IFACE" ]; then
        EGRESS_IFACE="eth1"
    fi
}

# Инициализация выходного интерфейса по умолчанию
auto_detect_egress_iface

# Проверка и миграция старой конфигурации
check_and_migrate_config() {
    local old_files_exist=false

    # Автоматическое исправление сбоя запуска после обновления 4.x -> 5.x, когда служба указывает на новый путь, а конфиг остался по старому.
    if [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; then
        migrate_legacy_main_config_if_needed
        if [ -f "$SYSTEMD_SERVICE_FILE" ] && ! systemctl is-enabled --quiet snell.socket 2>/dev/null; then
            write_main_systemd_service
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    # Проверка старых конфигов, всё ещё требующих ручного вмешательства. Если основной конфиг уже перенесен автоматически, старый файл просто остается без повторных напоминаний.
    if { [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; } || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        old_files_exist=true
        echo -e "\n${YELLOW}Обнаружены файлы конфигурации старой версии Snell${RESET}"
        echo -e "Расположение старых файлов:"
        [ -f "$OLD_SNELL_CONF_FILE" ] && echo -e "- Файл конфигурации: ${OLD_SNELL_CONF_FILE}"
        [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && echo -e "- Файл службы: ${OLD_SYSTEMD_SERVICE_FILE}"
        
        # Проверка существования пользовательского каталога
        if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
            mkdir -p "${SNELL_CONF_DIR}/users"
            # Установка правильных прав доступа (файлы конфигурации содержат PSK и доступны только владельцу)
            ensure_snell_service_user
            chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}"
            find "${SNELL_CONF_DIR}" -type d -exec chmod 755 {} +
            find "${SNELL_CONF_DIR}" -name "*.conf" -exec chmod 600 {} +
        fi
    fi

    # Если требуется миграция, спрашиваем пользователя
    if [ "$old_files_exist" = true ]; then
        echo -e "\n${YELLOW}Перенести старые файлы конфигурации? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo -e "${CYAN}Начало миграции файлов конфигурации...${RESET}"
            
            # Остановка службы
            systemctl stop snell 2>/dev/null
            
            # Миграция файла конфигурации
            if [ -f "$OLD_SNELL_CONF_FILE" ]; then
                cp "$OLD_SNELL_CONF_FILE" "${SNELL_CONF_FILE}"
                # Установка правильных прав на файл
                ensure_snell_service_user
                chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_FILE}"
                chmod 644 "${SNELL_CONF_FILE}"
                echo -e "${GREEN}Файл конфигурации перенесен${RESET}"
            fi
            
            # Миграция файла службы
            if [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
                write_main_systemd_service
                echo -e "${GREEN}Файл службы перенесен${RESET}"
            fi
            
            # Запрос на удаление старых файлов
            echo -e "${YELLOW}Удалить старые файлы конфигурации? [y/N]${RESET}"
            read -r del_choice
            if [[ "$del_choice" == "y" || "$del_choice" == "Y" ]]; then
                [ -f "$OLD_SNELL_CONF_FILE" ] && rm -f "$OLD_SNELL_CONF_FILE"
                [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && rm -f "$OLD_SYSTEMD_SERVICE_FILE"
                echo -e "${GREEN}Старые файлы конфигурации удалены${RESET}"
            fi
            
            # Перезагрузка конфигурации systemd и запуск службы
            systemctl daemon-reload
            if validate_snell_main_config; then
                systemctl start snell
            fi
            
            # Проверка статуса службы
            if systemctl is-active --quiet snell; then
                echo -e "${GREEN}Миграция конфигурации завершена, служба успешно запущена${RESET}"
            else
                echo -e "${RED}Внимание: не удалось запустить службу, проверьте файлы конфигурации и права доступа${RESET}"
                systemctl status snell
            fi
        else
            echo -e "${YELLOW}Миграция конфигурации пропущена${RESET}"
        fi
    fi
}

check_root

# Запрос на включение управления выходом в Snell v5/v6
get_egress_feature_choice() {
    EGRESS_FEATURE_ENABLED="false"
    if [ "$SNELL_VERSION_CHOICE" != "v5" ] && [ "$SNELL_VERSION_CHOICE" != "v6" ]; then
        return
    fi

    echo -e "${CYAN}Включить управление выходом Snell ${SNELL_VERSION_CHOICE} (netns + socket activation)?${RESET}"
    echo -e "${GREEN}1.${RESET} Включить (новая функция)"
    echo -e "${GREEN}2.${RESET} Не включать (рекомендуется)"

    while true; do
        read -rp "Введите вариант [1-2]: " egress_choice
        case "$egress_choice" in
            1)
                EGRESS_FEATURE_ENABLED="true"
                echo -e "${GREEN}Управление выходом Snell включено${RESET}"
                break
                ;;
            2)
                EGRESS_FEATURE_ENABLED="false"
                echo -e "${YELLOW}Выбран классический режим${RESET}"
                break
                ;;
            *)
                echo -e "${RED}Пожалуйста, введите корректный вариант [1-2]${RESET}"
                ;;
        esac
    done
}

# Получение параметров управления выходом
get_egress_settings() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    auto_detect_egress_iface
    read -rp "Введите имя выходного интерфейса (по умолчанию ${EGRESS_IFACE}): " custom_iface
    if [ -n "$custom_iface" ]; then
        EGRESS_IFACE="$custom_iface"
    fi

    read -rp "Введите имя сетевого пространства netns (по умолчанию snell-egress): " custom_ns
    if [ -n "$custom_ns" ]; then
        EGRESS_NS="$custom_ns"
    fi

    # Проверка по белому списку: эти два значения записываются в скрипт инициализации, выполняемый от root;
    # недопустимые символы могут повредить скрипт или привести к инъекции команд
    if ! [[ "$EGRESS_IFACE" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]; then
        echo -e "${RED}Недопустимое имя интерфейса (разрешены только буквы, цифры, _ . -, макс. 15 символов). Восстановлено автоматически определенное значение.${RESET}"
        auto_detect_egress_iface
    fi
    if ! [[ "$EGRESS_NS" =~ ^[a-zA-Z0-9_.-]{1,16}$ ]]; then
        echo -e "${YELLOW}Недопустимое имя пространства имен (разрешены только буквы, цифры, _ . -). Восстановлено значение по умолчанию snell-egress.${RESET}"
        EGRESS_NS="snell-egress"
    fi

    # Автоматическое определение подсети по умолчанию с возможностью ручного переопределения
    auto_pick_egress_subnet
    read -rp "Введите подсеть veth (CIDR, по умолчанию ${EGRESS_SUBNET}): " custom_subnet
    if [ -n "$custom_subnet" ]; then
        if [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){3}0/30$ ]]; then
            apply_egress_subnet "$custom_subnet"
        else
            echo -e "${YELLOW}Некорректный формат подсети, используется автоматически выбранная: ${EGRESS_SUBNET}${RESET}"
        fi
    fi

    echo -e "${GREEN}Выходной интерфейс: ${EGRESS_IFACE}${RESET}"
    echo -e "${GREEN}Пространство имен: ${EGRESS_NS}${RESET}"
    echo -e "${GREEN}Подсеть veth: ${EGRESS_SUBNET}${RESET}"
    echo -e "${YELLOW}Справка: ${EGRESS_HOST_IP} (основное пространство) <-> ${EGRESS_NS_IP} (${EGRESS_NS})${RESET}"
}

# Проверка зависимостей для управления выходом
check_egress_dependencies() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    ensure_cmds ip nft || exit 1
}

# Запись юнита инициализации netns
write_snell_netns_service() {
    cat > ${NETNS_SETUP_SCRIPT} << EOF
#!/bin/bash
set -eux

ip netns add ${EGRESS_NS} 2>/dev/null || true
ip link show veth-host >/dev/null 2>&1 || ip link add veth-host type veth peer name veth-snell
ip link set veth-snell netns ${EGRESS_NS} 2>/dev/null || true

ip addr replace ${EGRESS_HOST_IP} dev veth-host
ip link set veth-host up

ip netns exec ${EGRESS_NS} ip addr replace ${EGRESS_NS_IP} dev veth-snell
ip netns exec ${EGRESS_NS} ip link set lo up
ip netns exec ${EGRESS_NS} ip link set veth-snell up
ip netns exec ${EGRESS_NS} ip route replace default via ${EGRESS_GW}

mkdir -p /etc/netns/${EGRESS_NS}
cp -f /etc/resolv.conf /etc/netns/${EGRESS_NS}/resolv.conf
if grep -Eq '^nameserver[[:space:]]+127\\.0\\.0\\.53$' /etc/netns/${EGRESS_NS}/resolv.conf; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/netns/${EGRESS_NS}/resolv.conf
fi

sysctl -w net.ipv4.ip_forward=1

nft delete table ip snell_nat 2>/dev/null || true
nft add table ip snell_nat
nft add chain ip snell_nat postrouting '{ type nat hook postrouting priority 100; policy accept; }'
nft add rule ip snell_nat postrouting oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} masquerade

nft add table inet snell_filter 2>/dev/null || true
nft list chain inet snell_filter forward >/dev/null 2>&1 || nft add chain inet snell_filter forward '{ type filter hook forward priority -5; policy accept; }'
nft add rule inet snell_filter forward iifname 'veth-host' oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} accept 2>/dev/null || true
nft add rule inet snell_filter forward iifname "${EGRESS_IFACE}" oifname 'veth-host' ct state established,related accept 2>/dev/null || true

if command -v iptables >/dev/null 2>&1; then
    iptables -C FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT
    iptables -C FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi
EOF
    chmod +x ${NETNS_SETUP_SCRIPT}

    cat > ${SYSTEMD_NETNS_FILE} << EOF
[Unit]
Description=Prepare netns and NAT for Snell egress
DefaultDependencies=no
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NETNS_SETUP_SCRIPT}
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF
}

# Запись юнитов socket activation
# Параметр listen_addr необязателен: если не передан, выводится из строки listen основного конфига для соответствия семейства адресов сокета и конфига
# (ранее был жестко прописан 0.0.0.0, из-за чего у пользователей с IPv6 при включении egress прослушивание IPv6 незаметно пропадало)
write_snell_socket_service_units() {
    local listen_port=$1
    local listen_addr="${2:-}"
    local snell_binary
    snell_binary=$(main_snell_binary)

    if [ -z "$listen_addr" ] && [ -f "$SNELL_CONF_FILE" ]; then
        listen_addr=$(grep -E '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF_FILE" | head -n 1 \
            | sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*\(.*\):[0-9][0-9]*[[:space:]]*$/\1/p')
    fi
    [ -z "$listen_addr" ] && listen_addr="0.0.0.0"

    local socket_stream="ListenStream=0.0.0.0:${listen_port}"
    local socket_datagram="ListenDatagram=0.0.0.0:${listen_port}"
    if [[ "$listen_addr" == *:* ]]; then
        socket_stream="ListenStream=[::]:${listen_port}"
        socket_datagram="ListenDatagram=[::]:${listen_port}"
    fi

    cat > ${SYSTEMD_SOCKET_FILE} << EOF
[Unit]
Description=Snell v5 (socket-activated)

[Socket]
${socket_stream}
${socket_datagram}
FileDescriptorName=snell_inet
ReusePort=no
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main, netns)
Requires=snell-netns.service
After=snell-netns.service

[Service]
Type=simple
NetworkNamespacePath=/run/netns/${EGRESS_NS}
BindReadOnlyPaths=/etc/netns/${EGRESS_NS}/resolv.conf:/etc/resolv.conf
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
LimitNOFILE=32768
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=${INSTALL_DIR}
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

# Освобождение порта от прослушивающих процессов: автоматически завершаются только процессы, связанные со snell;
# сторонние процессы завершаются только после явного подтверждения пользователем, чтобы случайно не убить nginx/sshd и др.
force_release_port_by_pid() {
    local port="$1"
    local pids pid cmd
    local snell_pids="" other_pids=""

    if command -v ss &> /dev/null; then
        pids=$( {
            ss -H -ltnp "( sport = :${port} )" 2>/dev/null
            ss -H -lunp "( sport = :${port} )" 2>/dev/null
        } | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
    elif command -v lsof &> /dev/null; then
        pids=$( {
            lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
            lsof -t -nP -iUDP:"${port}" 2>/dev/null
        } | sort -u)
    fi

    [ -z "$pids" ] && return 0

    for pid in $pids; do
        cmd=$(ps -p "$pid" -o args= 2>/dev/null)
        if echo "$cmd" | grep -q "snell"; then
            snell_pids="${snell_pids}${pid} "
        else
            other_pids="${other_pids}${pid} "
        fi
    done

    for pid in $snell_pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 0.2

    if is_port_in_use "$port"; then
        if [ -n "$other_pids" ]; then
            echo -e "${RED}Порт ${port} всё ещё занят следующими сторонними процессами (не Snell):${RESET}"
            for pid in $other_pids; do
                echo -e "  PID ${pid}: $(ps -p "$pid" -o args= 2>/dev/null)"
            done
            echo -e "${YELLOW}Принудительно завершить эти процессы для освобождения порта? [y/N]${RESET}"
            read -r kill_choice
            case "$kill_choice" in
                [yY]|[yY][eE][sS]) ;;
                *)
                    echo -e "${YELLOW}Отменено, порт ${port} не был освобожден${RESET}"
                    return 1
                    ;;
            esac
            for pid in $other_pids; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        else
            for pid in $snell_pids; do
                kill -KILL "$pid" 2>/dev/null || true
            done
        fi
    fi
    return 0
}

# Перед переключением на socket activation убеждаемся, что основной порт свободен
ensure_main_port_free_for_socket() {
    local port="$1"
    local i

    systemctl stop snell.socket 2>/dev/null
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    systemctl reset-failed snell.socket 2>/dev/null

    # Подстраховка: предотвращаем удержание порта остаточными процессами snell-server
    systemctl kill snell --signal=SIGKILL 2>/dev/null
    pkill -f "${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}" 2>/dev/null || true
    # Если пользователь отказался завершать сторонний процесс, сразу прерываем выполнение без ожидания 20 итераций
    force_release_port_by_pid "$port" || return 1

    for i in {1..20}; do
        if ! is_port_in_use "$port"; then
            return 0
        fi
        sleep 0.2
    done

    echo -e "${RED}Порт ${port} всё ещё занят, невозможно запустить snell.socket.${RESET}"
    echo -e "${YELLOW}Подробности о процессе, занимающем порт:${RESET}"
    show_port_occupier "$port"
    return 1
}

# Запуск среды выполнения egress: приоритет у связки socket + service; при неудаче — откат к прямому запуску службы внутри netns
start_egress_runtime() {
    local port="$1"

    if ! ensure_main_port_free_for_socket "$port"; then
        return 1
    fi

    if ! systemctl enable snell.socket; then
        echo -e "${RED}Не удалось включить автозапуск snell.socket.${RESET}"
        return 1
    fi
    if ! systemctl start snell.socket; then
        echo -e "${RED}Не удалось запустить snell.socket.${RESET}"
        return 1
    fi

    # Важно: активно запускаем службу snell, чтобы гарантировать работу UDP/QUIC без ожидания первого TCP-соединения
    if systemctl start snell; then
        echo -e "${GREEN}Включен режим работы socket + service.${RESET}"
        return 0
    fi

    echo -e "${YELLOW}Не удалось активно запустить snell в режиме сокета. Автоматический возврат к прямому запуску службы в netns.${RESET}"
    systemctl stop snell.socket 2>/dev/null
    systemctl disable snell.socket 2>/dev/null

    if ! systemctl enable snell; then
        echo -e "${RED}Режим отката: не удалось включить автозапуск snell.${RESET}"
        return 1
    fi
    if ! systemctl restart snell; then
        echo -e "${RED}Режим отката: не удалось запустить snell.${RESET}"
        return 1
    fi

    echo -e "${GREEN}Выполнен переход к режиму прямого запуска службы в netns (без активации через сокет).${RESET}"
    return 0
}

# Установка Snell
# Запись команды управления /usr/local/bin/snell: при каждом запуске скачивает свежий скрипт через короткий домен
# (перенаправление настроено в Cloudflare, поэтому при перемещении файлов в репозитории менять код здесь не придется)
write_management_script() {
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash

# Определение цветовых кодов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Проверка запуска с правами root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Пожалуйста, запустите этот скрипт с правами root${RESET}"
    exit 1
fi

# Скачивание и запуск последней версии скрипта (с проверкой целостности: остановка при ошибке передачи, проверка на пустоту и синтаксис)
echo -e "${CYAN}Получение последней версии скрипта управления...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 https://snell.jinqians.com -o "$TMP_SCRIPT" \
    && [ -s "$TMP_SCRIPT" ] && bash -n "$TMP_SCRIPT" 2>/dev/null; then
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}Не удалось скачать или проверить скрипт. Пожалуйста, проверьте подключение к сети.${RESET}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi
EOFSCRIPT
    chmod +x /usr/local/bin/snell
}

# В старых версиях команда управления обращалась напрямую к фиксированным путям на raw.githubusercontent.com (snell.sh / snell-centos.sh);
# обновляем её для работы через короткий домен. Файлы, созданные не этим скриптом, не затрагиваются. До переименования репозиторий назывался jinqians/snell.sh — распознаем оба варианта.
upgrade_management_script() {
    [ -f /usr/local/bin/snell ] || return 0
    grep -qE 'raw\.githubusercontent\.com/jinqians/snell(\.sh)?/' /usr/local/bin/snell 2>/dev/null || return 0
    write_management_script && echo -e "${GREEN}Команда управления snell обновлена (получение свежего скрипта переведено на snell.jinqians.com)${RESET}"
}

# Чтение значения key = value из основного конфига (берется всё после первого знака =, чтобы символы = в base64 PSK не обрезались)
main_conf_value() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$SNELL_CONF_FILE" 2>/dev/null | head -n 1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//'
}

install_snell() {
    echo -e "${CYAN}Установка Snell${RESET}"

    # При наличии основной конфигурации сначала предлагаем выбор пользователю, чтобы при случайной переустановке не сбросить порт и PSK
    local keep_existing_conf="false"
    if [ -f "$SNELL_CONF_FILE" ]; then
        local old_port old_ver
        old_port=$(get_snell_port)
        old_ver=$(get_conf_snell_version "$SNELL_CONF_FILE" 2>/dev/null)
        echo -e "${YELLOW}Обнаружена существующая конфигурация основного пользователя: ${SNELL_CONF_FILE}${RESET}"
        [ -n "$old_port" ] && echo -e "${YELLOW}  Текущий порт: ${old_port}${RESET}"
        [ -n "$old_ver" ] && echo -e "${YELLOW}  Текущая ветка версии: ${old_ver}${RESET}"
        echo -e "${GREEN}1.${RESET} Сохранить текущие порт и PSK (только переустановить бинарник / восстановить службу)"
        echo -e "${GREEN}2.${RESET} Чистая установка (заново выбрать порт и сгенерировать PSK)"
        echo -e "${GREEN}0.${RESET} Отмена"
        local reinstall_choice
        if ! read -rp "Введите вариант [0-2]: " reinstall_choice; then
            echo
            echo -e "${YELLOW}Установка отменена.${RESET}"
            return 0
        fi
        case "$reinstall_choice" in
            1) keep_existing_conf="true" ;;
            2) keep_existing_conf="false" ;;
            0)
                echo -e "${YELLOW}Установка отменена.${RESET}"
                return 0
                ;;
            *)
                echo -e "${RED}Некорректный выбор, установка отменена.${RESET}"
                return 1
                ;;
        esac
    fi

    if [ "$keep_existing_conf" = "true" ]; then
        # Переустанавливаем бинарник для ветки из существующего конфига без повторного запроса параметров
        SNELL_VERSION_CHOICE=$(get_conf_snell_version "$SNELL_CONF_FILE" 2>/dev/null)
        case "$SNELL_VERSION_CHOICE" in
            v4|v5|v6) ;;
            *)
                echo -e "${YELLOW}Не удалось определить ветку версии из текущего конфига. Выберите версию для переустановки вручную.${RESET}"
                select_snell_version
                ;;
        esac
        # Читаем порт, PSK и прочие параметры из текущего конфига для открытия порта в файрволе, запуска службы и вывода итоговой сводки
        PORT=$(get_snell_port)
        PSK=$(main_conf_value psk)
        IPV6_ENABLE=$(main_conf_value ipv6)
        if [ -z "$IPV6_ENABLE" ]; then
            # В конфиге v6 нет ключа ipv6, определяем по dns-ip-preference (только для отображения в итоговой сводке, сам конфиг не меняется)
            if [ "$(main_conf_value dns-ip-preference)" = "ipv4-only" ]; then
                IPV6_ENABLE="false"
            else
                IPV6_ENABLE="true"
            fi
        fi
        DNS=$(main_conf_value dns)
        [ -z "$DNS" ] && DNS="8.8.8.8"
        if [ -z "$PORT" ] || [ -z "$PSK" ]; then
            echo -e "${RED}В существующей конфигурации отсутствует порт или PSK (возможно, файл поврежден). Выберите чистую установку.${RESET}"
            return 1
        fi
        # Наличие сокет-юнита на диске означает, что ранее было включено управление выходом — сохраняем этот режим
        # (скрипт инициализации netns не перезаписываем: для этого нужны параметры интерфейса/подсети, а на диске они уже верные)
        if [ -f "$SYSTEMD_SOCKET_FILE" ]; then
            EGRESS_FEATURE_ENABLED="true"
            # Восстанавливаем имена интерфейса и пространства имен из скрипта инициализации netns на диске для сокет-юнита и итоговой сводки
            if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
                local keep_ns keep_iface
                keep_ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
                [ -n "$keep_ns" ] && EGRESS_NS="$keep_ns"
                keep_iface=$(grep -o 'oifname "[^"]*"' "${NETNS_SETUP_SCRIPT}" 2>/dev/null | head -n 1 | cut -d'"' -f2)
                [ -n "$keep_iface" ] && EGRESS_IFACE="$keep_iface"
            fi
        else
            EGRESS_FEATURE_ENABLED="false"
        fi
        echo -e "${GREEN}Текущие порт и PSK будут сохранены; выполняется переустановка бинарного файла и обновление юнитов службы.${RESET}"
    else
        # Выбор версии Snell
        select_snell_version
    fi

    ensure_cmds curl unzip || exit 1

    # Если на сервере всё ещё старая одноверсионная структура, сначала мигрируем на версионированную, чтобы не затереть используемый бинарник
    migrate_snell_binary_layout

    # Установка (или принудительная переустановка) бинарника выбранной ветки; остальные ветки остаются без изменений
    if ! install_snell_binary_for_version "$SNELL_VERSION_CHOICE" "true"; then
        echo -e "${RED}Ошибка установки Snell ${SNELL_VERSION_CHOICE}.${RESET}"
        exit 1
    fi

    # Ветка основного пользователя определяет, куда указывает симлинк snell-server
    update_snell_symlink "$SNELL_VERSION_CHOICE"

    if [ "$keep_existing_conf" != "true" ]; then
        get_user_port  # Запрос порта у пользователя
        get_dns # Запрос DNS-серверов у пользователя
        get_ipv6_choice # Включение/отключение IPv6
        # Для v6 требуется дополнительно выбрать mode и dns-ip-preference
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            configure_snell_v6_options
        fi
        get_egress_feature_choice
        get_egress_settings
        check_egress_dependencies
        PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

        # Создание каталога пользовательских конфигураций
        mkdir -p ${SNELL_CONF_DIR}/users

        # Сохранение конфигурации основного пользователя в каталоге users
        write_snell_conf "${SNELL_CONF_FILE}" "${LISTEN_ADDR}" "${PORT}" "${PSK}" "${IPV6_ENABLE}" "${DNS}" "${SNELL_VERSION_CHOICE}"
    fi

    write_main_systemd_service

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        # При сохранении конфигурации используем существующий скрипт инициализации netns на диске;
        # так как snell.service только что был перезаписан обычной версией, нужно заново записать юниты для режима сокета (адрес прослушивания берется из конфига)
        if [ "$keep_existing_conf" != "true" ]; then
            write_snell_netns_service
            write_snell_socket_service_units "$PORT" "$LISTEN_ADDR"
        else
            write_snell_socket_service_units "$PORT"
        fi
    fi

    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}Не удалось перезагрузить конфигурацию Systemd.${RESET}"
        exit 1
    fi

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        systemctl enable snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось включить автозапуск snell-netns.${RESET}"
            exit 1
        fi

        systemctl start snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось запустить snell-netns.${RESET}"
            exit 1
        fi

        if ! start_egress_runtime "$PORT"; then
            exit 1
        fi

        echo -e "${GREEN}Сокет snell.socket запущен, служба snell будет подниматься по требованию (при первом подключении)${RESET}"
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            echo -e "${YELLOW}В v6 удален режим проксирования QUIC; на клиенте укажите version = 6 и такой же mode, как на сервере.${RESET}"
        else
            echo -e "${YELLOW}На клиенте рекомендуется использовать version = 4 (версия v5 сильнее зависит от прохождения QUIC/UDP).${RESET}"
        fi
    else
        systemctl stop snell.socket 2>/dev/null
        systemctl disable snell.socket 2>/dev/null
        systemctl stop snell-netns 2>/dev/null
        systemctl disable snell-netns 2>/dev/null

        systemctl enable snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось включить автозапуск Snell при загрузке.${RESET}"
            exit 1
        fi

        if ! validate_snell_main_config; then
            exit 1
        fi

        systemctl start snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось запустить службу Snell.${RESET}"
            exit 1
        fi
    fi

    # Открытие порта в файрволе
    open_port "$PORT"

    # Вывод информации о конфигурации после завершения установки
    echo -e "\n${GREEN}Установка завершена! Ваша конфигурация:${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        echo -e "${YELLOW}Управление выходом: Включено (интерфейс ${EGRESS_IFACE}, пространство имен ${EGRESS_NS})${RESET}"
        echo -e "${YELLOW}Активация через сокет: snell.socket${RESET}"
    fi
    echo -e "${YELLOW}Порт прослушивания: ${PORT}${RESET}"
    echo -e "${YELLOW}Ключ PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}IPv6: ${IPV6_ENABLE}${RESET}"
    echo -e "${YELLOW}DNS-серверы: ${DNS}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"

    # Получение и отображение IP-адресов сервера
    echo -e "\n${GREEN}Информация об адресах сервера:${RESET}"
    
    # Получение IPv4-адреса
    IPV4_ADDR=$(get_public_ipv4)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4-адрес: ${RESET}${IPV4_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # Получение IPv6-адреса
    IPV6_ADDR=$(get_public_ipv6)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6-адрес: ${RESET}${IPV6_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    # Вывод конфигурации в формате Surge
    echo -e "\n${GREEN}Формат конфигурации для Surge:${RESET}"
    local installed_version="$SNELL_VERSION_CHOICE"
    if [ ! -z "$IPV4_ADDR" ]; then
        generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV4" "$installed_version"
    fi
    
    if [ ! -z "$IPV6_ADDR" ]; then
        generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV6" "$installed_version"
    fi


    # Создание скрипта управления
    echo -e "${CYAN}Установка скрипта управления...${RESET}"
    if write_management_script; then
        echo -e "\n${GREEN}Скрипт управления успешно установлен!${RESET}"
        echo -e "${YELLOW}Введите 'snell' в терминале для вызова меню управления.${RESET}"
        echo -e "${YELLOW}Примечание: запускайте через sudo snell или от имени пользователя root.${RESET}\n"
    else
        echo -e "\n${RED}Не удалось создать скрипт управления.${RESET}"
        echo -e "${YELLOW}Вы можете управлять Snell, запуская исходный скрипт напрямую.${RESET}\n"
    fi
}

# Управление выходом для уже установленного Snell v5/v6
configure_v5_egress_control() {
    echo -e "${CYAN}=============== Настройка управления выходом v5/v6 ===============${RESET}"

    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}Snell не обнаружен, сначала выполните установку.${RESET}"
        return 1
    fi

    # Управление выходом применяется к основной службе, поэтому проверяем ветку основного конфига
    local installed_version
    installed_version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    if [ "$installed_version" != "v5" ] && [ "$installed_version" != "v6" ]; then
        echo -e "${YELLOW}Основной пользователь сейчас использует ${installed_version}. Эта функция поддерживается только в Snell v5/v6.${RESET}"
        return 1
    fi

    local main_port
    main_port=$(get_snell_port)
    if [ -z "$main_port" ]; then
        echo -e "${RED}Не найден порт в основной конфигурации, проверьте ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    local egress_enabled="false"
    if systemctl is-enabled snell.socket &> /dev/null || systemctl is-active snell.socket &> /dev/null; then
        egress_enabled="true"
    fi

    echo -e "${GREEN}Версия основного пользователя: Snell ${installed_version}${RESET}"
    echo -e "${GREEN}Основной порт: ${main_port}${RESET}"
    if [ "$egress_enabled" = "true" ]; then
        echo -e "${YELLOW}Текущий статус управления выходом: Включено${RESET}"
    else
        echo -e "${YELLOW}Текущий статус управления выходом: Не включено${RESET}"
    fi

    echo -e "${GREEN}1.${RESET} Включить / обновить управление выходом"
    echo -e "${GREEN}2.${RESET} Отключить управление выходом (вернуться к классическому режиму)"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Введите вариант [0-2]: " egress_manage_choice

    case "$egress_manage_choice" in
        1)
            if router_active; then
                echo -e "${RED}Сейчас запущена маршрутизация по правилам: при переносе Snell в отдельное сетевое пространство (netns) маршрутизатор не сможет перехватывать его трафик. Сначала отключите маршрутизацию в пункте меню 11.${RESET}"
                return 1
            fi
            EGRESS_FEATURE_ENABLED="true"
            get_egress_settings
            check_egress_dependencies

            write_snell_netns_service
            write_snell_socket_service_units "$main_port"

            systemctl daemon-reload
            if ! systemctl enable snell-netns; then
                echo -e "${RED}Не удалось включить автозапуск snell-netns.${RESET}"
                return 1
            fi
            if ! systemctl start snell-netns; then
                echo -e "${RED}Не удалось запустить snell-netns, выполните для проверки: systemctl status snell-netns.service${RESET}"
                return 1
            fi

            if ! start_egress_runtime "$main_port"; then
                return 1
            fi

            echo -e "${GREEN}Управление выходом применено (интерфейс ${EGRESS_IFACE}, пространство имен ${EGRESS_NS}).${RESET}"
            if [ "$installed_version" = "v6" ]; then
                echo -e "${YELLOW}В v6 удален режим проксирования QUIC; на клиенте укажите version = 6 и такой же mode, как на сервере.${RESET}"
            else
                echo -e "${YELLOW}На клиенте рекомендуется использовать version = 4 (версия v5 сильнее зависит от прохождения QUIC/UDP).${RESET}"
            fi
            echo -e "${YELLOW}Справка: snell.socket прослушивает порт, служба snell.service запустится автоматически при первом подключении.${RESET}"
            ;;
        2)
            systemctl stop snell.socket 2>/dev/null
            systemctl disable snell.socket 2>/dev/null
            systemctl stop snell-netns 2>/dev/null
            systemctl disable snell-netns 2>/dev/null

            write_main_systemd_service

            rm -f ${SYSTEMD_SOCKET_FILE}
            rm -f ${SYSTEMD_NETNS_FILE}

            systemctl daemon-reload
            systemctl enable snell
            if ! validate_snell_main_config; then
                return 1
            fi
            systemctl restart snell

            echo -e "${GREEN}Управление выходом отключено, восстановлен классический режим.${RESET}"
            ;;
        0)
            echo -e "${CYAN}Возврат в меню.${RESET}"
            ;;
        *)
            echo -e "${RED}Пожалуйста, введите корректный вариант [0-2]${RESET}"
            ;;
    esac
}


# Удаление Snell
uninstall_snell() {
    echo -e "${CYAN}Удаление Snell${RESET}"

    # Заодно удаляем маршрутизацию по правилам (sing-box): правила перехвата, службу и конфиги
    router_remove

    # Останавливаем и удаляем службы ShadowTLS, зависящие от бэкенда Snell, чтобы не оставлять висящие слушающие порты без бэкенда
    local snell_shadowtls_services
    snell_shadowtls_services=$(find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$snell_shadowtls_services" ]; then
        while IFS= read -r service_file; do
            [ -z "$service_file" ] && continue
            local service_name
            service_name=$(basename "$service_file")
            local shadowtls_port
            shadowtls_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            echo -e "${YELLOW}Остановка службы ShadowTLS (${service_name})${RESET}"
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service_file"
            if [ -n "$shadowtls_port" ]; then
                close_port "$shadowtls_port"
            fi
        done <<< "$snell_shadowtls_services"
    fi

    # Остановка и отключение основных служб
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    systemctl stop snell.socket 2>/dev/null
    systemctl disable snell.socket 2>/dev/null
    systemctl stop snell-netns 2>/dev/null
    systemctl disable snell-netns 2>/dev/null

    # Остановка и отключение всех дополнительных пользовательских служб
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}Остановка пользовательской службы (порт: $port)${RESET}"
                    systemctl stop "snell-${port}" 2>/dev/null
                    systemctl disable "snell-${port}" 2>/dev/null
                    rm -f "${SYSTEMD_DIR}/snell-${port}.service"
                    close_port "$port"
                fi
            fi
        done
    fi

    # Очистка остатков управления выходом: netns / veth / таблицы nft / правила FORWARD / /etc/netns (при отсутствии тихо пропускаются)
    # Имя пространства имен берется из скрипта инициализации netns (пользователь мог задать свое), иначе используется значение по умолчанию
    local egress_ns="${EGRESS_NS:-snell-egress}"
    if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
        local script_ns
        script_ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
        [ -n "$script_ns" ] && egress_ns="$script_ns"
    fi
    if command -v ip >/dev/null 2>&1; then
        [ -n "$egress_ns" ] && ip netns del "$egress_ns" 2>/dev/null || true
        # Удаление пары veth (при удалении одного конца второй исчезает автоматически)
        ip link del veth-host 2>/dev/null || true
    fi
    if [ -n "$egress_ns" ]; then
        rm -rf "/etc/netns/${egress_ns}" 2>/dev/null
    fi
    if command -v nft >/dev/null 2>&1; then
        # Точечное удаление двух таблиц, созданных этим скриптом (см. скрипт инициализации netns)
        nft delete table ip snell_nat 2>/dev/null || true
        nft delete table inet snell_filter 2>/dev/null || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        # Скрипт netns добавлял только правила FORWARD с участием veth-host; удаляем их по одному из текущих правил системы
        local fwd_del
        while fwd_del=$(iptables -S FORWARD 2>/dev/null | grep -- '-A FORWARD.*veth-host' | head -n 1 | sed 's/^-A /-D /'); do
            [ -z "$fwd_del" ] && break
            # shellcheck disable=SC2086
            iptables $fwd_del 2>/dev/null || break
        done
    fi

    # Удаление файлов служб (включая preset от старого скрипта для CentOS)
    rm -f /lib/systemd/system/snell.service
    rm -f ${SYSTEMD_SERVICE_FILE}
    rm -f ${SYSTEMD_SOCKET_FILE}
    rm -f ${SYSTEMD_NETNS_FILE}
    rm -f ${NETNS_SETUP_SCRIPT}
    rm -f /usr/lib/systemd/system-preset/90-snell.preset

    # Удаление бинарных файлов всех веток, симлинка и резервных копий, оставшихся после обновлений
    local version
    for version in $SNELL_ALL_VERSIONS; do
        rm -f "$(snell_binary_for_version "$version")"
    done
    rm -f "${INSTALL_DIR}"/snell-server-v[456].bak.*
    rm -f ${INSTALL_DIR}/snell-server
    rm -rf ${SNELL_CONF_DIR}
    rm -f /usr/local/bin/snell  # Удаление скрипта управления

    if ! find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-*.service" 2>/dev/null | grep -q .; then
        rm -f /usr/local/bin/shadow-tls
    fi

    # Системный пользователь и группа snell по умолчанию сохраняются, удаляем только после подтверждения
    echo -e "${YELLOW}Удалить также системного пользователя и группу snell? [y/N]${RESET}"
    local del_snell_user
    if ! read -r del_snell_user; then
        del_snell_user=""
    fi
    if [[ "$del_snell_user" =~ ^[Yy]$ ]]; then
        if getent passwd snell >/dev/null 2>&1; then
            userdel snell 2>/dev/null && echo -e "${GREEN}Системный пользователь snell удален${RESET}"
        fi
        if getent group snell >/dev/null 2>&1; then
            groupdel snell 2>/dev/null && echo -e "${GREEN}Группа пользователей snell удалена${RESET}"
        fi
    else
        echo -e "${YELLOW}Системный пользователь и группа snell сохранены.${RESET}"
    fi

    # Перезагрузка конфигурации systemd
    systemctl daemon-reload

    echo -e "${GREEN}Snell и все пользовательские конфигурации успешно удалены${RESET}"
}

# Перезапуск Snell
restart_snell() {
    echo -e "${YELLOW}Перезапуск всех служб Snell...${RESET}"

    if ! validate_snell_main_config; then
        echo -e "${RED}Перезапуск отменен во избежание сбоя snell-server из-за отсутствия конфигурации.${RESET}"
        return 1
    fi
    
    # Если используется socket activation, сначала перезапускаем сокет и netns, а затем саму службу
    if systemctl list-unit-files | grep -q '^snell.socket'; then
        systemctl restart snell-netns 2>/dev/null
        systemctl restart snell.socket 2>/dev/null
    fi

    # Перезапуск основной службы
    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Основная служба Snell успешно перезапущена.${RESET}"
    else
        echo -e "${RED}Не удалось перезапустить основную службу Snell.${RESET}"
    fi

    # Перезапуск всех дополнительных пользовательских служб
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}Перезапуск пользовательской службы (порт: $port)${RESET}"
                    systemctl restart "snell-${port}" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}Пользовательская служба (порт: $port) успешно перезапущена.${RESET}"
                    else
                        echo -e "${RED}Не удалось перезапустить пользовательскую службу (порт: $port).${RESET}"
                    fi
                fi
            fi
        done
    fi
}
# Проверка и отображение статуса служб
check_and_show_status() {
    echo -e "\n${CYAN}=============== Проверка статуса служб ===============${RESET}"
    
    # Проверка статуса Snell
    if command -v snell-server &> /dev/null; then
        # Инициализация счетчиков и переменных потребления ресурсов
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0
        
        # Проверка статуса основной службы
        local main_available=false
        if systemctl is-active snell &> /dev/null; then
            main_available=true
        elif systemctl is-active snell.socket &> /dev/null; then
            # При использовании socket activation служба может запускаться по требованию
            main_available=true
        fi

        if [ "$main_available" = "true" ]; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            
            # Получение потребления ресурсов основной службой
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null)
                local cpu=$(ps -o %cpu= -p $main_pid 2>/dev/null)
                if [ ! -z "$mem" ]; then
                    total_snell_memory=$((total_snell_memory + mem))
                fi
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        
        # Проверка статуса дополнительных пользователей
        if [ -d "${SNELL_CONF_DIR}/users" ]; then
            for user_conf in "${SNELL_CONF_DIR}/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            
                            # Получение потребления ресурсов пользовательской службой
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null)
                                local cpu=$(ps -o %cpu= -p $user_pid 2>/dev/null)
                                if [ ! -z "$mem" ]; then
                                    total_snell_memory=$((total_snell_memory + mem))
                                fi
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
                
# Отображение статуса Snell
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc)
        printf "${GREEN}Snell установлен${RESET}  ${YELLOW}CPU: %.2f%%${RESET}  ${YELLOW}Память: %.2f MB${RESET}  ${GREEN}Активно: ${running_count}/${user_count}${RESET}\n" "$total_snell_cpu" "$total_snell_memory_mb"

        # Установленные ветки и количество служб, использующих каждую из них
        local installed_channels channel channel_summary=""
        installed_channels=$(list_installed_snell_versions)
        if [ -n "$installed_channels" ]; then
            for channel in $installed_channels; do
                channel_summary="${channel_summary}${channel}(×$(list_services_using_version "$channel" | grep -c .)) "
            done
            echo -e "${GREEN}Установленные ветки:${RESET}  ${YELLOW}${channel_summary}${RESET}"
        fi
    else
        echo -e "${YELLOW}Snell не установлен${RESET}"
    fi
    
    # Проверка статуса ShadowTLS
    if [ -f "/usr/local/bin/shadow-tls" ]; then
        # Инициализация счетчиков и ресурсов служб ShadowTLS
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        declare -A processed_ports
        
        # Проверка служб ShadowTLS для Snell
        local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
        if [ ! -z "$snell_services" ]; then
            while IFS= read -r service_file; do
                local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
                
                # Проверяем, не обрабатывался ли уже этот порт
                if [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    stls_total=$((stls_total + 1))
                    if systemctl is-active "shadowtls-snell-${port}" &> /dev/null; then
                        stls_running=$((stls_running + 1))
                        
                        # Получение потребления ресурсов службой ShadowTLS
                        local stls_pid=$(systemctl show -p MainPID "shadowtls-snell-${port}" | cut -d'=' -f2)
                        if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                            local mem=$(ps -o rss= -p $stls_pid 2>/dev/null)
                            local cpu=$(ps -o %cpu= -p $stls_pid 2>/dev/null)
                            if [ ! -z "$mem" ]; then
                                total_stls_memory=$((total_stls_memory + mem))
                            fi
                            if [ ! -z "$cpu" ]; then
                                total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                            fi
                        fi
                    fi
                fi
            done <<< "$snell_services"
        fi
        
        # Отображение статуса ShadowTLS
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS установлен${RESET}  ${YELLOW}CPU: %.2f%%${RESET}  ${YELLOW}Память: %.2f MB${RESET}  ${GREEN}Активно: ${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS не установлен${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS не установлен${RESET}"
    fi

    # Маршрутизация по правилам (отображается только если включалась ранее)
    if router_active; then
        echo -e "${GREEN}Маршрутизация активна${RESET}  ${YELLOW}правил: $(jq '.rules | length' "$ROUTER_STATE" 2>/dev/null || echo 0)${RESET}"
    elif router_installed; then
        echo -e "${YELLOW}Маршрутизация отключена${RESET}"
    fi
    
    echo -e "${CYAN}============================================${RESET}\n"
}

# Просмотр конфигурации
view_snell_config() {
    echo -e "${GREEN}Информация о конфигурации Snell:${RESET}"
    echo -e "${CYAN}================================${RESET}"
    
    # Каждый пользователь может использовать свою ветку; здесь выводим только список установленных на сервере
    local installed_channels
    installed_channels=$(list_installed_snell_versions)
    if [ -n "$installed_channels" ]; then
        echo -e "${YELLOW}Установленные ветки: ${installed_channels}${RESET}"
    else
        echo -e "${YELLOW}Установленные ветки Snell не обнаружены${RESET}"
    fi
    
    # Получение IPv4-адреса
    IPV4_ADDR=$(get_public_ipv4)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4-адрес: ${RESET}${IPV4_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    # Получение IPv6-адреса
    IPV6_ADDR=$(get_public_ipv6)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6-адрес: ${RESET}${IPV6_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    # Проверка, удалось ли получить хотя бы один IP-адрес
    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${RED}Не удалось получить внешний IP-адрес, проверьте подключение к сети.${RESET}"
        return
    fi
    
    echo -e "\n${YELLOW}=== Список конфигураций пользователей ===${RESET}"
    
    # Отображение конфигурации основного пользователя
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ]; then
        echo -e "\n${GREEN}Конфигурация основного пользователя:${RESET}"
        local main_port=$(grep -E '^listen' "$main_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local main_psk=$(grep -E '^psk' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_version=$(get_conf_snell_version "$main_conf")

        echo -e "${YELLOW}Порт: ${main_port}${RESET}"
        echo -e "${YELLOW}Версия: Snell ${main_version}${RESET}"
        echo -e "${YELLOW}PSK: ${main_psk}${RESET}"
        [ -n "$main_ipv6" ] && echo -e "${YELLOW}IPv6: ${main_ipv6}${RESET}"
        [ -n "$main_mode" ] && echo -e "${YELLOW}Режим (mode): ${main_mode}${RESET}"
        [ -n "$main_dns_pref" ] && echo -e "${YELLOW}Приоритет DNS-резолвинга: ${main_dns_pref}${RESET}"
        echo -e "${YELLOW}DNS: ${main_dns}${RESET}"
        
        echo -e "\n${GREEN}Формат конфигурации для Surge:${RESET}"
        if [ ! -z "$IPV4_ADDR" ]; then
            generate_surge_config "$IPV4_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV4" "$main_version"
        fi
        if [ ! -z "$IPV6_ADDR" ]; then
            generate_surge_config "$IPV6_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV6" "$main_version"
        fi
    fi
    
    # Отображение конфигураций остальных пользователей
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local user_port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                local user_psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_version=$(get_conf_snell_version "$user_conf")

                echo -e "\n${GREEN}Конфигурация пользователя (порт: ${user_port}):${RESET}"
                echo -e "${YELLOW}Версия: Snell ${user_version}${RESET}"
                echo -e "${YELLOW}PSK: ${user_psk}${RESET}"
                [ -n "$user_ipv6" ] && echo -e "${YELLOW}IPv6: ${user_ipv6}${RESET}"
                [ -n "$user_mode" ] && echo -e "${YELLOW}Режим (mode): ${user_mode}${RESET}"
                [ -n "$user_dns_pref" ] && echo -e "${YELLOW}Приоритет DNS-резолвинга: ${user_dns_pref}${RESET}"
                echo -e "${YELLOW}DNS: ${user_dns}${RESET}"
                
                echo -e "\n${GREEN}Формат конфигурации для Surge:${RESET}"
                if [ ! -z "$IPV4_ADDR" ]; then
                    generate_surge_config "$IPV4_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV4" "$user_version"
                fi
                if [ ! -z "$IPV6_ADDR" ]; then
                    generate_surge_config "$IPV6_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV6" "$user_version"
                fi
            fi
        done
    fi
    
    # Если установлен ShadowTLS, отображаем комбинированную конфигурацию (версия определяется по ветке соответствующего бэкенд-порта)
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}=== Комбинированная конфигурация с ShadowTLS ===${RESET}"
        declare -A processed_ports
        while IFS= read -r service_file; do
            local exec_line=$(grep "ExecStart=" "$service_file")
            local stls_port=$(printf '%s\n' "$exec_line" | sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' | head -n 1)
            local stls_password=$(printf '%s\n' "$exec_line" | sed -n 's/.*--password \([^ ][^ ]*\).*/\1/p' | head -n 1)
            local stls_domain=$(printf '%s\n' "$exec_line" | sed -n 's/.*--tls \([^ ][^ ]*\).*/\1/p' | head -n 1)
            local snell_port=$(printf '%s\n' "$exec_line" | sed -n 's/.*--server 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' | head -n 1)
            # Поиск psk
            local psk=""
            if [ -f "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            elif [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ] && [ "$snell_port" = "$(get_snell_port)" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            fi
            # Предотвращение дублирования
            if [ -z "$snell_port" ] || [ -z "$psk" ] || [ -n "${processed_ports[$snell_port]}" ]; then
                continue
            fi
            processed_ports[$snell_port]=1
            local snell_version=$(get_port_snell_version "$snell_port")
            local snell_mode=$(get_snell_mode "$(snell_conf_for_port "$snell_port")")
            if [ "$snell_port" = "$(get_snell_port)" ]; then
                echo -e "\n${GREEN}Конфигурация ShadowTLS основного пользователя:${RESET}"
            else
                echo -e "\n${GREEN}Конфигурация ShadowTLS пользователя (порт: ${snell_port}):${RESET}"
            fi
            echo -e "  - Порт Snell: ${snell_port}"
            echo -e "  - PSK: ${psk}"
            echo -e "  - Порт прослушивания ShadowTLS: ${stls_port}"
            echo -e "  - Пароль ShadowTLS: ${stls_password}"
            echo -e "  - Домен SNI ShadowTLS: ${stls_domain}"
            echo -e "  - Версия ShadowTLS: 3"
            echo -e "  - Версия Snell: ${snell_version}"
            echo -e "\n${GREEN}Формат конфигурации для Surge:${RESET}"
            if [ ! -z "$IPV4_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
            if [ ! -z "$IPV6_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
        done <<< "$snell_services"
    fi
    
    echo -e "\n${YELLOW}Примечание:${RESET}"
    echo -e "1. Протокол Snell поддерживается только в клиенте Surge"
    echo -e "2. При необходимости замените адрес сервера в строке конфигурации на ваш актуальный адрес/домен"
    read -p "Нажмите любую клавишу для возврата в главное меню..."
}

# Обновление бинарного файла одной ветки до последней версии.
# Не меняет привязку пользователей к веткам, поэтому формат конфигов остается прежним; перезапускаются только службы, использующие эту ветку.
update_snell_channel() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    echo -e "\n${CYAN}=============== Обновление ветки Snell ${version} ===============${RESET}"
    echo -e "${GREEN}✓ Заменяется только бинарный файл ${version}, остальные ветки не затрагиваются${RESET}"
    echo -e "${GREEN}✓ Порты, ключи PSK и пользовательские конфигурации остаются без изменений${RESET}"

    local services
    services=$(list_services_using_version "$version")
    if [ -n "$services" ]; then
        echo -e "${YELLOW}Будут перезапущены: $(echo "$services" | tr '\n' ' ')${RESET}"
    else
        echo -e "${YELLOW}Сейчас ни одна служба не использует ветку ${version}, обновляется только бинарный файл${RESET}"
    fi

    # Создаем точки отката для конфигураций и бинарного файла
    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}Резервная копия конфигурации сохранена в: ${backup_dir}${RESET}"

    local backup_binary=""
    if [ -f "$target" ]; then
        backup_binary="${target}.bak.$(date +%Y%m%d_%H%M%S)"
        if cp -a "$target" "$backup_binary"; then
            echo -e "${GREEN}Исходный бинарный файл сохранен в: ${backup_binary}${RESET}"
        else
            echo -e "${YELLOW}Внимание: не удалось создать резервную копию бинарного файла, автоматический откат при сбое будет невозможен${RESET}"
            backup_binary=""
        fi
    fi

    if ! install_snell_binary_for_version "$version" "true"; then
        if [ -n "$backup_binary" ]; then
            cp -a "$backup_binary" "$target" && echo -e "${YELLOW}Выполнен откат к предыдущему бинарному файлу${RESET}"
        fi
        return 1
    fi

    # Если основной пользователь использует эту ветку, обновляем симлинк
    if [ "$(get_conf_snell_version "$SNELL_CONF_FILE")" = "$version" ]; then
        update_snell_symlink "$version"
    fi

    local service failed=""
    while IFS= read -r service; do
        [ -n "$service" ] || continue
        if [ "$service" = "snell" ] && ! validate_snell_main_config; then
            failed="${failed}${service} "
            continue
        fi
        echo -e "${CYAN}Перезапуск ${service}...${RESET}"
        if ! restart_and_verify_service "$service"; then
            failed="${failed}${service} "
        fi
    done <<< "$services"

    if [ -n "$failed" ]; then
        echo -e "\n${RED}Следующие службы не смогли нормально запуститься: ${failed}${RESET}"
        if [ -n "$backup_binary" ]; then
            echo -e "${YELLOW}Откат бинарного файла ветки ${version}...${RESET}"
            cp -a "$backup_binary" "$target"
            for service in $failed; do
                systemctl restart "$service" 2>/dev/null
            done
            echo -e "${YELLOW}Откат выполнен. Резервная копия конфигурации сохранена в ${backup_dir}${RESET}"
        fi
        return 1
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Обновление ветки Snell ${version} завершено ($(get_channel_binary_version "$version"))${RESET}"
    echo -e "${GREEN}✓ Остальные ветки и все конфигурации не затронуты${RESET}"
    echo -e "${YELLOW}Каталог резервной копии конфигурации: ${backup_dir}${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    # Точка отката больше не нужна, удаляем её, чтобы не захламлять ${INSTALL_DIR}
    [ -n "$backup_binary" ] && rm -f "$backup_binary"
    return 0
}

# Переключение одной конфигурации на целевую ветку: подготовка бинарника -> миграция параметров конфига -> обновление юнита -> перезапуск (с автооткатом при сбое)
switch_conf_to_version() {
    local conf_file="$1"
    local target_version="$2"
    local port service unit current_version

    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}Конфигурация не существует: ${conf_file}${RESET}"
        return 1
    fi

    current_version=$(get_conf_snell_version "$conf_file")
    port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
    if [ -z "$port" ]; then
        echo -e "${RED}Не удалось определить порт прослушивания из ${conf_file}${RESET}"
        return 1
    fi

    if [ "$current_version" = "$target_version" ]; then
        echo -e "${YELLOW}Порт ${port} уже использует ветку ${target_version}, переключение не требуется${RESET}"
        return 0
    fi

    service=$(snell_service_for_port "$port")
    if [ "$service" = "snell" ]; then
        unit="$SYSTEMD_SERVICE_FILE"
    else
        unit="${SYSTEMD_DIR}/snell-${port}.service"
    fi

    if [ ! -f "$unit" ]; then
        echo -e "${RED}Файл службы не найден: ${unit}${RESET}"
        return 1
    fi

    if [ "$target_version" = "v6" ] && ! check_conf_psk_for_v6 "$conf_file"; then
        return 1
    fi

    if ! ensure_snell_binary "$target_version"; then
        return 1
    fi

    # Параметры mode / dns-ip-preference для v6 выбираются индивидуально для этого пользователя
    if [ "$target_version" = "v6" ]; then
        configure_snell_v6_options "$conf_file"
    fi

    local stamp backup_conf backup_unit
    stamp=$(date +%Y%m%d_%H%M%S)
    backup_conf=$(snell_backup_path "$conf_file" "$stamp")
    if [ -z "$backup_conf" ] || ! cp -a "$conf_file" "$backup_conf"; then
        echo -e "${RED}Не удалось создать резервную копию конфигурации, переключение прервано${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 1
    fi
    backup_unit=$(snell_backup_path "$unit" "$stamp")
    cp -a "$unit" "$backup_unit" 2>/dev/null || backup_unit=""

    echo -e "${CYAN}Переключение порта ${port} с ${current_version} на ${target_version}...${RESET}"

    migrate_snell_conf_for_version "$conf_file" "$target_version"
    point_service_unit_to_version "$unit" "$target_version"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$target_version"
    fi

    if restart_and_verify_service "$service"; then
        echo -e "${GREEN}✓ Порт ${port} переключен на Snell ${target_version}${RESET}"
        echo -e "${YELLOW}На клиенте измените параметр version для этого узла на ${target_version#v}${RESET}"
        if [ "$target_version" = "v6" ]; then
            echo -e "${YELLOW}и добавьте mode = $(get_snell_mode "$conf_file")${RESET}"
        fi
        echo -e "${YELLOW}Резервная копия для отката: ${backup_conf}${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 0
    fi

    echo -e "${RED}После переключения служба не запустилась, выполняется откат к ${current_version}...${RESET}"
    cat "$backup_conf" > "$conf_file"
    [ -n "$backup_unit" ] && cat "$backup_unit" > "$unit"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$current_version"
    fi
    if restart_and_verify_service "$service"; then
        echo -e "${YELLOW}Выполнен откат к ${current_version}, работа службы восстановлена${RESET}"
    else
        echo -e "${RED}После отката служба всё ещё не запущена, проверьте вручную: systemctl status ${service}${RESET}"
    fi
    SNELL_V6_OPTIONS_SET="false"
    return 1
}

# Поочередная проверка наличия обновлений для всех установленных веток
update_installed_channels() {
    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}Установленные ветки не обнаружены${RESET}"
        return 1
    fi

    local version current latest updated=0
    for version in $installed; do
        current=$(get_channel_binary_version "$version")
        latest=$(resolve_latest_version_for_channel "$version")
        echo -e "\n${CYAN}--- Ветка ${version} ---${RESET}"
        echo -e "${YELLOW}Текущая: ${current:-неизвестно}   Последняя: ${latest:-неизвестно}${RESET}"

        if [ -z "$latest" ]; then
            echo -e "${YELLOW}Не удалось получить номер последней версии, пропуск${RESET}"
            continue
        fi
        local found="Обнаружена новая версия"
        if [ -n "$current" ] && version_greater_equal "$current" "$latest"; then
            # При совпадении номеров версий дополнительно сверяем саму сборку: rc-выпуски v6 тоже сообщают версию v6.0.0
            if [ "$(snell_version_sort_key "$current")" != "$(snell_version_sort_key "$latest")" ]; then
                echo -e "${GREEN}Установлена последняя версия${RESET}"
                continue
            fi
            echo -e "${CYAN}Номера версий совпадают, сверяем контрольную сумму с официальной сборкой ${latest}...${RESET}"
            snell_binary_differs_from_release "$version" "$latest"
            case $? in
                1) echo -e "${GREEN}Установлена последняя версия${RESET}"; continue ;;
                2) echo -e "${YELLOW}Не удалось скачать официальную сборку ${latest} для сверки, считаем версию актуальной${RESET}"; continue ;;
            esac
            echo -e "${YELLOW}Локальный бинарный файл отличается от текущей официальной сборки ${latest} (например, установлена предрелизная версия до выхода финальной)${RESET}"
            found="Доступна обновленная официальная сборка"
        fi

        echo -e "${CYAN}${found}. Обновить ветку ${version}? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            update_snell_channel "$version" && updated=$((updated + 1))
        else
            echo -e "${CYAN}Ветка ${version} пропущена${RESET}"
        fi
    done

    echo -e "\n${GREEN}Проверка завершена, обновлено веток: ${updated}${RESET}"
}

# Установка новой ветки: только сохраняет бинарный файл на диск, не затрагивая существующих пользователей
install_extra_channel() {
    local installed missing version
    installed=" $(list_installed_snell_versions) "
    missing=""
    for version in $SNELL_ALL_VERSIONS; do
        case "$installed" in
            *" ${version} "*) ;;
            *) missing="${missing}${version} " ;;
        esac
    done
    missing="${missing% }"

    if [ -z "$missing" ]; then
        echo -e "${GREEN}Все три ветки (v4 / v5 / v6) уже установлены${RESET}"
        return 0
    fi

    echo -e "\n${YELLOW}Ещё не установленные ветки: ${missing}${RESET}"
    echo -e "${CYAN}После установки их можно назначать конкретным портам в «Управлении пользователями» или через «Переключить ветку» в этом меню${RESET}"
    local idx=1
    local options=()
    for version in $missing; do
        echo -e "${GREEN}${idx}.${RESET} Установить Snell ${version}"
        options+=("$version")
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} Назад"

    read -rp "Введите вариант [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#options[@]}" ]; then
        echo -e "${RED}Некорректный выбор${RESET}"
        return 1
    fi

    local target="${options[$((pick - 1))]}"
    if install_snell_binary_for_version "$target" "true"; then
        echo -e "${GREEN}✓ Snell ${target} готов к работе, существующие службы не затронуты${RESET}"
    else
        return 1
    fi
}

# Переключение ветки, используемой конкретным пользователем (включая основного)
switch_user_channel() {
    local conf_file port version
    local confs=()
    local labels=()

    if [ -f "$SNELL_CONF_FILE" ]; then
        port=$(grep -E '^listen' "$SNELL_CONF_FILE" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        version=$(get_conf_snell_version "$SNELL_CONF_FILE")
        confs+=("$SNELL_CONF_FILE")
        labels+=("Основной пользователь (порт ${port}) — сейчас: ${version}")
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            [ -f "$conf_file" ] || continue
            case "$conf_file" in
                *snell-main.conf) continue ;;
            esac
            port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            [ -n "$port" ] || continue
            version=$(get_conf_snell_version "$conf_file")
            confs+=("$conf_file")
            labels+=("Пользователь (порт ${port}) — сейчас: ${version}")
        done
    fi

    if [ "${#confs[@]}" -eq 0 ]; then
        echo -e "${RED}Нет доступных пользователей для переключения${RESET}"
        return 1
    fi

    echo -e "\n${YELLOW}=== Выберите пользователя для смены ветки ===${RESET}"
    local idx=1
    for label in "${labels[@]}"; do
        echo -e "${GREEN}${idx}.${RESET} ${label}"
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} Назад"

    read -rp "Введите вариант [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#confs[@]}" ]; then
        echo -e "${RED}Некорректный выбор${RESET}"
        return 1
    fi

    local selected="${confs[$((pick - 1))]}"
    local current
    current=$(get_conf_snell_version "$selected")

    echo -e "\n${YELLOW}=== Выберите целевую ветку (текущая: ${current}) ===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Введите вариант [0-3]: " target_pick

    local target=""
    case "$target_pick" in
        1) target="v4" ;;
        2) target="v5" ;;
        3)
            target="v6"
            snell_v6_notes
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}Некорректный выбор${RESET}"; return 1 ;;
    esac

    switch_conf_to_version "$selected" "$target"
}

# Меню управления версиями Snell (бывшее «Обновить Snell»)
check_snell_update() {
    echo -e "\n${CYAN}=============== Управление версиями Snell ===============${RESET}"

    # Сначала мигрируем со старой одноверсионной структуры, иначе список по веткам ниже будет пустым
    migrate_snell_binary_layout

    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}Не обнаружено ни одной установленной ветки Snell. Сначала выполните установку.${RESET}"
        return 1
    fi

    echo -e "${YELLOW}Установленные ветки:${RESET}"
    local version svc_count svc_list
    for version in $installed; do
        svc_list=$(list_services_using_version "$version")
        svc_count=$(echo "$svc_list" | grep -c .)
        echo -e "  ${GREEN}${version}${RESET}  версия: $(get_channel_binary_version "$version")  используется службами: ${svc_count}"
    done

    echo -e "\n${GREEN}1.${RESET} Проверить и обновить установленные ветки"
    echo -e "${GREEN}2.${RESET} Установить дополнительную ветку (только скачать бинарник, без влияния на текущих пользователей)"
    echo -e "${GREEN}3.${RESET} Переключить ветку для конкретного пользователя"
    echo -e "${GREEN}0.${RESET} Назад"

    read -rp "Введите вариант [0-3]: " manage_choice
    case "$manage_choice" in
        1) update_installed_channels ;;
        2) install_extra_channel ;;
        3) switch_user_channel ;;
        0|"") echo -e "${CYAN}Возврат в меню${RESET}" ;;
        *) echo -e "${RED}Пожалуйста, введите корректный вариант [0-3]${RESET}" ;;
    esac
}

# Обновление скрипта
update_script() {
    echo -e "${CYAN}Проверка обновлений скрипта...${RESET}"
    
    # Создание временного файла
    local TMP_SCRIPT
    TMP_SCRIPT=$(mktemp)

    # Скачивание последней версии (с проверкой целостности)
    if fetch_verified_script "$SNELL_SCRIPT_URL" "$TMP_SCRIPT"; then
        # Получение нового номера версии
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)

        # Проверка корректности формата версии во избежание ошибочного обновления при скачивании некорректного файла
        if ! [[ "$new_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo -e "${RED}Некорректный формат номера версии в скачанном скрипте, обновление прервано${RESET}"
            rm -f "$TMP_SCRIPT"
            return 1
        fi
        
        echo -e "${YELLOW}Текущая версия: ${current_version}${RESET}"
        echo -e "${YELLOW}Последняя версия: ${new_version}${RESET}"
        
        # Сравнение номеров версий
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${CYAN}Обновить скрипт до новой версии? [y/N]${RESET}"
            read -r choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                # Получение полного пути к текущему скрипту
                SCRIPT_PATH=$(readlink -f "$0")
                
                # Резервное копирование текущего скрипта
                cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                
                # Замена скрипта новой версией
                mv "$TMP_SCRIPT" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                
                echo -e "${GREEN}Скрипт обновлен до последней версии${RESET}"
                echo -e "${YELLOW}Резервная копия старого скрипта сохранена в: ${SCRIPT_PATH}.backup${RESET}"
                echo -e "${CYAN}Пожалуйста, запустите скрипт заново для использования новой версии${RESET}"
                exit 0
            else
                echo -e "${YELLOW}Обновление отменено${RESET}"
                rm -f "$TMP_SCRIPT"
            fi
        else
            echo -e "${GREEN}У вас уже установлена последняя версия скрипта${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}Не удалось скачать новую версию, проверьте подключение к сети${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# Начальная проверка при запуске
initial_check() {
    check_root
    # bc: используется для подсчета суммарного потребления CPU / памяти в статусе
    ensure_cmds curl bc || exit 1
    check_and_migrate_config
    # Миграция со старой одноверсионной структуры на раздельное хранение по веткам; если структура уже новая — ничего не делает
    if [ -e "${INSTALL_DIR}/snell-server" ]; then
        migrate_snell_binary_layout
    fi
    sync_existing_main_service_unit
    upgrade_management_script
}

# Выполнение начальной проверки
initial_check

# Скачивание дочернего скрипта во временный файл и его выполнение после проверки
run_remote_script() {   # <url> <название>
    local tmp_script
    tmp_script=$(mktemp) || return 1
    if fetch_verified_script "$1" "$tmp_script"; then
        bash "$tmp_script"
    else
        echo -e "${RED}Не удалось скачать или проверить ${2}, выполнение отменено.${RESET}"
    fi
    rm -f "$tmp_script"
}

# Управление пользователями (мультипользовательский режим)
setup_multi_user() {
    echo -e "${CYAN}Запуск скрипта управления пользователями...${RESET}"
    run_remote_script "${SNELL_RAW_BASE}/scripts/multi-user.sh" "скрипт управления пользователями"

    # После завершения дочернего скрипта управление автоматически вернется сюда
    echo -e "${GREEN}Операции управления пользователями завершены${RESET}"
    sleep 1  # Даем пользователю немного времени увидеть сообщение
}

# ── Изменение конфигурации: порт / PSK / DNS (основной и дополнительные пользователи) ──
# Значение конкретного ключа в конфиге (берется всё после первого =, чтобы символы = в base64 PSK не обрезались)
conf_value() {   # <conf> <key>
    grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | head -n 1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//'
}
conf_port() { conf_value "$1" listen | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p'; }

# Замена значения ключа в конфиге на новое (если ключа нет — добавляется в конец); перезапись в исходный файл с сохранением владельца и прав
conf_set() {   # <conf> <key> <value>
    local tmp rc
    tmp=$(mktemp) || return 1
    awk -v k="$2" -v v="$3" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" && !done { print k " = " v; done = 1; next }
        { print }
        END { if (!done) print k " = " v }
    ' "$1" > "$tmp" && cat "$tmp" > "$1"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# Сохранение состояния перед правкой: копируем конфиг и связанные юниты во временный каталог в /tmp для полного восстановления при сбое
_edit_backup_dir=""
edit_backup() {   # <файл>…
    local f
    _edit_backup_dir=$(mktemp -d /tmp/snell-edit.XXXXXX) || return 1
    for f in "$@"; do
        [ -e "$f" ] || continue
        mkdir -p "${_edit_backup_dir}$(dirname "$f")"
        cp -a "$f" "${_edit_backup_dir}${f}"
    done
}
edit_restore() {
    local f
    case "$_edit_backup_dir" in /tmp/snell-edit.*) ;; *) return 0 ;; esac
    while IFS= read -r f; do
        cp -a "${_edit_backup_dir}${f}" "$f"
    done < <(cd "$_edit_backup_dir" && find . -type f | sed 's|^\.||')
    edit_forget_backup
}
edit_forget_backup() {
    case "$_edit_backup_dir" in /tmp/snell-edit.*) rm -rf -- "${_edit_backup_dir:?}" ;; esac
    _edit_backup_dir=""
}

# Проверка, занят ли порт другой конфигурацией Snell
port_taken_by_snell() {   # <port> <исключаемый conf>
    local f
    for f in "$SNELL_CONF_FILE" "${SNELL_CONF_DIR}"/users/*.conf; do
        [ -f "$f" ] && [ "$f" != "$2" ] && [ "$(conf_port "$f")" = "$1" ] && return 0
    done
    return 1
}

edit_snell_port() {   # <conf> <service>
    local conf="$1" service="$2" old new listen host version ns
    old=$(conf_port "$conf")
    listen=$(conf_value "$conf" listen)
    # Хост-часть первого адреса (в v6 параметр listen может содержать несколько адресов через запятую)
    host=$(printf '%s' "$listen" | cut -d, -f1 | sed 's/:[0-9]*[[:space:]]*$//')
    while true; do
        read -rp "Новый порт (1-65535, нажмите Enter для отмены): " new || return 0
        [ -z "$new" ] && return 0
        if ! [[ "$new" =~ ^[0-9]+$ ]] || [ "$new" -lt 1 ] || [ "$new" -gt 65535 ]; then
            echo -e "${RED}Порт должен быть числом от 1 до 65535${RESET}"; continue
        fi
        [ "$new" = "$old" ] && { echo -e "${YELLOW}Совпадает с текущим портом${RESET}"; continue; }
        if port_taken_by_snell "$new" "$conf"; then
            echo -e "${RED}Порт ${new} уже используется другим пользователем Snell${RESET}"; continue
        fi
        if is_port_in_use "$new"; then
            echo -e "${RED}Порт ${new} сейчас занят другой программой:${RESET}"; show_port_occupier "$new"; continue
        fi
        break
    done

    local unit_dir="${SYSTEMD_DIR:?}"
    local stls_old="${unit_dir}/shadowtls-snell-${old}.service"
    local stls_new="${unit_dir}/shadowtls-snell-${new}.service"
    local new_conf="$conf" new_service="snell"
    version=$(get_conf_snell_version "$conf")
    if [ "$service" != "snell" ]; then
        new_conf="${SNELL_CONF_DIR:?}/users/snell-${new}.conf"; new_service="snell-${new}"
    fi
    local socket_mode=false
    [ "$service" = "snell" ] && systemctl is-enabled --quiet snell.socket 2>/dev/null && socket_mode=true
    edit_backup "$conf" "${unit_dir}/${service}.service" "$SYSTEMD_SOCKET_FILE" "$stls_old"

    # Сначала останавливаем службы, после внесения изменений запустим вместе
    [ -f "$stls_old" ] && systemctl stop "shadowtls-snell-${old}" 2>/dev/null
    if $socket_mode; then systemctl stop snell snell.socket 2>/dev/null; else systemctl stop "$service" 2>/dev/null; fi

    local ok=true
    conf_set "$conf" listen "$(listen_replace_port "$listen" "$old" "$new")" || ok=false
    if $ok && [ "$service" != "snell" ]; then
        # Дополнительный пользователь: имена конфига и юнита содержат номер порта
        systemctl disable "$service" 2>/dev/null
        if mv "$conf" "$new_conf"; then
            rm -f -- "${unit_dir}/snell-${old}.service"
            write_user_service_unit "$new" "$new_conf" "$version"
            [ -d "${unit_dir}/snell-${old}.service.d" ] && mv "${unit_dir}/snell-${old}.service.d" "${unit_dir}/snell-${new}.service.d"
            systemctl daemon-reload
            systemctl enable "$new_service" 2>/dev/null
        else
            ok=false
        fi
    fi
    if $ok && [ -f "$stls_old" ]; then
        # Стоящий перед ним ShadowTLS: меняем порт бэкенда на новый и переименовываем юнит соответственно
        systemctl disable "shadowtls-snell-${old}" 2>/dev/null
        if sed "s|--server 127.0.0.1:${old} |--server 127.0.0.1:${new} |" "$stls_old" > "$stls_new"; then
            rm -f -- "$stls_old"
            systemctl daemon-reload
            systemctl enable "shadowtls-snell-${new}" 2>/dev/null
        else
            ok=false
        fi
    fi

    if $ok; then
        if $socket_mode; then
            # Управление выходом (активация через сокет): перезаписываем сокет-юнит с новым портом и поднимаем
            if [ -f "${NETNS_SETUP_SCRIPT}" ]; then
                ns=$(sed -n 's/^ip netns add \([A-Za-z0-9_.-]\{1,\}\).*/\1/p' "${NETNS_SETUP_SCRIPT}" | head -n 1)
                [ -n "$ns" ] && EGRESS_NS="$ns"
            fi
            write_snell_socket_service_units "$new"
            systemctl daemon-reload
            start_egress_runtime "$new" >/dev/null || ok=false
        else
            restart_and_verify_service "$new_service" || ok=false
        fi
    fi
    if $ok && [ -f "$stls_new" ]; then
        restart_and_verify_service "shadowtls-snell-${new}" || ok=false
    fi

    if ! $ok; then
        echo -e "${RED}Не удалось изменить порт, выполняется откат…${RESET}"
        systemctl stop "$new_service" "shadowtls-snell-${new}" 2>/dev/null
        systemctl disable "$new_service" "shadowtls-snell-${new}" 2>/dev/null
        if [ "$service" != "snell" ]; then
            rm -f -- "${unit_dir}/snell-${new}.service" "${SNELL_CONF_DIR:?}/users/snell-${new}.conf"
            [ -d "${unit_dir}/snell-${new}.service.d" ] && mv "${unit_dir}/snell-${new}.service.d" "${unit_dir}/snell-${old}.service.d"
        fi
        [ -f "$stls_new" ] && rm -f -- "$stls_new"
        edit_restore
        systemctl daemon-reload
        systemctl enable "$service" 2>/dev/null
        [ -f "$stls_old" ] && systemctl enable "shadowtls-snell-${old}" 2>/dev/null
        if $socket_mode; then start_egress_runtime "$old" >/dev/null; else restart_and_verify_service "$service" >/dev/null; fi
        [ -f "$stls_old" ] && systemctl restart "shadowtls-snell-${old}" 2>/dev/null
        echo -e "${YELLOW}Восстановлен прежний порт ${old}${RESET}"
        return 1
    fi
    edit_forget_backup

    # Файрвол: открываем/закрываем порты только если Snell сам слушает внешние интерфейсы (при наличии ShadowTLS он слушает только 127.0.0.1)
    if [ "$host" != "127.0.0.1" ]; then
        close_port "$old" >/dev/null 2>&1
        open_port "$new"
    fi
    echo -e "${GREEN}✓ Порт изменен на ${new}${RESET}"
    [ -f "$stls_new" ] && echo -e "${YELLOW}Перед Snell стоит ShadowTLS: клиенты по-прежнему подключаются к порту ShadowTLS, менять порт на клиенте не нужно${RESET}"
    EDIT_CONF="$new_conf"; EDIT_SERVICE="$new_service"
}

edit_snell_psk() {   # <conf> <service>
    local conf="$1" service="$2" psk
    while true; do
        read -rp "Новый PSK (нажмите Enter для случайной генерации): " psk || return 0
        [ -z "$psk" ] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
        # Минимум 12 символов: Snell v6 не запустится с PSK короче 12 байт; применяем это правило и для v4 / v5, чтобы при переходе на v6 не пришлось менять ключ
        [[ "$psk" =~ ^[A-Za-z0-9._~+/=-]{12,128}$ ]] && break
        echo -e "${RED}PSK должен содержать от 12 до 128 символов (только буквы, цифры и . _ ~ + / = -)${RESET}"
    done
    edit_backup "$conf"
    if conf_set "$conf" psk "$psk" && restart_and_verify_service "$service"; then
        edit_forget_backup
        echo -e "${GREEN}✓ PSK изменен на ${psk}${RESET}"
        echo -e "${YELLOW}Не забудьте обновить PSK на клиенте${RESET}"
    else
        edit_restore; restart_and_verify_service "$service" >/dev/null
        echo -e "${RED}Не удалось изменить PSK, выполнены откат и восстановление${RESET}"; return 1
    fi
}

edit_snell_dns() {   # <conf> <service>
    local conf="$1" service="$2"
    get_dns
    edit_backup "$conf"
    if conf_set "$conf" dns "$DNS" && restart_and_verify_service "$service"; then
        edit_forget_backup
        echo -e "${GREEN}✓ DNS изменен на ${DNS}${RESET}"
    else
        edit_restore; restart_and_verify_service "$service" >/dev/null
        echo -e "${RED}Не удалось изменить DNS, выполнены откат и восстановление${RESET}"; return 1
    fi
}

# Пункт меню 4: выбор пользователя (если есть только основной — переходит сразу к нему) и изменение его порта, PSK или DNS
edit_snell_config() {
    local confs=() f i choice
    [ -f "$SNELL_CONF_FILE" ] && confs+=("$SNELL_CONF_FILE")
    for f in "${SNELL_CONF_DIR}"/users/snell-*.conf; do
        [ -f "$f" ] && [ "$f" != "$SNELL_CONF_FILE" ] && confs+=("$f")
    done
    if [ ${#confs[@]} -eq 0 ]; then
        echo -e "${YELLOW}Snell ещё не установлен${RESET}"; return 0
    fi
    EDIT_CONF="${confs[0]}"
    if [ ${#confs[@]} -gt 1 ]; then
        echo -e "${CYAN}Кого изменить:${RESET}"
        for i in "${!confs[@]}"; do
            f="${confs[$i]}"
            printf "  ${GREEN}%2d${RESET}  %s Порт %-6s %s\n" $((i + 1)) "$([ "$f" = "$SNELL_CONF_FILE" ] && echo "Основной    " || echo "Пользователь")" "$(conf_port "$f")" "$(get_conf_snell_version "$f")"
        done
        echo -e "  ${GREEN} 0${RESET}  Назад"
        read -rp "Выберите [0-${#confs[@]}]: " choice || return 0
        [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#confs[@]} ] || return 0
        EDIT_CONF="${confs[$((choice - 1))]}"
    fi
    EDIT_SERVICE=$(snell_service_for_port "$(conf_port "$EDIT_CONF")")
    while true; do
        echo
        echo -e "${CYAN}  ${EDIT_SERVICE}: Порт $(conf_port "$EDIT_CONF")   PSK $(conf_value "$EDIT_CONF" psk)   DNS $(conf_value "$EDIT_CONF" dns)   $(get_conf_snell_version "$EDIT_CONF")${RESET}"
        echo -e "  ${GREEN}1${RESET}  Порт    ${GREEN}2${RESET}  PSK    ${GREEN}3${RESET}  DNS    ${GREEN}0${RESET}  Назад"
        read -rp "Что изменить [0-3]: " choice || return 0
        case "$choice" in
            1) edit_snell_port "$EDIT_CONF" "$EDIT_SERVICE" ;;
            2) edit_snell_psk "$EDIT_CONF" "$EDIT_SERVICE" ;;
            3) edit_snell_dns "$EDIT_CONF" "$EDIT_SERVICE" ;;
            0|"") break ;;
            *) echo -e "${RED}Некорректный выбор${RESET}" ;;
        esac
    done
    echo -e "${CYAN}Обновленные строки конфигурации для клиента см. в пункте «3. Просмотр конфигурации»${RESET}"
}

# Вычисление отображаемой ширины строки независимо от локали (на чистых VPS часто нет UTF-8 локали): побайтовый разбор UTF-8,
# где ASCII и двухбайтовые символы (кириллица, ×) занимают 1 знакоместо, трех- и четырехбайтовые (CJK) — 2 знакоместа, а байты продолжения игнорируются (аналогично _mwidth в PSM)
_dw() {
    local s="$1" i code w=0
    local LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        printf -v code '%d' "'${s:i:1}"
        (( code < 0 )) && (( code += 256 ))
        if (( code < 0x80 || (code >= 0xC0 && code < 0xE0) )); then
            w=$((w + 1))
        elif (( code >= 0xE0 )); then
            w=$((w + 2))
        fi
    done
    echo "$w"
}
_pad() {   # <текст> <ширина>: дополняет текст пробелами справа до указанной ширины
    local w; w=$(_dw "$1")
    printf '%s%*s' "$1" $(( $2 > w ? $2 - w : 0 )) ''
}

# Элемент строки состояния: <метка> <значение> <цвет> (добавляется в массивы внутри menu_status)
_st() { labels+=("$1"); values+=("$2"); colors+=("$3"); }

# Статус-бар вверху меню (в стиле PSM): две колонки «Метка ▶ Значение»; зеленый = работает / включено, желтый = отсутствует / запущено частично.
# Внешний IP запрашивается только один раз.
MENU_IP=""
menu_status() {
    local labels=() values=() colors=()
    local conf port unit running=0 total=0 mem=0 pid rss ch chs="" n=0 r=0 f i line
    [ -n "$MENU_IP" ] || MENU_IP=$(curl -s4 --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null)
    [[ "$MENU_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || MENU_IP="N/A"
    _st IP "$MENU_IP" ""
    if command -v snell-server >/dev/null 2>&1 || ls "${INSTALL_DIR}"/snell-server-v[456] >/dev/null 2>&1; then
        # Конфигурация основного пользователя тоже лежит в users/ (snell-main.conf), каждый конфиг считаем один раз
        for conf in "${SNELL_CONF_DIR}"/users/*.conf; do
            [ -f "$conf" ] || continue
            port=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p' "$conf" | head -n 1)
            [ -n "$port" ] || continue
            unit=$(snell_service_for_port "$port")
            total=$((total + 1))
            if systemctl is-active --quiet "$unit" || { [ "$unit" = "snell" ] && systemctl is-active --quiet snell.socket; }; then
                running=$((running + 1))
                pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
                rss=$( [ -n "$pid" ] && [ "$pid" != "0" ] && ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
                mem=$((mem + ${rss:-0}))
            fi
        done
        for ch in $(list_installed_snell_versions); do
            chs="${chs:+$chs }${ch}×$(list_services_using_version "$ch" | grep -c .)"
        done
        if [ "$total" -eq 0 ]; then _st Snell "Не настроен" "$YELLOW"
        elif [ "$running" -eq "$total" ]; then _st Snell "Активно ${running}/${total}" "$GREEN"
        else _st Snell "Активно ${running}/${total}" "$YELLOW"; fi
        _st Версия "${chs:-Нет}" ""
        _st Память "$(awk -v k="$mem" 'BEGIN { printf "%.1f", k / 1024 }') MB" ""
    else
        _st Snell "Не установлен" "$YELLOW"
    fi
    if [ -x /usr/local/bin/shadow-tls ]; then
        for f in "${SYSTEMD_DIR}"/shadowtls-*.service; do
            [ -f "$f" ] || continue
            n=$((n + 1)); systemctl is-active --quiet "$(basename "$f")" && r=$((r + 1))
        done
        if [ "$n" -eq 0 ]; then _st ShadowTLS "Не настроен" "$YELLOW"
        elif [ "$r" -eq "$n" ]; then _st ShadowTLS "Активно ${r}/${n}" "$GREEN"
        else _st ShadowTLS "Активно ${r}/${n}" "$YELLOW"; fi
    else
        _st ShadowTLS "Не установлен" "$YELLOW"
    fi
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then _st BBR "Включен" "$GREEN"
    else _st BBR "Не включен" "$YELLOW"; fi
    if systemctl is-active --quiet snell-router 2>/dev/null; then _st Маршруты "Включены" "$GREEN"
    elif router_installed; then _st Маршруты "Отключены" "$YELLOW"
    else _st Маршруты "Не включены" "$YELLOW"; fi
    # Метка занимает 9 знакомест (макс. длина — ShadowTLS), значения в левой колонке дополняются до 16 знакомест
    for (( i = 0; i < ${#labels[@]}; i += 2 )); do
        line="  ${CYAN}$(_pad "${labels[i]}" 9)${RESET} ▶  ${colors[i]}"
        if (( i + 1 < ${#labels[@]} )); then
            line="${line}$(_pad "${values[i]}" 16)${RESET} ${CYAN}$(_pad "${labels[i + 1]}" 9)${RESET} ▶  ${colors[i + 1]}${values[i + 1]}${RESET}"
        else
            line="${line}${values[i]}${RESET}"
        fi
        echo -e "$line"
    done
}

# Главное меню (в стиле PSM): заголовок, панель статуса, ниже две колонки (сначала заполняется левая)
show_menu() {
    local BOLD='\033[1m' BLUE='\033[34m' BC='\033[96m' BB='\033[94m' WH='\033[97m' DM='\033[2m'
    local wide="══════════════════════════════════════════════════════════════"
    local thin="──────────────────────────────────────────────────────────────"
    local rule="──────────────────────────────────────────────"
    local items=("Установить Snell" "Удалить Snell" "Просмотр конфигурации" "Изменить порт / PSK / DNS" "Управление пользователями" "Версии Snell (v4/v5/v6)" "Перезапуск служб"
                 "Статус служб" "ShadowTLS" "BBR" "Маршрутизация (sing-box)" "Контроль выхода (v5/v6)" "Обновить скрипт")
    local rows=7 i k w=0 line
    clear 2>/dev/null || true
    echo
    printf "  ${BOLD}${BC}%s${RESET}\n" ' ____     _   _    _____    _        _     '
    printf "  ${BOLD}${BC}%s${RESET}\n" '/ ___|   | \ | |  | ____|  | |      | |    '
    printf "  ${BOLD}${BB}%s${RESET}\n" '\___ \   |  \| |  |  _|    | |      | |    '
    printf "  ${BOLD}${BB}%s${RESET}\n" ' ___) |  | |\  |  | |___   | |___   | |___ '
    printf "  ${BOLD}${BC}%s${RESET}\n" '|____/   |_| \_|  |_____|  |_____|  |_____|'
    echo
    echo -e "  ${BOLD}${WH}Snell Manager v${current_version}${RESET}  ${DM}·····${RESET}  ${YELLOW}◆ https://jinqians.com${RESET}"
    echo -e "  ${BLUE}${rule}${RESET}"
    menu_status
    echo -e "  ${BLUE}${rule}${RESET}"
    echo
    # Ширина левой колонки равняется самому длинному её пункту
    for (( i = 0; i < rows; i++ )); do
        k=$(_dw "${items[i]}"); (( k > w )) && w=$k
    done
    echo -e "${BOLD}${BLUE}${wide}${RESET}"
    echo -e "${BOLD}                      JQ's Snell Manager${RESET}"
    echo -e "${BOLD}${BLUE}${wide}${RESET}"
    for (( i = 0; i < rows; i++ )); do
        line="  ${CYAN}$(printf '%2d.' $((i + 1)))${RESET} "
        if [ -n "${items[i + rows]:-}" ]; then
            line="${line}$(_pad "${items[i]}" "$w")  ${CYAN}$(printf '%2d.' $((i + 1 + rows)))${RESET} ${items[i + rows]}"
        else
            line="${line}${items[i]}"
        fi
        echo -e "$line"
    done
    echo -e "${BOLD}${BLUE}${thin}${RESET}"
    echo -e "  ${CYAN} 0.${RESET} Выход"
    echo -e "${BOLD}${BLUE}${wide}${RESET}"
    if ! read -rp "$(echo -e "${CYAN}Выберите пункт: ${RESET}")" num; then
        echo
        echo -e "${YELLOW}Ввод не получен, выход из меню Snell.${RESET}"
        exit 0
    fi
}

# Включение и настройка BBR
setup_bbr() {
    echo -e "${CYAN}Получение и запуск скрипта управления BBR...${RESET}"

    # Скачивание локально и запуск после проверки целостности
    run_remote_script "${SNELL_RAW_BASE}/scripts/bbr.sh" "скрипт BBR"

    # После завершения скрипта BBR управление автоматически вернется сюда
    echo -e "${GREEN}Операции управления BBR завершены${RESET}"
    sleep 1  # Даем пользователю немного времени увидеть сообщение
}

# Управление ShadowTLS
setup_shadowtls() {
    echo -e "${CYAN}Запуск скрипта управления ShadowTLS...${RESET}"
    run_remote_script "${SNELL_RAW_BASE}/scripts/shadowtls.sh" "скрипт ShadowTLS"

    # После завершения скрипта ShadowTLS управление автоматически вернется сюда
    echo -e "${GREEN}Операции управления ShadowTLS завершены${RESET}"
    sleep 1  # Даем пользователю немного времени увидеть сообщение
}

# Главный цикл
while true; do
    show_menu
    case "$num" in
        1) install_snell ;;
        2) uninstall_snell ;;
        3) view_snell_config ;;
        4) edit_snell_config ;;
        5) setup_multi_user ;;
        6) check_snell_update ;;
        7) restart_snell ;;
        8) check_and_show_status ;;
        9) setup_shadowtls ;;
        10) setup_bbr ;;
        11) router_menu ;;
        12) configure_v5_egress_control ;;
        13) update_script ;;
        0)
            echo -e "${GREEN}Спасибо за использование, до свидания!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Пожалуйста, введите корректный пункт [0-13]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}Нажмите любую клавишу для возврата в главное меню...${RESET}"
    read -n 1 -s -r || exit 0
done
