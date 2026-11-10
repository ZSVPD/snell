#!/bin/bash
# Этот файл сгенерирован скриптом tools/build.sh из src/bbr.sh и src/lib: пожалуйста, вносите изменения в файлы внутри src/ и генерируйте заново.
# =========================================
# Автор: jinqians
# Сайт: jinqians.com
# Описание: Управление BBR: включение встроенного в ядро BBR или установка ядра XanMod (BBR v3) на Debian / Ubuntu
# =========================================

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


check_root

BBR_SYSCTL="/etc/sysctl.d/99-snell-bbr.conf"
BBR_MODULES="/etc/modules-load.d/snell-bbr.conf"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_REPO="http://deb.xanmod.org"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
# Для тестирования: BBR_APT_SIMULATE=1 только симулирует установку ядра (apt-get -s); BBR_CPUINFO подменяет файл cpuinfo
CPUINFO="${BBR_CPUINFO:-/proc/cpuinfo}"

current_cc()    { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null; }
current_qdisc() { sysctl -n net.core.default_qdisc 2>/dev/null; }
available_cc()  { cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; }
bbr_available() { available_cc | grep -qw bbr; }

# Проверка, что версия ядра не ниже <мажорная> <минорная>
kernel_at_least() {
    local v maj min
    v=$(uname -r); maj=${v%%.*}; v=${v#*.}; min=${v%%[!0-9]*}
    [ "$maj" -gt "$1" ] || { [ "$maj" -eq "$1" ] && [ "${min:-0}" -ge "$2" ]; }
}

# Проверка запуска в контейнере или OpenVZ: там используется ядро хоста, заменить его нельзя и не всегда можно менять параметры sysctl
in_container() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt -c -q && return 0
        [ "$(systemd-detect-virt 2>/dev/null)" = "openvz" ] && return 0
        return 1
    fi
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] && return 0
    grep -qa 'container=' /proc/1/environ 2>/dev/null && return 0   # LXC и др.
    [ -d /proc/vz ] && [ ! -d /proc/bc ]                              # OpenVZ (на хосте есть /proc/bc)
}

# Машины с включенным Secure Boot принимают только подписанные ядра; ядро XanMod не подписано — после установки система не загрузится
secure_boot_on() {
    local f
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [ -r "$f" ] || continue
        [ "$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}')" = "1" ] && return 0
    done
    return 1
}

xanmod_suite_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${XANMOD_REPO}/dists/$1/Release")" = "200" ]; }

# Старая версия скрипта добавляла ветку репозитория XanMod «releases», которой больше нет (404), из-за чего apt-get update постоянно выдает ошибку:
# если XanMod уже установлен — меняем на кодовое имя текущей системы (обновления ядра продолжат приходить), если не установлен — удаляем файл репозитория
fix_legacy_xanmod_repo() {
    [ -f "$XANMOD_LIST" ] && grep -q '^deb .*deb\.xanmod\.org releases' "$XANMOD_LIST" || return 0
    local codename
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if xanmod_installed && [ -n "$codename" ] && command -v curl >/dev/null 2>&1 && xanmod_suite_ok "$codename"; then
        sed -i "s#deb\.xanmod\.org releases#deb.xanmod.org ${codename}#" "$XANMOD_LIST"
        echo -e "${YELLOW}Добавленный старой версией скрипта репозиторий XanMod (releases) больше не существует. Он изменен на ${codename}, ядро будет обновляться как обычно.${RESET}"
    else
        rm -f "$XANMOD_LIST"
        echo -e "${YELLOW}Добавленный старой версией скрипта репозиторий XanMod (releases) больше не существует. Он вызывал ошибки при apt-get update и был удален.${RESET}"
    fi
}

