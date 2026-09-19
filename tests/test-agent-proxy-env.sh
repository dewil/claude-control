#!/usr/bin/env bash
# Tests for спека docs/dev/2026-09-19-spec-agent-proxy.md (тег INV-RECON-27):
# прокси-триада (HTTP_PROXY/HTTPS_PROXY/NO_PROXY) переезжает из `claude-rc` в
# общий `bin/_proxy_env.sh` и подключается оттуда обоими файлами - `claude-rc`
# и `claude-agent-reconciler` (`acquire_agent`).
#
# Реализации еще нет: файла `bin/_proxy_env.sh` не существует, поэтому все
# проверки ниже КРАСНЫЕ. Основная часть (критерии 2-5) идет через прямой вызов
# `proxy_setenv_args` из общего хелпера - функция вызывается напрямую, а не
# через claude-rc или reconciler целиком. Критерий 1 и факт подключения в
# acquire_agent проверяются грепом по файлам - это проверка проводки (что файл
# существует и подключен через `.`), а не поведения функции.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
PROXY_ENV_SH="$ROOT/bin/_proxy_env.sh"
RC_BIN="$ROOT/bin/claude-rc"
RECONCILER_BIN="$ROOT/bin/claude-agent-reconciler"
MANIFEST="$ROOT/scripts.manifest"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

# --- критерий 1: функция переехала в общий файл, у claude-rc своей копии нет ---
# (проводка, не поведение: смотрим на текст файлов, а не на результат вызова)

if [[ -f "$PROXY_ENV_SH" ]]; then ok
else fail "bin/_proxy_env.sh не существует"; fi

if [[ -f "$PROXY_ENV_SH" ]] && grep -q 'proxy_setenv_args *()' "$PROXY_ENV_SH"; then ok
else fail "bin/_proxy_env.sh не определяет proxy_setenv_args"; fi

if ! grep -q 'proxy_setenv_args *()' "$RC_BIN"; then ok
else fail "claude-rc все еще содержит свою копию proxy_setenv_args"; fi

if grep -q '_proxy_env\.sh' "$RC_BIN"; then ok
else fail "claude-rc не подключает bin/_proxy_env.sh"; fi

if grep -q '_proxy_env\.sh' "$RECONCILER_BIN"; then ok
else fail "claude-agent-reconciler не подключает bin/_proxy_env.sh"; fi

# Факт подключения именно в acquire_agent: proxy-переменные должны где-то
# использоваться в reconciler (иначе подключение файла - мертвый импорт, а не
# реальная проводка в run_args агента).
if grep -q 'PROXY_SETENV\|proxy_setenv_args' "$RECONCILER_BIN"; then ok
else fail "claude-agent-reconciler не использует proxy_setenv_args/PROXY_SETENV нигде в файле"; fi

# --- поведение общей функции: подключаем хелпер напрямую, зовем proxy_setenv_args ---

if [[ -f "$PROXY_ENV_SH" ]]; then
  # shellcheck disable=SC1090
  . "$PROXY_ENV_SH"
fi

# Пишет settings.json с заданным env-объектом. Значение "__ABSENT__" означает
# "ключа в settings вовсе нет" (не то же самое, что пустая строка).
write_settings() { # <dir> <HTTP_PROXY> <HTTPS_PROXY> <NO_PROXY>
  mkdir -p "$1"
  python3 - "$1/settings.json" "$2" "$3" "$4" <<'PY'
import json, sys
path, http_v, https_v, no_v = sys.argv[1:5]
env = {}
for k, v in (("HTTP_PROXY", http_v), ("HTTPS_PROXY", https_v), ("NO_PROXY", no_v)):
    if v != "__ABSENT__":
        env[k] = v
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"env": env}, fh)
PY
}

PROXY_OUT=()
run_proxy_args() { # <config_dir>
  local -a a=()
  mapfile -t a < <(CLAUDE_CONFIG_DIR="$1" proxy_setenv_args 2>/dev/null)
  PROXY_OUT=("${a[@]}")
}

