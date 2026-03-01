## Enhanced WireGuard installer with DPI bypass

Скрипт `wireguard-install.sh` предназначен для первого запуска на новом сервере и включает:

- **обфускацию трафика через HTTPS** (wstunnel) — DPI видит обычный HTTPS, а не WireGuard;
- анти-блокировочные сетевые параметры (`MTU`, `PersistentKeepalive`, TCP MSS clamp);
- профиль совместимости для restrictive-сетей (рекомендован для пользователей из РФ);
- безопасные значения по умолчанию для маршрутизации;
- опциональный IPv6 (IPv4-first в restrictive-профиле);
- post-install проверки состояния интерфейса, порта, DNS, wstunnel и sysctl;
- автогенерацию скриптов подключения для клиентов (Linux, macOS, Windows).

## Как это работает

```
Клиент (Россия)                         Сервер
┌─────────────────┐                  ┌──────────────────────┐
│ WireGuard        │                  │ wstunnel (443/tcp)   │
│  Endpoint:       │   HTTPS/WSS     │   ↓                  │
│  127.0.0.1:51820 │ ──────────────→ │ WireGuard (51820/udp)│
│                  │  выглядит как   │   ↓                  │
│ wstunnel client  │  обычный HTTPS  │ NAT → интернет       │
└─────────────────┘                  └──────────────────────┘
```

DPI (ТСПУ) видит только HTTPS-трафик на порт 443 — стандартное TLS-соединение.
WireGuard-пакеты полностью скрыты внутри WebSocket-over-TLS.

## Быстрый запуск на новом сервере

```bash
git clone <repo-url>
cd enhanced-vpn
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh
```

## Рекомендуемые ответы в мастере установки

- `Restrictive-network profile` — `y` (особенно для пользователей из РФ).
- **`Traffic obfuscation (wstunnel)`** — **`y`** (обязательно для РФ!).
- `Public endpoint` — публичный IP или домен сервера.
- `WireGuard internal port` — оставить предложенный случайный порт (при обфускации не виден снаружи).
- `HTTPS obfuscation port` — `443` (выглядит как обычный HTTPS).
- `Enable IPv6` — `n`, если нет уверенности в стабильном IPv6 end-to-end.
- `DNS resolvers` — по умолчанию `9.9.9.9` и `8.8.8.8` в restrictive-профиле.
- `Client MTU` — `1200` (при обфускации) или `1280` (без обфускации).
- `PersistentKeepalive` — `25`.
- `Enable TCP MSS clamping` — `y`.
- `Enable kernel network optimizations` — `y`.
- `Allowed IPs` — `0.0.0.0/0`.

## Подключение клиентов (с обфускацией)

При создании клиента скрипт генерирует:
- `.conf` — стандартный WireGuard конфиг (Endpoint = 127.0.0.1:PORT)
- `*-tunnel/connect.sh` — скрипт подключения для Linux
- `*-tunnel/connect-macos.sh` — скрипт подключения для macOS
- `*-tunnel/connect.bat` — скрипт подключения для Windows
- `*-tunnel/README.txt` — полная инструкция

### Linux

```bash
# Установить wstunnel (один раз)
curl -fsSL -o /tmp/wstunnel.tar.gz https://github.com/erebe/wstunnel/releases/download/v10.1.6/wstunnel_10.1.6_linux_amd64.tar.gz
sudo tar -xzf /tmp/wstunnel.tar.gz -C /usr/local/bin/ wstunnel
sudo chmod +x /usr/local/bin/wstunnel

# Установить WireGuard tools (один раз)
sudo apt install wireguard-tools

# Подключиться
sudo ./connect.sh
```

### macOS

```bash
brew install wstunnel wireguard-tools
sudo ./connect-macos.sh
```

### Windows

1. Скачать `wstunnel.exe` с [GitHub releases](https://github.com/erebe/wstunnel/releases)
2. Установить [WireGuard](https://www.wireguard.com/install/)
3. Импортировать `.conf` в WireGuard
4. Запустить `connect.bat` от имени администратора
5. Активировать WireGuard-туннель в приложении

### Android / iOS

Рекомендуется использовать **AmneziaVPN** (Google Play / App Store).
Импортировать `.conf` файл — приложение само обеспечивает обфускацию.

## Проверка после установки (на сервере)

```bash
# WireGuard
sudo wg show
sudo systemctl status wg-quick@wg0 --no-pager

# wstunnel (обфускация)
sudo systemctl status wstunnel-server --no-pager
sudo ss -tlnp | grep wstunnel

# Логи
sudo journalctl -u wg-quick@wg0 -n 50 --no-pager
sudo journalctl -u wstunnel-server -n 50 --no-pager

# Iptables
sudo iptables -L INPUT -n -v | head -20
sudo iptables -t nat -L POSTROUTING -n -v
sudo iptables -t mangle -S | grep TCPMSS

# Параметры
cat /etc/wireguard/params
cat /etc/wstunnel/ws_path
```

## Проверка с клиента

После подключения через `connect.sh`:

```bash
# Проверка IP — должен быть IP сервера
curl -s ifconfig.me

# Проверка DNS
nslookup google.com

# Проверка latency
ping 8.8.8.8
```

## Устранение проблем

| Симптом | Решение |
|---------|---------|
| wstunnel не подключается | Проверить, что порт 443/tcp доступен с клиента: `nc -zv SERVER 443` |
| Handshake есть, интернета нет | Снизить MTU до 1100-1000 в `.conf` |
| DNS не работает | Сменить DNS на `8.8.8.8` или `77.88.8.8` в `.conf` |
| Медленная скорость | Нормально для HTTPS-туннеля (+10-15% overhead). Проверить BBR на сервере |
| Подключение рвётся | Проверить `PersistentKeepalive=25` в `.conf` |

## Обновление на сервере (после git pull)

```bash
cd enhanced-vpn
git pull

# Если нужна переустановка (полный сброс)
sudo ./wireguard-install.sh    # выбрать "4) Uninstall"
sudo ./wireguard-install.sh    # установить заново с обфускацией
```
