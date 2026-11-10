#!/bin/bash
# Этот файл сгенерирован скриптом tools/build.sh из src/multi-user.sh и src/lib: пожалуйста, вносите изменения в файлы внутри src/ и генерируйте заново.
# =========================================
# Автор: jinqians
# Дата: Февраль 2025 г.
# Сайт: jinqians.com
# Описание: Этот скрипт предназначен для управления многопользовательской конфигурацией прокси Snell
# =========================================

# Общая часть (src/lib, объединяется через tools/build.sh при сборке релиза)
# ── lib/common.sh ─────────────────────────────────────────────────────────────
# Общее для всех скриптов: цвета, проверка root, определение ОС и пакетного менеджера, адреса публикации скриптов.
# Используется только синтаксис POSIX sh: версии скриптов для Alpine / Docker должны работать в ash и dash.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Адреса публикации скриптов. Короткие домены (*.jinqians.com) перенаправляются через Cloudflare на файлы в репозитории:
# snell / snell-centos / snell-alpine → корневая директория, menu / snell-docker / install → scripts/.
# Подскрипты, вызываемые из меню, берутся из папок scripts/ и docker/ внутри SNELL_RAW_BASE.
# Обновление самого скрипта и команды управления идут через короткие домены для учета статистики запусков.
# Можно заменить на зеркало с помощью одноименных переменных окружения (при тестировании можно указать локальные файлы).
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

# Определение имени пакета для конкретной команды (здесь сопоставляются различия между дистрибутивами)
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

# Установка пакетов для отсутствующих команд; если установить не удалось — возврат ненулевого кода (вызывающая сторона решает, выходить ли)
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
            printf '%b\n' "${RED}После установки команда ${_ec_cmd} по-прежнему не найдена, установите вручную: $(pkg_for_cmd "$_ec_cmd")${RESET}"
            return 1
        fi
    done
}

# Скачивание удаленного скрипта и проверка целостности: остановка при ошибке передачи, проверка на пустоту и проверка синтаксиса.
# Гарантирует только целостность передачи; от компрометации самого репозитория должна защищать подпись релиза.
fetch_verified_script() {   # <url> <dest>
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$1" -o "$2"; then
        printf '%b\n' "${RED}Ошибка скачивания: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    if [ ! -s "$2" ]; then
        printf '%b\n' "${RED}Скачанный файл пуст и был удален: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    # bash может парсить синтаксис sh; на системах без bash (например, Alpine) для проверки используется sh
    if command -v bash >/dev/null 2>&1; then
        _fv_shell=bash
    else
        _fv_shell=sh
    fi
    if ! "$_fv_shell" -n "$2" 2>/dev/null; then
        printf '%b\n' "${RED}Скачанный скрипт не прошел проверку синтаксиса и был удален: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    return 0
}

# ── lib/release.sh ────────────────────────────────────────────────────────────
# Официальные версии Snell: получение последних номеров версий для каждой мажорной ветки со страницы релизов и генерация ссылок на скачивание. POSIX sh.

# Резервные номера версий на случай ошибки загрузки страницы или отсутствия ссылок для данной мажорной ветки на странице релизов.
# После выхода стабильной версии v6.0.0 со страницы релизов убрали ссылки на v5 (оставив только список изменений), поэтому v5 теперь опирается на указанную здесь v5.0.1
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0"

# Официальная страница релизов Snell (старый адрес manual.nssurge.com/others/snell.html больше не работает)
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

# Преобразование номера версии в ключ фиксированной длины для сортировки (приоритет: beta < rc < стабильный релиз)
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

# Выбор самой свежей версии указанной мажорной ветки со страницы релизов (порядок на странице не гарантирует хронологию, необходима сортировка)
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

# Определение последнего номера версии для указанного канала (при ошибке возвращает встроенную константу)
resolve_latest_version_for_channel() {
    case "$1" in
        v6) get_latest_snell_v6_version ;;
        v5) get_latest_snell_v5_version ;;
        v4) get_latest_snell_v4_version ;;
        *)  return 1 ;;
    esac
}

# Генерация URL скачивания для указанного канала и номера версии; при неподдерживаемой архитектуре возвращает ненулевой код (без exit, чтобы вызывающий код мог продолжить работу)
snell_download_url_for() {
    local version_choice="$1"
    local resolved_version="$2"
    local arch
    arch=$(uname -m)

    case "$version_choice" in
        v4|v5|v6) ;;
        *)
            printf '%b\n' "${RED}Неподдерживаемый канал Snell: ${version_choice}${RESET}" >&2
            return 1
            ;;
    esac

    if [ "$version_choice" = "v6" ] && { [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; }; then
        printf '%b\n' "${RED}Для Snell v6 пока нет сборок под архитектуру armv7l${RESET}" >&2
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
# Внешний IP-адрес сервера и страна его расположения (используется при генерации клиентских конфигураций). POSIX sh.

# Внешний IPv4 / IPv6 адрес сервера (пустая строка при неудаче)
get_public_ipv4() { curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null; }
get_public_ipv6() { curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null; }

# Определение двухбуквенного кода страны по IP (несколько API с резервным переключением во избежание ошибок при лимитах запросов)
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
# с сохранением правил после перезагрузки. Общий модуль для всех скриптов (ранее в каждом скрипте была своя копия:
# только версия для CentOS знала про firewalld, Docker-версия открывала только TCP, а повторная установка дублировала правила). POSIX sh.

# Проверка активности firewalld
_fw_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

# Проверка активности ufw (-w: чтобы не принять inactive за active)
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

# Сохранение правил nftables (при наличии конфигурационного файла постоянного хранения)
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

# Цепочки фильтрации в nftables с хуком на input (по одной записи «семейство таблица цепочка» на строку).
# Собственные таблицы filter (ip/ip6) от iptables-nft уже обработаны через iptables, пропускаем их во избежание дублирования.
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

# Разрешение порта в существующих цепочках input в nftables (если файрвола nftables нет — ничего не делает)
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

# Удаление правил разрешения для указанного порта из nftables
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

# Открытие порта: если запущен firewalld — используем только его; если активен ufw — только его; иначе настраиваем iptables и nftables
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
    # Если ufw установлен, но не включен — все равно добавляем правило, чтобы при будущем включении ufw порт остался открытым
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
# Используется совместно в snell.sh, multi-user.sh, shadowtls.sh (bash).
#
# Расположение бинарных файлов:
#   ${INSTALL_DIR}/snell-server-v4|v5|v6   реальные файлы для каждого канала, юниты systemd указывают напрямую на них
#   ${INSTALL_DIR}/snell-server            символьная ссылка, указывающая на канал основного пользователя (сохранена для старой логики определения)
#
# Метка версии:
#   В первой строке конфигурации каждого пользователя пишется "#version-choice = vX". Поскольку это комментарий,
#   snell-server его игнорирует, и метка сохраняется при резервном копировании/восстановлении вместе с .conf без дополнительных файлов. Конфигурации от PSM также содержат эту метку.

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
        # Вывод --v в ранних сборках v4 не содержал мажорного номера версии; для совместимости считаем его v4
        echo "v4"
    fi
}

