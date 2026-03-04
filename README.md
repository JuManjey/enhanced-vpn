## Enhanced VPN installer — обход DPI (Россия)

Скрипты для установки VPN-сервера с обфускацией трафика для обхода DPI.

### Какой протокол выбрать?

| Протокол | Работает из России? | Клиент | Сложность |
|----------|-------------------|--------|-----------|
| **AmneziaWG** | **Да** (рекомендуется) | AmneziaVPN (iOS/Android/Win/Mac/Linux) | Простой |
| **wstunnel** | Да | wstunnel + connect.sh | Средний |
| **OpenVPN** | **Нет** (без обфускации DPI блокирует) | OpenVPN Connect | — |
| **WireGuard** | **Нет** (DPI блокирует) | WireGuard app | — |

### Рекомендуемый путь для России: AmneziaWG

```bash
git clone <repo-url>
cd enhanced-vpn
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh
```

При установке выбрать:
- Restrictive-network profile: **y**
- Obfuscation method: **1 (AmneziaWG)**
- Port: **оставить случайный** (рекомендуется)
- DNS: **8.8.8.8, 1.1.1.1**
- MTU: **1100**
- PersistentKeepalive: **25**
- TCP MSS clamping: **y**
- BBR: **y**

### Подключение клиентов (AmneziaWG)

1. Скачать **AmneziaVPN**:
   - [Google Play](https://play.google.com/store/apps/details?id=org.amnezia.vpn)
   - [App Store](https://apps.apple.com/app/amneziavpn/id1600529900)
   - [amnezia.org](https://amnezia.org)

2. Получить конфигурацию (один из способов):
   - **Файл `.conf`** — самый надёжный, отправить через Telegram (себе в "Избранное")
   - **Текст конфигурации** — скопировать из терминала сервера, вставить в мессенджер
   - **QR-код PNG** — отправить PNG файл клиенту для сканирования
   - **QR-код в терминале** — может не работать для AmneziaWG конфигов

3. В AmneziaVPN:
   - Нажать **"+"** → **"У меня есть данные для подключения"**
   - **"Открыть конфиг, ключ или QR-код"**
   - Выбрать `.conf` файл **ИЛИ** вставить текст конфигурации
   - Подключиться

### Диагностика на сервере

```bash
# Запуск диагностики (в меню скрипта — пункт 4)
sudo ./wireguard-install.sh

# Ручная проверка
sudo awg show                                    # статус AmneziaWG
sudo systemctl status awg-quick@wg0              # статус сервиса
sysctl net.ipv4.ip_forward                       # IP forwarding
sudo iptables -t nat -L POSTROUTING -n -v        # NAT правила
sudo iptables -L FORWARD -n -v                   # FORWARD правила
curl -4 https://ifconfig.co                      # внешний IP сервера
```

### Если не работает из России

1. **Проверить диагностику** — запустить `sudo ./wireguard-install.sh` → пункт 4
2. **Убедиться, что клиент использует AmneziaVPN** (не стандартный WireGuard!)
3. **Попробовать мобильный интернет** вместо WiFi (разные ISP блокируют по-разному)
4. **Сменить порт** — переустановить с другим случайным портом
5. **Сменить датацентр/VPS** — IP сервера может быть в блоклисте Роскомнадзора
6. **Попробовать wstunnel** — если ISP блокирует весь UDP трафик:
   - Переустановить с методом обфускации **2 (wstunnel)**
   - Оборачивает WireGuard в HTTPS/WebSocket (TCP)

### OpenVPN

```bash
chmod +x openvpn-install.sh
sudo ./openvpn-install.sh
```

**Внимание:** Стандартный OpenVPN **не работает** из России. ТСПУ (DPI) распознаёт
сигнатуру TLS-хендшейка OpenVPN и блокирует соединение. Используйте AmneziaWG.

### Структура проекта

```
enhanced-vpn/
├── wireguard-install.sh   # WireGuard + AmneziaWG + wstunnel (рекомендуется для России)
├── openvpn-install.sh     # OpenVPN (НЕ работает из России без обфускации)
└── README.md
```

### Переустановка

```bash
sudo ./wireguard-install.sh    # Пункт 5) Uninstall
sudo ./wireguard-install.sh    # Установить заново с другими параметрами
```
