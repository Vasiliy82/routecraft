# Установка RouteCraft PoC

Это руководство описывает текущий однорукий PoC для физического OpenWrt-роутера и OpenWrt в виртуальной машине. Инсталлятор ставит пакеты и файлы, мастер собирает конфигурацию sing-box, а сетевой перехват включается только после отдельного подтверждения.

## Предварительные требования

- OpenWrt с доступом к root-shell по SSH или через консоль. Полностью проверен OpenWrt 25.12.6 x86_64; сборки подготовлены для `x86_64/amd64`, `aarch64/arm64` и `armv7`.
- Интернет и DNS с самого роутера: нужны настроенные OpenWrt package feeds, GitHub, источники GeoSite/GeoIP и ваш VLESS provider.
- Одна сетевая группа: LAN-интерфейс, через который приходят клиенты, совпадает с интерфейсом default route самого роутера. Схема с раздельными WAN и LAN пока не поддерживается.
- Свободное место на persistent-разделе и в `/tmp`. Перед запуском можно посмотреть его командой `df -h / /tmp`; точный минимум зависит от firmware и пакетов.
- Клиенты должны использовать этот OpenWrt как default gateway. Инсталлятор не меняет настройки DHCP, DNS-рекламу или шлюз клиентских устройств.

Пакеты `sing-box`, `curl`, `ca-bundle`, `ip-full`, `nftables-json` и `kmod-nft-tproxy` ставятся штатными feeds по необходимости. OpenWrt 25.12 и новее использует `apk`, старые выпуски — `opkg` ([руководство OpenWrt](https://openwrt.org/docs/guide-user/additional-software/managing_packages)). Код содержит оба варианта, но end-to-end установка проверена на `apk` в OpenWrt 25.12.6. Установщик обновляет индекс пакетов и добавляет только отсутствующие зависимости; полный `apk upgrade`/`opkg upgrade` не запускается. После установки sing-box проверяется поддержка embedded Tailscale endpoint и nftables TPROXY.

Если на роутере уже работает другой sing-box/TPROXY, занят mark `0x81`, table `100` или порт `12345`, установщик остановит активацию, не выключая чужую конфигурацию. Сначала потребуется отдельный контролируемый переход. На известных устройствах состояние до установки может отличаться от чистой VM.

## Установка после публикации GitHub Release

Сначала подключитесь к OpenWrt по SSH под `root`. На виртуальной машине откройте root-shell через консоль гипервизора или SSH. После публикации репозитория и первого тега `v*` GitHub Actions создаст release с bundle и checksum для каждой архитектуры.

Запустите bootstrap:

```sh
uclient-fetch -O /tmp/routecraft-install.sh https://raw.githubusercontent.com/Vasiliy82/routecraft/main/poc/install-openwrt.sh && sh /tmp/routecraft-install.sh
```

Bootstrap определит `uname -m`, скачает архив и sidecar последнего release, проверит SHA256 и запустит `install.sh --install`. Затем мастер настройки:

1. Покажет обнаруженные LAN-интерфейс, subnet и DNS; значения можно скорректировать.
2. Спросит Headscale control URL, Tailscale Exit Node, VLESS subscription URL и pre-auth key. Секреты вводятся без отображения и сохраняются локально с ограниченными правами.
3. Скачает используемые SRS, соберёт кандидат конфигурации и проверит его командой `sing-box check`.
4. Предложит активацию. Для запуска нужно ответить `y`, затем ввести `ACTIVATE`.

Активация включает IPv4 forwarding/SRCNAT на одном интерфейсе, policy route, nftables TPROXY и procd-службу RouteCraft. Инсталлятор не меняет клиентский gateway: установите IP роутера как default gateway для тестового клиента отдельно. Не проверяйте новый gateway на единственном компьютере, с которого администрируете устройство.

### Топология виртуальной машины

Создайте OpenWrt VM с одной сетевой картой, подключённой к виртуальному сегменту, где доступен upstream gateway. Проверьте, что default route OpenWrt использует этот же LAN bridge. Затем подключите отдельную клиентскую VM к тому же L2-сегменту и укажите адрес OpenWrt VM её шлюзом по умолчанию. Для первой проверки удобнее отдельная виртуальная L2-сеть, чтобы тестовый перехват не затронул другие устройства. Сохраните доступ к консоли гипервизора на время настройки.

## Установка до первого Release

Если готовый публичный Release ещё не создан, соберите bundle на машине разработки из клона репозитория. Нужны Go, `make`, PowerShell и `tar`:

```sh
git clone https://github.com/Vasiliy82/routecraft.git
cd routecraft
make package-openwrt
```

В `.cache/releases/` будут три архива и `.sha256` sidecar. На целевом OpenWrt проверьте архитектуру:

```sh
uname -m
```

Скопируйте соответствующие `routecraft-poc-openwrt-<arch>.tar.gz` и `.sha256` на OpenWrt. Например, для `x86_64`, на машине разработки выполните:

```sh
scp -O .cache/releases/routecraft-poc-openwrt-amd64.tar.gz .cache/releases/routecraft-poc-openwrt-amd64.tar.gz.sha256 root@<openwrt-ip>:/tmp/
```

Затем на OpenWrt выполните:

```sh
cd /tmp
sha256sum -c routecraft-poc-openwrt-amd64.tar.gz.sha256
mkdir -p /tmp/routecraft-install
tar -xzf routecraft-poc-openwrt-amd64.tar.gz -C /tmp/routecraft-install
cd /tmp/routecraft-install
sh ./install.sh --check
sh ./install.sh --install
sh /etc/routecraft-poc/configure.sh
```

`--check` ничего не меняет. `--install` добавляет недостающие пакеты и stage-ит файлы в `/etc/routecraft-poc`, но не активирует маршрутизацию. Команда configure запускает тот же мастер, что и публичный bootstrap.

## Быстрая проверка

С тестового клиента, которому отдельно назначен RouteCraft как gateway:

```sh
curl -4 https://2ip.io/                              # Tailscale Exit Node
curl -4 https://ifconfig.me/                         # VLESS
curl -4 https://icanhazip.com/                       # direct
curl -4 -I --max-time 10 https://theuselessweb.com/  # ожидается отказ
```

Внешние IP могут меняться вместе с выходным узлом. На самом OpenWrt статус процесса смотрите командой `service routecraft-poc status`, журнал — `logread | grep sing-box`.

## Границы текущего PoC

- Перехватывается IPv4 TCP/UDP; это не готовый полнофункциональный маршрутизатор для IPv6/ICMP.
- Схема только однорукая; WAN/LAN с разными группами интерфейсов — следующий этап.
- Нет LuCI, обновления VLESS-подписки по расписанию и автоматического обновления GeoSite/GeoIP.
- Готовый публичный one-command install заработает после публикации репозитория и первого tag-release; до этого используйте локальную сборку выше.
- RouteCraft не предоставляет VPN-аккаунт и не гарантирует доступность сторонних сайтов. Туннели и выходные IP принадлежат выбранному вами провайдеру/серверу.