# Список установленных на диске каналов версий (через пробел, может быть пустым)
list_installed_snell_versions() {
    local version installed=""
    for version in $SNELL_ALL_VERSIONS; do
        if [ -x "$(snell_binary_for_version "$version")" ]; then
            installed="${installed}${version} "
        fi
    done
    echo "${installed% }"
}

# Чтение метки версии из файла конфигурации; при отсутствии метки возвращает ненулевой код
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

# Получение канала версии для конфигурации: сначала читаем метку, при неудаче берем версию по символьной ссылке (совместимость со старыми установками до миграции)
get_conf_snell_version() {
    local conf_file="$1"
    local marked
    if marked=$(read_conf_snell_version "$conf_file"); then
        echo "$marked"
        return 0
    fi
    detect_installed_snell_version
}

# Идемпотентная запись метки версии: если совпадает — пропускаем, если отличается — заменяем, если отсутствует — вставляем в первую строку.
# Используем перезапись через cat вместо mv, чтобы сохранить владельца и права доступа исходного файла (служба читает его от имени пользователя snell)
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
        echo -e "${RED}Не удалось сформировать метку версии: ${conf_file}${RESET}" >&2
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

# Получение основного порта Snell
get_snell_port() {
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
    fi
}

# Порт -> путь к файлу конфигурации (основной порт использует основную конфигурацию)
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

# Порт -> канал версии
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

# Список служб, использующих указанный канал версии (по одному имени службы systemd на строку)
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

# Переключение символьной ссылки snell-server на указанный канал (старая логика определения и ShadowTLS все еще полагаются на это имя)
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

# Скачивание официального архива и распаковка <директория>/snell-server. Прогресс выводится только в stderr
fetch_snell_release_binary() {   # <канал> <версия> <директория>
    local version="$1" resolved="$2" dir="$3" url
    if ! url=$(snell_download_url_for "$version" "$resolved"); then
        return 1
    fi

    echo -e "${CYAN}Скачивание Snell ${version} (${resolved})...${RESET}" >&2
    echo -e "${YELLOW}${url}${RESET}" >&2

    # Проверка наличия команд для скачивания и распаковки, установка при отсутствии (для любого дистрибутива)
    ensure_cmds curl unzip >&2 || return 1

    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "${dir}/snell-server.zip" "$url"; then
        echo -e "${RED}Ошибка скачивания Snell ${version}: ${url}${RESET}" >&2
        return 1
    fi

    # Проверка целостности архива (официальные хеш-суммы не публикуются, возможна только проверка целостности передачи)
    if ! unzip -t -q "${dir}/snell-server.zip" >/dev/null 2>&1; then
        echo -e "${RED}Скачанный архив поврежден и был удален: ${url}${RESET}" >&2
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

# Проверка, отличается ли локальный бинарный файл этого канала от официальной сборки <версия>.
# Сравнения только номера версии недостаточно: релиз-кандидаты (rc) v6 тоже сообщают версию v6.0.0, и после выхода релиза кажется, что «уже установлена последняя версия».
# Возвращает 0: отличаются, стоит обновить; 1: идентичны; 2: не удалось скачать официальный файл для сравнения
snell_binary_differs_from_release() {   # <канал> <версия>
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

# Скачивание бинарного файла указанного канала по версионированному пути. При force=true скачивает заново даже при наличии файла.
# Прогресс выводится только в stderr, stdout остается для вызывающей функции.
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

    # Команда install выполняет атомарную замену: запущенные старые процессы продолжают удерживать старый inode без сбоев
    if ! install -m 755 "${tmp_dir}/snell-server" "$target"; then
        echo -e "${RED}Ошибка записи в ${target}${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    # Проверка после сохранения на диск: убеждаемся, что установлена именно нужная версия канала
    local actual
    actual=$(probe_snell_binary_version "$target")
    if [ "$actual" != "$version" ]; then
        echo -e "${YELLOW}Внимание: ${target} сообщает версию ${actual}, что не совпадает с ожидаемой ${version}${RESET}" >&2
    fi

    echo -e "${GREEN}✓ Snell ${version} (${resolved}) установлен: ${target}${RESET}" >&2
    return 0
}

# Гарантирует наличие бинарного файла для указанного канала (скачивает при отсутствии)
ensure_snell_binary() {
    install_snell_binary_for_version "$1" "false"
}

# Путь к бинарному файлу для основной службы (при отсутствии метки или версионированного файла возвращает символьную ссылку)
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

# Переключение ExecStart в юнитах с обычного snell-server на версионированный бинарный файл.
# Уже переключенные пути пропускаются (шаблон содержит пробел в конце и не затрагивает snell-server-v5), поэтому функцию можно вызывать повторно.
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
        echo -e "${GREEN}✓ Службы systemd переключены на версионированные пути бинарных файлов${RESET}"
    fi
}

# Перенаправление ExecStart в юните на бинарный файл целевого канала (используется при смене версии пользователя)
point_service_unit_to_version() {
    local unit="$1"
    local version="$2"
    local target
    target=$(snell_binary_for_version "$version")

    [ -f "$unit" ] || return 1
    [ -x "$target" ] || return 1

    sed -i -E "s|ExecStart=${INSTALL_DIR}/snell-server(-v[456])? |ExecStart=${target} |" "$unit"
}

# Миграция со старой структуры (единый файл /usr/local/bin/snell-server) на раздельное хранение по каналам версий.
# Идемпотентно: если это уже символьная ссылка и все конфигурации размечены — ничего не делает.
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

    # Добавление меток версии в файлы конфигурации, где их еще нет (в старой установке все пользователи заведомо одной версии)
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
    # Файлы конфигурации с ключами PSK доступны для чтения и записи только владельцу
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
    # Проверка существования директории пользовательских конфигураций
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
# Управление версиями Snell: обновление по каналам / добавление канала / переключение канала пользователя
# =========================================
# Чтение точного номера версии, сообщаемого бинарным файлом канала (например, v5.0.1)
get_channel_binary_version() {
    local version="$1"
    local binary
    binary=$(snell_binary_for_version "$version")
    [ -x "$binary" ] || return 1

    local detail
    detail=$("$binary" --v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9]*' | head -n 1)
    if [ -z "$detail" ]; then
        # В ранних v4 флаг --v не выводил номер версии, используем встроенную константу как резервный вариант
        case "$version" in
            v4) detail="$SNELL_V4_FALLBACK" ;;
            v5) detail="$SNELL_V5_FALLBACK" ;;
            v6) detail="$SNELL_V6_FALLBACK" ;;
        esac
    fi
    echo "$detail"
}

