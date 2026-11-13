# RouteCraft

Планируемый набор компонентов для декларативной маршрутизации IPv4 TCP/UDP через OpenWrt: ядро и CLI `routecraft`, данные категорий `routecraft-geodata`, адаптер `routecraft-provider-singbox` и веб-интерфейс `luci-app-routecraft`. Порядок правил и выбор выхода задаются пользователем; целевые выходы — direct, VLESS-подписка и отдельно проверяемый Tailscale Exit Node/IP gateway.

Работает PoC шлюза по `poc/policy.yaml`: на тестовых VM проверены маршруты Tailscale, VLESS, direct и блокировка. VM1 хранит конфигурацию в `/etc/routecraft-poc` и запускает её после reboot; свежие подписка и геоданные автоматически не обновляются. Постоянное применение пользовательской политики и веб-интерфейс ещё не реализованы.

Для ручного переноса PoC на OpenWrt соберите архитектурный bundle командой `make package-openwrt`; preflight, мастер и ограничения установки описаны в [инструкции PoC](poc/README.md#установка-на-openwrt). Это helper для текущего PoC, не полноценный production package manager.

### Ручная проверка тестовых правил

Запускайте команды на VM2 (`192.168.80.242`), у которой VM1 (`192.168.80.241`) задана шлюзом по умолчанию:

```sh
curl -4 https://2ip.io/                         # Tailscale Exit Node
curl -4 https://ifconfig.me/ip                  # VLESS-подписка
curl -4 https://icanhazip.com/                  # direct
curl -4 -I --max-time 10 https://theuselessweb.com/  # должно быть заблокировано
```

Последняя команда должна завершиться ошибкой соединения. Полный список тестов и проверка лога sing-box приведены в [инструкции PoC](poc/README.md#быстрый-poc-шлюза).

Команды для разработки с установленным Go: `make test`, `make test-offline`, `make lint`, `make build`. Примеры CLI: `go run ./cmd/routecraft validate`, `go run ./cmd/routecraft compile --output .cache/compiled` и `go run ./cmd/routecraft explain --domain example.org --port 80`. `compile` создаёт только фрагмент `sing-box.fragment.json` и ничего не применяет; `explain` сообщает неопределённость, если данных недостаточно.

- [Требования и критерии приёмки](docs/requirements.md)
- [Краткий обзор архитектуры](docs/overview.md)
- [Архитектура и компоненты](docs/architecture.md)
- [Формат политики](docs/policy-schema.md)
- [Тестовое оборудование и доступ](docs/test-environment.md)
- [Стратегия тестирования](docs/testing.md)
- [Подготовка и эксплуатация OpenWrt](docs/openwrt-deploy.md)
- [План подготовки](docs/execplan.md)
- [План разработки и тестирования](docs/development-execplan.md)
- [План текущего PoC](docs/poc-execplan.md)
- [План инсталлятора и помощника конфигурирования](docs/installer-execplan.md)
- [Краткий журнал этапов](docs/development-journal.md)

Исходные материалы сохранены локально в `archive/source-handoff/`; архив исключён из Git и не восстанавливается из клона. Для разработки пользуйтесь отслеживаемой документацией.
