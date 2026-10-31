#!/usr/bin/env bash

PASS=0
FAIL=0

check() {
    DESC="$1"
    EXPECTED="$2"
    ACTUAL="$3"
    if [ "$ACTUAL" = "$EXPECTED" ]; then
        echo " [OK]  $DESC"
        PASS=$((PASS+1))
    else
        echo " [FAIL] $DESC (ожидалось: '$EXPECTED', получено: '$ACTUAL')"
        FAIL=$((FAIL+1))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
check "MaxAuthTries = 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"
PORT_SSH=$(sudo sshd -T | awk '/^port/{print $2}')
if [ "$PORT_SSH" != "22" ] && [ -n "$PORT_SSH" ]; then
    echo " [OK]  Порт SSH нестандартный ($PORT_SSH)"
    PASS=$((PASS+1))
else
    echo " [FAIL] Порт SSH равен 22"
    FAIL=$((FAIL+1))
fi

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
check "Политика incoming = deny" "deny" "$(sudo ufw status verbose | awk '/Default:/{print $2}')"

echo "[3] Веб-сервер"
if sudo nginx -t > /dev/null 2>&1; then
    echo " [OK]  Синтаксис Nginx корректен"
    PASS=$((PASS+1))
else
    echo " [FAIL] Синтаксис Nginx содержит ошибки"
    FAIL=$((FAIL+1))
fi

EXPIRY=$(sudo openssl x509 -checkend 2592000 -noout -in /etc/ssl/certs/devops.crt 2>/dev/null)
if echo "$EXPIRY" | grep -q "will not expire"; then
    echo " [OK]  Сертификат действителен более 30 дней"
    PASS=$((PASS+1))
else
    echo " [FAIL] Сертификат истекает или отсутствует"
    FAIL=$((FAIL+1))
fi

WRITABLE=$(find /var/www/devops-site -perm -o+w 2>/dev/null)
if [ -z "$WRITABLE" ]; then
    echo " [OK]  В каталоге ресурса нет файлов с правом записи для всех"
    PASS=$((PASS+1))
else
    echo " [FAIL] Найдены файлы с правом записи для всех: $WRITABLE"
    FAIL=$((FAIL+1))
fi
KEY_PERMS=$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null || echo "missing")
check "Права на закрытый ключ TLS равны 600" "600" "$KEY_PERMS"

echo "[4] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
DB_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo "missing")
check "СУБД в состоянии healthy" "healthy" "$DB_HEALTH"

BAD_PORTS=$(ss -tln | grep -E ':(5000|5432)' | grep -v '127.0.0.1' || true)
if [ -z "$BAD_PORTS" ]; then
    echo " [OK]  Порты приложения и СУБД не опубликованы наружу"
    PASS=$((PASS+1))
else
    echo " [FAIL] Найдены опасно опубликованные порты: $BAD_PORTS"
    FAIL=$((FAIL+1))
fi

ENV_PERMS=$(stat -c '%a' ~/app/.env 2>/dev/null || echo "missing")
check "Права на файл .env равны 600" "600" "$ENV_PERMS"

echo "Пройдено: $PASS, не пройдено: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    exit 0
else
    exit 1
fi
