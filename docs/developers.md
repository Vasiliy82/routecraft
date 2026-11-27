# Для разработчиков

## Состояние проекта

Текущая поставка — PoC шлюза OpenWrt для однорукой схемы и раздельных WAN/LAN. Мастер устанавливает зависимости, создаёт конфигурацию sing-box и активирует IPv4 TCP/UDP TPROXY после подтверждения. Обе схемы проверены на изолированных OpenWrt VM. Для VPN-подписок есть отдельная shell-утилита с запуском через cron. LuCI и обновление геоданных по расписанию остаются отдельными этапами.

## Стек и компоненты

- `sing-box` принимает перехваченный трафик, сопоставляет правила и использует выходы VLESS, Tailscale, direct и reject.
- `nftables` TPROXY вместе с Linux policy routing передаёт транзитные IPv4 TCP/UDP соединения в sing-box.
- Штатный OpenWrt procd запускает gateway service; для одной интерфейсной группы настраиваются forwarding и SRCNAT.
- `poc/policy.yaml` задаёт порядок правил. `poc/build` собирает тестовый sing-box JSON из политики, VLESS-подписки и выбранных GeoSite/GeoIP SRS.
- Автономный PoC URL-подписок запускается через `poc/subscription-poc.sh`. [Запуск](#автономный-poc-url-подписок)
- Go CLI в `cmd/routecraft` и Go-пакеты `internal/` формируют основу будущего декларативного ядра; они не заменяют текущий PoC запускной service.

## Сборка и проверки

На машине с Go:

```sh
go test ./...
go vet ./...
make build
```

Для сборки OpenWrt PoC архивов на Windows-хосте:

```sh
make package-openwrt
```

Команда создаёт архивы `routecraft-openwrt-<arch>.tar.gz` для `amd64`, `arm64` и `armv7` с файлами SHA256 в `poc/bundles/`. Готовые архивы хранятся в репозитории рядом с установщиком. Bootstrap скачивает архив подходящей архитектуры и проверяет его SHA256.

Упаковщик нормализует окончания строк shell-файлов и проверяет их после извлечения каждого архива. Команда `sh tests/integration/bundle-shell.sh poc/bundles/routecraft-openwrt-amd64.tar.gz` проверяет SHA256, имена файлов, синтаксис и начальные сценарии `start.sh` без изменения сети. Workflow выпуска выполняет эту проверку для всех трёх архивов.

Примеры экспериментального CLI:

```sh
go run ./cmd/routecraft validate
go run ./cmd/routecraft compile --output .cache/compiled
go run ./cmd/routecraft explain --domain example.org --port 80
```

`compile` создаёт только фрагмент конфигурации; сам по себе не применяет изменения к работающему OpenWrt. `explain` — статическая оценка по имеющимся правилам и данным.

## Документы проекта

- [Краткая архитектура](overview.md)
- [Подробная архитектура](architecture.md)
- [Требования](requirements.md)
- [Требования к проверке установки](testing.md#проверка-установки)
- [Формат политики](policy-schema.md)
- [План разработки](development-execplan.md)
- [План PoC](poc-execplan.md)
- [План turnkey установки](turnkey-onearm-execplan.md)
- [Журнал этапов и результатов](development-journal.md)
- [Тестовый контур](test-environment.md)

Локальные IP, hostnames и credentials тестовых стендов лежат только в игнорируемом архиве и не должны переноситься в публичную документацию, release assets или CI logs.

## Направление пакетирования и LuCI

Текущий PoC bundle — временный механизм доставки файлов, не готовый системный пакет. Продуктовое пакетирование планируется через OpenWrt build system/SDK с отдельным пакетом ядра/службы и независимым `luci-app-routecraft`. Пакеты собираются для конкретных OpenWrt release branches и targets: начиная с 25.12 это APK v3/feed, для более старых поддерживаемых веток потребуется IPK/opkg или явно ограниченный диапазон версий. Не устанавливать произвольный локальный APK с `--allow-untrusted` как способ распространения; релизный feed должен иметь проверяемую подпись и фиксированные версии.

Сначала поддерживается собственный публичный feed и release pipeline. Upstream submission в `openwrt/packages` и LuCI repository — отдельная цель после того, как есть сопровождающий, стабильные исходные релизы, воспроизводимая сборка, тесты на объявленных ветках/targets и выполнены актуальные submission rules. Ядро и UI подаются отдельно, чтобы CLI/service работали без LuCI и UI мог обновляться независимо.

LuCI приложение использует контроллер RouteCraft через ограниченный `ubus`/`rpcd` API и ACL, а не shell-команды из браузерного кода. Контроллер остаётся единственным владельцем apply/rollback и общей активной конфигурации. До UI реализации сначала стабилизировать и документировать API, ошибки валидации, статус операций и структуру плана изменений; затем сделать LuCI-страницы политики, выходов, диагностики и подтверждения применения. Документы по альтернативным панелям и выбору LuCI как первого target собраны в [обзоре архитектуры](overview.md#поставка-и-пользовательский-интерфейс).

## Автономный PoC URL-подписок

Скопируйте `poc/subscription-poc.sh` в `/etc/routecraft/` и выставьте права `0755`. Скрипт работает под штатным OpenWrt `sh` и использует `curl`, `jq` 1.8+, `flock`, `hexdump`, системные корневые сертификаты и sing-box с командой `tools fetch`. PoC запускается вручную и проверяет узлы отдельными вызовами sing-box.

Первый запуск читает URL из файла или позиционного аргумента. Вариант с файлом сохраняет URL вне аргументов процесса и истории оболочки.

```sh
/etc/routecraft/subscription-poc.sh --url-stdin < /path/to/private-subscription-url
/etc/routecraft/subscription-poc.sh --status
/etc/routecraft/subscription-poc.sh
```

Третья команда повторно загружает сохранённую подписку. `--hwid ID` задаёт уже зарегистрированный идентификатор вручную. По умолчанию UUID v4 создаётся один раз и переживает перезапуски при сохранении каталога состояния. `--user-agent UA` задаёт User-Agent для провайдеров с выбором формата по заголовкам. `--state-dir DIR` позволяет проверять второй URL отдельно.

Порядковые номера в выводе и поле `selected` начинаются с единицы. Совместимость проверяет `sing-box check`, затем PoC запрашивает DNS-ответ через HTTPS для каждого прошедшего проверку выхода. В `current.json` под индексом `selected - 1` массива `nodes` лежат URI (если исходный формат содержит URI) и конфигурация выбранного выхода. Ошибка обновления оставляет предыдущий `current.json` и сохраняется в `last-attempt.json` вместе с заголовками ответа и распакованным телом в поле `body`. По умолчанию оба файла и `hwid` находятся в `/etc/routecraft/subscription-poc/`. Файлы содержат секреты и доступны через каталог с правами `0700`.

Парсер принимает списки URI и Base64. Для JSON поддерживаются отдельные выходы sing-box, массивы и поле `outbounds`. Для Xray поддерживаются VLESS, VMess, Trojan и Shadowsocks с одиночным endpoint, а транспорт ограничен TCP, WebSocket, HTTP Upgrade и gRPC. XHTTP и неизвестные протоколы сохраняются со статусом несовместимости. Маршрутизация и DNS из ответа сохраняются как диагностические данные. Привязанные к устройству ссылки Happ собственного формата выходят за рамки приёма HTTP/HTTPS URL. [Документация Happ](https://github.com/HappDev/happ_su/blob/main/dev-docs/hwid-links.md) [Документация Remnawave](https://docs.rw/features/hwid-device-limit/)

Регрессионный сценарий `sh tests/integration/subscription-poc.sh` запускается из корня checkout на OpenWrt с синтетическими ответами и пробами.

## Обновление активного VPN-выхода

Разместите `poc/subscription.sh` и `poc/subscription-poc.sh` в `/etc/routecraft/` с правами 0755. Для применения нужна работающая служба RouteCraft со штатным loopback-входом `test-vless`. Утилита использует тот же sing-box, который запускается этой службой.

```sh
/etc/routecraft/subscription.sh set url --stdin < /path/to/private-subscription-url
/etc/routecraft/subscription.sh check
/etc/routecraft/subscription.sh update
```

При наличии зарегистрированного HWID задайте его командой `subscription.sh set hwid ID`. Команды `get url`, `get hwid` и `get selected` выводят секретные значения по явному запросу. `check` и `update` выводят статусы и найденные внешние IPv4. Условия выбора, формат состояния и порядок отката описаны в [ТЗ на обновление VPN-подписки](subscription-updater.md).

При запуске из терминала ход проверки и подписи узлов выводятся в stderr по мере обработки. При запуске из cron итоговые строки сохраняют прежний формат. Подпись выбранного узла сохранена в поле `name` результата `get selected`.

Пример записи в root crontab OpenWrt для ежедневной проверки в 04:30 по часам роутера. После изменения crontab перезапустите службу cron.

```cron
30 4 * * * /etc/routecraft/subscription.sh update 2>&1 | logger -t routecraft-subscription
```

Регрессия применения запускается на OpenWrt командой `sh tests/integration/subscription-update.sh`. Сценарий использует отдельный временный каталог, моделирует отказ рестарта и проверяет сохранность предыдущего выхода.
