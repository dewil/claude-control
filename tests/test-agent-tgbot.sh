#!/usr/bin/env bash
# Offline-тесты TG-бота (auth/валидация/эскейпинг) - см. selftest в самом боте.
exec "$(cd "$(dirname "$0")" && pwd)/../bin/claude-agent-tgbot" selftest