# Перезапуск службы с проверкой успешного старта; при сбое выводит конец журнала логов, чтобы пользователю не пришлось искать вручную
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
        # При активации через сокет основная служба поднимается по требованию; если активен snell.socket — считаем состояние нормальным
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

# Запись юнита systemd для пользователя, где ExecStart указывает на бинарный файл выбранного канала
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

# Резервные копии для переключения/отката сохраняются в ${SNELL_CONF_DIR}/backup.
# Их нельзя класть в users/, так как многие циклы перебирают users/* и приняли бы бэкап за реального пользователя.
snell_backup_path() {
    local src="$1"
    local stamp="$2"
    local dir="${SNELL_CONF_DIR}/backup"
    mkdir -p "$dir" 2>/dev/null || return 1
    echo "${dir}/$(basename "$src").${stamp}"
}

# === Функции резервного копирования и восстановления конфигурации ===
# Резервное копирование конфигурации Snell (хранятся только последние 10 копий, чтобы не накапливались)
backup_snell_config() {
    local backup_dir="${SNELL_CONF_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "${SNELL_CONF_DIR}/users"/*.conf "$backup_dir"/ 2>/dev/null
    ls -dt "${SNELL_CONF_DIR}"/backup_* 2>/dev/null | tail -n +11 | xargs -r rm -rf
    echo "$backup_dir"
}


# ── lib/conf.sh ───────────────────────────────────────────────────────────────
# Пользовательская конфигурация: выбор версии и параметров v6, запись и миграция конфигов, ввод порта / DNS / IPv6, строки конфигурации для Surge.
# Используется совместно в snell.sh и multi-user.sh (bash).

# Глобальная переменная: выбранная версия Snell
SNELL_VERSION_CHOICE=""

# Режим шифрования Snell v6: default / unshaped / unsafe-raw (на клиенте и сервере должен совпадать)
SNELL_MODE="default"

# Предпочтение семейства адресов при разрешении DNS в Snell v6: default / prefer-ipv4 / prefer-ipv6 / ipv4-only / ipv6-only
# Если пусто — определяется автоматически на основе переключателя IPv6
SNELL_DNS_IP_PREFERENCE=""

# Флаг того, выбирал ли пользователь параметры v6 вручную в текущей операции (влияет на то, перезаписывать ли существующие настройки при обновлении)
SNELL_V6_OPTIONS_SET="false"

IPV6_ENABLE="true"

# Длина PSK в Snell v6 должна быть от 12 до 255 байт, иначе snell-server откажется запускаться
SNELL_V6_PSK_MIN=12
SNELL_V6_PSK_MAX=255

# Памятка при выборе версии v6
snell_v6_notes() {
    echo -e "${YELLOW}v6 принимает только клиентов с version = 6 (клиенты v4 / v5 подключиться не смогут), а параметр mode на клиенте должен совпадать с серверным${RESET}"
    echo -e "${YELLOW}В v6 удалены режим проксирования QUIC и параметр obfs, а также отсутствуют сборки для armv7l${RESET}"
}

# Проверка, подходит ли PSK из конфигурации для v6; если нет — выводит причину и возвращает 1
check_conf_psk_for_v6() {   # <conf>
    local psk len
    psk=$(grep -E '^[[:space:]]*psk[[:space:]]*=' "$1" 2>/dev/null | head -n 1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    len=$(printf '%s' "$psk" | LC_ALL=C wc -c | tr -d ' ')
    if [ "$len" -ge "$SNELL_V6_PSK_MIN" ] && [ "$len" -le "$SNELL_V6_PSK_MAX" ]; then
        return 0
    fi
    echo -e "${RED}Длина PSK этого пользователя составляет ${len} байт, а Snell v6 требует от ${SNELL_V6_PSK_MIN} до ${SNELL_V6_PSK_MAX} байт, иначе служба не запустится${RESET}"
    echo -e "${YELLOW}Пожалуйста, сначала смените PSK (в главном меню «Изменить порт / PSK / DNS», нажатие Enter сгенерирует случайный ключ из 20 символов), а затем переключайтесь на v6${RESET}"
    return 1
}

# Замена порта во всех адресах параметра listen со <старый порт> на <новый порт>.
# В v6 параметр listen может содержать несколько адресов через запятую (listen = 0.0.0.0:7177,[::]:7177), замена только последнего привела бы к рассинхронизации портов
listen_replace_port() {   # <значение listen> <старый порт> <новый порт>
    printf '%s\n' "$1" | awk -v o="$2" -v n="$3" 'BEGIN { FS = OFS = "," }
        { for (i = 1; i <= NF; i++) sub(":" o "[[:space:]]*$", ":" n, $i); print }'
}

# === Функция выбора версии ===
# Выбор версии Snell для установки
select_snell_version() {
    echo -e "${CYAN}Выберите версию Snell для установки:${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6"

    while true; do
        read -rp "Выберите вариант [1-3]: " version_choice
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
# Режим шифрования (mode): на клиенте должно быть указано точно такое же значение, иначе подключение не установится
select_snell_v6_mode() {
    local current="$1"
    local default_choice="1"
    case "$current" in
        unshaped)   default_choice="2" ;;
        unsafe-raw) default_choice="3" ;;
    esac

    echo -e "\n${CYAN}=== Режим шифрования Snell v6 (mode) ===${RESET}"
    echo -e "${YELLOW}На клиенте должен быть настроен точно такой же mode, как на сервере, иначе подключение невозможно${RESET}\n"
    echo -e "${GREEN}1.${RESET} default     Обфускация трафика + шифрование AES"
    echo -e "   Максимальная маскировка сигнатур трафика и устойчивость к блокировкам"
    echo -e "   ${CYAN}Рекомендуется: для большинства пользователей, а также при наличии помех или QoS на линии${RESET}"
    echo -e "${GREEN}2.${RESET} unshaped    Без обфускации, только шифрование AES"
    echo -e "   Пропускная способность выше примерно на 10% по сравнению с default, но характер трафика заметнее"
    echo -e "   ${CYAN}Рекомендуется: для чистых каналов с приоритетом скорости или при использовании внешней маскировки (например, ShadowTLS)${RESET}"
    echo -e "${GREEN}3.${RESET} unsafe-raw  Передача открытым текстом, без шифрования и обфускации"
    echo -e "   ${RED}Передаваемые данные легко перехватываются, ни в коем случае не используйте в публичных сетях!${RESET}"
    echo -e "   ${CYAN}Рекомендуется: только для тестирования производительности во внутренней или полностью доверенной сети${RESET}\n"

    while true; do
        read -rp "Выберите режим шифрования [1-3] (Enter — вариант ${default_choice}): " mode_choice
        [ -z "$mode_choice" ] && mode_choice="$default_choice"
        case "$mode_choice" in
            1) SNELL_MODE="default";    break ;;
            2) SNELL_MODE="unshaped";   break ;;
            3)
                SNELL_MODE="unsafe-raw"
                echo -e "${RED}Внимание: unsafe-raw передает данные открытым текстом! Убедитесь, что канал полностью доверенный.${RESET}"
                read -rp "Подтверждаете использование unsafe-raw? [y/N]: " raw_confirm
                case "$raw_confirm" in
                    [yY]|[yY][eE][sS]) break ;;
                    *) echo -e "${CYAN}Отменено, пожалуйста, выберите другой вариант${RESET}" ;;
                esac
                ;;
            *) echo -e "${RED}Пожалуйста, введите корректный вариант [1-3]${RESET}" ;;
        esac
    done
    echo -e "${GREEN}Выбран mode = ${SNELL_MODE}${RESET}"
}

