# Для разработчиков

## Состояние проекта

Текущая поставка — PoC однорукого OpenWrt gateway. Shell helper устанавливает зависимости, создаёт конфигурацию sing-box и активирует IPv4 TCP/UDP TPROXY после подтверждения. Маршруты PoC проверены на изолированной OpenWrt VM. Общее применение продуктовой политики развивается отдельно; LuCI, scheduled update подписок/геоданных и разные WAN/LAN интерфейсные группы ещё не готовы.

## Стек и компоненты

- `sing-box` принимает перехваченный трафик, сопоставляет правила и использует выходы VLESS, Tailscale, direct и reject.
- `nftables` TPROXY вместе с Linux policy routing передаёт транзитные IPv4 TCP/UDP соединения в sing-box.
- Штатный OpenWrt procd запускает gateway service; для одной интерфейсной группы настраиваются forwarding и SRCNAT.
- `poc/policy.yaml` задаёт порядок правил. `poc/build` собирает тестовый sing-box JSON из политики, VLESS-подписки и выбранных GeoSite/GeoIP SRS.
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

Команда создаёт Linux `amd64`, `arm64` и `armv7` bundles с SHA256 sidecar в `.cache/releases/`. Release pipeline запускается push tag `v*`, собирает те же файлы и прикрепляет их к GitHub Release.

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
- [Формат политики](policy-schema.md)
- [План разработки](development-execplan.md)
- [План PoC](poc-execplan.md)
- [План turnkey установки](turnkey-onearm-execplan.md)
- [Журнал этапов и результатов](development-journal.md)
- [Тестовый контур](test-environment.md)

Локальные IP, hostnames и credentials тестовых стендов лежат только в игнорируемом архиве и не должны переноситься в публичную документацию, release assets или CI logs.
