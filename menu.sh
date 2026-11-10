#!/bin/bash
# Этот файл сгенерирован скриптом tools/build.sh из src/menu.sh и src/lib: пожалуйста, вносите изменения в файлы внутри src/ и генерируйте заново.
# =========================================
# Автор: jinqians
# Дата: Июль 2026 г.
# Сайт: jinqians.com
# Описание: Этот скрипт предназначен для единого управления Snell, SS-Rust и ShadowTLS (постепенно будет отделен от меню управления Snell)
# =========================================

# Общая часть (src/lib, объединяется через tools/build.sh при сборке релиза): цвета, проверка root, установка зависимостей, файрвол
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


# ── lib/routing.sh ────────────────────────────────────────────────────────────
# Маршрутизация по правилам (роутинг): сервер Snell по-прежнему использует официальный snell-server, но его исходящий трафик направляется согласно правилам —
# напрямую (direct), блокируется (reject) или передается через другой выход (SOCKS5 / HTTP / Shadowsocks / WireGuard, например, домашний провайдер или WARP).
#
# Принцип работы: nftables перехватывает только новые исходящие соединения от пользователя snell (от его имени работают все службы Snell) —
# TCP через REDIRECT, UDP через TPROXY — и передает их локальному процессу sing-box (официальный релиз фиксированной версии).
# sing-box распознает домен (TLS SNI / HTTP Host / QUIC) и выбирает выход по правилам. Обратный трафик к клиентам, собственный трафик sing-box
# и DNS-запросы через него не проходят. При остановке (или сбое) sing-box правила перехвата снимаются, и Snell возвращается к прямому соединению без потери сети.
# В режиме управления выходом через сетевые пространства имен (netns) трафик Snell инициируется не в основном пространстве хоста, поэтому эти два режима взаимоисключающие. (bash)

ROUTER_DIR="/etc/snell-router"                 # Состояние и сгенерированная конфигурация (не в /etc/snell, так как та папка принадлежит пользователю snell)
ROUTER_STATE="${ROUTER_DIR}/state.json"
ROUTER_CONFIG="${ROUTER_DIR}/config.json"
ROUTER_BIN="${INSTALL_DIR}/snell-router"       # Отдельный бинарник sing-box, чтобы не затрагивать другие экземпляры sing-box на сервере (например, от PSM)
ROUTER_NET="${INSTALL_DIR}/snell-router-net"   # Скрипт включения / отключения правил перехвата (up / down)
ROUTER_UNIT="${SYSTEMD_DIR}/snell-router.service"
ROUTER_DROPIN_NAME="snell-router.conf"         # Drop-in для перевода служб Snell, запущенных от root (например, установленных через PSM), на пользователя snell
ROUTER_TCP_PORT=17391
ROUTER_UDP_PORT=17392
ROUTER_MARK=0x736e                             # "sn"
ROUTER_TABLE=7391
# Проверенная версия sing-box (формат конфигурации меняется между мажорными релизами, поэтому версия зафиксирована; можно переопределить через переменную окружения)
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

# Тег набора правил (rule-set) → URL для скачивания (для geosite-* / geoip-* используются репозитории SagerNet, остальные берутся из state.json)
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
        | (if .action == "reject" then "Блокировка" elif .outbound == "direct" then "Напрямую" else "Выход: " + .outbound end) as $to
        | "\($what) → \($to)"'
}

# Генерация конфигурации sing-box: сначала записываем во временный файл и проверяем через sing-box check, заменяем только при успешной проверке
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
    # На машинах с отключенным IPv6 прослушивание :: вызовет ошибку
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

# Скрипт включения / отключения правил перехвата (вызывается через systemd при запуске и остановке службы)
router_write_net_script() {
    local udp
    udp=$(router_state | jq -r '.udp')
    cat > "$ROUTER_NET" <<EOF
#!/bin/bash
# Сгенерировано скриптом snell.sh: перенаправляет новые соединения от пользователя snell в snell-router (sing-box).
# При старте (up) сначала ожидает начала прослушивания порта со стороны sing-box; при остановке (down) удаляет все правила, возвращая Snell к прямому соединению.
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
    # Локальный петлевой интерфейс (loopback) и DNS не перехватываются: разрешение имен самим Snell работает штатно; остальное (включая локальные сети) обрабатывается по правилам
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
Description=Snell Routing Service (sing-box)
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

# Поиск всех служб Snell (snell, snell-<порт>)
router_snell_units() {
    local f n
    for f in "${SYSTEMD_DIR}"/snell*.service; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .service)
        [[ "$n" =~ ^snell(-[0-9]+)?$ ]] && echo "$n"
    done
    return 0
}

