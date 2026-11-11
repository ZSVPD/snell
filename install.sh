#!/bin/sh
# Этот файл сгенерирован скриптом tools/build.sh из src/install.sh и src/lib: пожалуйста, вносите изменения в файлы внутри src/ и генерируйте заново.

# ==============================================================================
# - Используется более безопасный режим «сначала скачать локально, затем выполнить».
# - Автоматическая очистка временных файлов.
# - Принудительный запуск от имени root и автоматическая установка зависимостей.
# ==============================================================================

# --- 0. Механизм очистки ---
# Используется команда trap, чтобы гарантировать автоматическое удаление временного файла
# при любом завершении скрипта (нормальный выход, ошибка, прерывание).
# Имя временного файла генерируется случайно через mktemp для защиты от локальных атак с предсозданием символьных ссылок.
TMP_FILE=$(mktemp /tmp/install_payload.XXXXXX) || { echo "Ошибка: не удалось создать временный файл." >&2; exit 1; }
trap 'rm -f "$TMP_FILE"' EXIT

# --- 1. Проверка прав доступа ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: этот скрипт должен запускаться с правами пользователя root." >&2
  exit 1
fi

# --- 2. Определение операционной системы ---
OS_FAMILY=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
  ID_LIKE=$(echo "$ID_LIKE" | tr '[:upper:]' '[:lower:]')
  if echo "$ID_LIKE" | grep -q "debian" || [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ]; then
    OS_FAMILY="debian"
  elif echo "$ID_LIKE" | grep -q "rhel" || echo "$ID_LIKE" | grep -q "centos" || [ "$OS_ID" = "centos" ] || [ "$OS_ID" = "rhel" ] || [ "$OS_ID" = "fedora" ]; then
    OS_FAMILY="rhel"
  elif [ "$OS_ID" = "alpine" ]; then
    OS_FAMILY="alpine"
  fi
fi
if [ -z "$OS_FAMILY" ]; then
  echo "Ошибка: не удалось определить тип операционной системы." >&2; exit 1;
fi

# --- 3. Проверка и автоматическая установка зависимостей ---
ensure_packages() {
  for pkg in "$@"; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      echo "--> Команда '$pkg' не найдена, попытка автоматической установки..."
      case "$OS_FAMILY" in
        debian) apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "$pkg" ;;
        rhel) if command -v dnf >/dev/null 2>&1; then dnf install -y "$pkg"; else yum install -y "$pkg"; fi ;;
        alpine) apk add --no-cache "$pkg" ;;
      esac
      if ! command -v "$pkg" >/dev/null 2>&1; then
        echo "Ошибка: не удалось автоматически установить '$pkg'. Пожалуйста, установите вручную и повторите попытку." >&2; exit 1;
      else
        echo "--> '$pkg' успешно установлен.";
      fi
    fi
  done
}

# --- 4. Выполнение основной логики ---
ensure_packages "curl"

# Можно заменить на зеркало с помощью одноименных переменных окружения (при тестировании можно указать локальные файлы)
DEBIAN_URL="${SNELL_SCRIPT_URL:-https://raw.githubusercontent.com/ZSVPD/snell-script/main/snell.sh}"
CENTOS_URL="${SNELL_CENTOS_SCRIPT_URL:-https://snell-centos.jinqians.com}"
ALPINE_URL="${SNELL_DOCKER_SCRIPT_URL:-https://snell-docker.jinqians.com}"

# Проверка синтаксиса: приоритетно используется bash -n (умеет парсить синтаксис sh), при отсутствии bash используется sh -n
check_syntax() {
  if command -v bash >/dev/null 2>&1; then
    bash -n "$1"
  else
    sh -n "$1"
  fi
}

main() {
  url=$1
  os_name=$2
  shell_to_use=$3

  echo "--------------------------------------------------"
  echo "Тип системы:      $os_name"
  echo "Удаленный скрипт: $url"
  echo "Режим работы:     скачивание скрипта в $TMP_FILE с последующим выполнением"
  echo "--------------------------------------------------"
  printf "Вы уверены, что хотите продолжить? [y/N]: "
  read -r choice

  case "$choice" in
    y|Y)
      echo "--> Скачивание скрипта в $TMP_FILE ..."
      # Опция -o сохраняет вывод в файл, опция -f заставляет curl тихо завершаться с ошибкой при сбое на стороне сервера
      if ! curl -sSL -f -o "$TMP_FILE" "$url"; then
        echo "Ошибка: не удалось скачать скрипт, проверьте URL или подключение к сети." >&2
        # trap автоматически удалит пустой файл после неудачного скачивания
        exit 1
      fi

      # Проверка целостности: файл не пустой + проверка синтаксиса; при неудаче файл отбрасывается и выполнение прерывается
      if [ ! -s "$TMP_FILE" ]; then
        echo "Ошибка: скачанный файл пуст, выполнение прервано." >&2
        exit 1
      fi
      if ! check_syntax "$TMP_FILE" 2>/dev/null; then
        echo "Ошибка: скачанный скрипт не прошел проверку синтаксиса и был удален." >&2
        exit 1
      fi
      echo "--> Проверка скачанного файла успешно пройдена."

      echo "--> Скачивание завершено. Назначение прав на выполнение..."
      chmod +x "$TMP_FILE"

      echo "--> Запуск локального скрипта $TMP_FILE ..."
      # Непосредственное выполнение локального скрипта
      "$TMP_FILE"
      echo "--> Выполнение локального скрипта завершено."
      ;;
    *)
      echo "--> Операция отменена."
      exit 0
      ;;
  esac
}

case "$OS_FAMILY" in
  debian) main "$DEBIAN_URL" "Debian/Ubuntu" "bash" ;;
  rhel)   main "$CENTOS_URL" "CentOS/RHEL" "bash" ;;
  alpine) main "$ALPINE_URL" "Alpine" "sh" ;;
esac

# trap выполнится на последнем шаге завершения скрипта и удалит временный файл
exit 0
