# runbook: claude-control-backup

Опциональный модуль: клиентски-шифрованный дедуплицированный бэкап произвольных путей в **два независимых S3-репозитория** через [restic](https://restic.net). Ставится флагом `--with-backup` (Linux).

## Зачем так

- **Клиентское шифрование** (restic, AES): провайдер S3 видит только шифртекст - бэкап можно держать у хостинга, которому не доверяешь plaintext.
- **Два независимых провайдера**: два независимых `restic backup` (не `copy`), у репо разные ключи - падение или бан одного не мешает второму, восстановление возможно из любого. Классика 3-2-1.
- **Дедуп + zstd-сжатие**: на текстовых данных обычно 5-10x экономии места и трафика; инкременты дальше копеечные.

## Компоненты

- `bin/claude-control-backup` - ежедневный бэкап (оба репо + `forget --prune`).
- `bin/claude-control-backup-init` - первичная инициализация репо (идемпотентно).
- `bin/claude-control-backup-restore-test` - DR-drill (restore + проверка непустоты).
- `systemd/claude-control-backup.{service,timer}.tmpl` - таймер (ежедневно ~04:30).
- `examples/backup-env.example` - конфиг с плейсхолдерами.

Конфиг - `~/.config/claude-control/backup-env` (или `$CLAUDE_BACKUP_ENV`), `chmod 600`, **вне git**. Bash-файл (source'ится): пути (`BACKUP_PATHS` - массив), URL репо, креды. Ничего машино-специфичного в самих скриптах нет.

## Установка и настройка

```
./install.sh --with-backup
```

Ставит скрипты + юниты и сидит `backup-env` из примера. Таймер **не включается** - сперва заполни конфиг и инициализируй репо:

1. Заведи по bucket'у у **двух разных** S3-провайдеров + пары ключей доступа. Годятся любые S3-совместимые: Yandex Object Storage (`storage.yandexcloud.net`), Timeweb Cloud (`s3.twcstorage.ru`), Backblaze B2, Cloudflare R2, Wasabi, AWS S3.
2. Сгенерь пароль репозитория: `openssl rand -base64 32`, положи в менеджер паролей.
3. Заполни `~/.config/claude-control/backup-env` (см. таблицу подстановки).
4. `claude-control-backup-init` - создаст оба репо и проверит доступ.
5. `claude-control-backup` - первый прогон (полный; дальше инкременты).
6. `systemctl --user enable --now claude-control-backup.timer`.
7. `claude-control-backup-restore-test` - убедись, что восстановление работает.

## Эксплуатация

- Логи прогонов: `journalctl --user -u claude-control-backup.service`.
- Ручной бэкап: `claude-control-backup`.
- Список снапшотов репо A:
  ```
  source ~/.config/claude-control/backup-env
  RESTIC_REPOSITORY=$RESTIC_REPO_A AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID_A \
    AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY_A restic snapshots
  ```
- **Консистентность**: если бэкапишь live-данные, где важна атомарность, снимай снапшот ФС (btrfs/LVM/ZFS) в drop-in перед прогоном - restic забэкапит снапшот.
- **Шифрованный/съёмный том**, который бывает недоступен: gate службу drop-in'ом `ConditionPathIsMountPoint=/your/mount` - при отсутствии тома прогон пропускается без ошибки.

## Восстановление (DR)

Нужен только пароль репозитория + S3-ключи (из менеджера паролей) - ничего с исходной машины. На чистом хосте:

```
export RESTIC_PASSWORD=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
export RESTIC_REPOSITORY='s3:https://<endpoint>/<bucket>/restic'
restic snapshots
restic restore latest --target /куда/восстановить
```

Один провайдер недоступен - берёшь второй, содержимое идентично. Периодически прогоняй restore-drill на **отдельном** хосте (не там, где бэкапишь) плюс `restic check --read-data-subset=10%` - ловит тихую порчу блоков на стороне S3.

## Таблица подстановки

| Плейсхолдер | Что это | Пример |
|---|---|---|
| `BACKUP_PATHS` | что бэкапить (bash-массив путей) | `(/srv/data "/home/me/notes")` |
| `<endpoint-a>` / `<endpoint-b>` | S3-эндпоинты двух провайдеров | `storage.yandexcloud.net` / `s3.twcstorage.ru` |
| `<bucket>` | имя bucket'а у провайдера | `myhost-backup` |
| `<access-key>` / `<secret>` | ключ доступа S3 (свой на каждый репо) | - |
| `RESTIC_PASSWORD` | пароль репозитория (общий на A и B) | длинная случайная строка |
