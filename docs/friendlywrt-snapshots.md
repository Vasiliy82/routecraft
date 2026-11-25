# Снапшоты FriendlyWrt на NanoPi R28S

Выполняйте команды от `root` на роутере. Установщик сам монтирует раздел `opt` в `/persistent` и создаёт скрипты.

## Установить

```sh
curl -fsSL https://raw.githubusercontent.com/Vasiliy82/routecraft/main/snapshot/setup.sh | sh
```

Повторный запуск обновляет оба скрипта и сохраняет файлы снимков. Версия указана в первой строке справки `snapshotctl help`. Версия 0.2.1 работает с новым форматом. Старые файлы `.img` остаются на диске и отсутствуют в списке.

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

`create` сохраняет gzip-образ и его SHA-256 в каталоге `/persistent/snapshots/NAME.snapshot`. Перед записью `restore` сверяет SHA-256, проверяет поток gzip и размер распакованного образа. Затем пишет в активный `userdata` через `dd` и сразу перезагружает роутер. Проверки обнаруживают повреждение файла, а согласованность смонтированного ext4 зависит от записей во время снятия образа.

Для 0.2.1 сжатие, проверки и полный откат проверены на файловой имитации. На R28S создание и вывод списка проверены в 0.2.0.
