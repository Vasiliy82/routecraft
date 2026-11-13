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

## Установка на OpenWrt

Установщик и мастер конфигурации находятся в `poc/install.sh` и `poc/configure.sh`. Для публичной установки после публикации первого GitHub Release достаточно выполнить на чистом OpenWrt от root:

    wget -qO /tmp/routecraft-install.sh https://raw.githubusercontent.com/Vasiliy82/routecraft/main/poc/install-openwrt.sh && sh /tmp/routecraft-install.sh

Bootstrap выберет bundle по `uname -m`, проверит SHA256 и скачает его из последнего GitHub Release. `install.sh --install` поставит недостающие `sing-box`, `curl`, `ca-bundle`, `ip-full`, `nftables-json` и `kmod-nft-tproxy` штатным `apk` (OpenWrt 25.12+) или `opkg` (старые релизы), без общего upgrade, затем подготовит файлы и запустит мастер. Для первой публикации поддерживаемого релиза нужно запушить tag вида `v0.1.0`; GitHub Actions соберёт и прикрепит три архитектурных bundle и их checksum.

Этот этап поддерживает только однорукую схему: клиентский трафик входит и upstream уходит через один LAN-интерфейс. Если default route использует другой интерфейс, helper остановится; группы WAN/LAN появятся отдельным этапом. Для ручной сборки переносимого bundle на Windows-хосте с Go:

    make package-openwrt

В `.cache/releases/` появятся архивы `routecraft-poc-openwrt-amd64.tar.gz`, `...-arm64.tar.gz`, `...-armv7.tar.gz` и отдельные `.sha256` sidecar. Архив не содержит VLESS-ссылку или Headscale key. Поддерживаются Linux `x86_64/amd64`, `aarch64/arm64` и `armv7`; перед выбором архива сверяйте `uname -m` на устройстве. На R28S архитектуру заранее не предполагайте.

Скопируйте соответствующий архив и sidecar на OpenWrt, затем выполните:

    sha256sum -c routecraft-poc-openwrt-amd64.tar.gz.sha256
    mkdir -p /tmp/routecraft-install
    tar -xzf routecraft-poc-openwrt-amd64.tar.gz -C /tmp/routecraft-install
    cd /tmp/routecraft-install
    sh ./install.sh --check

`--check` только сообщает версию OpenWrt, архитектуру, зависимости, интерфейс, шлюз и очевидные конфликты; он не меняет файлы, маршруты, firewall или процессы. При `--install` helper ставит только необходимые пакеты через настроенные фиды OpenWrt, не запускает общий upgrade и проверяет наличие embedded Tailscale endpoint и nft TPROXY. Требуются интернет/DNS и рабочие фиды пакетов. При ошибке пакетного менеджера установка останавливается до активации.

Запустите `sh /etc/routecraft-poc/configure.sh`. Мастер покажет обнаруженные LAN interface/subnet и DNS, спросит параметры Headscale/Exit Node, VLESS subscription URL и pre-auth key (секреты без echo), затем скачает SRS/подписку, создаст `sing-box.candidate.json` и проверит его командой `sing-box check`. Пока пользователь отдельно не подтвердит активацию, активная конфигурация и сеть не меняются. Перед запуском служба создаёт резервную копию; при ошибке запуска восстанавливает прежний конфиг.

Если проверка обнаружит чужой `fwmark 0x81/table 100`, порт `12345`, RouteCraft nft table или другой процесс sing-box, активация остановится. Она не останавливает существующий роутерный стек и не переписывает LAN gateway. Это особенно важно перед первым ручным размещением на TOP50 `.253`, где handoff описывает существующий TPROXY. Сначала изучите сообщение preflight; не отключайте чужие правила вслепую. Для R28S повторите `uname -m`, `cat /etc/openwrt_release`, `df -h / /tmp` и `sing-box version`, выберите совместимый bundle и проверьте его до активации.

Дополнительные категории проверяются так: `curl -4 -I https://www.youtube.com` должен идти через VLESS, `curl -4 -I https://example.com` — direct. Выбранный путь виден в журнале sing-box на VM1 (`logread | grep sing-box`). Локальные диагностические SOCKS-прокси на VM1: `127.0.0.1:1080` direct, `:1081` VLESS, `:1082` Tailscale.

На тестовом стенде текущая конфигурация сохраняется на постоянном разделе и проходит reboot. Повторный запуск `poc/start.sh` остаётся ручным действием, которое загружает свежие подписку и геоданные; расписание их обновления и UI не реализованы. Скрипт по умолчанию использует `/tmp/routecraft-poc`, а служба автозапуска — сохранённую конфигурацию `/etc/routecraft-poc`.