# Для служб Snell, работающих не от имени пользователя snell (например, установленных через PSM): добавляем drop-in для смены пользователя на snell,
# а перед запуском передаем права на чтение конфига пользователю snell (автоматически исправляет права даже после перезаписи конфига через PSM)
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
            echo "# Добавлено маршрутизацией по правилам snell.sh: трафик Snell определяется по пользователю snell"
            echo "[Service]"
            echo "User=${SNELL_SERVICE_USER}"
            echo "Group=${SNELL_SERVICE_GROUP}"
            echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
            [ -n "$conf" ] && echo "ExecStartPre=+/bin/chown ${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP} ${conf}"
        } > "${SYSTEMD_DIR}/${unit}.service.d/${ROUTER_DROPIN_NAME}"
        echo -e "${YELLOW}Служба ${unit} ранее работала от имени ${user:-root}, переключена на пользователя ${SNELL_SERVICE_USER} (через drop-in, исходный файл службы не затронут)${RESET}"
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

# Включение (или перегенерация конфигурации по текущим правилам и перезапуск)
router_enable() {
    if systemctl is-enabled --quiet snell.socket 2>/dev/null || systemctl is-active --quiet snell.socket 2>/dev/null; then
        echo -e "${RED}Включено управление выходом (netns): в этом режиме трафик Snell не инициируется с основного хоста и не может быть перехвачен роутером. Сначала отключите управление выходом в пункте меню 11.${RESET}"
        return 1
    fi
    if [ -z "$(router_snell_units)" ]; then
        echo -e "${RED}Службы Snell не найдены, сначала установите Snell.${RESET}"
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
        echo -e "${RED}Не удалось запустить snell-router, правила перехвата сняты, Snell продолжает работать напрямую.${RESET}"
        return 1
    fi
    local unit
    for unit in $UNITS_TO_RESTART; do restart_and_verify_service "$unit" || true; done
    echo -e "${GREEN}✓ Маршрутизация по правилам включена (правил: $(router_state | jq '.rules | length'), остальной трафик — напрямую)${RESET}"
}

# Отключение: служба, правила перехвата и drop-in удаляются, но настроенные правила и выходы сохраняются (восстановятся при повторном включении)
router_disable() {
    systemctl stop snell-router 2>/dev/null
    systemctl disable snell-router 2>/dev/null
    [ -x "$ROUTER_NET" ] && "$ROUTER_NET" down
    router_remove_dropins
    echo -e "${GREEN}✓ Маршрутизация по правилам отключена, Snell работает напрямую. Правила и выходы сохранены и восстановятся при повторном включении.${RESET}"
}

# Полное удаление вместе с удалением Snell
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

# При изменении правил: если роутер запущен — перегенерируем конфиг и перезапускаем
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
                echo -e "${RED}Неверный выбор${RESET}"
                return 1
            fi
            ;;
    esac
}

