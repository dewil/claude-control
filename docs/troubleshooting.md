# Поломки и что с ними делать

## "Поднял проект пару часов назад, теперь его нет на телефоне"

Это нормальное поведение. Проектные сессии, которые поднимает `claude-rc`, гаснут на простое - если к ним никто не подключается, процесс `claude remote-control` сам выходит спустя какое-то время (порядка часов, точный таймаут не документирован). Как только процесс умер, `tmux` закрывает окно, и сессия пропадает из приложения Claude.

Control-сессия живет существенно дольше (плюс watchdog ее подстраховывает), а вот каждая `claude-<project>` - это обычное `tmux`-окно с одним `claude`-процессом внутри.

**Что делать:** поднимай проект непосредственно перед тем, как он понадобится, а не заранее. Если успела погаснуть - снова "подними `<имя>`": `claude-rc` увидит мертвый `tmux` и спокойно поднимет заново.

## Control-сессия пропала, а супервизор считает юнит здоровым

Это тот самый случай, ради которого существует watchdog. Процесс `claude remote-control` жив, но зарегистрированная сессия "ушла" со стороны роутинга. Симптом:

- macOS: `launchctl print gui/$UID/com.<user>.claude-control` показывает `Ready · Capacity 0/1`.
- Linux: `systemctl --user status claude-control.service` - `active (running)`, но на телефоне `control` пропал.

**Что смотреть в первую очередь:** `tail -n 30 ~/.claude-control/watchdog.log`. Если там свежие записи про `kick` - watchdog работает, просто control-сессия валится быстрее, чем раз в 5 минут. Можно ускорить watchdog:

- macOS: подкрутить `StartInterval` в watchdog plist'е и `launchctl bootout/bootstrap` его заново.
- Linux: подправить `OnUnitActiveSec` в `~/.config/systemd/user/claude-control-watchdog.timer` и `systemctl --user daemon-reload && systemctl --user restart claude-control-watchdog.timer`.

Если watchdog-лог давно пустой - значит сам watchdog сломан. Перезапусти `./install.sh` и посмотри `~/.claude-control/watchdog.err`. На Linux дополнительно проверь `systemctl --user status claude-control-watchdog.timer` - таймер должен быть `active (waiting)`.

## `claude-rc` пишет "Unknown project"

Либо опечатка в имени, либо в `~/.claude-control/projects.yaml` нет ключа с таким именем. `claude-rc` парсит YAML через `yq` (mikefarah, v4): `yq -r '.[strenv(name)]' projects.yaml`. Если ключ не на верхнем уровне, или в YAML битый отступ, или используется не mikefarah-вариант `yq` - запись не найдется.

Полный список валидных имен можно посмотреть командой `claude-rc list`.

## tmux: "no server running" / "session not found"

`claude-rc` использует tmux-сервер по умолчанию (без `-L`). Если у тебя нестандартный tmux с именованными сокетами, либо выставь `TMUX_TMPDIR` / нужный сокет в окружении перед вызовом `claude-rc`, либо правь скрипт под себя - он умышленно простой и про сокеты ничего не знает.

## `claude` не находится при запуске из супервизора

Супервизоры запускают агентов с тощим PATH.

- На macOS оба скрипта (`claude-control-session`, `claude-control-watchdog`) сами добавляют в начало PATH `/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.local/bin`, `$HOME/bin` - этого хватает для типовых установок Claude Code и `tmux`.
- На Linux `install.sh` прокидывает `BIN_DIR` (по умолчанию `$HOME/.local/bin`) в unit через `Environment=PATH=...`, а сами скрипты дополнительно ставят разумный PATH без homebrew-путей.

Если у тебя `claude` живет где-то еще (`mise`, `asdf`, кастомный prefix):

- macOS: правь PATH в `bin/claude-control-session`.
- Linux: создай `~/.config/claude-control/env` с строкой `PATH=...` или `CLAUDE_BIN=/full/path/to/claude` (если решишь править entrypoint под `CLAUDE_BIN`).

## Mac уходит в сон - все умирает

launchd не запускает пользовательских агентов во время сна Mac'а, и удаленные сессии вместе с ним. Если ты хочешь, чтобы машина была доступна с телефона круглосуточно, нужно держать ее неспящей самостоятельно - типовое решение - отдельный launchd-агент, гоняющий `caffeinate -i`. Этот репо умышленно его не ставит: способ держать Mac бодрым каждый выбирает сам.

## Linux: сервис умер после logout

Без включенного lingering systemd-user-manager останавливается, когда последняя login-сессия пользователя закрывается, и все user-сервисы (включая claude-control) останавливаются вместе с ним. После reboot они тоже не поднимутся, пока кто-то не залогинится.

**Что делать:** включить lingering один раз - `loginctl enable-linger $USER`. После этого user-manager запускается при загрузке системы и держится всегда. `install.sh` проверяет состояние и пишет предупреждение, если lingering выключен.

Команда может потребовать sudo - зависит от того, как настроен polkit в дистрибутиве. На большинстве Ubuntu 22.04+ работает без sudo интерактивно.

## Linux: `systemd-analyze --user verify` не находит `default.target`

Очень минимальные среды (некоторые контейнеры) могут не иметь полноценного user-target'а. Это не критично - сервис все равно запускается, `verify` ругается на отсутствие зависимости. Если хочется идеальной чистоты: убери `WantedBy=default.target` и `PartOf=default.target` из шаблонов в `systemd/`, переустанови.

Если же `systemctl --user` вообще не работает (`Failed to connect to bus`), значит у тебя нет user-инстанса systemd - так бывает в WSL без `systemd-genie` и в контейнерах. `install.sh` сам ловит это и падает с явным сообщением.
