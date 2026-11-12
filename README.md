# RouteCraft

Планируемый набор компонентов для декларативной маршрутизации IPv4 TCP/UDP через OpenWrt: ядро и CLI `routecraft`, данные категорий `routecraft-geodata`, адаптер `routecraft-provider-singbox` и веб-интерфейс `luci-app-routecraft`. Порядок правил и выбор выхода задаются пользователем; целевые выходы — direct, VLESS-подписка и отдельно проверяемый Tailscale Exit Node/IP gateway.

Реализован начальный срез: проверка YAML, компиляция фрагмента правил sing-box и статическое объяснение выбора. На тестовых VM отдельно проверен временный прозрачный TCP/UDP через sing-box. Постоянное применение политики, управление шлюзом, геоданные, VPN-провайдер и веб-интерфейс ещё разрабатываются; подробности и результаты — в журнале.

Команды для разработки с установленным Go: `make test`, `make test-offline`, `make lint`, `make build`. Примеры CLI: `go run ./cmd/routecraft validate`, `go run ./cmd/routecraft compile --output .cache/compiled` и `go run ./cmd/routecraft explain --domain example.org --port 80`. `compile` создаёт только фрагмент `sing-box.fragment.json` и ничего не применяет; `explain` сообщает неопределённость, если данных недостаточно.

- [Требования и критерии приёмки](docs/requirements.md)
- [Архитектура и компоненты](docs/architecture.md)
- [Формат политики](docs/policy-schema.md)
- [Тестовое оборудование и доступ](docs/test-environment.md)
- [Стратегия тестирования](docs/testing.md)
- [Подготовка и эксплуатация OpenWrt](docs/openwrt-deploy.md)
- [План подготовки](docs/execplan.md)
- [План разработки и тестирования](docs/development-execplan.md)
- [Краткий журнал этапов](docs/development-journal.md)

Исходные материалы сохранены локально в `archive/source-handoff/`; архив исключён из Git и не восстанавливается из клона. Для разработки пользуйтесь отслеживаемой документацией.