xanmod_running() { uname -r | grep -qi xanmod; }
xanmod_installed() { dpkg-query -W -f='${Status} ${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | grep -q '^install ok installed'; }

show_status() {
    local mine="нет" kern
    [ -f "$BBR_SYSCTL" ] && mine="записаны в ${BBR_SYSCTL}"
    kern=$(uname -r)
    if xanmod_running; then kern="${kern} (XanMod)"
    elif xanmod_installed; then kern="${kern} (XanMod установлен, вступит в силу после перезагрузки)"
    fi
    echo -e "  Ядро                ${kern}"
    # В контейнере не видно очереди по умолчанию (она существует только в сетевом пространстве имен хоста)
    local q; q=$(current_qdisc); q=${q:+   Очередь по умолчанию: $q}
    if [ "$(current_cc)" = "bbr" ]; then
        echo -e "  Контроль перегрузки ${GREEN}bbr${RESET}${q}"
    else
        echo -e "  Контроль перегрузки ${YELLOW}$(current_cc)${RESET}${q}   Доступно: $(available_cc)"
    fi
    echo -e "  Настройки скрипта   ${mine}"
}

BBR_KEYS="net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem"

# Записываются только параметры самого BBR (fq + bbr) и размеры буферов приема/передачи для высокоскоростных каналов с большой задержкой; форвардинг и другие системные настройки не затрагиваются.
# При первой записи исходные значения этих параметров сохраняются в файле («# Исходное значение ») для возврата при выборе «Восстановить по умолчанию»; при повторной записи сохраненные значения переносятся.
# Одноименный файл от старой версии скрипта предварительно бэкапится (sysctl читает только *.conf, поэтому бэкап не применится); значения из него были заданы старым скриптом, их не сохраняем.
write_bbr_sysctl() {
    local orig="" k v
    if [ -f "$BBR_SYSCTL" ] && grep -q '^# Исходное значение ' "$BBR_SYSCTL"; then
        orig=$(grep '^# Исходное значение ' "$BBR_SYSCTL")
    elif [ -f "$BBR_SYSCTL" ]; then
        cp -a "$BBR_SYSCTL" "${BBR_SYSCTL}.bak_$(date +%Y%m%d_%H%M%S)"
    else
        for k in $BBR_KEYS; do
            v=$(sysctl -n "$k" 2>/dev/null | tr -s '\t ' '  ')
            [ -n "$v" ] && orig="${orig:+$orig
}# Исходное значение ${k} = ${v}"
        done
    fi
    # В минималистичных системах (например, образах контейнеров) этих двух директорий может не быть
    mkdir -p "$(dirname "$BBR_SYSCTL")" "$(dirname "$BBR_MODULES")"
    {
        echo "# Записано управлением BBR из snell.sh. Удалите этот файл и перезагрузитесь (или выберите «Восстановить по умолчанию» в меню) для возврата прежних настроек."
        [ -n "$orig" ] && printf '%s\n' "$orig"
        cat <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
EOF
    } > "$BBR_SYSCTL"
    # Если BBR собран как модуль — загружать его при старте системы (если встроен в ядро — тоже не помешает)
    echo "tcp_bbr" > "$BBR_MODULES"
}

# Поочередное применение параметров; если в контейнере какие-то параметры изменить нельзя — выводим предупреждение без прерывания работы
apply_bbr_sysctl() {
    local out
    if ! out=$(sysctl -p "$BBR_SYSCTL" 2>&1); then
        echo -e "${YELLOW}Некоторые параметры не удалось применить (в контейнере нельзя изменить настройки хоста):${RESET}"
        printf '%s\n' "$out" | grep -i -E 'error|denied|cannot|read-only|invalid' | sed 's/^/  /'
    fi
}