# Предпочтение семейства адресов при разрешении DNS (dns-ip-preference): определяет, какой протокол сервер выберет для исходящего соединения после резолва домена
select_snell_v6_dns_preference() {
    local current="$1"
    local default_choice="1"

    # Если не задано, определяем значение по умолчанию на основе переключателя IPv6
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

    echo -e "\n${CYAN}=== Предпочтение разрешения DNS в Snell v6 (dns-ip-preference) ===${RESET}"
    echo -e "${YELLOW}Определяет приоритет протокола (IPv4/IPv6) для исходящих соединений сервера после разрешения целевого домена (не влияет на адрес прослушивания)${RESET}\n"
    echo -e "${GREEN}1.${RESET} default       Следовать системному поведению по умолчанию"
    echo -e "   ${CYAN}Рекомендуется: выбирайте при сомнениях, подходит для большинства VPS${RESET}"
    echo -e "${GREEN}2.${RESET} prefer-ipv4   Приоритет IPv4 при наличии обоих стеков, переход на IPv6 при сбое"
    echo -e "   ${CYAN}Рекомендуется: если маршрут IPv6 хуже по качеству или хуже открывает целевые сайты${RESET}"
    echo -e "${GREEN}3.${RESET} prefer-ipv6   Приоритет IPv6 при наличии обоих стеков, переход на IPv4 при сбое"
    echo -e "   ${CYAN}Рекомендуется: если маршрут IPv6 лучше или нужен для разблокировки стриминговых сервисов${RESET}"
    echo -e "${GREEN}4.${RESET} ipv4-only     Использовать только результаты разрешения IPv4"
    echo -e "   ${CYAN}Рекомендуется: если на VPS нет выхода в IPv6 (позволяет избежать таймаутов при попытке подключения к IPv6)${RESET}"
    echo -e "${GREEN}5.${RESET} ipv6-only     Использовать только результаты разрешения IPv6"
    echo -e "   ${CYAN}Рекомендуется: для IPv6-only VPS (без выхода в IPv4)${RESET}\n"

    while true; do
        read -rp "Выберите предпочтение DNS [1-5] (Enter — вариант ${default_choice}): " dns_pref_choice
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
    echo -e "${GREEN}Выбрано dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}${RESET}"
}

# Единая точка входа: вызывается при установке v6 или обновлении до v6; можно передать существующий файл конфигурации для подстановки текущих значений
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

# Чтение параметра mode из установленного сервера v6 (при отсутствии возвращает значение по умолчанию)
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

# Генерация конфигурационного файла snell-server
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

    # PSK — общий секретный ключ: чтение и запись только для владельца, чтобы другие пользователи системы не могли его прочитать
    chmod 600 "$conf_file" 2>/dev/null || true
    if getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$conf_file" 2>/dev/null || true
    fi
}

# Синхронизация параметров конфигурационного файла после смены версии: для v6 — mode / dns-ip-preference, для v4/v5 — ipv6
migrate_snell_conf_for_version() {
    local conf_file="$1"
    local version_choice="$2"
    [ -f "$conf_file" ] || return 0

    local ipv6_enable="true"
    if grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$conf_file" \
        || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$conf_file"; then
        ipv6_enable="false"
    fi

    # Сохраняем уже имеющиеся в конфиге параметры v6; перезаписываем только если пользователь явно выбирал их в текущей операции
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
        echo -e "${RED}Не удалось сформировать конфигурацию: ${conf_file}${RESET}" >&2
        return 1
    }

    # Перезапись через cat для сохранения владельца и прав доступа исходного файла (служба читает его от имени пользователя snell)
    cat "$tmp_conf" > "$conf_file" || {
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось записать конфигурацию: ${conf_file}${RESET}" >&2
        return 1
    }
    rm -f "$tmp_conf"

    # Обновляем метку принадлежности к каналу версии
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
        # Для версии v5 выводим оба варианта конфигурации (v4 и v5)
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        # Для версии v4 выводим только конфигурацию v4
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# Сравнение номеров версий (использует snell_version_sort_key для корректной обработки b4 / rc / rc2 / релизов)
version_greater_equal() {
    local key1 key2
    key1=$(snell_version_sort_key "$1")
    key2=$(snell_version_sort_key "$2")

    [[ "$key1" > "$key2" || "$key1" == "$key2" ]]
}

# Запрос номера порта у пользователя в диапазоне 1-65535
get_user_port() {
    while true; do
        read -rp "Введите желаемый номер порта (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            if is_port_in_use "$PORT"; then
                echo -e "${YELLOW}Внимание: порт ${PORT} сейчас уже занят${RESET}"
                show_port_occupier "$PORT"
                read -rp "Все равно использовать этот порт? [y/N]: " port_confirm
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
            echo -e "${RED}Недопустимый номер порта, введите число от 1 до 65535.${RESET}"
        fi
    done
}

# Получение системных DNS-серверов
get_system_dns() {
    # Попытка получить системные DNS из /etc/resolv.conf
    if [ -f "/etc/resolv.conf" ]; then
        system_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        if [ ! -z "$system_dns" ]; then
            echo "$system_dns"
            return 0
        fi
    fi
    
    # Если получить из resolv.conf не удалось, используем публичные DNS
    echo "1.1.1.1,8.8.8.8"
}

