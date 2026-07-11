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

Bash-скрипт. Ищет `<project>` в `~/.claude-control/projects.yaml` через `yq` (строго `mikefarah/yq` v4), проверяет существование пути, поднимает detached `tmux`-сессию `claude-<project>`, запуская в ней `claude-control-run` (launcher), который выполняет `claude remote-control --name <project>` в нужной директории и пишет вывод в лог проекта с первой строки. Режим `--spawn` определяет автоматически: `worktree`, если каталог - git-репозиторий, `same-dir` иначе. `status <project>` сверяет имя с `projects.yaml` и классифицирует состояние по последнему статусному событию в выводе. `stop <project>` (глагол "положи `<имя>`" с телефона) гасит сессию ЛОКАЛЬНО: шлет `SIGTERM` именно процессу `claude remote-control` (не панельному shell/`tee`, находит его через `pgrep -P <pane_pid> -f "remote-control --name <project>"`), чтобы claude чисто дренил под-сессии/MCP/worktree, ждет выхода до `CLAUDE_RC_STOP_GRACE` секунд (по умолчанию 15) и только если не вышел - добивает `tmux kill-session`. Это лучше голого `kill-session` (SIGHUP осиротит детей). **ВАЖНО:** `stop` НЕ убирает сессию из списка на телефоне - `claude remote-control` намеренно сохраняет environment для resume при любом локальном завершении (сигнал/клавиша/выход) и дерегистрирует его только после ~10 мин сетевого give-up или серверного таймаута (bridge-pointer TTL ~4ч). Поддерживаемого headless-способа убрать раньше нет (внутренний путь - `DELETE /v1/environments/bridge/{envId}` с OAuth-токеном CLI - осознанно не используем). Поэтому запись висит до ~4ч и уходит сама.

`last <project>` и `<project> --continue` дают resume. `last` показывает самую свежую восстановимую сессию, перечисляя транскрипты (`~/.claude/projects/<slug>/*.jsonl`) И проектного слага, И всех worktree-слагов `<slug>--claude-worktrees-*` - реальная работа часто уходит в спавненную worktree-сессию, чей транскрипт лежит под слагом ЕЕ каталога, а не проекта, - и помечает каждую тегом origin (`project`/`worktree`) плюс вердиктом `resumable`. `--continue` восстанавливает эту сессию одиночным продолжением: если свежайшая - проектная, это `--continue` в каталоге проекта; если worktree-сессия - `cd` в тот worktree и `--session-id <uuid>` (CLI запрещает совмещать `--continue`/`--session-id` со `--spawn`/`--capacity`, поэтому resume их не несет - это не диспетчер, а одиночное продолжение). Worktree-resume отказывает, если каталог worktree залочен (его может держать живая сессия) или вырезан. Обе команды только читают транскрипты; превью первого сообщения (строка с префиксом `|`) возвращается как недоверенные данные, как вывод `status`.

`sessions <project>` печатает то же перечисление как меню выбора при старте: строка `[0] fresh` плюс до 4 последних восстановимых сессий (индекс, возраст, origin, превью), с пометкой у worktree-строк, если восстановить нельзя (залочен/вырезан). `<project> --resume N` поднимает пункт N из этого меню - всегда явным `--session-id <uuid>` в каталоге той сессии (для worktree-пунктов те же гарды залочен/вырезан, что у `--continue`); индекс резолвится в конкретную сессию в момент вызова. Плайн `<project>` без опций по-прежнему всегда стартует свежую диспетчер-сессию - на этот путь завязан авто-рестарт зомби из `claude-control-project-watchdog`, поэтому меню он не показывает.

Если сессия с таким именем уже жива, скрипт делает no-op с сообщением, а не плодит дубль.

### `claude-control-watchdog`

