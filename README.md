# RouteCraft

RouteCraft — OpenWrt-шлюз для удобной настройки мультитуннелинга. Он собирает правила маршрутизации в одну политику и направляет разные подключения через выбранный выход: VLESS, Tailscale Exit Node со стабильным публичным IP, прямое соединение или блокировку.

## Для чего

- Отправлять LLM-сервисы и API, где нужен постоянный IP или allowlist, через собственный VPS/Tailscale Exit Node с закреплённым адресом.
- Направлять YouTube и другие выбранные сайты через недорогую VLESS-подписку, например RAF VPN из вашей текущей схемы.
- Оставлять остальной трафик прямым или блокировать его правилами.

RouteCraft использует sing-box для выбора выхода, nftables TPROXY и policy routing OpenWrt для передачи транзитного трафика, procd для запуска и GeoSite/GeoIP для категорий доменов и адресов. На тестовых OpenWrt VM PoC проверен в однорукой схеме и на шлюзе с раздельными WAN и LAN.

## Установка

Требуются OpenWrt с root-доступом и рабочим интернетом. При раздельных WAN и LAN заранее настройте обычную маршрутизацию шлюза, firewall и NAT. Проверенная среда — OpenWrt 25.12.6 x86_64. Архивы подготовлены для `x86_64`, `aarch64` и `armv7`. [Руководство по установке](docs/install.md)

Установка запускается одной командой из root-shell OpenWrt:

Сначала проверьте доступ к интернету с самого роутера. На чистом OpenWrt используйте штатный `uclient-fetch`:

```sh
uclient-fetch -4 -T 8 -O /dev/null https://raw.githubusercontent.com/Vasiliy82/routecraft/main/poc/install-openwrt.sh
```

Если проверка не проходит, сначала восстановите интернет на роутере. Если `curl` уже установлен, эквивалентная проверка: `curl -4 -fIsS --connect-timeout 5 https://raw.githubusercontent.com/Vasiliy82/routecraft/main/poc/install-openwrt.sh`.

```sh
uclient-fetch -4 -O /tmp/routecraft-install.sh https://raw.githubusercontent.com/Vasiliy82/routecraft/main/poc/install-openwrt.sh && sh /tmp/routecraft-install.sh
```

Инсталлятор скачает подходящий архив и SHA256, установит недостающие пакеты из настроенных OpenWrt feeds и запустит мастер. Секреты можно заранее положить в стандартные файлы на роутере. Сетевой перехват включается после отдельного подтверждения. [Файлы секретов](docs/install.md#файлы-секретов)

## Обновление VPN-подписки

После активации `/etc/routecraft/subscription.sh check` проверяет узлы. Команда `/etc/routecraft/subscription.sh update` применяет первый рабочий выход и перезапускает RouteCraft при его смене. Расписание задаётся вручную в cron. [Команды и пример расписания](docs/install.md#обновление-vpn-подписки)

## Для разработчиков

Сборка, тестовая схема, архитектурные заметки и журнал изменений находятся в [разделе для разработчиков](docs/developers.md).