# Получение DNS-серверов от пользователя
# Валидация одного хоста DNS: IPv4 / IPv6 / доменное имя
validate_dns_host() {
    local host="$1"
    # IPv4: четыре октета чисел от 0 до 255
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
    # IPv6: шестнадцатеричные группы с двоеточиями (мягкая проверка, snell выполнит финальный парсинг сам)
    if [[ "$host" == *:* ]] && [[ "$host" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        return 0
    fi
    # Доменное имя: буквы, цифры, точки и дефисы (не начинается и не заканчивается точкой или дефисом)
    if [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
        return 0
    fi
    return 1
}

# Валидация строки ввода DNS: допускается несколько адресов через запятую
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

# Запрос DNS-серверов у пользователя (с проверкой формата IPv4/IPv6/домена и повторным запросом при ошибке)
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
        echo -e "${RED}Неверный формат адреса DNS. Введите адреса IPv4/IPv6 или домены (несколько значений разделяйте запятой)${RESET}"
    done
}

# Запрос включения IPv6
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



# Чтение dns-ip-preference (v6) из основной конфигурации; при отсутствии выводится из переключателя ipv6
get_snell_dns_preference() {
    local ipv6_enable="$1"
    local conf_file="${2:-$SNELL_CONF_FILE}"
    local pref=""
    if [ -f "$conf_file" ]; then
        pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [ -z "$pref" ]; then
        if [ "$ipv6_enable" = "false" ]; then
            pref="ipv4-only"
        else
            pref="default"
        fi
    fi
    echo "$pref"
}

# Вывод строки конфигурации для Surge (для v6 требуется указать mode)
print_surge_line() {
    local country="$1"
    local ip_addr="$2"
    local port="$3"
    local psk="$4"
    local installed_version="$5"

    if [ "$installed_version" = "v6" ]; then
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 6, mode = $(get_snell_mode "$(snell_conf_for_port "$port")"), reuse = true, tfo = true${RESET}"
    elif [ "$installed_version" = "v5" ]; then
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# Проверка, установлен ли Snell
check_snell_installed() {
    if ! command -v snell-server &> /dev/null && [ -z "$(list_installed_snell_versions)" ]; then
        echo -e "${RED}Установка Snell не обнаружена. Пожалуйста, сначала установите Snell.${RESET}"
        exit 1
    fi

    # Сначала мигрируем старую одноверсионную структуру на раздельное хранение по каналам, чтобы новые пользователи могли выбирать собственные версии
    if [ -e "${INSTALL_DIR}/snell-server" ]; then
        migrate_snell_binary_layout
    fi
}

# Получение порта основного пользователя
get_main_port() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        echo "$main_port"
    fi
}

# Получение портов всех пользователей
get_all_ports() {
    # Проверка существования директории пользовательских конфигураций
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi
    
    # Получение портов из всех файлов конфигурации
    for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        if [ -f "$conf_file" ]; then
            grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
        fi
    done | sort -n | uniq
}

# Вывод списка всех пользователей
list_users() {
    echo -e "\n${YELLOW}=== Текущий список пользователей ===${RESET}"
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        local count=0
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                count=$((count + 1))
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local version=$(get_conf_snell_version "$user_conf")
                echo -e "${GREEN}Пользователь $count:${RESET}"
                echo -e "Порт:             ${port}"
                echo -e "Версия:           Snell ${version}"
                echo -e "PSK:              ${psk}"
                echo -e "Файл конфигурации: ${user_conf}\n"
            fi
        done
        if [ $count -eq 0 ]; then
            echo -e "${YELLOW}Настроенных пользователей пока нет${RESET}"
        fi
    else
        echo -e "${YELLOW}Настроенных пользователей пока нет${RESET}"
    fi
}

# Проверка, занят ли уже указанный порт
check_port_usage() {
    local port=$1
    # Проверка использования другими экземплярами snell
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$conf" ]; then
                local used_port=$(grep -E '^listen' "$conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ "$used_port" == "$port" ]; then
                    return 1
                fi
            fi
        done
    fi
    # Проверка основного файла конфигурации (устаревший путь)
    if [ -f "${SNELL_CONF_DIR}/snell-server.conf" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/snell-server.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        if [ "$main_port" == "$port" ]; then
            return 1
        fi
    fi
    # Проверка реально прослушиваемых портов в системе (пропускается, если нет утилиты ss)
    if command -v ss &> /dev/null; then
        if ss -tulnH 2>/dev/null | grep -q ":${port} "; then
            return 1
        fi
    fi
    return 0
}

# Валидация введенного пользователем порта: только цифры + диапазон 1-65535; явный запрет на значение main (основная конфигурация)
validate_user_port() {
    local port="$1"
    if [ "$port" = "main" ]; then
        echo -e "${RED}Нельзя напрямую редактировать конфигурацию основного пользователя (snell-main.conf). Пожалуйста, используйте главный скрипт для управления основным пользователем.${RESET}"
        return 1
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Недопустимый номер порта, введите число от 1 до 65535${RESET}"
        return 1
    fi
    return 0
}

# Блокировка конкурентного доступа к многопользовательским данным: операции add/delete/modify работают по принципу check-then-act,
# блокировка предотвращает взаимную перезапись конфигураций при одновременной работе двух сессий управления с одним и тем же портом
multi_user_lock() {
    if ! command -v flock &> /dev/null; then
        echo -e "${YELLOW}Утилита flock не найдена, блокировка параллельного доступа пропущена${RESET}"
        return 0
    fi
    if ! exec 200>"${SNELL_CONF_DIR}/.multi-user.lock" 2>/dev/null; then
        echo -e "${RED}Не удалось создать файл блокировки, операция отменена${RESET}"
        return 1
    fi
    if ! flock -n 200 2>/dev/null; then
        echo -e "${RED}В данный момент уже выполняется другая операция управления пользователями, повторите попытку позже${RESET}"
        exec 200>&- 2>/dev/null || true
        return 1
    fi
    return 0
}

multi_user_unlock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
}


# Статус установки канала на сервере (для подсказки в меню)
snell_channel_label() {
    if [ -x "$(snell_binary_for_version "$1")" ]; then
        echo "установлен"
    else
        echo "не установлен, скачается автоматически при выборе"
    fi
}

# Выбор канала версии Snell для пользователя (результат записывается в глобальную переменную SNELL_VERSION_CHOICE)
select_user_snell_version() {
    local prompt_title="${1:-Выбор версии Snell для этого пользователя}"
    local installed default_version arch
    installed=$(list_installed_snell_versions)
    default_version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    arch=$(uname -m)

    # При отсутствии основной конфигурации или поломке символьной ссылки default_version может быть unknown — берем первый установленный канал
    case "$default_version" in
        v4|v5|v6) ;;
        *) default_version="${installed%% *}" ;;
    esac
    [ -n "$default_version" ] || default_version="v5"

    echo -e "\n${CYAN}=== ${prompt_title} ===${RESET}"
    echo -e "${YELLOW}Установленные каналы: ${installed:-нет}${RESET}"
    echo -e "${YELLOW}Разные порты могут работать на разных версиях независимо друг от друга${RESET}\n"
    echo -e "${GREEN}1.${RESET} Snell v4        ($(snell_channel_label v4))"
    echo -e "${GREEN}2.${RESET} Snell v5        ($(snell_channel_label v5))"
    echo -e "${GREEN}3.${RESET} Snell v6        ($(snell_channel_label v6))"
    echo -e "${GREEN}0.${RESET} Как у основного пользователя (${default_version})"

    while true; do
        read -rp "Выберите вариант [0-3]: " version_pick
        case "$version_pick" in
            1) SNELL_VERSION_CHOICE="v4"; break ;;
            2) SNELL_VERSION_CHOICE="v5"; break ;;
            3)
                if [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; then
                    echo -e "${RED}Для Snell v6 пока нет сборок под armv7l, выберите другую версию${RESET}"
                    continue
                fi
                SNELL_VERSION_CHOICE="v6"
                snell_v6_notes
                break
                ;;
            0|"") SNELL_VERSION_CHOICE="$default_version"; break ;;
            *) echo -e "${RED}Пожалуйста, введите корректный вариант [0-3]${RESET}" ;;
        esac
    done

    echo -e "${GREEN}Выбран Snell ${SNELL_VERSION_CHOICE}${RESET}"
}