# Строка со значениями через запятую → JSON-массив (с удалением пробелов и пустых элементов)
router_list_json() { printf '%s' "$1" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'; }

router_add_rule() {
    local pick match label value
    echo -e "\n${CYAN}=== Добавление правила: условие совпадения ===${RESET}"
    echo -e "${GREEN}1.${RESET} Реклама и трекеры (geosite category-ads-all)"
    echo -e "${GREEN}2.${RESET} Сайты и IP материкового Китая (geosite cn + geoip cn)"
    echo -e "${GREEN}3.${RESET} Локальные и частные IP-адреса (защита от доступа клиентов к внутренней сети и метаданным облачных провайдеров)"
    echo -e "${GREEN}4.${RESET} Трафик BitTorrent (BT)"
    echo -e "${GREEN}5.${RESET} Сервисы ИИ (OpenAI, Anthropic, Gemini, Perplexity)"
    echo -e "${GREEN}6.${RESET} Стриминговые сервисы (Netflix, Disney+, HBO, Prime Video, Hulu)"
    echo -e "${GREEN}7.${RESET} Категория geosite (введите названия, например: google, telegram; можно несколько)"
    echo -e "${GREEN}8.${RESET} Страна / регион geoip (введите коды, например: cn, ir; можно несколько)"
    echo -e "${GREEN}9.${RESET} Суффиксы доменов (например: example.com; можно несколько через запятую)"
    echo -e "${GREEN}10.${RESET} Подсети IP (например: 1.2.3.0/24; можно несколько)"
    echo -e "${GREEN}11.${RESET} Удаленный набор правил (URL на файл .srs для sing-box)"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Выберите [0-11]: " pick
    case "$pick" in
        1) match='{"rule_set": ["geosite-category-ads-all"]}'; label="Реклама и трекеры" ;;
        2) match='{"rule_set": ["geosite-cn", "geoip-cn"]}'; label="Материковый Китай" ;;
        3) match='{"ip_is_private": true}'; label="Локальные адреса" ;;
        4) match='{"protocol": ["bittorrent"]}'; label="BitTorrent" ;;
        5) match='{"rule_set": ["geosite-openai", "geosite-anthropic", "geosite-google-gemini", "geosite-perplexity"]}'; label="ИИ (AI)" ;;
        6) match='{"rule_set": ["geosite-netflix", "geosite-disney", "geosite-hbo", "geosite-primevideo", "geosite-hulu"]}'; label="Стриминг" ;;
        7|8)
            local kind; [ "$pick" = 7 ] && kind="geosite" || kind="geoip"
            read -rp "Введите названия ${kind} (через запятую): " value
            match=$(router_list_json "$value" | jq -c --arg k "$kind" 'map(ascii_downcase | select(test("^[a-z0-9@!._-]+$")) | "\($k)-\(.)") | {rule_set: .}')
            label="${kind} ${value}"
            ;;
        9)
            read -rp "Введите суффиксы доменов (через запятую): " value
            match=$(router_list_json "$value" | jq -c '{domain_suffix: .}')
            label="Домены ${value}"
            ;;
        10)
            read -rp "Введите подсети IP (через запятую): " value
            match=$(router_list_json "$value" | jq -c '{ip_cidr: .}')
            label="IP ${value}"
            ;;
        11)
            read -rp "URL набора правил (https://…): " value
            if [[ ! "$value" =~ ^https://[^[:space:]]+$ ]]; then echo -e "${RED}Требуется адрес с https://"${RESET}; return 1; fi
            local tag="custom-$(printf '%s' "$value" | sha256sum | cut -c1-8)"
            router_save_state "$(router_state | jq --arg t "$tag" --arg u "$value" '.rule_sets[$t] = $u')"
            match=$(jq -nc --arg t "$tag" '{rule_set: [$t]}')
            label="Набор правил ${value##*/}"
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}Неверный выбор${RESET}"; return 1 ;;
    esac
    if [ -z "$match" ] || printf '%s' "$match" | jq -e 'to_entries[0].value | (type == "array" and length == 0)' >/dev/null; then
        echo -e "${RED}Нет допустимых условий для сопоставления${RESET}"
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
    read -rp "Номер правила для удаления [1-${n}] (0 — назад): " pick
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
    echo -e "${GREEN}4.${RESET} WireGuard (например Cloudflare WARP; укажите параметры, сгенерированные через wgcf и т. п.)"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Выберите [0-4]: " pick
    [ "$pick" = "0" ] || [ -z "$pick" ] && return 0
    read -rp "Название выхода (буквы, цифры, - _): " tag
    if [[ ! "$tag" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || [ "$tag" = "direct" ]; then echo -e "${RED}Недопустимое название${RESET}"; return 1; fi
    if router_state | jq -e --arg t "$tag" '(.outbounds + .endpoints) | any(.tag == $t)' >/dev/null; then
        echo -e "${RED}Выход с таким названием уже существует${RESET}"; return 1
    fi
    case "$pick" in
        1|2|3)
            read -rp "Адрес сервера: " server
            read -rp "Порт: " port
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo -e "${RED}Недопустимый порт${RESET}"; return 1; }
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
            read -rp "Метод шифрования (например, 2022-blake3-aes-128-gcm, aes-256-gcm): " method
            read -rp "Пароль: " pass
            ob=$(jq -nc --arg t "$tag" --arg s "$server" --argjson p "$port" --arg m "$method" --arg pw "$pass" \
                '{type: "shadowsocks", tag: $t, server: $s, server_port: $p, method: $m, password: $pw}')
            router_save_state "$(router_state | jq --argjson o "$ob" '.outbounds += [$o]')"
            ;;
        4)
            local key addr peer_key endpoint reserved
            read -rp "Приватный ключ клиента (PrivateKey): " key
            read -rp "Локальный адрес (Address, несколько через запятую, например 172.16.0.2/32,2606:4700:110:8a36::1/128): " addr
            read -rp "Публичный ключ сервера (PublicKey): " peer_key
            read -rp "Адрес:порт сервера (Endpoint, например 162.159.192.1:2408): " endpoint
            read -rp "Поле reserved (для WARP, например 1,2,3; нажмите Enter, если нет): " reserved
            [[ "$endpoint" =~ ^(.+):([0-9]+)$ ]] || { echo -e "${RED}Endpoint должен быть в формате адрес:порт${RESET}"; return 1; }
            ob=$(jq -nc --arg t "$tag" --arg k "$key" --argjson a "$(router_list_json "$addr")" --arg pk "$peer_key" \
                    --arg h "$(echo "${BASH_REMATCH[1]}" | tr -d '[]')" --argjson p "${BASH_REMATCH[2]}" --argjson r "$(router_list_json "$reserved" | jq -c 'map(tonumber)')" '
                {type: "wireguard", tag: $t, address: $a, private_key: $k, mtu: 1280,
                 peers: [{address: $h, port: $p, public_key: $pk, allowed_ips: ["0.0.0.0/0", "::/0"]}
                         + (if ($r | length) == 3 then {reserved: $r} else {} end)]}')
            router_save_state "$(router_state | jq --argjson o "$ob" '.endpoints += [$o]')"
            ;;
        *) echo -e "${RED}Неверный выбор${RESET}"; return 1 ;;
    esac
    echo -e "${GREEN}✓ Выход ${tag} добавлен. Выберите его при добавлении правила, чтобы направлять туда совпадающий трафик.${RESET}"
    router_apply_if_active
}