Запускается каждые 2 минуты (на macOS - `StartInterval=120` в plist watchdog'а; на Linux - `.timer` с `OnUnitActiveSec=2min`). Основной сигнал живости - `--debug-file` control-сессии: клиент пишет туда heartbeat по таймеру каждые ~20с (`CCRClient: Heartbeat sent` при успехе, `CCRClient: Heartbeat failed: ...` при сбое), без backoff. Пока heartbeat капает, mtime файла свежий - живая сессия (здоровая или ретраящая сеть после 403/обрыва) освежает его ~каждые 20с. Если mtime старше `STALE_SECONDS` (по умолчанию 150с, ~7 пропущенных ударов), таймер heartbeat встал = зомби ("zombie-Connected": TUI еще рисует "Connected", а фоновый цикл мертв). Один промах не вызывает рестарт: watchdog считает подряд пропущенные тики (`.watchdog-misses`) и пинает супервизор только после нескольких промахов подряд (по умолчанию 2), чтобы единичный сетевой blip не дергал control-сессию зря. Если `--debug-file` еще нет (старая или только что перезапущенная сессия) - fallback на прежний способ: ищет имя сессии (`control` по умолчанию) как whitespace-bounded token в хвосте `control.log`. Каждый тик watchdog также вызывает `claude-control-logrotate`.

Зачем это нужно: процесс `claude remote-control` может оставаться живым, при этом **зарегистрированная сессия** на стороне Anthropic-роутинга может исчезнуть (capacity падает до 0). Супервизор этого не видит - процесс-то жив; на телефоне же сессия `control` пропадает. Watchdog ловит это по логу и пинает процесс.

### `claude-control-project-watchdog`

То же самое, но для **проектных** сессий, которые запускает `claude-rc`. У них, в отличие от control, нет ни супервизора (KeepAlive), ни своего watchdog'а: сессия живет в detached tmux-окне `claude-<project>` и после 403-флапа (обрыв VPN, сон/пробуждение) зомбируется - TUI рисует "Ready / Capacity 0/5", а поллинг мертв. Проект молча "пропадает" с телефона на простое.

Запускается каждые 2 минуты (macOS - `StartInterval=120`; Linux - `.timer` с `OnUnitActiveSec=2min`). Надзирает **ровно за теми проектами, у кого сейчас есть живое tmux-окно**: сессию, которую пользователь остановил сам, воскрешать не надо (ее окно закрыто), а зомби окно сохраняет. Сигнал живости переиспользован у control-watchdog'а: `claude-rc` теперь запускает проектные сессии с `--debug-file`, так что у каждой есть тот же heartbeat. Свежий mtime debug-файла = жива (в т.ч. ретраит сеть - `Heartbeat failed` тоже капает каждые ~20с, флап не трогаем); молчание дольше `STALE_SECONDS` (150с) = зомби. Для сессий без debug-файла (запущены до инструментации) - fallback на mtime TUI-лога, но этот сигнал НЕ отличает здоровый простой (сессия просто перестала перерисовываться) от смерти, поэтому на fallback watchdog **только логирует, никогда не рестартит** (даже armed). Чтобы взять такую сессию под реальный надзор - один раз перезапустить ее через `claude-rc`, она получит `--debug-file`. После `MISS_THRESHOLD` промахов подряд (2), только если armed (`CLAUDE_CONTROL_PROJECT_WATCHDOG_ARM=1`, дефолт) И вердикт по heartbeat (не fallback) - убивает зависшее окно и перезапускает через `claude-rc` (новая сессия снова получает свой `--debug-file`). Для калибровки нового детектора по реальному трафику можно поставить `ARM=0` - тогда вместо kill+relaunch только пишет "WOULD restart" в `project-watchdog.log`.

Вне охвата: смерти, которые сносят и tmux-окно (жесткий краш, ребут, убивший tmux-сервер) - живого окна, за которое можно зацепиться, не остается.

### `claude-control-run` и `claude-control-logrotate`

`claude-control-run` - тонкий launcher проектной сессии: пишет лог с первого байта (без гонки `new-session` -> `pipe-pane`) и сохраняет код возврата `claude` (не маскируется `tee`). Параметры получает через `tmux -e` (env, без shell-парсинга - безопасно для путей с пробелами/кавычками), на старом tmux - позиционными аргументами. Если передан `CCR_DEBUG` (его ставит `claude-rc`), добавляет `--debug-file` - heartbeat-сигнал для `claude-control-project-watchdog`.

`claude-control-logrotate` - ротация всех логов (`control.log/.err`, `watchdog.*`, `project-watchdog.log`, `sessions/*.log` и их `*.debug.log`) по размеру. Вызывается watchdog'ом каждый тик, `claude-rc` на старте и отдельным таймером (независимо от `--watchdog`), так что логи ограничены даже без watchdog'а.

## Агентный слой (Linux only)

Поверх проектных сессий живет слой **автономных агентов**: миссии, которые работают без человека под надзором reconciler'а. Полный контракт (state machine, lease/fencing, crash-матрица) - в `docs/design-2026-07-11-agent-state-machine.md`; здесь - карта компонентов.

- **`claude-rc agent <verb>`** (диспатчится в `claude-rc-agent`) - операторский CLI: `create/start/pause/stop/status/list/resolve/revise/accept/reject/attach`. Реестр - `~/.claude-control/agents/<name>/` (spec.yaml, mission.md, control.json, state.<gen>.json, events.jsonl, work/ - приватный git-worktree агента). `create` фиксирует `mission_base` и создает ветку `agent/<name>`.
- **`claude-agent-io`** (python3) - единственный писатель `control.json`: durable-write (tmp -> fsync -> rename -> fsync каталога), CAS под flock с монотонным `seq`, schema-валидация при чтении, фенсинг поколений через `state.<gen>.json`, чистая классификация состояния.
- **`claude-agent-reconciler`** - демон (`--loop`, systemd-юнит) или одиночный проход (`--once`): сводит факт (systemd-юниты, state, relay-heartbeat из `session.debug.log`) к desired. Lease-протокол с CAS-гейтами A/B; гашение по инварианту "lease освобождается только при доказанно пустом cgroup"; admission по RAM-бюджету (`CLAUDE_AGENTS_RAM_BUDGET_MB`, дефолт 2500) с одним стартом за проход; fail-closed hold при запертом `/data` (`CLAUDE_AGENTS_REQUIRE_MOUNT`); alert-леджер `reconciler/alerts.jsonl` с дедупом эпизодов (пуш-канал - hook `CLAUDE_AGENT_ALERT_CMD`, TG-бот - этап 3).
- **`claude-agent-session`** - обертка рантайма одного поколения (MainPID транзиентного `agent-<name>.service`, Type=exec, KillMode=control-group, MemoryMax из spec): пресидит trust/onboarding в `$CLAUDE_CONFIG_DIR/.claude.json`, держит tmux-клиент форграундом на per-generation сокете `agent-<name>.g<gen>` (внутри - `claude remote-control --name agent-<name>`). Attach: `claude-rc agent attach <name>`.
- **`claude-agent-checkrun`** - bounded-воркер приемки: гоняет детерминированный `acceptance.check` дважды в worktree артефакта, результат собирает reconciler следующими проходами (fencing по `{job_id, generation, artifact}`).
- **`claude-agent-tgbot`** - TG-дашборд: long-poll getUpdates через mihomo-прокси (webhook и прямой API режутся ТСПУ); auth = private chat + from.id whitelist (группа правом не является); `/agents`, `/agent <name>` (имя валидируется до обращения к ФС, вывод агентов эскейпится как недоверенный); режим `send` = хук `CLAUDE_AGENT_ALERT_CMD` для пушей reconciler'а (дедуп эпизодов - на стороне alert-леджера). Токен/whitelist - в `~/.config/claude-control/env`. Офлайн-тесты: `claude-agent-tgbot selftest`.

Агентские сессии **вне охвата** `claude-control-project-watchdog` (живут на своих tmux-сокетах и не числятся в projects.yaml; в watchdog есть и явный guard) - их надзирает только reconciler: политика "stale -> stop + fresh" уничтожила бы миссию.

Тесты: `tests/test-agent-io.sh`, `tests/test-agent-cli.sh` (юнит, локально), `tests/fault/run-fault-tests.sh` (fault-injection сценарии crash-матрицы, Linux/systemd, с mock-агентом).

## Супервизоры

### macOS (launchd)

- `~/Library/LaunchAgents/com.<user>.claude-control.plist` - control-сессия, `KeepAlive=true`, `ThrottleInterval=30`. Перезапуск - `launchctl kickstart -k gui/$UID/<label>`.
- `~/Library/LaunchAgents/com.<user>.claude-control-watchdog.plist` - watchdog control-сессии, `StartInterval=120`, `RunAtLoad=true`.
- `~/Library/LaunchAgents/com.<user>.claude-control-project-watchdog.plist` - watchdog проектных сессий, `StartInterval=120`, `RunAtLoad=true`. Ставится вместе с control-watchdog'ом (тем же `--watchdog`), `ARM=1` (auto-restart; 0 = observe-only).
- `~/Library/LaunchAgents/com.<user>.claude-control-logrotate.plist` - ротация логов, `StartInterval=3600`. Ставится независимо от `--watchdog`.

### Linux (systemd --user)

- `~/.config/systemd/user/claude-control.service` - control-сессия, `Restart=always`, `RestartSec=30`. Перезапуск - `systemctl --user restart claude-control.service`.
- `~/.config/systemd/user/claude-control-watchdog.service` - oneshot (watchdog control-сессии).
- `~/.config/systemd/user/claude-control-watchdog.timer` - триггер: `OnActiveSec=2min` (первый запуск) + `OnUnitActiveSec=2min` (последующие). `Persistent=false` - watchdog это health-probe, а не задание, упущенные тики ловить не нужно.
- `~/.config/systemd/user/claude-control-project-watchdog.{service,timer}` - watchdog проектных сессий, тот же интервал 2min. Ставится вместе с control-watchdog'ом (`--watchdog`), `ARM=1` (auto-restart; 0 = observe-only).
- `~/.config/systemd/user/claude-control-logrotate.{service,timer}` - ротация логов, `OnUnitActiveSec=1h`. Ставится независимо от `--watchdog`, поэтому логи ограничены и при `--no-watchdog`.
- `~/.config/systemd/user/claude-agent-reconciler.service` - reconciler агентного слоя, `Restart=always`, `RestartSec=30`. Ставится безусловно (при пустом реестре - холостой цикл). Рантаймы агентов - транзиентные `agent-<name>.service` через `systemd-run`, юнит-файлов у них нет.
- `~/.config/systemd/user/claude-agent-tgbot.service` - TG-дашборд, `Restart=on-failure` (без токена выходит с кодом 0 и не рестартится; install.sh включает юнит только при настроенном `CLAUDE_AGENT_TG_TOKEN`).

Без `loginctl enable-linger $USER` user-сервисы остановятся при logout. `install.sh` проверяет и предупреждает, если lingering выключен.

Опционально: `~/.config/claude-control/env` подхватывается обоими unit'ами через `EnvironmentFile=-` (отсутствие файла - не ошибка). На macOS launchd env-файлы не читает, поэтому тот же файл читает сам entrypoint `claude-control-session` - на macOS это влияет на control-сессию (`CLAUDE_BIN`, proxy), но не на watchdog/logrotate. Удобно для проброса `CLAUDE_BIN`, proxy-переменных и т.п. без правки unit'а.

## Что где лежит после установки

### macOS

```
~/.local/bin/
  claude-rc                       # скрипт (или симлинк на репо при --link)
  claude-control-run              # launcher проектной сессии (лог с первого байта)
  claude-control-logrotate        # ротация всех логов
  claude-control-session          # launchd entrypoint
  claude-control-watchdog         # скрипт watchdog'а

~/Library/LaunchAgents/
  com.<user>.claude-control.plist             # control-сессия
  com.<user>.claude-control-watchdog.plist    # watchdog (раз в 5 минут)
  com.<user>.claude-control-logrotate.plist   # ротация логов (раз в час)

~/.claude-control/
  projects.yaml                   # твой реестр (в .gitignore репо)
  CLAUDE.md                       # контекст control-сессии
  .claude/settings.local.json     # allow-list bash-команд
  control.log, control.err        # stdout/stderr control-сессии
  watchdog.log                    # история kickstart'ов watchdog'а
  watchdog.out, watchdog.err      # stdout/stderr watchdog'а
  .watchdog-misses                # счетчик подряд пропущенных heartbeat (служебный)
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
  claude-control-logrotate.service
  claude-control-logrotate.timer

~/.config/claude-control/env      # опционально, env-переменные для unit'ов

~/.claude-control/
  projects.yaml, CLAUDE.md, .claude/settings.local.json
  control.log, control.err
  watchdog.log, watchdog.out, watchdog.err
```