# Переключение конфигурации пользователя на целевой канал: подготовка бинарника -> миграция параметров конфига -> обновление юнита -> перезапуск (с автооткатом при сбое)
switch_user_conf_version() {
    local conf_file="$1"
    local target_version="$2"
    local port service unit current_version

    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}Файл конфигурации не существует: ${conf_file}${RESET}"
        return 1
    fi

    current_version=$(get_conf_snell_version "$conf_file")
    if [ "$current_version" = "$target_version" ]; then
        echo -e "${YELLOW}Этот пользователь уже использует канал ${target_version}, переключение не требуется${RESET}"
        return 0
    fi

    port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
    if [ -z "$port" ]; then
        echo -e "${RED}Не удалось извлечь порт прослушивания из ${conf_file}${RESET}"
        return 1
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

    # Параметры mode / dns-ip-preference для v6 выбираются индивидуально для этого пользователя;
    # предварительно сбрасываем IPV6_ENABLE по текущему конфигу, чтобы не использовать остаточное значение от предыдущего вызова add_user
    if [ "$target_version" = "v6" ]; then
        IPV6_ENABLE="true"
        if grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$conf_file" \
            || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$conf_file"; then
            IPV6_ENABLE="false"
        fi
        configure_snell_v6_options "$conf_file"
    fi

    local stamp backup_conf backup_unit
    stamp=$(date +%Y%m%d_%H%M%S)
    backup_conf=$(snell_backup_path "$conf_file" "$stamp")
    if [ -z "$backup_conf" ] || ! cp -a "$conf_file" "$backup_conf"; then
        echo -e "${RED}Ошибка резервного копирования конфигурации, переключение прервано${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 1
    fi
    backup_unit=$(snell_backup_path "$unit" "$stamp")
    cp -a "$unit" "$backup_unit" 2>/dev/null || backup_unit=""

    echo -e "${CYAN}Переключение порта ${port} с ${current_version} на ${target_version}...${RESET}"

    migrate_snell_conf_for_version "$conf_file" "$target_version"
    if [ "$service" = "snell" ]; then
        point_service_unit_to_version "$unit" "$target_version"
        update_snell_symlink "$target_version"
    else
        write_user_service_unit "$port" "$conf_file" "$target_version"
    fi
    systemctl daemon-reload 2>/dev/null || true

    if restart_and_verify_service "$service"; then
        echo -e "${GREEN}✓ Порт ${port} переключен на Snell ${target_version}${RESET}"
        echo -e "${YELLOW}Не забудьте изменить параметр version на ${target_version#v} для этого узла в клиентском приложении${RESET}"
        if [ "$target_version" = "v6" ]; then
            echo -e "${YELLOW}а также добавить параметр mode = $(get_snell_mode "$conf_file")${RESET}"
        fi
        echo -e "${YELLOW}Резервная копия для отката: ${backup_conf}${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 0
    fi

    echo -e "${RED}Не удалось запустить службу после переключения, выполняется откат на ${current_version}...${RESET}"
    cat "$backup_conf" > "$conf_file"
    [ -n "$backup_unit" ] && cat "$backup_unit" > "$unit"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$current_version"
    fi
    if restart_and_verify_service "$service"; then
        echo -e "${YELLOW}Выполнен откат на ${current_version}, работа службы восстановлена${RESET}"
    else
        echo -e "${RED}После отката служба по-прежнему не запустилась, проверьте вручную: systemctl status ${service}${RESET}"
    fi
    SNELL_V6_OPTIONS_SET="false"
    return 1
}

# Добавление нового пользователя
add_user() {
    # Блокировка конкурентного доступа (автоматически снимается при выходе из функции); сброс IPV6_ENABLE от предыдущих вызовов
    multi_user_lock || return 1
    trap 'multi_user_unlock' RETURN
    IPV6_ENABLE="true"

    echo -e "\n${YELLOW}=== Добавление нового пользователя ===${RESET}"
    
    # Создание директории пользовательских конфигураций
    mkdir -p "${SNELL_CONF_DIR}/users"
    
    # Запрос номера порта
    while true; do
        read -rp "Введите номер порта для нового пользователя (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            # Проверка, не занят ли порт
            if ! check_port_usage "$PORT"; then
                echo -e "${RED}Порт $PORT уже используется, выберите другой порт${RESET}"
                continue
            fi
            break
        else
            echo -e "${RED}Недопустимый номер порта, введите число от 1 до 65535${RESET}"
        fi
    done
    
    # Выбор канала версии для этого пользователя
    select_user_snell_version
    local installed_version="$SNELL_VERSION_CHOICE"

    # Если нужный канал еще не установлен — скачиваем его; при неудаче отменяем создание пользователя
    if ! ensure_snell_binary "$installed_version"; then
        echo -e "${RED}Не удалось подготовить Snell ${installed_version}, добавление пользователя отменено${RESET}"
        return 1
    fi

    # Генерация случайного ключа PSK
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    
    # Запрос настроек DNS
    get_dns
    
    # Создание файла конфигурации пользователя (настройка IPv6 наследуется из основной конфигурации)
    ensure_snell_service_user
    local ipv6_enable="true"
    local listen_addr="::0"
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ] && { grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$main_conf" \
        || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$main_conf"; }; then
        ipv6_enable="false"
        listen_addr="0.0.0.0"
    fi

    # Параметры mode / dns-ip-preference для v6 задаются индивидуально для этого пользователя (по умолчанию предлагаются значения из основной конфигурации)
    if [ "$installed_version" = "v6" ]; then
        IPV6_ENABLE="$ipv6_enable"
        SNELL_MODE=$(get_snell_mode "$main_conf")
        SNELL_DNS_IP_PREFERENCE=$(get_snell_dns_preference "$ipv6_enable" "$main_conf")
        configure_snell_v6_options "$main_conf"
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${PORT}.conf"
    # В v6 используются mode / dns-ip-preference, параметр ipv6 в v6 устарел
    {
        echo "#${SNELL_VERSION_MARKER_KEY} = ${installed_version}"
        echo "[snell-server]"
        echo "listen = ${listen_addr}:${PORT}"
        echo "psk = ${PSK}"
        if [ "$installed_version" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            echo "dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}"
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
        echo "dns = ${DNS}"
    } > "$user_conf"
    SNELL_V6_OPTIONS_SET="false"
    
    # Создание файла службы пользователя с указанием выбранного канала в ExecStart
    local service_name="snell-${PORT}"
    write_user_service_unit "$PORT" "$user_conf" "$installed_version"

    # Перезагрузка конфигурации systemd
    systemctl daemon-reload
    systemctl enable "$service_name" 2>/dev/null

    # Запуск и проверка работоспособности службы; при сбое удаляем созданные файлы, чтобы не оставлять нерабочего пользователя
    if ! restart_and_verify_service "$service_name"; then
        echo -e "${RED}Не удалось запустить пользовательскую службу, выполняется откат созданной конфигурации...${RESET}"
        systemctl disable "$service_name" 2>/dev/null
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        rm -f "$user_conf"
        systemctl daemon-reload
        echo -e "${YELLOW}Откат выполнен. Порт ${PORT} освобожден, попробуйте снова с другой версией или портом.${RESET}"
        return 1
    fi

    # Открытие порта в файрволе
    open_port "$PORT"
    
    echo -e "\n${GREEN}Пользователь успешно добавлен! Информация о конфигурации:${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}Порт:              ${PORT}${RESET}"
    echo -e "${YELLOW}Версия:            Snell ${installed_version}${RESET}"
    echo -e "${YELLOW}PSK:               ${PSK}${RESET}"
    [ "$installed_version" = "v6" ] && echo -e "${YELLOW}mode:              ${SNELL_MODE} (на клиенте должен быть таким же)${RESET}"
    echo -e "${YELLOW}Файл конфигурации: ${user_conf}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
}