router_delete_outbound() {
    local tags pick i=1 list=()
    tags=$(router_state | jq -r '(.outbounds + .endpoints)[].tag')
    [ -n "$tags" ] || { echo -e "${YELLOW}Выходов пока нет${RESET}"; return 0; }
    for t in $tags; do echo -e "  ${GREEN}${i}.${RESET} ${t}"; list+=("$t"); i=$((i + 1)); done
    read -rp "Номер выхода для удаления (0 — назад): " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -lt "$i" ] || return 0
    local tag="${list[$((pick - 1))]}"
    if router_state | jq -e --arg t "$tag" 'any(.rules[]; .outbound == $t)' >/dev/null; then
        echo -e "${RED}Выход ${tag} все еще используется в правилах, сначала удалите эти правила${RESET}"
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
        echo -e "${YELLOW}Snell по-прежнему работает через официальный snell-server; его исходящий трафик идет по правилам ниже, остальное — напрямую.${RESET}"
        if router_active; then
            echo -e "${GREEN}Статус: Запущено (sing-box ${ROUTER_SINGBOX_VERSION}, UDP $(router_state | jq -r 'if .udp then "также маршрутизируется" else "идет напрямую" end'))${RESET}"
        elif router_installed; then
            echo -e "${YELLOW}Статус: Остановлено${RESET}"
        else
            echo -e "${YELLOW}Статус: Не включено${RESET}"
        fi
        echo -e "${CYAN}Правила (проверяются сверху вниз, срабатывает первое совпадение):${RESET}"
        router_list_rules
        local obs
        obs=$(router_state | jq -r '[(.outbounds + .endpoints)[] | "\(.tag) (\(.type))"] | join(", ")')
        [ -n "$obs" ] && echo -e "${CYAN}Выходы: ${RESET}${obs}"
        echo -e "\n${GREEN}1.${RESET} Включить / перегенерировать конфиг и перезапустить"
        echo -e "${GREEN}2.${RESET} Добавить правило"
        echo -e "${GREEN}3.${RESET} Удалить правило"
        echo -e "${GREEN}4.${RESET} Добавить выход (SOCKS5 / HTTP / Shadowsocks / WireGuard)"
        echo -e "${GREEN}5.${RESET} Удалить выход"
        echo -e "${GREEN}6.${RESET} Маршрутизация UDP Вкл / Выкл"
        echo -e "${GREEN}7.${RESET} Отключить маршрутизацию (вернуть прямое соединение)"
        echo -e "${GREEN}8.${RESET} Просмотр журнала логов"
        echo -e "${GREEN}0.${RESET} Назад"
        local choice
        read -rp "Выберите действие [0-8]: " choice || return 0
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
            *) echo -e "${RED}Неверный выбор${RESET}" ;;
        esac
    done
}