# Точное совпадение пары --setenv KEY=VALUE в выводе (не подстрока: HTTP_PROXY
# и HTTPS_PROXY иначе легко перепутать).
has_setenv() { # <KEY=VALUE>
  local want="$1" i
  for ((i = 0; i < ${#PROXY_OUT[@]}; i++)); do
    if [[ "${PROXY_OUT[$i]}" == "--setenv" && "${PROXY_OUT[$((i+1))]:-}" == "$want" ]]; then
      return 0
    fi
  done
  return 1
}

# Отсутствие --setenv для ключа вовсе (независимо от значения).
no_setenv_for() { # <KEY>
  local key="$1" i
  for ((i = 0; i < ${#PROXY_OUT[@]}; i++)); do
    if [[ "${PROXY_OUT[$i]}" == "--setenv" && "${PROXY_OUT[$((i+1))]:-}" == "$key="* ]]; then
      return 1
    fi
  done
  return 0
}

# --- критерий 2: заданные в settings.json значения доезжают как --setenv ---

CFG2="$TMP/cfg2"
write_settings "$CFG2" \
  "http://proxy-from-settings-http:7890" \
  "http://proxy-from-settings-https:7890" \
  "proxy-from-settings-no,localhost"
unset HTTP_PROXY HTTPS_PROXY NO_PROXY
run_proxy_args "$CFG2"

if has_setenv "HTTP_PROXY=http://proxy-from-settings-http:7890"; then ok
else fail "HTTP_PROXY из settings.json не дошел до --setenv: ${PROXY_OUT[*]:-<пусто>}"; fi

if has_setenv "HTTPS_PROXY=http://proxy-from-settings-https:7890"; then ok
else fail "HTTPS_PROXY из settings.json не дошел до --setenv: ${PROXY_OUT[*]:-<пусто>}"; fi

if has_setenv "NO_PROXY=proxy-from-settings-no,localhost"; then ok
else fail "NO_PROXY из settings.json не дошел до --setenv: ${PROXY_OUT[*]:-<пусто>}"; fi

# --- критерий 3: пустое или отсутствующее значение --setenv не порождает ---

CFG3A="$TMP/cfg3a"
write_settings "$CFG3A" "" "" ""
unset HTTP_PROXY HTTPS_PROXY NO_PROXY
run_proxy_args "$CFG3A"
if no_setenv_for "HTTP_PROXY" && no_setenv_for "HTTPS_PROXY" && no_setenv_for "NO_PROXY"; then ok
else fail "пустая строка в settings.json все равно породила --setenv: ${PROXY_OUT[*]:-<пусто>}"; fi

CFG3B="$TMP/cfg3b"
write_settings "$CFG3B" "__ABSENT__" "__ABSENT__" "__ABSENT__"
unset HTTP_PROXY HTTPS_PROXY NO_PROXY
run_proxy_args "$CFG3B"
if no_setenv_for "HTTP_PROXY" && no_setenv_for "HTTPS_PROXY" && no_setenv_for "NO_PROXY"; then ok
else fail "полностью отсутствующий ключ в settings.json все равно породил --setenv: ${PROXY_OUT[*]:-<пусто>}"; fi

# --- критерий 4: settings.json приоритетнее одноименной переменной окружения ---

CFG4="$TMP/cfg4"
write_settings "$CFG4" "http://proxy-from-settings:7890" "__ABSENT__" "__ABSENT__"
export HTTP_PROXY="http://proxy-from-env:9999"
unset HTTPS_PROXY NO_PROXY 2>/dev/null || true
run_proxy_args "$CFG4"
if has_setenv "HTTP_PROXY=http://proxy-from-settings:7890"; then ok
else fail "значение из settings.json не победило: ${PROXY_OUT[*]:-<пусто>}"; fi
if ! has_setenv "HTTP_PROXY=http://proxy-from-env:9999"; then ok
else fail "в --setenv просочилось значение переменной окружения вместо settings.json"; fi
unset HTTP_PROXY

# Обратная сторона того же приоритета: при отсутствии значения в settings.json
# используется переменная окружения (иначе тест выше проверял бы факт наличия,
# а не именно приоритет источника).
CFG4B="$TMP/cfg4b"
write_settings "$CFG4B" "__ABSENT__" "" "__ABSENT__"
export HTTPS_PROXY="http://proxy-from-env-https:1111"
run_proxy_args "$CFG4B"
if has_setenv "HTTPS_PROXY=http://proxy-from-env-https:1111"; then ok
else fail "фолбэк на переменную окружения не сработал при пустом значении в settings.json: ${PROXY_OUT[*]:-<пусто>}"; fi
unset HTTPS_PROXY

# --- критерий 5: значение с пробелами и спецсимволами доезжает неискаженным ---

CFG5="$TMP/cfg5"
ODD_VALUE="localhost, 127.0.0.1, host with spaces & 'quotes' \$dollar"
write_settings "$CFG5" "__ABSENT__" "__ABSENT__" "$ODD_VALUE"
unset HTTP_PROXY HTTPS_PROXY NO_PROXY
run_proxy_args "$CFG5"
if has_setenv "NO_PROXY=$ODD_VALUE"; then ok
else fail "значение с пробелами/спецсимволами исказилось: ${PROXY_OUT[*]:-<пусто>}"; fi

# --- критерий 6: install.sh раскатывает bin/_proxy_env.sh (строка в манифесте) ---

if grep -qxF '_proxy_env.sh' "$MANIFEST"; then ok
else fail "scripts.manifest не содержит строки _proxy_env.sh"; fi

echo "test-agent-proxy-env: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