# Удаление пользователя
delete_user() {
    # Блокировка конкурентного доступа (автоматически снимается при выходе из функции)
    multi_user_lock || return 1
    trap 'multi_user_unlock' RETURN

    echo -e "\n${YELLOW}=== Удаление пользователя ===${RESET}"

    # Отображение списка пользователей
    list_users

    # Запрос порта удаляемого пользователя (проверка на число, запрет редактирования main)
    read -rp "Введите номер порта пользователя для удаления: " del_port
    if ! validate_user_port "$del_port"; then
        return 1
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${del_port}.conf"
    local service_name="snell-${del_port}"

    if [ -f "$user_conf" ]; then
        # Остановка и отключение службы
        systemctl stop "$service_name" 2>/dev/null || true
        systemctl disable "$service_name" 2>/dev/null || true

        # Удаление файлов службы
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        rm -f "/lib/systemd/system/${service_name}.service"
        # Удаление файла конфигурации
        rm -f "$user_conf"

        # Закрытие порта в файрволе
        close_port "$del_port"

        # Очистка старых резервных копий этого порта в backup/ (содержат PSK открытым текстом)
        rm -f "${SNELL_CONF_DIR}/backup/snell-${del_port}.conf".* 2>/dev/null
        rm -f "${SNELL_CONF_DIR}/backup/snell-${del_port}.service".* 2>/dev/null

        # Перезагрузка конфигурации systemd
        systemctl daemon-reload

        echo -e "${GREEN}Пользователь успешно удален${RESET}"
    else
        echo -e "${RED}Пользователь с портом ${del_port} не найден${RESET}"
    fi
}

# Изменение конфигурации пользователя
modify_user() {
    # Блокировка конкурентного доступа (автоматически снимается при выходе из функции)
    multi_user_lock || return 1
    trap 'multi_user_unlock' RETURN

    echo -e "\n${YELLOW}=== Изменение конфигурации пользователя ===${RESET}"

    # Отображение списка пользователей
    list_users

    # Запрос порта изменяемого пользователя (проверка на число, запрет редактирования main)
    read -rp "Введите номер порта пользователя для изменения: " mod_port
    if ! validate_user_port "$mod_port"; then
        return 1
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${mod_port}.conf"
    local service_name="snell-${mod_port}"
    
    if [ -f "$user_conf" ]; then
        echo -e "\n${YELLOW}Текущая версия: Snell $(get_conf_snell_version "$user_conf")${RESET}"
        echo -e "${YELLOW}Выберите параметр для изменения:${RESET}"
        echo -e "${GREEN}1.${RESET} Изменить порт"
        echo -e "${GREEN}2.${RESET} Сбросить PSK"
        echo -e "${GREEN}3.${RESET} Изменить DNS"
        echo -e "${GREEN}4.${RESET} Изменить версию Snell (переключить канал)"
        echo -e "${GREEN}0.${RESET} Назад"
        
        read -rp "Выберите действие [0-4]: " mod_choice
        case "$mod_choice" in
            1)
                # Изменение порта
                while true; do
                    read -rp "Введите новый номер порта (1-65535): " new_port
                    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                        if ! check_port_usage "$new_port"; then
                            echo -e "${RED}Порт $new_port уже используется, выберите другой порт${RESET}"
                            continue
                        fi
                        break
                    else
                        echo -e "${RED}Недопустимый номер порта, введите число от 1 до 65535${RESET}"
                    fi
                done
                
                local mod_version
                mod_version=$(get_conf_snell_version "$user_conf")

                # Резервное копирование старой конфигурации и файла службы для отката при ошибке запуска на новом порту
                local stamp backup_old_conf backup_old_unit new_conf
                stamp=$(date +%Y%m%d_%H%M%S)
                backup_old_conf=$(snell_backup_path "$user_conf" "$stamp")
                backup_old_unit=""
                if [ -n "$backup_old_conf" ] && cp -a "$user_conf" "$backup_old_conf" 2>/dev/null; then
                    if [ -f "${SYSTEMD_DIR}/${service_name}.service" ]; then
                        backup_old_unit=$(snell_backup_path "${SYSTEMD_DIR}/${service_name}.service" "$stamp")
                        cp -a "${SYSTEMD_DIR}/${service_name}.service" "$backup_old_unit" 2>/dev/null || backup_old_unit=""
                    fi
                else
                    echo -e "${RED}Ошибка резервного копирования старой конфигурации, смена порта прервана${RESET}"
                    return 1
                fi

                # Остановка и отключение старой службы
                systemctl stop "$service_name" 2>/dev/null || true
                systemctl disable "$service_name" 2>/dev/null || true

                # Изменение порта в файле конфигурации: меняем во всех адресах listen (в v6 может быть несколько адресов),
                # сопоставляем по концу адреса, чтобы при mod_port=5 случайно не испортить :12345
                local old_listen new_listen
                old_listen=$(grep -E '^[[:space:]]*listen[[:space:]]*=' "$user_conf" | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
                new_listen=$(listen_replace_port "$old_listen" "$mod_port" "$new_port")
                sed -i "s|^[[:space:]]*listen[[:space:]]*=.*|listen = ${new_listen}|" "$user_conf"
                if ! grep -Eq "^listen = .*:${new_port}$" "$user_conf"; then
                    echo -e "${RED}Ошибка замены порта в файле конфигурации, операция прервана${RESET}"
                    systemctl enable "$service_name" 2>/dev/null || true
                    restart_and_verify_service "$service_name" || true
                    return 1
                fi

                # Переименование файла конфигурации и полная перезапись файла службы (в Description указана версия, построчный sed больше не подходит)
                new_conf="${SNELL_CONF_DIR}/users/snell-${new_port}.conf"
                mv "$user_conf" "$new_conf"
                rm -f "${SYSTEMD_DIR}/${service_name}.service"
                write_user_service_unit "$new_port" "$new_conf" "$mod_version"

                # Перезагрузка конфигурации systemd и запуск новой службы
                systemctl daemon-reload
                systemctl enable "snell-${new_port}" 2>/dev/null || true
                if restart_and_verify_service "snell-${new_port}"; then
                    # Успешно: закрываем старый порт в файрволе и открываем новый
                    close_port "$mod_port"
                    open_port "$new_port"
                    echo -e "${GREEN}Порт успешно изменен: ${mod_port} -> ${new_port}${RESET}"
                else
                    echo -e "${RED}Не удалось запустить службу на новом порту, выполняется откат...${RESET}"
                    systemctl disable "snell-${new_port}" 2>/dev/null || true
                    rm -f "${SYSTEMD_DIR}/snell-${new_port}.service" "$new_conf"
                    cat "$backup_old_conf" > "$user_conf"
                    [ -n "$backup_old_unit" ] && cat "$backup_old_unit" > "${SYSTEMD_DIR}/${service_name}.service"
                    systemctl daemon-reload 2>/dev/null || true
                    systemctl enable "$service_name" 2>/dev/null || true
                    if restart_and_verify_service "$service_name"; then
                        echo -e "${YELLOW}Выполнен откат на порт ${mod_port}, работа службы восстановлена${RESET}"
                    else
                        echo -e "${RED}После отката служба по-прежнему не запустилась, проверьте вручную: systemctl status ${service_name}${RESET}"
                    fi
                fi
                ;;
            2)
                # Сброс PSK
                local new_psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
                sed -i "s/psk = .*/psk = ${new_psk}/" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}Ключ PSK сброшен на: ${new_psk}${RESET}"
                ;;
            3)
                # Изменение DNS (get_dns уже проверяет формат; экранируем & и разделители для sed во избежание ошибок)
                get_dns
                local dns_escaped
                dns_escaped=$(printf '%s' "$DNS" | sed 's/[&|\\]/\\&/g')
                sed -i "s|^[[:space:]]*dns[[:space:]]*=[[:space:]]*.*|dns = ${dns_escaped}|" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}Настройки DNS успешно изменены${RESET}"
                ;;
            4)
                # Переключение канала версии Snell для этого пользователя
                select_user_snell_version "На какую версию переключить порт ${mod_port}"
                switch_user_conf_version "$user_conf" "$SNELL_VERSION_CHOICE"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    else
        echo -e "${RED}Пользователь с портом ${mod_port} не найден${RESET}"
    fi
}