# Текущий номер версии
current_version="4.6"

# Директория служб systemd
SYSTEMD_DIR="/etc/systemd/system"

# Адреса скриптов блокировки IP материкового Китая в репозитории
MAINLAND_BLOCK_URL="https://raw.githubusercontent.com/jinqians/ss-2022/refs/heads/main/block-mainland.sh"
MAINLAND_EXTRACT_URL="https://raw.githubusercontent.com/jinqians/ss-2022/refs/heads/main/extract-cn-ip-from-mmdb.py"
MAINLAND_SCRIPT_DIR="/usr/local/share/ss-2022"

# Установка глобальной команды
install_global_command() {
    echo -e "${CYAN}Установка глобальной команды...${RESET}"

    # Сначала скачиваем во временный файл и перезаписываем целевой только после проверки, чтобы при сбое сети не сломать существующую команду menu
    local tmp_file
    tmp_file=$(mktemp /tmp/menu_download.XXXXXX) || { echo -e "${RED}Не удалось создать временный файл${RESET}"; return 1; }
    if ! fetch_verified_script "$SNELL_MENU_SCRIPT_URL" "$tmp_file"; then
        echo -e "${RED}Ошибка скачивания или проверки скрипта menu, проверьте подключение к сети${RESET}"
        return 1
    fi

    mv -f "$tmp_file" "/usr/local/bin/menu.sh"
    chmod +x "/usr/local/bin/menu.sh"
    
    # Создание символьной ссылки
    if [ -f "/usr/local/bin/menu" ]; then
        rm -f "/usr/local/bin/menu"
    fi
    ln -s "/usr/local/bin/menu.sh" "/usr/local/bin/menu"
    
    echo -e "${GREEN}Установка успешно завершена! Теперь вы можете использовать команду 'menu' из любого места для запуска скрипта управления${RESET}"
}

# Получение загрузки CPU
get_cpu_usage() {
    local pid=$1
    local cpu_usage=0
    
    # Получение количества ядер CPU
    local cpu_cores=$(nproc)
    
    # Использование команды top для получения точной загрузки CPU
    if [ ! -z "$pid" ] && [ "$pid" != "0" ]; then
        cpu_usage=$(top -b -n 2 -d 0.2 -p "$pid" | tail -1 | awk '{print $9}')
        # При неудаче используем команду ps как резервный вариант
        if [ -z "$cpu_usage" ]; then
            cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo 0)
        fi
        # Делим загрузку CPU на количество ядер для получения среднего значения
        cpu_usage=$(echo "scale=2; $cpu_usage / $cpu_cores" | bc -l)
    fi
    
    echo "$cpu_usage"
}

