# Маршрутизационный PoC

PoC демонстрирует выбор одного из четырёх выходов для клиентского IPv4 TCP/UDP трафика:

| Назначение | Выход | Ручная проверка с клиента |
|---|---|---|
| `2ip.io` | Tailscale Exit Node | `curl -4 https://2ip.io/` |
| `ifconfig.me` | VLESS subscription | `curl -4 https://ifconfig.me/` |
| `icanhazip.com` | direct | `curl -4 https://icanhazip.com/` |
| `theuselessweb.com` | reject | `curl -4 -I --max-time 10 https://theuselessweb.com/` должен завершиться ошибкой соединения |

Полная инструкция для физического роутера или виртуальной машины находится в [руководстве по установке](../docs/install.md). Схемы правил и границы PoC описаны в [архитектуре](../docs/architecture.md).

PoC использует sing-box, nftables TPROXY, Linux policy routing и штатный procd OpenWrt. Сейчас поддерживается только один LAN-интерфейс для входящего и upstream трафика. Источники подписки и Exit Node настраиваются владельцем; проект не включает или не публикует личные ключи в release bundle.
