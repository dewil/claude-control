# Архитектура

```
┌──────────────────┐         ┌──────────────────────────────┐
│  Claude mobile / │ ─────►  │  Anthropic remote-control    │
│  claude.ai/code  │         │  routing (claude.ai)         │
└──────────────────┘         └──────────────┬───────────────┘
                                            │
                                            ▼
                              ┌──────────────────────────────┐
                              │  Твой Mac / Linux-машина     │
                              │                              │
   супервизор (user-level)    │   ┌────────────────────────┐ │
   control unit              ─┼─► │ claude-control-session │ │
                              │   │  → claude remote-      │ │
                              │   │    control --name      │ │
                              │   │    control --capacity 1│ │
                              │   └────────────────────────┘ │
                              │                              │
   watchdog unit              │   ┌────────────────────────┐ │
   (раз в 5 минут)           ─┼─► │ claude-control-watchdog│ │
                              │   │  читает control.log,   │ │
                              │   │  при отсутствии        │ │
                              │   │  heartbeat'а пинает    │ │
                              │   │  супервизор            │ │
                              │   └────────────────────────┘ │
                              │                              │
                              │   когда ты говоришь          │
                              │   "подними X" в control:     │
                              │                              │
                              │   ┌────────────────────────┐ │
                              │   │ claude-rc X            │ │
                              │   │  → tmux new-session    │ │
                              │   │    cd $path && claude  │ │
                              │   │    remote-control      │ │
                              │   │    --name X            │ │
                              │   └────────────────────────┘ │
                              └──────────────────────────────┘
```

## Компоненты

### `claude-control-session` (control)

Тонкая bash-обертка, которую супервизор держит живой. Внутри - `claude remote-control --name control --capacity 1`, запускается из `~/.claude-control/`. Эта папка для control-сессии - проектная директория, поэтому ее `CLAUDE.md` тоже подгружается как контекст. Назначение `CLAUDE.md` тут - научить control-сессию реагировать на "подними `<имя>`", "что запущено", "убей `<имя>`" соответствующими bash-командами и ничего больше в этой папке не делать.

`--capacity 1` потому что control-сессия одна и параллелизм ей не нужен.

### `claude-rc <project>`

Bash-скрипт. Ищет `<project>` в `~/.claude-control/projects.yaml` через `yq` (строго `mikefarah/yq` v4), проверяет существование пути, поднимает detached `tmux`-сессию `claude-<project>` с `claude remote-control --name <project>` внутри нужной директории. Режим `--spawn` определяет автоматически: `worktree`, если каталог - git-репозиторий, `same-dir` иначе.

Если сессия с таким именем уже жива, скрипт делает no-op с сообщением, а не плодит дубль.

### `claude-control-watchdog`

Запускается раз в 5 минут (на macOS - `StartInterval=300` в plist watchdog'а; на Linux - `.timer` с `OnUnitActiveSec=5min`). Читает последние 30 строк `control.log` и ищет имя сессии (`control` по умолчанию) как whitespace-bounded token - то есть в выводе `remote-control` где-то рядом с пробельными символами стоит слово `control`. Если не нашел - ждет 5 секунд и проверяет повторно (защита от гонки startup), и только потом пишет строку в `watchdog.log` и пинает супервизор.

Зачем это нужно: процесс `claude remote-control` может оставаться живым, при этом **зарегистрированная сессия** на стороне Anthropic-роутинга может исчезнуть (capacity падает до 0). Супервизор этого не видит - процесс-то жив; на телефоне же сессия `control` пропадает. Watchdog ловит это по логу и пинает процесс.

## Супервизоры

### macOS (launchd)

- `~/Library/LaunchAgents/com.<user>.claude-control.plist` - control-сессия, `KeepAlive=true`, `ThrottleInterval=30`. Перезапуск - `launchctl kickstart -k gui/$UID/<label>`.
- `~/Library/LaunchAgents/com.<user>.claude-control-watchdog.plist` - watchdog, `StartInterval=300`, `RunAtLoad=true`.

### Linux (systemd --user)

- `~/.config/systemd/user/claude-control.service` - control-сессия, `Restart=always`, `RestartSec=30`. Перезапуск - `systemctl --user restart claude-control.service`.
- `~/.config/systemd/user/claude-control-watchdog.service` - oneshot.
- `~/.config/systemd/user/claude-control-watchdog.timer` - триггер: `OnActiveSec=2min` (первый запуск) + `OnUnitActiveSec=5min` (последующие). `Persistent=false` - watchdog это health-probe, а не задание, упущенные тики ловить не нужно.

Без `loginctl enable-linger $USER` user-сервисы остановятся при logout. `install.sh` проверяет и предупреждает, если lingering выключен.

Опционально: `~/.config/claude-control/env` подхватывается обоими unit'ами через `EnvironmentFile=-` (отсутствие файла - не ошибка). На macOS launchd env-файлы не читает, поэтому тот же файл читает сам entrypoint `claude-control-session` - на macOS это влияет на control-сессию (`CLAUDE_BIN`, proxy), но не на watchdog/logrotate. Удобно для проброса `CLAUDE_BIN`, proxy-переменных и т.п. без правки unit'а.

## Что где лежит после установки

### macOS

```
~/.local/bin/
  claude-rc                       # скрипт (или симлинк на репо при --link)
  claude-control-session          # launchd entrypoint
  claude-control-watchdog         # скрипт watchdog'а

~/Library/LaunchAgents/
  com.<user>.claude-control.plist            # control-сессия
  com.<user>.claude-control-watchdog.plist   # watchdog (раз в 5 минут)

~/.claude-control/
  projects.yaml                   # твой реестр (в .gitignore репо)
  CLAUDE.md                       # контекст control-сессии
  .claude/settings.local.json     # allow-list bash-команд
  control.log, control.err        # stdout/stderr control-сессии
  watchdog.log                    # история kickstart'ов watchdog'а
  watchdog.out, watchdog.err      # stdout/stderr watchdog'а
```

### Linux

```
~/.local/bin/
  claude-rc, claude-control-run, claude-control-logrotate
  claude-control-session, claude-control-watchdog

~/.config/systemd/user/
  claude-control.service
  claude-control-watchdog.service
  claude-control-watchdog.timer

~/.config/claude-control/env      # опционально, env-переменные для unit'ов

~/.claude-control/
  projects.yaml, CLAUDE.md, .claude/settings.local.json
  control.log, control.err
  watchdog.log, watchdog.out, watchdog.err
```