# Проверка и отображение статуса служб
check_and_show_status() {
    # Получение количества ядер CPU
    local cpu_cores=$(nproc)
    
    echo -e "\n${CYAN}=== Проверка статуса служб ===${RESET}"
    echo -e "${CYAN}Ядер CPU в системе: ${cpu_cores}${RESET}"
    
    # Проверка статуса Snell
    if command -v snell-server &> /dev/null; then
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0
        
        # Проверка статуса основной службы
        if systemctl is-active snell &> /dev/null; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null || echo 0)
                local cpu=$(get_cpu_usage "$main_pid")
                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        
        # Проверка статуса дополнительных пользователей
        if [ -d "/etc/snell/users" ]; then
            for user_conf in "/etc/snell/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null || echo 0)
                                local cpu=$(get_cpu_usage "$user_pid")
                                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        
        # Убеждаемся, что все числовые значения корректны
        total_snell_memory=${total_snell_memory:-0}
        total_snell_cpu=${total_snell_cpu:-0}
        
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc -l 2>/dev/null || echo "0")
        printf "${GREEN}Snell установлен${RESET}     ${YELLOW}CPU: %.2f%% (на ядро)${RESET}  ${YELLOW}Память: %.2f MB${RESET}  ${GREEN}Запущено: ${running_count}/${user_count}${RESET}\n" "${total_snell_cpu:-0}" "${total_snell_memory_mb:-0}"
    else
        echo -e "${YELLOW}Snell не установлен${RESET}"
    fi
    
    # Проверка статуса SS-2022
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_memory=0
        local ss_cpu=0
        local ss_running=0
        
        if systemctl is-active ss-rust &> /dev/null; then
            ss_running=1
            local ss_pid=$(systemctl show -p MainPID ss-rust | cut -d'=' -f2)
            if [ ! -z "$ss_pid" ] && [ "$ss_pid" != "0" ]; then
                ss_memory=$(ps -o rss= -p $ss_pid 2>/dev/null || echo 0)
                ss_cpu=$(get_cpu_usage "$ss_pid")
            fi
        fi
        
        local ss_memory_mb=$(echo "scale=2; $ss_memory/1024" | bc)
        printf "${GREEN}SS-2022 установлен${RESET}   ${YELLOW}CPU: %.2f%% (на ядро)${RESET}  ${YELLOW}Память: %.2f MB${RESET}  ${GREEN}Запущено: ${ss_running}/1${RESET}\n" "$ss_cpu" "$ss_memory_mb"
    else
        echo -e "${YELLOW}SS-2022 не установлен${RESET}"
    fi
    
    # Проверка статуса ShadowTLS
    if systemctl list-units --type=service | grep -q "shadowtls-"; then
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        
        while IFS= read -r service; do
            stls_total=$((stls_total + 1))
            if systemctl is-active "$service" &> /dev/null; then
                stls_running=$((stls_running + 1))
                
                local stls_pid=$(systemctl show -p MainPID "$service" | cut -d'=' -f2)
                if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                    local mem=$(ps -o rss= -p $stls_pid 2>/dev/null || echo 0)
                    local cpu=$(get_cpu_usage "$stls_pid")
                    total_stls_memory=$((total_stls_memory + mem))
                    total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                fi
            fi
        done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
        
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS установлен${RESET} ${YELLOW}CPU: %.2f%% (на ядро)${RESET}  ${YELLOW}Память: %.2f MB${RESET}  ${GREEN}Запущено: ${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS не установлен${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS не установлен${RESET}"
    fi
    
    echo -e "${CYAN}==============================${RESET}\n"
}

# Обновление скрипта
update_script() {
    echo -e "${CYAN}Проверка обновлений скрипта...${RESET}"
    
    # Создание временного файла
    TMP_SCRIPT=$(mktemp)
    
    # Скачивание последней версии (с проверкой целостности)
    if fetch_verified_script "$SNELL_MENU_SCRIPT_URL" "$TMP_SCRIPT"; then
        # Получение нового номера версии
        # Ищем присваивание только в начале строки: эта строка кода сама содержит current_version=, без привязки к началу строки прочитаются две «версии» и всегда будет предлагаться обновление
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)
        
        if [ -z "$new_version" ]; then
            echo -e "${RED}Не удалось получить информацию о новой версии${RESET}"
            rm -f "$TMP_SCRIPT"
            return 1
        fi
        
        echo -e "${YELLOW}Текущая версия:   ${current_version}${RESET}"
        echo -e "${YELLOW}Последняя версия: ${new_version}${RESET}"
        
        # Сравнение номеров версий
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${CYAN}Обновить до новой версии? [y/N]${RESET}"
            read -r choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                # Получение полного пути к текущему скрипту
                SCRIPT_PATH=$(readlink -f "$0")
                
                # Резервное копирование текущего скрипта
                cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                
                # Обновление скрипта
                mv "$TMP_SCRIPT" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                
                echo -e "${GREEN}Скрипт обновлен до последней версии${RESET}"
                echo -e "${YELLOW}Исходный скрипт сохранен в: ${SCRIPT_PATH}.backup${RESET}"
                echo -e "${CYAN}Пожалуйста, перезапустите скрипт для использования новой версии${RESET}"
                exit 0
            else
                echo -e "${YELLOW}Обновление отменено${RESET}"
                rm -f "$TMP_SCRIPT"
            fi
        else
            echo -e "${GREEN}У вас уже установлена последняя версия${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}Не удалось скачать новую версию, проверьте подключение к сети${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# Установка / управление Snell
manage_snell() {
    bash <(curl -fsSL "$SNELL_SCRIPT_URL")
}

# Установка / управление SS-2022
manage_ss_rust() {
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022/main/ss-2022.sh)
}

