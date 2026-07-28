#!/usr/bin/env bash
# Offline-тесты TG-бота (auth/валидация/эскейпинг) - см. selftest в самом боте.
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# HOME переопределен: selftest дергает только чистые функции и явно
# подменяет пути состояния (CLAUDE_AGENT_TG_CARDS_COUNT и т.п.) на
# временные, но LOG_FILE/OFFSET_FILE в bin/claude-agent-tgbot резолвятся
# от $HOME - страхуемся на случай появления в selftest вызовов log().
export HOME="$TMP/home"
mkdir -p "$HOME"

"$HERE/../bin/claude-agent-tgbot" selftest
exit $?
