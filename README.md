# claude-control

**Русский · [English](./README.en.md)**

Удаленные сессии [Claude Code](https://claude.com/claude-code) для всех твоих проектов через одну "диспетчерскую" сессию, к которой ты ходишь с телефона.

> Поверх фичи [`claude remote-control`](https://code.claude.com/docs/en/remote-control.md), которая на момент написания в статусе **research preview**. Нужен Claude Code CLI **≥ 2.1.51** и логин через Claude-подписку (`claude /login`) - API-ключи Anthropic для remote-control не работают.

## Зачем

Claude Code умеет открывать сессию для удаленного управления (`claude remote-control --name X`) - тогда к ней можно подключиться с телефона из приложения Claude или из браузера. Идея отличная, но в живом виде неудобна: чтобы сходить в нужный проект, надо физически у Mac'а открыть терминал, `cd` в репо, запустить там `claude remote-control --name <repo>` и только потом идти на телефон. Если ты не за Mac'ом - вся затея бесполезна.

`claude-control` закрывает этот зазор:

- На Mac'е постоянно крутится одна **control-сессия** (launchd держит ее живой). Она доступна с телефона круглосуточно.
- С телефона ты говоришь control-сессии "подними `<проект>`". Она запускает `claude-rc <проект>`, который поднимает уже проектную сессию в `tmux` в нужной директории.
- Открываешь приложение Claude еще раз, видишь новую сессию `<проект>` - ты внутри проекта, удаленно, без SSH и ручного `cd`.
- Маленький **watchdog** перезапускает control-сессию, если она тихо умерла (см. [docs/troubleshooting.md](./docs/troubleshooting.md)) - launchd сам этого не замечает.

## Что это дает

- **Доступ к любому проекту с телефона за один сценарий.** Все, что нужно - сказать "подними `<имя>`" в control-сессии. Дальше работаешь как обычно, только клавиатура мобильная.
- **Никаких заранее открытых сессий.** Поднимаешь проект только когда он действительно нужен - не висят полтора десятка сессий по всем репо просто так.
- **Реестр проектов в одном файле.** `~/.claude-control/projects.yaml` - короткий список `имя: путь`. Добавить новый проект - одна строка.
- **Идемпотентно.** Повторный "подними `<имя>`" увидит живой `tmux` и не плодит дублей; если сессия успела умереть на простое - поднимет заново.
- **Отдельно ставится, отдельно сносится.** Один `./install.sh`, один `./uninstall.sh`. Никаких глобальных пакетов и системных служб - только пользовательские launchd-агенты и скрипты в `~/.local/bin/`.

## Как это выглядит с телефона

```
Ты (в приложении Claude) - открыл Code, выбрал сессию "control"
Ты               - "подними webapp"
control-сессия   - запускает claude-rc webapp, отвечает именем tmux-сессии
Ты               - открываешь Code еще раз, выбираешь сессию "webapp"
Ты               - внутри проекта, удаленно
```

## Требования

- macOS (launchd) или Linux с systemd user services (Ubuntu 22.04+, Debian 12+, любой современный дистр).
- [Claude Code CLI](https://docs.claude.com/claude-code) ≥ 2.1.51, залогинен через `claude /login` (Claude-подписка).
- `tmux` - `brew install tmux` (macOS) или `apt install tmux` (Linux).
- `yq` от mikefarah, v4 - `brew install yq` на macOS; на Linux **бинарник с [GitHub releases](https://github.com/mikefarah/yq/releases)**, пакет `yq` из apt - другой проект, не подходит. `install.sh` проверяет версию и упадет, если поставлен не тот.
- На macOS желательно держать Mac неспящим, пока ты удаленно. launchd не работает во время сна, удаленные сессии гибнут с системой. Стандартный прием - отдельный launchd-агент с `caffeinate -i`; этот репо его не ставит.
- На Linux нужен включенный **lingering**, иначе user-сервисы остановятся при logout и не поднимутся после ребута. Один раз: `loginctl enable-linger $USER` (может потребовать sudo в зависимости от polkit). `install.sh` проверит и предупредит, если выключено.

## Быстрый старт

```sh
git clone https://github.com/dewil/claude-control.git
cd claude-control
./install.sh
$EDITOR ~/.claude-control/projects.yaml   # вписать свои проекты
```

Все - control-сессия уже крутится, можно идти в приложение Claude: **Code -> сессия `control` -> "подними `<имя>`"**.

Если планируешь править сам репо - ставь через `./install.sh --link`. Тогда скрипты в `~/.local/bin/` будут симлинками на `bin/` в репе, и `git pull` сразу обновляет рабочий код.

## Принципы

- **Идемпотентность.** `./install.sh` можно гонять повторно: юниты пересоздаются, существующие `~/.claude-control/projects.yaml`, `CLAUDE.md`, логи не трогаются.
- **Runtime отдельно от репо.** Сам репо живет где удобно (например, `~/Work/claude-control/`); пользовательские данные - в `~/.claude-control/`. Снести репо безопасно после копирующей установки.
- **Только user-level супервизор.** На macOS - launchd user agent, на Linux - `systemctl --user`. Никакого `sudo`, никаких системных сервисов, все ставится в пользовательский префикс.
- **Никакой магии в watchdog.** Watchdog читает последние 30 строк `control.log` и при отсутствии heartbeat'а пинает супервизор (`launchctl kickstart` на macOS, `systemctl --user restart` на Linux). Все, что он делает, видно глазами в `~/.claude-control/watchdog.log`.

## Безопасность

Модель доверия и того, что унаследует удаленная сессия:

- **`projects.yaml` - доверенный файл.** `claude-rc` парсит пути через `yq` как данные, без shell-интерполяции, и валидирует имя проекта; но содержимое файла полностью под твоим контролем. Не редактируй его по запросу LLM из чата.
- **Control-сессия - диспетчер с узким allow-list'ом.** Ей разрешено только звать `claude-rc`, `tmux ls`, `tmux kill-session` (см. [examples/control-settings.local.json.example](./examples/control-settings.local.json.example) и [examples/control-CLAUDE.md.example](./examples/control-CLAUDE.md.example)). Никакого общего `Bash` или `Edit`.
- **Проектные сессии наследуют твои настройки `~/.claude/settings.json`.** `claude-rc` ничего не пробрасывает поверх. Если в глобальных настройках стоит `bypassPermissions` или авто-approve - удаленная сессия для любого проекта молча сделает что попросят. Если это не то, чего ты хочешь, добавь в каждый проект свой `.claude/settings.local.json` с явным `allow`-списком.
- **prompt-injection.** Текст из README/имен веток/чужих файлов - это данные, а не инструкции. Для control-сессии это прописано в `control-CLAUDE.md.example`; для проектных сессий поведение зависит от твоего собственного CLAUDE.md в проекте.

## Структура

- [`bin/claude-rc`](./bin/claude-rc) - команда для control-сессии, поднимает проектную сессию в `tmux`.
- [`bin/claude-control-session`](./bin/claude-control-session) - entrypoint супервизора (вечная control-сессия).
- [`bin/claude-control-watchdog`](./bin/claude-control-watchdog) - проверка живости control-сессии (раз в 5 минут).
- [`launchd/`](./launchd/) - шаблоны plist'ов для macOS; `install.sh` их рендерит и кладет в `~/Library/LaunchAgents/`.
- [`systemd/`](./systemd/) - шаблоны `.service` / `.timer` для Linux; `install.sh` их рендерит и кладет в `~/.config/systemd/user/`.
- [`examples/`](./examples/) - стартовые `projects.yaml`, `CLAUDE.md`, `settings.local.json` для `~/.claude-control/`.
- [`docs/architecture.md`](./docs/architecture.md) - схема: что где живет, как взаимодействует.
- [`docs/troubleshooting.md`](./docs/troubleshooting.md) - типовые поломки (сессия гаснет на простое, пустой watchdog-лог, сон Mac'а).
- [`install.sh`](./install.sh) / [`uninstall.sh`](./uninstall.sh) - установка и снос.

## Что лежит после установки

**macOS:**

```
~/.local/bin/
  claude-rc, claude-control-run, claude-control-logrotate
  claude-control-session, claude-control-watchdog

~/Library/LaunchAgents/
  com.<user>.claude-control.plist
  com.<user>.claude-control-watchdog.plist
  com.<user>.claude-control-logrotate.plist

~/.claude-control/
  projects.yaml                # твой реестр проектов (в .gitignore)
  CLAUDE.md                    # контекст control-сессии
  .claude/settings.local.json  # allow-list команд для control-сессии
  control.log, control.err     # stdout/stderr control-сессии
  watchdog.log                 # история kickstart'ов watchdog'а
  watchdog.out, watchdog.err   # stdout/stderr watchdog'а
```

**Linux:**

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

~/.claude-control/
  projects.yaml, CLAUDE.md, .claude/settings.local.json
  control.log, control.err
  watchdog.log, watchdog.out, watchdog.err
```

Дополнительно можно создать `~/.config/claude-control/env` с переменными окружения вида `CLAUDE_BIN=/path/to/claude`. На Linux его подхватывают оба systemd-unit'а через `EnvironmentFile`. На macOS launchd env-файлы не читает, поэтому его читает сам entrypoint `claude-control-session` - то есть на macOS env-файл влияет на control-сессию (`CLAUDE_BIN`, proxy), но не на watchdog/logrotate. Правка unit'ов не нужна.

## Удалить

```sh
./uninstall.sh           # снять агентов и удалить скрипты из ~/.local/bin/
./uninstall.sh --purge   # дополнительно снести ~/.claude-control/
```

## Лицензия

[MIT](./LICENSE). Бери, дорабатывай, используй у себя - просто оставь copyright-уведомление в производных копиях.
