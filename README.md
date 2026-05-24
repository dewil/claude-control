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

- macOS (Apple Silicon или Intel). Linux/systemd в планах.
- [Claude Code CLI](https://docs.claude.com/claude-code) ≥ 2.1.51, залогинен через `claude /login` (Claude-подписка).
- `tmux` (`brew install tmux`).
- Желательно держать Mac неспящим, пока ты удаленно. launchd не работает во время сна, и любая удаленная сессия гибнет вместе с системой. Стандартный прием - отдельный launchd-агент с `caffeinate -i`; этот репо его не ставит, держи Mac бодрым сам.

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

- **Идемпотентность.** `./install.sh` можно гонять повторно: launchd-юниты пересоздаются, существующие `~/.claude-control/projects.yaml`, `CLAUDE.md`, логи не трогаются.
- **Runtime отдельно от репо.** Сам репо живет где удобно (например, `~/Work/claude-control/`); пользовательские данные - в `~/.claude-control/`. Снести репо безопасно после копирующей установки.
- **launchd-only.** Никаких демонов вне launchd, никакого `sudo`. Все ставится в пользовательский префикс.
- **Никакой магии в watchdog.** Watchdog читает последние 30 строк `control.log` и при отсутствии heartbeat'а делает `launchctl kickstart`. Все, что он делает, видно глазами в `~/.claude-control/watchdog.log`.

## Структура

- [`bin/claude-rc`](./bin/claude-rc) - команда для control-сессии, поднимает проектную сессию в `tmux`.
- [`bin/claude-control-session`](./bin/claude-control-session) - entrypoint launchd-агента (вечная control-сессия).
- [`bin/claude-control-watchdog`](./bin/claude-control-watchdog) - проверка живости control-сессии (раз в 5 минут).
- [`launchd/`](./launchd/) - шаблоны plist'ов; `install.sh` их рендерит и кладет в `~/Library/LaunchAgents/`.
- [`examples/`](./examples/) - стартовые `projects.yaml`, `CLAUDE.md`, `settings.local.json` для `~/.claude-control/`.
- [`docs/architecture.md`](./docs/architecture.md) - схема: что где живет, как взаимодействует.
- [`docs/troubleshooting.md`](./docs/troubleshooting.md) - типовые поломки (сессия гаснет на простое, пустой watchdog-лог, сон Mac'а).
- [`install.sh`](./install.sh) / [`uninstall.sh`](./uninstall.sh) - установка и снос.

## Что лежит после установки

```
~/.local/bin/
  claude-rc, claude-control-session, claude-control-watchdog

~/Library/LaunchAgents/
  com.<user>.claude-control.plist
  com.<user>.claude-control-watchdog.plist

~/.claude-control/
  projects.yaml                # твой реестр проектов (в .gitignore)
  CLAUDE.md                    # контекст control-сессии
  .claude/settings.local.json  # allow-list команд для control-сессии
  control.log, control.err     # логи launchd
  watchdog.log, watchdog.out, watchdog.err
```

## Удалить

```sh
./uninstall.sh           # снять агентов и удалить скрипты из ~/.local/bin/
./uninstall.sh --purge   # дополнительно снести ~/.claude-control/
```

## Лицензия

[MIT](./LICENSE). Бери, дорабатывай, используй у себя - просто оставь copyright-уведомление в производных копиях.
