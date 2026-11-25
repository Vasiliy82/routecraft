# Снапшоты FriendlyWrt на NanoPi R28S

Выполняйте команды от `root` на роутере. Установщик сам монтирует раздел `opt` в `/persistent` и создаёт скрипты.

## Установить

```sh
curl -fsSL https://raw.githubusercontent.com/Vasiliy82/routecraft/main/snapshot/setup.sh | sh
```

Повторный запуск обновляет оба скрипта и сохраняет снимки. Версия указана в первой строке справки `snapshotctl help`.

## Вернуть доступ после firstboot

После заводского сброса и загрузки роутера выполните:

```sh
curl -fsSL https://raw.githubusercontent.com/Vasiliy82/routecraft/main/snapshot/setup.sh | sh -s -- recover
```

Команда снова монтирует `/persistent`, возвращает автомонтирование и ссылку на `snapshotctl`. Снимки хранятся на `opt`.

## Использование

```sh
snapshotctl create golden
snapshotctl list
snapshotctl restore golden
snapshotctl delete golden
```

`restore` пишет образ в активный `userdata` через `dd` и сразу перезагружает роутер. Работа со смонтированным ext4 может привести к несогласованному снимку или откату. Создание и вывод списка проверены на R28S. Запись в активный `userdata` с перезагрузкой проверена на файловой имитации.
