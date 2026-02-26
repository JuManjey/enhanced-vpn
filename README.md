## Enhanced WireGuard installer

Скрипт `wireguard-install.sh` предназначен для первого запуска на новом сервере и уже включает:

- анти-блокировочные сетевые параметры (`MTU`, `PersistentKeepalive`, TCP MSS clamp);
- безопасные значения по умолчанию для маршрутизации;
- опциональный IPv6 (без принудительного `::/0`, если у сервера нет рабочего IPv6);
- post-install проверки состояния интерфейса, порта и sysctl.

## Быстрый запуск на новом сервере

```bash
git clone <repo-url>
cd enhanced-vpn
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh
```

## Рекомендуемые ответы в мастере установки

- `Public endpoint` — публичный IP или домен сервера.
- `WireGuard port` — `443` (UDP), если он свободен.
- `Enable IPv6` — `y` только если на сервере реально есть глобальный IPv6.
- `Client MTU` — `1280`.
- `PersistentKeepalive` — `25`.
- `Enable TCP MSS clamping` — `y`.
- `Enable kernel network optimizations` — `y`.
- `Allowed IPs` — `0.0.0.0/0` (или `0.0.0.0/0,::/0` при рабочем IPv6).

## Проверка после установки

```bash
sudo wg show
sudo systemctl status wg-quick@wg0 --no-pager
sudo journalctl -u wg-quick@wg0 -n 100 --no-pager
sudo ss -lunp | grep -E ":443|:51820"
sudo iptables -t mangle -S | grep TCPMSS
```

## Проверка с клиента

После импорта клиентского `.conf`:

```bash
ping 1.1.1.1
ping 8.8.8.8
```

Если handshake есть, но трафик нестабилен:

- оставь `MTU=1280`;
- проверь, что `PersistentKeepalive=25`;
- проверь, что сервер слушает именно тот UDP-порт, который указан в `Endpoint`.
