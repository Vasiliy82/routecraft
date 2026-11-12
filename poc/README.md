# Быстрый PoC шлюза

PoC запускается на тестовой VM1 `192.168.80.241`; VM2 `192.168.80.242` использует её как шлюз по умолчанию. `policy.yaml` повторяет `config.yaml.example`: OpenAI/Cursor/Anthropic и 2ip.io идут через Tailscale Exit Node, заблокированные категории и YouTube/Telegram/WhatsApp — через VLESS-подписку, остальное — напрямую. Дополнительное правило `block.routecraft.test` используется только для проверки блокировки.

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

Скрипт загружает категориальные SRS и подписку, генерирует конфигурацию sing-box, запускает его и включает перехват. `ru-blocked` берётся из `runetfreedom/russia-v2ray-rules-dat`; остальные категории — из `MetaCubeX/meta-rules-dat`. Другая Headscale-сеть или exit node задаются через `ROUTECRAFT_HEADSCALE_URL` и `ROUTECRAFT_EXIT_NODE`. На VM2: `ip route replace default via 192.168.80.241 dev br-lan`.

Проверка на VM2: `curl -4 -I https://2ip.io`, `curl -4 -I https://www.youtube.com`, `curl -4 -I https://example.com`. Первые два запроса должны идти через Tailscale и VLESS соответственно, последний — direct. Для блокировки: `curl --resolve block.routecraft.test:80:1.1.1.1 http://block.routecraft.test/`. Выбранный путь виден в `/tmp/routecraft-poc/sing-box.log` на VM1. Локальные диагностические SOCKS-прокси на VM1: `127.0.0.1:1080` direct, `:1081` VLESS, `:1082` Tailscale.

Это временный PoC: файлы и правила в RAM, автоматического запуска после reboot и обновления подписки по расписанию пока нет. После reboot требуется повторный запуск; default route VM2 также задан временно.