# Старые версии скрипта записывали целый блок параметров в /etc/sysctl.conf (до сентября 2026 файл перезаписывался целиком) или в 99-snell-bbr.conf,
# попутно включая IP-форвардинг и route_localnet: первое лишает IPv6-адреса машины, получающие его через Router Advertisements (RA), второе представляет угрозу безопасности.
# 99-snell-bbr.conf — это файл данного скрипта, он будет полностью заменен; /etc/sysctl.conf — системный файл, перед изменением спрашиваем пользователя.
cleanup_legacy_sysctl() {
    local f=/etc/sysctl.conf keys ans fixed=""
    keys='net\.ipv4\.conf\.all\.route_localnet|net\.ipv4\.ip_forward|net\.ipv4\.conf\.(all|default)\.forwarding|net\.ipv6\.conf\.(all|default)\.forwarding|net\.ipv4\.tcp_fack'
    if [ -f "$BBR_SYSCTL" ] && grep -q '^net\.ipv4\.conf\.all\.route_localnet = 1' "$BBR_SYSCTL"; then
        echo -e "${YELLOW}Созданный старой версией файл ${BBR_SYSCTL} включал IP-форвардинг и route_localnet. Заменяем только на настройки BBR (будет создана резервная копия исходного файла).${RESET}"
        fixed=1
    fi
    if [ -f "$f" ] && grep -q '^net\.ipv4\.conf\.all\.route_localnet = 1' "$f"; then
        echo -e "${YELLOW}В /etc/sysctl.conf обнаружены настройки от старой версии скрипта BBR: включены IP-форвардинг и route_localnet.${RESET}"
        echo -e "${YELLOW}route_localnet несет угрозу безопасности; форвардинг IPv6 может привести к потере IPv6 на машинах, получающих адрес через Router Advertisements.${RESET}"
        read -rp "Закомментировать эти строки? (будет создана резервная копия файла) [Y/n]: " ans
        case "$ans" in
            [nN]*) ;;
            *)
                cp -a "$f" "${f}.bak_$(date +%Y%m%d_%H%M%S)"
                sed -i -E "s/^(($keys)[[:space:]]*=.*)$/# Закомментировано управлением BBR: \1/" "$f"
                fixed=1
                ;;
        esac
    fi
    [ -n "$fixed" ] || return 0
    sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true
    echo -e "${GREEN}route_localnet немедленно отключен; настройки форвардинга вернутся к значениям по умолчанию после следующей перезагрузки (программы вроде Docker, которым нужен форвардинг, включат его сами).${RESET}"
}

enable_bbr() {
    ensure_cmds sysctl modprobe || return 1
    if ! kernel_at_least 4 9; then
        echo -e "${RED}Ядро $(uname -r) слишком старое: для BBR требуется версия 4.9 или выше. На Debian / Ubuntu можно выбрать пункт «2» для установки ядра XanMod.${RESET}"
        return 1
    fi
    modprobe tcp_bbr 2>/dev/null || true
    if ! bbr_available; then
        if in_container; then
            echo -e "${RED}BBR не загружен (доступные алгоритмы контроля перегрузки: $(available_cc)). Это контейнер или OpenVZ, модули могут загружаться только на хосте:${RESET}"
            echo -e "${YELLOW}Выполните modprobe tcp_bbr на хост-машине и попробуйте снова; для OpenVZ обратитесь к хостинг-провайдеру.${RESET}"
        else
            echo -e "${RED}В этом ядре нет поддержки BBR (доступные алгоритмы: $(available_cc)). На Debian / Ubuntu можно выбрать пункт «2» для установки ядра XanMod.${RESET}"
        fi
        return 1
    fi
    cleanup_legacy_sysctl
    write_bbr_sysctl
    apply_bbr_sysctl
    if [ "$(current_cc)" = "bbr" ]; then
        echo -e "${GREEN}✓ BBR включен (контроль перегрузки: bbr, очередь по умолчанию: $(current_qdisc)), сохранится после перезагрузки.${RESET}"
    else
        echo -e "${RED}Не удалось переключиться на BBR, текущий алгоритм контроля перегрузки по-прежнему $(current_cc).${RESET}"
        return 1
    fi
}

# Уровень набора инструкций x86-64, поддерживаемый процессором (1–4); XanMod разделяет пакеты ядер по этим уровням
cpu_level() {
    local flags f
    flags=" $(grep -m1 '^flags' "$CPUINFO" | cut -d: -f2) "
    has() { for f in "$@"; do case "$flags" in *" $f "*) ;; *) return 1 ;; esac; done; }
    has cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 || { echo 1; return; }
    has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave || { echo 2; return; }
    has avx512f avx512bw avx512cd avx512dq avx512vl || { echo 3; return; }
    echo 4
}

