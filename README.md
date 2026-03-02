## Enhanced WireGuard installer with DPI bypass

Скрипт для установки WireGuard VPN с обфускацией трафика для обхода DPI (Россия, и др.).

### Методы обфускации

| Метод | Как работает | Клиент | Рекомендация |
|-------|-------------|--------|-------------|
| **AmneziaWG** | Модифицирует заголовки WireGuard-пакетов | AmneziaVPN (Android/iOS/Win/Mac/Linux) | **Для мобильных** |
| **wstunnel** | Оборачивает WireGuard в HTTPS/WebSocket | wstunnel + connect.sh | Для десктопа |
| **None** | Стандартный WireGuard | WireGuard app | Вне России |

## Быстрый старт

```bash
git clone <repo-url>
cd enhanced-vpn
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh
```

## Рекомендуемые настройки (Россия)

- Restrictive-network profile: **y**
- Obfuscation method: **1 (AmneziaWG)** — если нужны мобильные клиенты
- Server port: **443**
- DNS: **9.9.9.9, 8.8.8.8**
- MTU: **1280**
- PersistentKeepalive: **25**
- TCP MSS clamping: **y**
- BBR: **y**

## Подключение клиентов

### AmneziaWG (рекомендуемый)

1. Скачать **AmneziaVPN**: [amnezia.org](https://amnezia.org)
2. Импортировать `.conf` файл
3. Подключиться

Работает на Android, iOS, Windows, macOS, Linux. Никакого доп. софта.

### wstunnel

Требует wstunnel на клиенте. При создании клиента генерируются скрипты `connect.sh` / `connect.bat`.

```bash
# Linux
sudo ./connect.sh

# Windows
connect.bat (от имени администратора)
```

## Проверка на сервере

```bash
# Статус (AmneziaWG)
sudo systemctl status awg-quick@wg0
sudo awg show

# Статус (wstunnel)
sudo systemctl status wg-quick@wg0
sudo systemctl status wstunnel-server

# Общее
sudo iptables -L INPUT -n -v | head
cat /etc/wireguard/params
```

## Переустановка с другим методом

```bash
sudo ./wireguard-install.sh    # 4) Uninstall
sudo ./wireguard-install.sh    # Установить заново
```
