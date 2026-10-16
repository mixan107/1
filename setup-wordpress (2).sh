#!/usr/bin/env bash
#
# setup-wordpress.sh
# Автоматическая установка LEMP-стека и WordPress на Ubuntu Server 22.04/24.04
#
# Использование:
#   1. Скопируйте этот файл на свежую VM (Ubuntu Server), например через scp
#      или примонтированную папку VirtualBox.
#   2. chmod +x setup-wordpress.sh
#   3. sudo ./setup-wordpress.sh
#
# После завершения сайт будет доступен по IP машины (http://<IP-VM>/)
# либо через проброшенный порт, если используете NAT в VirtualBox.

set -euo pipefail

# ---------- НАСТРОЙКИ (при желании поменяйте перед запуском) ----------
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS="$(openssl rand -base64 16)"   # случайный пароль, будет выведен в конце
WP_DIR="/var/www/wordpress"
SITE_NAME="wordpress"                  # имя конфига nginx
DOMAIN="ekaterina.vostrok.ru"          # домен для сайта и SSL-сертификата
CERTBOT_EMAIL=""                       # укажите email для уведомлений Let's Encrypt (например admin@vostrok.ru), можно оставить пустым
# ------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт с sudo: sudo ./setup-wordpress.sh"
  exit 1
fi

echo "=== 1/7: Обновление системы ==="
apt update && apt upgrade -y

echo "=== 2/8: Установка Nginx, MySQL, PHP, Certbot ==="
DEBIAN_FRONTEND=noninteractive apt install -y \
  nginx mysql-server \
  php-fpm php-mysql php-xml php-curl php-gd php-mbstring php-zip php-intl \
  unzip curl certbot python3-certbot-nginx

PHP_VERSION=$(php -v | head -n1 | grep -oP '^PHP \K[0-9]+\.[0-9]+')
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

echo "=== 3/8: Настройка базы данных ==="
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

echo "=== 4/8: Загрузка WordPress ==="
mkdir -p /var/www
cd /tmp
curl -sSL -O https://wordpress.org/latest.tar.gz
rm -rf "${WP_DIR}"
tar -xzf latest.tar.gz -C /var/www
mv /var/www/wordpress "${WP_DIR}" 2>/dev/null || true
rm -f latest.tar.gz

echo "=== 5/8: Настройка wp-config.php ==="
cp "${WP_DIR}/wp-config-sample.php" "${WP_DIR}/wp-config.php"
sed -i "s/database_name_here/${DB_NAME}/" "${WP_DIR}/wp-config.php"
sed -i "s/username_here/${DB_USER}/" "${WP_DIR}/wp-config.php"
sed -i "s/password_here/${DB_PASS}/" "${WP_DIR}/wp-config.php"

# Подставляем уникальные ключи безопасности WordPress
SALT=$(curl -sSL https://api.wordpress.org/secret-key/1.1/salt/ || true)
if [[ -n "$SALT" ]]; then
  php -r "
    \$content = file_get_contents('${WP_DIR}/wp-config.php');
    \$content = preg_replace(
      '/define\(\s*\x27AUTH_KEY\x27.*put your unique phrase here.*\n(.*\n){0,7}/m',
      '', \$content
    );
    \$content = str_replace(
      \"/* That's all, stop editing!\",
      \"${SALT//$'\n'/\\n}\n\n/* That's all, stop editing!\",
      \$content
    );
    file_put_contents('${WP_DIR}/wp-config.php', \$content);
  " || echo "Не удалось автоматически подставить ключи — можно сделать вручную позже."
fi

echo "=== 6/8: Права доступа ==="
chown -R www-data:www-data "${WP_DIR}"
find "${WP_DIR}" -type d -exec chmod 755 {} \;
find "${WP_DIR}" -type f -exec chmod 644 {} \;

echo "=== 7/8: Настройка Nginx ==="
cat > "/etc/nginx/sites-available/${SITE_NAME}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WP_DIR};
    index index.php index.html;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }

    location ~ /\.ht {
        deny all;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; allow all; }
}
EOF

ln -sf "/etc/nginx/sites-available/${SITE_NAME}" "/etc/nginx/sites-enabled/${SITE_NAME}"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
systemctl enable nginx mysql "php${PHP_VERSION}-fpm"

# Firewall (если ufw установлен) — открываем SSH, HTTP и HTTPS
if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH || true
  ufw allow 80,443/tcp || true
fi

echo "=== 8/8: Получение SSL-сертификата (Let's Encrypt) для ${DOMAIN} ==="
SSL_OK=0
if [[ -n "${DOMAIN}" ]]; then
  CERTBOT_ARGS=(--nginx -d "${DOMAIN}" --non-interactive --agree-tos --redirect)
  if [[ -n "${CERTBOT_EMAIL}" ]]; then
    CERTBOT_ARGS+=(-m "${CERTBOT_EMAIL}")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi

  if certbot "${CERTBOT_ARGS[@]}"; then
    SSL_OK=1
  else
    echo ""
    echo "!!! Не удалось получить сертификат автоматически."
    echo "!!! Обычная причина — домен ${DOMAIN} ещё не указывает (A-запись) на публичный IP этой машины,"
    echo "!!! или порт 80/443 не проброшен наружу (актуально для локальной VM в VirtualBox за NAT/роутером)."
    echo "!!! Когда DNS будет настроен и порты открыты, запустите вручную:"
    echo "!!!   sudo certbot --nginx -d ${DOMAIN}"
    echo ""
  fi
fi

IP_ADDR=$(hostname -I | awk '{print $1}')

echo ""
echo "=================================================================="
echo "Готово! WordPress установлен."
echo ""
if [[ "${SSL_OK}" -eq 1 ]]; then
  echo "Откройте в браузере:   https://${DOMAIN}/"
else
  echo "Домен:      ${DOMAIN} (SSL-сертификат пока не выпущен, см. сообщение выше)"
  echo "Откройте в браузере:   http://${IP_ADDR}/  (по IP, без SSL)"
  echo "или, если DNS для ${DOMAIN} уже настроен: http://${DOMAIN}/"
fi
echo "(если используете NAT в VirtualBox — через проброшенный порт хоста)"
echo ""
echo "Данные базы данных:"
echo "  База:      ${DB_NAME}"
echo "  Юзер:      ${DB_USER}"
echo "  Пароль:    ${DB_PASS}"
echo ""
echo "Сохраните пароль от БД — он больше нигде не выводится!"
echo "Завершите установку WordPress через веб-интерфейс (язык, название сайта, админ-аккаунт)."
echo "=================================================================="