# Отображение подробной информации о конфигурации пользователя
show_user_config() {
    echo -e "\n${YELLOW}=== Информация о конфигурации пользователя ===${RESET}"
    
    # Отображение списка пользователей
    list_users
    
    # Запрос порта просматриваемого пользователя (проверка на число, запрет на main)
    read -rp "Введите номер порта пользователя для просмотра: " view_port
    if ! validate_user_port "$view_port"; then
        return 1
    fi

    local user_conf="${SNELL_CONF_DIR}/users/snell-${view_port}.conf"
    
    if [ -f "$user_conf" ]; then
        local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        # Версия берется из индивидуальной конфигурации этого пользователя, а не из глобального определения
        local installed_version=$(get_conf_snell_version "$user_conf")

        echo -e "\n${GREEN}Подробности конфигурации пользователя:${RESET}"
        echo -e "${CYAN}--------------------------------${RESET}"
        echo -e "${YELLOW}Порт:                ${port}${RESET}"
        echo -e "${YELLOW}Версия:              Snell ${installed_version}${RESET}"
        echo -e "${YELLOW}PSK:                 ${psk}${RESET}"
        [ -n "$mode" ] && echo -e "${YELLOW}Режим (mode):        ${mode}${RESET}"
        [ -n "$dns_pref" ] && echo -e "${YELLOW}Предпочтение DNS:    ${dns_pref}${RESET}"
        echo -e "${YELLOW}DNS:                 ${dns}${RESET}"
        
        # Получение адреса IPv4
        IPV4_ADDR=$(curl -s4 https://api.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
            IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
            echo -e "\n${GREEN}Конфигурация IPv4:${RESET}"
            print_surge_line "$IP_COUNTRY_IPV4" "$IPV4_ADDR" "$port" "$psk" "$installed_version"
        fi
        
        # Получение адреса IPv6
        IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
            IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
            echo -e "\n${GREEN}Конфигурация IPv6:${RESET}"
            print_surge_line "$IP_COUNTRY_IPV6" "$IPV6_ADDR" "$port" "$psk" "$installed_version"
        fi
        
        echo -e "${CYAN}--------------------------------${RESET}"
    else
        echo -e "${RED}Пользователь с портом ${view_port} не найден${RESET}"
    fi
}

# Главное меню
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}     Многопользовательское управление Snell${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}Автор: jinqian${RESET}"
    echo -e "${GREEN}Сайт:  https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    echo -e "${YELLOW}=== Управление пользователями ===${RESET}"
    echo -e "${GREEN}1.${RESET} Показать всех пользователей"
    echo -e "${GREEN}2.${RESET} Добавить нового пользователя"
    echo -e "${GREEN}3.${RESET} Удалить пользователя"
    echo -e "${GREEN}4.${RESET} Изменить конфигурацию пользователя"
    echo -e "${GREEN}5.${RESET} Показать подробную конфигурацию пользователя"
    echo -e "${GREEN}0.${RESET} Выйти из скрипта"
    
    echo -e "${CYAN}============================================${RESET}"
    if ! read -rp "Выберите пункт меню [0-5]: " choice; then
        echo
        echo -e "${YELLOW}Ввод не получен, выход из многопользовательского меню.${RESET}"
        exit 0
    fi
}

# Начальная проверка
check_root
check_snell_installed

# Главный цикл
while true; do
    show_menu
    case "$choice" in
        1)
            list_users
            ;;
        2)
            add_user
            ;;
        3)
            delete_user
            ;;
        4)
            modify_user
            ;;
        5)
            show_user_config
            ;;
        0)
            echo -e "${GREEN}Спасибо за использование, до свидания!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Пожалуйста, введите корректный пункт меню [0-5]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}Нажмите любую клавишу для возврата в главное меню...${RESET}"
    read -n 1 -s -r || exit 0
done
