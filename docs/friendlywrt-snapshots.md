# Снапшоты FriendlyWrt на NanoPi R28S

Выполняйте команды от `root` на роутере. Установщик сам монтирует раздел `opt` в `/persistent` и создаёт скрипты.

## Установить

```sh
curl -fsSL https://raw.githubusercontent.com/Vasiliy82/routecraft/main/snapshot/setup.sh | sh
```

## Вернуть доступ после firstboot

После заводского сброса и загрузки роутера выполните:

```sh
curl -fsSL https://raw.githubusercontent.com/Vasiliy82/routecraft/main/snapshot/setup.sh | sh -s -- recover
```

Команда снова монтирует `/persistent`, возвращает автомонтирование и ссылку на `snapshotctl`. Снимки хранятся на `opt`.

## Использование

```sh
snapshotctl create golden
snapshotctl restore golden
snapshotctl delete golden
```

`restore` пишет образ в активный `userdata` через `dd` и сразу перезагружает роутер. Работа со смонтированным ext4 может привести к несогласованному снимку или откату. На R28S запись и перезагрузка остаются непроверенными.
