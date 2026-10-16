#!/usr/bin/env bash
#
# increase-upload-limit-v2.sh
# Увеличивает лимиты загрузки файлов для WordPress и ПРОВЕРЯЕТ,
# что значения реально применились (не просто "прописались в файл").
#
# Использование:
#   sudo ./increase-upload-limit-v2.sh [размер_в_MB]

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Запустите с sudo: sudo ./increase-upload-limit-v2.sh [размер_в_MB]"
  exit 1
fi

LIMIT_MB="${1:-64}"

echo "=================================================================="
echo "1. Какая версия PHP реально обслуживает сайт?"
echo "=================================================================="
NGINX_SITE=$(grep -rl "fastcgi_pass" /etc/nginx/sites-enabled/ 2>/dev/null | head -n1 || true)
if [[ -z "${NGINX_SITE}" ]]; then
  echo "Не нашёл активный конфиг Nginx с fastcgi_pass. Ищу вручную..."
  NGINX_SITE=$(find /etc/nginx/sites-enabled -type f | head -n1)
fi
echo "Конфиг сайта: ${NGINX_SITE}"
SOCK_LINE=$(grep -oP 'fastcgi_pass\s+unix:\K[^;]+' "${NGINX_SITE}" | head -n1 || true)
echo "Сокет PHP-FPM, который использует сайт: ${SOCK_LINE}"
PHP_VER_FROM_SOCK=$(echo "${SOCK_LINE}" | grep -oP 'php\K[0-9]+\.[0-9]+' || true)
echo "Версия PHP из сокета: ${PHP_VER_FROM_SOCK:-не определилась}"
echo ""

echo "=================================================================="
echo "2. Все установленные php.ini для php-fpm"
echo "=================================================================="
PHP_INI_FILES=$(find /etc/php -path "*/fpm/php.ini" 2>/dev/null || true)
echo "${PHP_INI_FILES}"
echo ""

if [[ -z "${PHP_INI_FILES}" ]]; then
  echo "php.ini для fpm не найден. PHP-FPM установлен?"
  exit 1
fi

echo "=================================================================="
echo "3. Правлю php.ini + пул (pool) конфиги — пул может переопределять php.ini"
echo "=================================================================="
for INI in ${PHP_INI_FILES}; do
  echo "--- ${INI} ---"
  cp "${INI}" "${INI}.bak.$(date +%Y%m%d%H%M%S)"

  for KEY_VAL in "upload_max_filesize=${LIMIT_MB}M" "post_max_size=${LIMIT_MB}M" "memory_limit=256M" "max_execution_time=120"; do
    KEY="${KEY_VAL%%=*}"
    VAL="${KEY_VAL#*=}"
    if grep -qE "^${KEY}\s*=" "${INI}"; then
      sed -i -E "s/^${KEY}\s*=.*/${KEY} = ${VAL}/" "${INI}"
    else
      echo "${KEY} = ${VAL}" >> "${INI}"
    fi
    echo "  ${KEY} = ${VAL}"
  done

  # Проверяем пул-конфиги той же версии PHP на php_admin_value / php_value —
  # они ИМЕЮТ ПРИОРИТЕТ над php.ini и часто являются причиной, почему правка php.ini "не действует"
  POOL_DIR=$(dirname "$(dirname "${INI}")")/fpm/pool.d
  if [[ -d "${POOL_DIR}" ]]; then
    for POOL in "${POOL_DIR}"/*.conf; do
      [[ -f "${POOL}" ]] || continue
      if grep -qE "php_(admin_)?value\[(upload_max_filesize|post_max_size)\]" "${POOL}"; then
        echo "  !! Найдено переопределение в пуле ${POOL} — правлю и его:"
        cp "${POOL}" "${POOL}.bak.$(date +%Y%m%d%H%M%S)"
        sed -i -E "s/(php_(admin_)?value\[upload_max_filesize\]\s*=\s*).*/\1${LIMIT_MB}M/" "${POOL}"
        sed -i -E "s/(php_(admin_)?value\[post_max_size\]\s*=\s*).*/\1${LIMIT_MB}M/" "${POOL}"
        grep -E "php_(admin_)?value\[(upload_max_filesize|post_max_size)\]" "${POOL}"
      fi
    done
  fi
done
echo ""

echo "=================================================================="
echo "4. Обновляю client_max_body_size в Nginx"
echo "=================================================================="
if grep -q "client_max_body_size" "${NGINX_SITE}"; then
  sed -i -E "s/client_max_body_size\s+[0-9]+M;/client_max_body_size ${LIMIT_MB}M;/" "${NGINX_SITE}"
else
  sed -i "/server_name/a\\    client_max_body_size ${LIMIT_MB}M;" "${NGINX_SITE}"
fi
grep "client_max_body_size" "${NGINX_SITE}"
echo ""

echo "=================================================================="
echo "5. Перезапускаю ВСЕ php-fpm сервисы и nginx"
echo "=================================================================="
for SERVICE in $(systemctl list-units --full -all --type=service | grep -oP 'php[0-9.]+-fpm\.service' | sort -u); do
  systemctl restart "${SERVICE}"
  echo "Перезапущен: ${SERVICE}"
done
nginx -t
systemctl reload nginx
echo ""

echo "=================================================================="
echo "6. Проверка фактического значения (напрямую у PHP, без веб-сервера)"
echo "=================================================================="
for INI in ${PHP_INI_FILES}; do
  PHP_VER=$(echo "${INI}" | grep -oP '/php/\K[0-9]+\.[0-9]+')
  if command -v "php${PHP_VER}" >/dev/null 2>&1; then
    BIN="php${PHP_VER}"
  else
    BIN="php"
  fi
  echo "--- ${BIN} (использует ${INI}) ---"
  "${BIN}" -c "${INI}" -r 'echo "upload_max_filesize = " . ini_get("upload_max_filesize") . "\n"; echo "post_max_size = " . ini_get("post_max_size") . "\n";'
done

echo ""
echo "=================================================================="
echo "Готово. Обновите страницу Медиафайлы → Добавить новый в WordPress"
echo "(жёсткое обновление страницы: Ctrl+F5 / Cmd+Shift+R)."
echo ""
echo "Если цифра выше в пункте 6 уже ${LIMIT_MB}M, а в WordPress всё ещё старая —"
echo "пришлите мне полный вывод этого скрипта, разберём дальше."
echo "=================================================================="