# Получение списка пакетов ядер XanMod, доступных в репозитории для данной версии системы (например, для Debian 12 есть только LTS-версии)
xanmod_packages() {   # <codename>
    curl -fsSL --retry 2 --max-time 60 "${XANMOD_REPO}/dists/$1/main/binary-amd64/Packages.gz" | gzip -dc 2>/dev/null |
        sed -n 's/^Package: \(linux-xanmod-[a-z0-9-]*\)$/\1/p' | sort -u
}

# Сопоставление уровня CPU и пакета: сначала ищем mainline, если нет — LTS, если и его нет — на уровень ниже (ядра более низкого уровня нормально работают на новых CPU).
# В mainline есть только x64v2 и x64v3 (процессоры с v4 используют v3), для v1 осталась только LTS-версия
xanmod_package() {   # <уровень> <доступные в репозитории пакеты, по одному на строке>
    local c want
    case "$1" in
        1) want="lts-x64v1" ;;
        2) want="x64v2 lts-x64v2 lts-x64v1" ;;
        *) want="x64v3 lts-x64v3 x64v2 lts-x64v2 lts-x64v1" ;;
    esac
    for c in $want; do
        printf '%s\n' "$2" | grep -qx "linux-xanmod-$c" && { echo "linux-xanmod-$c"; return 0; }
    done
    return 1
}

install_xanmod() {
    detect_os
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${RED}XanMod предоставляет ядра только для архитектуры x86_64, а здесь $(uname -m). Вы можете выбрать пункт «1» для использования встроенного в ядро BBR.${RESET}"; return 1
    fi
    if [ "$OS_FAMILY" != "debian" ]; then
        echo -e "${RED}XanMod предоставляет пакеты только для Debian / Ubuntu. Вы можете выбрать пункт «1» для использования встроенного в ядро BBR.${RESET}"; return 1
    fi
    # Симуляция установки (для тестов) не затрагивает ядро, поэтому ее можно прогнать и в контейнере
    if in_container && [ "${BBR_APT_SIMULATE:-}" != "1" ]; then
        echo -e "${RED}Это контейнер или OpenVZ: используется ядро хоста, заменить его нельзя.${RESET}"; return 1
    fi
    if secure_boot_on; then
        echo -e "${RED}На этой машине включена безопасная загрузка (Secure Boot): ядра XanMod не подписаны, после установки система не сможет загрузиться.${RESET}"
        echo -e "${YELLOW}Чтобы сменить ядро, сначала отключите Secure Boot в панели управления хостинг-провайдера; либо выберите пункт «1» для использования встроенного BBR.${RESET}"; return 1
    fi
    ensure_cmds curl gpg gzip || return 1
    local codename level pkg ans
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if [ -z "$codename" ] || ! xanmod_suite_ok "$codename"; then
        echo -e "${RED}У XanMod нет репозитория для этой версии системы (${codename:-неизвестно}). Поддерживаются Debian 12 / 13, Ubuntu 24.04 и др.${RESET}"; return 1
    fi
    level=$(cpu_level)
    if ! pkg=$(xanmod_package "$level" "$(xanmod_packages "$codename")"); then
        echo -e "${RED}В репозитории XanMod для ${codename} нет подходящего пакета ядра для этого процессора (x86-64-v${level}), либо не удалось загрузить список пакетов.${RESET}"; return 1
    fi
    echo -e "${CYAN}Уровень инструкций CPU: x86-64-v${level}  →  установка ${pkg} (система: ${codename})${RESET}"
    echo -e "${YELLOW}Будет установлено новое ядро и назначено по умолчанию, изменения вступят в силу после перезагрузки; текущее ядро останется в меню загрузки.${RESET}"
    read -rp "Продолжить? [y/N]: " ans
    case "$ans" in [yY]*) ;; *) echo "Отменено."; return 0 ;; esac

    mkdir -p "$(dirname "$XANMOD_KEYRING")"
    if ! curl -fsSL --retry 3 --max-time 60 "$XANMOD_KEY_URL" | gpg --dearmor --yes -o "$XANMOD_KEYRING"; then
        echo -e "${RED}Не удалось скачать ключ подписи XanMod.${RESET}"; return 1
    fi
    echo "deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPO} ${codename} main" > "$XANMOD_LIST"
    wait_for_apt
    if ! apt-get update -qq; then
        echo -e "${RED}Ошибка выполнения apt-get update.${RESET}"; return 1
    fi
    local sim=""
    [ "${BBR_APT_SIMULATE:-}" = "1" ] && sim="-s"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $sim "$pkg"; then
        echo -e "${RED}Ошибка установки ${pkg}.${RESET}"; return 1
    fi
    if [ -n "$sim" ]; then
        echo -e "${YELLOW}(Симуляция установки, ядро на самом деле не устанавливалось)${RESET}"; return 0
    fi
    # Алгоритм контроля перегрузки по умолчанию в XanMod — уже BBR v3; тем не менее записываем параметры в конфиг для единообразия после перезагрузки
    cleanup_legacy_sysctl
    write_bbr_sysctl
    echo -e "${GREEN}✓ ${pkg} установлен, новое ядро и BBR v3 будут задействованы после перезагрузки.${RESET}"
    read -rp "Перезагрузить сейчас? [y/N]: " ans
    case "$ans" in [yY]*) reboot ;; esac
}

