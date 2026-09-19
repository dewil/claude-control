#!/usr/bin/env bash
# Общий резолв прокси-переменных для транзиентных юнитов: подключается через "."
# и из claude-rc (юниты сессий), и из claude-agent-reconciler (юниты агентов).
# Один файл на оба места намеренно: две копии разъехались бы молча, а
# расхождение проявилось бы новым классом смерти в том из них, что отстал
# (спека docs/dev/2026-09-19-spec-agent-proxy.md).

# Прокси-переменные для юнита сессии.
#
# У процесса сессии их не было вовсе: через каскад трафик шел только потому, что
# Claude Code подставляет прокси из своего settings.json. Любое соединение мимо
# этой подстановки уходит прямым адресом машины, а Anthropic отвечает на него
# 403 - проверено: через прокси тот же эндпоинт дает 401 ("нет токена"), напрямую
# 403. В логах это выглядело как "10 consecutive auth failures with a
# valid-looking token — server-side auth unrecoverable, exiting", после чего мост
# сносился и сессия умирала, хотя dwl ее не трогал (пять случаев 26-28.08).
#
# Источник правды - settings.json: там прокси уже задан для CLI, и второе место
# со своим значением разъехалось бы молча. Окружение - фолбэк для случая, когда
# в настройках его нет.
proxy_setenv_args() {
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" v
  local -a out=()
  local k
  for k in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    v="$(python3 - "$cfg" "$k" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        print((json.load(fh).get("env") or {}).get(sys.argv[2], ""))
except Exception:
    print("")
PY
)"
    [[ -z "$v" ]] && v="$(printenv "$k" 2>/dev/null || true)"
    [[ -n "$v" ]] && out+=(--setenv "$k=$v")
  done
  printf '%s\n' "${out[@]}"
}
# Считаем один раз на прогон: значения не меняются по ходу, а лишний питон на
# каждый подъем стоил бы заметной доли времени старта.
