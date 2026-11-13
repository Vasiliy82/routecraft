# Быстрый PoC шлюза

PoC запускается на тестовой VM1 `192.168.80.241`; VM2 `192.168.80.242` использует её как шлюз по умолчанию. `policy.yaml` повторяет `config.yaml.example` и содержит контрольные сайты для ручной проверки:

| Назначение | Правило | Проверка с VM2 |
|---|---|---|
| `2ip.io` | Tailscale Exit Node | `curl -4 https://2ip.io/` |
| `ifconfig.me` | VLESS-подписка | `curl -4 https://ifconfig.me/` |
| `icanhazip.com` | direct | `curl -4 https://icanhazip.com/` |
| `theuselessweb.com` | reject | `curl -4 -I --max-time 10 https://theuselessweb.com/` должен завершиться ошибкой соединения |

Для теста block также оставлено синтетическое имя `block.routecraft.test`. Внешние IP сервисов показывают фактический адрес выбранного выхода, но могут измениться. Пользователь сообщил исходные значения до тестовой маршрутизации: `ifconfig.me` → `2.26.4.216`, `icanhazip.com` → `2.26.4.222`, `2ip.io` → `2.26.4.216`; это наблюдения, а не зафиксированные адреса узлов.

На компьютере разработки в PowerShell из корня проекта собрать PoC для Linux/amd64 и скопировать файлы на VM1:

```powershell
New-Item -ItemType Directory -Force .cache | Out-Null
$env:GOOS = 'linux'
$env:GOARCH = 'amd64'
$env:CGO_ENABLED = '0'
go build -o .cache/routecraft-poc-build ./poc/build
Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED
ssh root@192.168.80.241 'mkdir -p /tmp/routecraft-poc'
scp -O .cache/routecraft-poc-build poc/policy.yaml poc/start.sh poc/direct-gateway.sh poc/tproxy-gateway.sh root@192.168.80.241:/tmp/routecraft-poc/
```

В `/tmp/routecraft-poc/` на VM1 также нужны файлы `subscription.url` и `headscale.key` с тестовыми значениями из `docs/test-environment.md`. На VM уже установлены `sing-box`, `curl`, `ip-full` и `kmod-nft-tproxy`. Далее на VM1 выполнить:

```sh
chmod 700 /tmp/routecraft-poc/routecraft-poc-build
sh /tmp/routecraft-poc/start.sh
```

Скрипт загружает категориальные SRS и подписку, генерирует конфигурацию sing-box, запускает его и включает перехват. `ru-blocked` берётся из `runetfreedom/russia-v2ray-rules-dat`; остальные категории — из `MetaCubeX/meta-rules-dat`. Другая Headscale-сеть или exit node задаются через `ROUTECRAFT_HEADSCALE_URL` и `ROUTECRAFT_EXIT_NODE`.

Для сохранения текущего рабочего PoC после reboot скопируйте проверенные файлы, SRS, подписку и Tailscale state из `/tmp/routecraft-poc/` в `/etc/routecraft-poc/`, замените в `sing-box.json` абсолютные пути `/tmp/routecraft-poc` на `/etc/routecraft-poc`, установите `poc/routecraft-poc.init` как `/etc/init.d/routecraft-poc` и включите его через `/etc/init.d/routecraft-poc enable`. Служба при загрузке запускает forwarding/SRCNAT, policy route и TPROXY, затем sing-box под procd. Для клиента закрепите шлюз в OpenWrt UCI: `uci set network.lan.gateway='192.168.80.241'; uci commit network`. На тестовом стенде это уже настроено; VM2 маршрутизируется через VM1 после reboot.

Дополнительные категории проверяются так: `curl -4 -I https://www.youtube.com` должен идти через VLESS, `curl -4 -I https://example.com` — direct. Выбранный путь виден в журнале sing-box на VM1 (`logread | grep sing-box`). Локальные диагностические SOCKS-прокси на VM1: `127.0.0.1:1080` direct, `:1081` VLESS, `:1082` Tailscale.

На тестовом стенде текущая конфигурация сохраняется на постоянном разделе и проходит reboot. Повторный запуск `poc/start.sh` остаётся ручным действием, которое загружает свежие подписку и геоданные; расписание их обновления и UI не реализованы. Скрипт по умолчанию использует `/tmp/routecraft-poc`, а служба автозапуска — сохранённую конфигурацию `/etc/routecraft-poc`.
