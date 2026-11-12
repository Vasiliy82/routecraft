# Контракт политики RouteCraft

Планируемый формат версии 1; реализация и имена файлов ещё должны быть проверены разработкой. Правила идут сверху вниз; используется первый подходящий rule. Все элементы `filter` — OR. Отдельные `port` и `network` тоже являются самостоятельными альтернативами, а не AND с предыдущим фильтром. Единственное правило без `filter` стоит последним.

```yaml
version: 1
rules:
  - name: vpn-static
    filter:
      - geosite:openai
      - geosite:cursor
      - geosite:anthropic
      - domain:2ip.io
    outbound: tailscale-exit
  - name: vpn-sub
    filter:
      - geosite:ru-blocked
      - geoip:ru-blocked
      - geosite:youtube
      - geosite:telegram
      - geoip:telegram
      - geosite:whatsapp
    outbound: vpn-sub
  - name: default
    outbound: direct
```

Фильтры: `geosite:<category>`, `geoip:<category>`, `domain:<fqdn>` (точное имя), `domainsuffix:<fqdn>` (зона и поддомены, с границей метки), `domainkeyword:<string>`, `ip:<address>`, `ipnet:<CIDR>`, `port:<1..65535>` и `network:tcp|udp`. Валидация должна отклонять некорректные значения, неизвестные категории/выходы, повтор имён, несколько default и правила после default. Синтаксическое принятие IPv6 не обещает IPv6 forwarding.

Именованные выходы конфигурируются отдельно и имеют явный тип `direct`, `reject`, `sing-box-tag`, `gateway` или `tailscale-exit`. Тип `gateway` задаёт достижимый IP next-hop и интерфейс; Tailscale Exit Node — отдельная интеграция. Отсутствие нужного выхода является ошибкой. Метаданные источников и overlays конфигурируются отдельно; не считать `cursor` или `ru-blocked` существующими в любом произвольном источнике.

DNS сопоставляет только доменную часть правил; IP и GeoIP проверяются при маршрутизации трафика. Из-за shared IP/CDN, ECH и DNS внутри приложения доменное объяснение может отличаться от фактического сетевого пути и должно описывать ограничения.