# Управление блокировкой IP-адресов материкового Китая
manage_mainland_block() {
    echo -e "${CYAN}Получение скрипта блокировки IP материкового Китая из репозитория...${RESET}"

    mkdir -p "${MAINLAND_SCRIPT_DIR}"

    if ! curl -fL -s "${MAINLAND_BLOCK_URL}" -o "${MAINLAND_SCRIPT_DIR}/block-mainland.sh"; then
        echo -e "${RED}Не удалось скачать block-mainland.sh${RESET}"
        return 1
    fi

    if ! curl -fL -s "${MAINLAND_EXTRACT_URL}" -o "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py"; then
        echo -e "${RED}Не удалось скачать extract-cn-ip-from-mmdb.py${RESET}"
        return 1
    fi

    chmod +x "${MAINLAND_SCRIPT_DIR}/block-mainland.sh" "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py"
    PYTHONIOENCODING=UTF-8 bash "${MAINLAND_SCRIPT_DIR}/block-mainland.sh"
}

# Установка / управление ShadowTLS
manage_shadowtls() {
    bash <(curl -fsSL "${SNELL_RAW_BASE}/scripts/shadowtls.sh")
}

# Установка / управление VLESS Reality (интегрировано в PSM)
manage_vless() {
    echo -e "${CYAN}Установка и управление VLESS Reality теперь предоставляются через PSM (Proxy Stack Manager). Запуск PSM...${RESET}"
    if ! bash <(curl -fsSL https://psm.jinqians.com); then
        echo -e "${RED}Не удалось запустить PSM. Проверьте подключение к сети и повторите попытку или выполните вручную: bash <(curl -fsSL https://psm.jinqians.com)${RESET}"
        return 1
    fi
}

# Удаление Snell
uninstall_snell() {
    echo -e "${CYAN}Удаление Snell...${RESET}"

    # Заодно удаляем маршрутизацию по правилам (пункт 12 меню snell.sh): правила перехвата, службу, конфигурацию
    router_remove

    # Останавливаем и удаляем службы ShadowTLS, зависящие от бэкенда Snell, чтобы не оставлять висящие службы без бэкенда
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

    # Остановка и отключение всех многопользовательских служб
    if [ -d "/etc/snell/users" ]; then
        for user_conf in "/etc/snell/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
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

    # Удаление файлов служб
    rm -f "/lib/systemd/system/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.socket"
    rm -f "${SYSTEMD_DIR}/snell-netns.service"
    rm -f "/usr/local/bin/snell-netns-setup.sh"

    # Удаление исполняемых файлов и директории конфигурации
    rm -f /usr/local/bin/snell-server
    rm -rf /etc/snell
    rm -f /usr/local/bin/snell  # Удаление скрипта управления

    if ! find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-*.service" 2>/dev/null | grep -q .; then
        rm -f /usr/local/bin/shadow-tls
    fi

    # Перезагрузка конфигурации systemd
    systemctl daemon-reload

    echo -e "${GREEN}Snell и все многопользовательские конфигурации успешно удалены${RESET}"
}

# Удаление SS-2022
uninstall_ss_rust() {
    echo -e "${CYAN}Удаление SS-2022...${RESET}"

    # Получение порта основной службы для закрытия его в файрволе
    local main_port=""
    if [ -f "/etc/ss-rust/config.json" ]; then
        main_port=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' /etc/ss-rust/config.json | grep -oE '[0-9]+' | head -n 1)
    fi

    # Остановка и отключение основной службы
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f "${SYSTEMD_DIR}/ss-rust.service"
    if [ -n "$main_port" ]; then
        close_port "$main_port"
    fi

    # Очистка многопортовых узловых служб
    local extra_service
    for extra_service in "${SYSTEMD_DIR}"/ss-rust-*.service; do
        [ -f "$extra_service" ] || continue
        local svc_name=$(basename "$extra_service" .service)
        local extra_port="${svc_name#ss-rust-}"
        echo -e "${YELLOW}Остановка многопортовой службы (порт: ${extra_port})${RESET}"
        systemctl stop "$svc_name" 2>/dev/null
        systemctl disable "$svc_name" 2>/dev/null
        rm -f "$extra_service"
        case "$extra_port" in
            ''|*[!0-9]*) ;;
            *) close_port "$extra_port" ;;
        esac
    done

    # Удаление бинарного файла и директории конфигурации
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/etc/ss-rust"

    # Перезагрузка systemd
    systemctl daemon-reload

    echo -e "${GREEN}Удаление SS-2022 завершено!${RESET}"
}