reset_bbr() {
    if [ ! -f "$BBR_SYSCTL" ] && [ ! -f "$BBR_MODULES" ]; then
        echo -e "${YELLOW}Этот скрипт еще не записывал настройки BBR.${RESET}"; return 0
    fi
    local orig="" line
    [ -f "$BBR_SYSCTL" ] && orig=$(sed -n 's/^# Исходное значение //p' "$BBR_SYSCTL")
    rm -f "$BBR_SYSCTL" "$BBR_MODULES"
    if [ -n "$orig" ]; then
        printf '%s\n' "$orig" | while IFS= read -r line; do
            sysctl -w "${line%% = *}=${line#* = }" >/dev/null 2>&1 || true
        done
    else
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    fi
    # Повторно применяем собственные системные конфигурации (остальные файлы в sysctl.d), как при загрузке ОС
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ Настройки BBR этого скрипта удалены. Контроль перегрузки: $(current_cc), очередь по умолчанию: $(current_qdisc).${RESET}"
    if [ "$(current_cc)" = "bbr" ] && ! xanmod_running; then
        local where
        where=$(grep -lsE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr' /etc/sysctl.conf /etc/sysctl.d/*.conf | tr '\n' ' ')
        [ -n "$where" ] && echo -e "${YELLOW}Контроль перегрузки по-прежнему bbr: он также задан в ${where}(записано не этим скриптом, оставлено без изменений).${RESET}"
    fi
    xanmod_installed && echo -e "${YELLOW}Ядро XanMod все еще установлено. Чтобы вернуться к стандартному ядру, выполните: apt-get remove 'linux-image-*xanmod*' 'linux-headers-*xanmod*' и перезагрузите систему.${RESET}"
    return 0
}

main_menu() {
    local choice
    fix_legacy_xanmod_repo
    while true; do
        echo
        echo -e "${CYAN}── Управление BBR ────────────────────────────${RESET}"
        show_status
        echo -e "${CYAN}──────────────────────────────────────────────${RESET}"
        echo -e "  ${GREEN}1${RESET}  Включить BBR (встроенный в ядро)"
        echo -e "  ${GREEN}2${RESET}  Установить ядро XanMod (BBR v3, Debian / Ubuntu x86_64)"
        echo -e "  ${GREEN}3${RESET}  Восстановить по умолчанию (удалить настройки BBR этого скрипта)"
        echo -e "  ${GREEN}0${RESET}  Назад"
        if ! read -rp "Выберите действие [0-3]: " choice; then
            echo; return 0
        fi
        case "$choice" in
            1) enable_bbr ;;
            2) install_xanmod ;;
            3) reset_bbr ;;
            0) return 0 ;;
            *) echo -e "${RED}Неверный выбор${RESET}" ;;
        esac
    done
}

main_menu
