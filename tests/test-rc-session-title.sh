#!/usr/bin/env bash
# Tests for bin/claude-rc: имя, с которым поднимается remote-control, НЕ должно
# затирать пользовательское название сессии.
#
# Механизм, ради которого написан тест (воспроизведен на живой сессии 2026-08-01):
# при подключении к bridge CLI пишет в транскрипт `custom-title` = значение,
# переданное в `--name`, и только потом `agent-name` + `bridge-session`. Пока
# claude-rc подставлял туда имя проекта из реестра, resume чужой сессии молча
# переименовывал ее в имя проекта ('сессия 1' -> 'проект 1'), и человек терял
# свою разметку истории. Поэтому при resume в --name уходит текущее название
# сессии: CLI перезапишет его тем же значением, то есть вхолостую.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/../bin/claude-rc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

export CLAUDE_CONFIG_DIR="$TMP/claude"
export CLAUDE_RC_PROJECTS_FILE="$TMP/projects.yaml"
export CLAUDE_RC_LOG_DIR="$TMP/logs"
mkdir -p "$CLAUDE_RC_LOG_DIR"

# --- фикстура: проект + транскрипты ---
PROJ="$TMP/proj"
mkdir -p "$PROJ"
printf 'proj: %s\n' "$PROJ" > "$CLAUDE_RC_PROJECTS_FILE"

SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
TDIR="$CLAUDE_CONFIG_DIR/projects/$SLUG"
mkdir -p "$TDIR"

# Транскрипт с пользовательским названием. Порядок полей и отсутствие пробелов -
# как пишет сам CLI; последняя запись custom-title выигрывает, поэтому кладем две.
SID_TITLED="11111111-1111-4111-8111-111111111111"
{
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"первая реплика"}]},"cwd":"'"$PROJ"'"}'
  printf '%s\n' '{"type":"custom-title","sessionId":"'"$SID_TITLED"'","customTitle":"старое имя"}'
  printf '%s\n' '{"type":"custom-title","sessionId":"'"$SID_TITLED"'","customTitle":"сессия 1"}'
} > "$TDIR/$SID_TITLED.jsonl"

# Транскрипт без названия вовсе - fallback на имя проекта.
SID_PLAIN="22222222-2222-4222-8222-222222222222"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"без названия"}]},"cwd":"'"$PROJ"'"}' \
  > "$TDIR/$SID_PLAIN.jsonl"
# Названная сессия должна быть новее, чтобы быть пунктом [1] в меню.
touch -d '2020-01-01 10:00' "$TDIR/$SID_PLAIN.jsonl"
touch -d '2020-01-02 10:00' "$TDIR/$SID_TITLED.jsonl"

# --- мок tmux: сохраняет argv запуска, ничего не запускает ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  -V)          echo "tmux 3.4"; exit 0 ;;
  has-session) exit 1 ;;                      # живой сессии нет
  new-session) printf '%s\n' "$@" > "$TMUX_ARGS_FILE"; exit 0 ;;
  kill-session|kill-server) exit 0 ;;
  list-sessions|ls) exit 0 ;;
  *)           exit 0 ;;
esac
MOCK
chmod +x "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH"
export TMUX_ARGS_FILE="$TMP/tmux-args"

ccr_name_of_last_launch() { # -> значение CCR_NAME из argv мока
  sed -n 's/^CCR_NAME=//p' "$TMUX_ARGS_FILE" | head -1
}

run_rc() { # <args...>; гасит вывод, тест смотрит на argv мока
  : > "$TMUX_ARGS_FILE"
  "$RC" "$@" >"$TMP/out" 2>"$TMP/err"
}

# 1. resume названной сессии: в --name уходит НАЗВАНИЕ, а не имя проекта.
run_rc proj --resume 1
got="$(ccr_name_of_last_launch)"
if [[ "$got" == "сессия 1" ]]; then ok
else fail "resume названной сессии: CCR_NAME='$got', ожидалось 'сессия 1' ($(head -c120 "$TMP/err"))"; fi

# 2. resume сессии без названия: fallback на имя проекта.
run_rc proj --resume 2
got="$(ccr_name_of_last_launch)"
if [[ "$got" == "proj" ]]; then ok
else fail "resume безымянной сессии: CCR_NAME='$got', ожидалось 'proj'"; fi

# 3. свежий старт: имя проекта, как и было (сессии еще нет, затирать нечего).
run_rc proj
got="$(ccr_name_of_last_launch)"
if [[ "$got" == "proj" ]]; then ok
else fail "свежий старт: CCR_NAME='$got', ожидалось 'proj'"; fi

# 4. --continue на названную сессию: то же правило, что и у явного пункта.
run_rc proj --continue
got="$(ccr_name_of_last_launch)"
if [[ "$got" == "сессия 1" ]]; then ok
else fail "--continue названной сессии: CCR_NAME='$got', ожидалось 'сессия 1'"; fi

# 5. Название с пробелами и кавычками не должно расщепляться на аргументы.
SID_ODD="33333333-3333-4333-8333-333333333333"
{
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"третья"}]},"cwd":"'"$PROJ"'"}'
  printf '%s\n' '{"type":"custom-title","sessionId":"'"$SID_ODD"'","customTitle":"сессия 4 \"прод\""}'
} > "$TDIR/$SID_ODD.jsonl"
touch -d '2020-01-03 10:00' "$TDIR/$SID_ODD.jsonl"
run_rc proj --resume 1
got="$(ccr_name_of_last_launch)"
if [[ "$got" == 'сессия 4 "прод"' ]]; then ok
else fail "название с пробелами/кавычками: CCR_NAME='$got'"; fi

# 6. Запись в pretty-формате (пробелы после двоеточий, другой порядок полей) тоже
# читается: так выглядят записи, дописанные не самим CLI (ручное восстановление
# названия, миграция) - на них правило обязано работать, иначе сессия считается
# безымянной и получает имя проекта, то есть ровно тот баг, что чинится.
SID_PRETTY="44444444-4444-4444-8444-444444444444"
{
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"четвертая"}]},"cwd":"'"$PROJ"'"}'
  printf '%s\n' '{"type": "custom-title", "customTitle": "имя с пробелами в записи", "sessionId": "'"$SID_PRETTY"'"}'
} > "$TDIR/$SID_PRETTY.jsonl"
touch -d '2020-01-04 10:00' "$TDIR/$SID_PRETTY.jsonl"
run_rc proj --resume 1
got="$(ccr_name_of_last_launch)"
if [[ "$got" == "имя с пробелами в записи" ]]; then ok
else fail "pretty-формат записи custom-title: CCR_NAME='$got'"; fi

echo "test-rc-session-title: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