# Удаление ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}Удаление ShadowTLS...${RESET}"

    # Остановка и отключение всех служб ShadowTLS
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        local service_file="${SYSTEMD_DIR}/${service}"
        local listen_port=""
        if [ -f "$service_file" ]; then
            listen_port=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
        fi
        systemctl stop "$service" 2>/dev/null
        systemctl disable "$service" 2>/dev/null
        rm -f "$service_file"
        if [ -n "$listen_port" ]; then
            close_port "$listen_port"
        fi
    done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
    
    # Удаление бинарного файла
    rm -f "/usr/local/bin/shadow-tls"
    
    # Перезагрузка systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}Удаление ShadowTLS завершено!${RESET}"
}

# Главное меню
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}      Единый скрипт управления v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}Автор: jinqian${RESET}"
    echo -e "${GREEN}Сайт:  https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    # Отображение статуса служб
    check_and_show_status
    
    echo -e "${YELLOW}=== Установка и управление ===${RESET}"
    echo -e "${GREEN}1.${RESET} Установка и управление Snell"
    echo -e "${GREEN}2.${RESET} Установка и управление SS-2022"
    echo -e "${GREEN}3.${RESET} Установка и управление VLESS Reality"
    echo -e "${GREEN}4.${RESET} Установка и управление ShadowTLS"
    
    echo -e "\n${YELLOW}=== Удаление ===${RESET}"
    echo -e "${GREEN}5.${RESET} Удалить Snell"
    echo -e "${GREEN}6.${RESET} Удалить SS-2022"
    echo -e "${GREEN}7.${RESET} Удалить ShadowTLS"
    
    echo -e "\n${YELLOW}=== Системные функции ===${RESET}"
    echo -e "${GREEN}8.${RESET} Обновить скрипт"
    echo -e "${GREEN}9.${RESET} Управление трафиком (рекомендуется использовать PSM)"
    echo -e "${GREEN}10.${RESET} Управление блокировкой IP материкового Китая (ss-2022)"
    echo -e "${GREEN}0.${RESET} Выход"
    
    echo -e "${CYAN}============================================${RESET}"

    echo -e "${GREEN}После выхода введите команду menu для повторного запуска скрипта${RESET}"

    echo -e "${CYAN}============================================${RESET}"
    read -rp "Выберите пункт меню [0-10]: " num
}

# Начальная проверка
check_root
# bc: используется для подсчета суммарного потребления CPU и памяти в статусе
ensure_cmds curl bc || exit 1
install_global_command

# Главный цикл
while true; do
    show_menu
    case "$num" in
        1)
            manage_snell
            ;;
        2)
            manage_ss_rust
            ;;
        3)
            manage_vless
            ;;
        4)
            manage_shadowtls
            ;;
        5)
            uninstall_snell
            ;;
        6)
            uninstall_ss_rust
            ;;
        7)
            uninstall_shadowtls
            ;;
        8)
            update_script
            ;;
        9)
            echo -e "\n${YELLOW}=== Управление трафиком ===${RESET}"
            echo -e "Встроенная в этот скрипт функция управления трафиком еще дорабатывается. Рекомендуется использовать ${GREEN}PSM (Proxy Stack Manager)${RESET} для учета и ограничения трафика."
            echo -e "\nPSM поддерживает единое управление лимитами трафика для протоколов Snell / SS2022 / Xray и др., включая:"
            echo -e "  • Установку месячного лимита трафика (в ГБ) и дня автоматического сброса"
            echo -e "  • Автоматическую приостановку узла при превышении лимита и разблокировку после сброса"
            echo -e "  • Точный подсчет через iptables с сохранением данных при перезагрузке"
            echo -e "\nУстановка PSM:"
            echo -e "  ${CYAN}bash <(curl -fsSL https://psm.jinqians.com)${RESET}"
            echo -e "\nПосле входа в PSM выберите пункт ${GREEN}15. Управление трафиком${RESET}, чтобы добавить узел SS2022 и настроить лимиты."
            read -p "Нажмите Enter для продолжения..."
            ;;
        10)
            if ! manage_mainland_block; then
                echo -e "${YELLOW}Проверьте адрес репозитория или подключение к сети и повторите попытку${RESET}"
                read -p "Нажмите Enter для продолжения..."
            fi
            ;;
        0)
            echo -e "${GREEN}Спасибо за использование, до свидания!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Пожалуйста, введите корректный пункт меню [0-10]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}Нажмите любую клавишу для возврата в главное меню...${RESET}"
    read -n 1 -s -r
done
