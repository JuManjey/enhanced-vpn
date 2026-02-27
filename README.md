## Enhanced WireGuard installer

Скрипт `wireguard-install.sh` предназначен для первого запуска на новом сервере и уже включает:

- анти-блокировочные сетевые параметры (`MTU`, `PersistentKeepalive`, TCP MSS clamp);
- профиль совместимости для restrictive-сетей (рекомендован для пользователей из РФ);
- безопасные значения по умолчанию для маршрутизации;
- опциональный IPv6 (IPv4-first в restrictive-профиле);
- post-install проверки состояния интерфейса, порта, DNS и sysctl.

## Быстрый запуск на новом сервере

```bash
git clone <repo-url>
cd enhanced-vpn
chmod +x wireguard-install.sh
sudo ./wireguard-install.sh
```

## Рекомендуемые ответы в мастере установки

- `Restrictive-network profile` — `y` (особенно для пользователей из РФ).
- `Public endpoint` — публичный IP или домен сервера.
- `WireGuard port` — `443` (UDP), если он свободен.
- `Enable IPv6` — `n`, если нет уверенности в стабильном IPv6 end-to-end.
- `DNS resolvers` — по умолчанию `9.9.9.9` и `8.8.8.8` в restrictive-профиле.
- `Client MTU` — `1280` (для IPv4-only можно опускаться до `1200` при проблемных сетях).
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
sudo grep -E "CLIENT_DNS_1|CLIENT_DNS_2|RESTRICTIVE_NETWORK_MODE" /etc/wireguard/params
```

## Проверка с клиента

После импорта клиентского `.conf`:

```bash
ping 1.1.1.1
ping 8.8.8.8
```

Если handshake есть, но трафик нестабилен:

- оставь `MTU=1280`;
- при IPv4-only профиле попробуй `MTU=1240` или `1200`;
- проверь, что `PersistentKeepalive=25`;
- проверь, что в клиентском конфиге DNS не пустой и резолверы рабочие;
- проверь, что сервер слушает именно тот UDP-порт, который указан в `Endpoint`.
