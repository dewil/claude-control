#!/usr/bin/env bash
# Tests for `claude-rc up|down|live` (V3.0 §3, §5): подъем сессии транзиентным
# systemd-юнитом вместо tmux, гашение и список поднятых.
#
# Две вещи, без которых подъем не работает вообще (V3.0 §1) и которые поэтому
# проверяются в argv, а не "на глаз":
#   - pty: claude запускается под `script -qec`, иначе процесс отрабатывает промпт
#     как одноразовый запуск и к мосту не подключается;
#   - промпт: `--resume` без него выходит с "No deferred tool marker" ВСЕГДА.
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

PROJ="$TMP/proj"; mkdir -p "$PROJ"
printf 'proj: %s\n' "$PROJ" > "$CLAUDE_RC_PROJECTS_FILE"
SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
TDIR="$CLAUDE_CONFIG_DIR/projects/$SLUG"; mkdir -p "$TDIR"

SID="aaaaaaaa-1111-4111-8111-111111111111"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"первая"}]},"cwd":"%s"}\n' "$PROJ"
  printf '{"type":"custom-title","customTitle":"сессия 1","sessionId":"%s"}\n' "$SID"
} > "$TDIR/$SID.jsonl"

mkdir -p "$TMP/bin"
export RUN_ARGS="$TMP/run-args" STOP_ARGS="$TMP/stop-args" LIVE_UNITS="$TMP/live-units"
: > "$LIVE_UNITS"

cat > "$TMP/bin/systemd-run" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RUN_ARGS"
exit 0
MOCK
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in
  *is-active*) for u in $(cat "$LIVE_UNITS" 2>/dev/null); do
                 case "$*" in *"$u"*) exit 0 ;; esac; done; exit 3 ;;
  *stop*)      printf '%s\n' "$@" >> "$STOP_ARGS"; exit 0 ;;
  *list-units*) # формат, из которого `live` берет поднятые юниты
                for u in $(cat "$LIVE_UNITS" 2>/dev/null); do echo "$u.service"; done; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/systemd-run" "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

argv_has() { grep -qxF -- "$1" "$RUN_ARGS"; }
argv_line_with() { grep -F "$1" "$RUN_ARGS" | head -1; }

# --- up ---
: > "$RUN_ARGS"
"$RC" up proj "$SID" >"$TMP/out" 2>"$TMP/err"
rc=$?

# 1. Успешный вызов.
if [[ "$rc" == 0 ]]; then ok; else fail "up вернул $rc ($(head -c150 "$TMP/err"))"; fi

# 2. Транзиентный юнит именован по uuid, не по проекту.
if argv_has "ccsession-aaaaaaaa"; then ok
else fail "нет --unit ccsession-aaaaaaaa: $(tr '\n' ' ' < "$RUN_ARGS" | head -c200)"; fi

# 3. Type=exec и гашение всей группы.
if argv_has "--service-type=exec" && argv_has "--property=KillMode=control-group"; then ok
else fail "нет --service-type=exec / KillMode"; fi

# 4. Запуск идет под pty (script -qec), иначе сессия не доживет до моста.
if argv_has "script"; then ok; else fail "запуск не под script (нет pty)"; fi

# 5. В команде claude: resume нужного uuid и имя сессии, а не имя проекта.
cmd_line="$(argv_line_with 'remote-control')"
if [[ "$cmd_line" == *"--resume $SID"* ]]; then ok; else fail "нет --resume $SID: $cmd_line"; fi
if [[ "$cmd_line" == *"сессия 1"* && "$cmd_line" != *"--name proj"* ]]; then ok
else fail "имя сессии не подставлено: $cmd_line"; fi

# 6. Промпт по умолчанию есть (без него CLI выходит сразу). Пробелы внутри
#    промпта экранированы %q - это намеренно (строка уходит в shell-парсинг
#    `script -qec`), поэтому сверка идет по словам, а не по фразе целиком.
if [[ "$cmd_line" == *связи* && "$cmd_line" == *задачу* ]]; then ok
else fail "нет дефолтного промпта: $cmd_line"; fi

# 7. Свой промпт подставляется вместо дефолтного.
: > "$RUN_ARGS"
"$RC" up proj "$SID" --prompt "продолжаем разбор" >/dev/null 2>&1
cmd_line="$(argv_line_with 'remote-control')"
if [[ "$cmd_line" == *продолжаем* && "$cmd_line" == *разбор* && "$cmd_line" != *связи* ]]; then ok
else fail "свой промпт не подставлен: $cmd_line"; fi

# 8. Идемпотентность: юнит уже активен -> второго экземпляра не поднимаем.
echo "ccsession-aaaaaaaa" > "$LIVE_UNITS"
: > "$RUN_ARGS"
"$RC" up proj "$SID" >"$TMP/out2" 2>&1
if [[ ! -s "$RUN_ARGS" ]]; then ok; else fail "повторный up поднял второй экземпляр"; fi
: > "$LIVE_UNITS"

# 9. Неизвестный проект - отказ до любого запуска.
: > "$RUN_ARGS"
if ! "$RC" up nosuch "$SID" >/dev/null 2>&1 && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "неизвестный проект не отвергнут"; fi

# 10. Кривой uuid - отказ до запуска (в callback бота прилетает произвольная строка).
: > "$RUN_ARGS"
if ! "$RC" up proj 'aaa; rm -rf /' >/dev/null 2>&1 && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "кривой uuid не отвергнут"; fi

# 12. Сессия с чужим (несуществующим) cwd: поднимается в каталоге проекта, а не
#     отвергается. Так выглядит вся история, начатая до переезда на другую машину -
#     отказ означал бы "половина сессий не поднимается с телефона".
SID_MAC="dddddddd-4444-4444-8444-444444444444"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"с мака"}]},"cwd":"/Users/dwl/Yandex.Disk/obs/2024-12 проект 1"}\n'
  printf '{"type":"custom-title","customTitle":"LLM start","sessionId":"%s"}\n' "$SID_MAC"
} > "$TDIR/$SID_MAC.jsonl"
: > "$RUN_ARGS"
"$RC" up proj "$SID_MAC" >/dev/null 2>&1
if grep -qF -- "--working-directory=$PROJ" "$RUN_ARGS"; then ok
else fail "сессия с чужим cwd не поднялась в каталоге проекта: $(tr '\n' ' ' < "$RUN_ARGS" | head -c200)"; fi
# и имя у нее все равно свое, а не имя проекта
cmd_line="$(argv_line_with 'remote-control')"
if [[ "$cmd_line" == *"LLM"* ]]; then ok; else fail "имя сессии с чужим cwd потеряно: $cmd_line"; fi

# --- down ---
: > "$STOP_ARGS"; echo "ccsession-aaaaaaaa" > "$LIVE_UNITS"
"$RC" down "$SID" >/dev/null 2>&1
if grep -q 'ccsession-aaaaaaaa' "$STOP_ARGS" 2>/dev/null; then ok
else fail "down не остановил юнит: $(cat "$STOP_ARGS" 2>/dev/null)"; fi

# 11. down на кривой uuid ничего не гасит.
: > "$STOP_ARGS"
if ! "$RC" down 'nonsense' >/dev/null 2>&1 && [[ ! -s "$STOP_ARGS" ]]; then ok
else fail "down принял кривой uuid"; fi

# --- live ---
echo "ccsession-aaaaaaaa" > "$LIVE_UNITS"
"$RC" live > "$TMP/live" 2>/dev/null
if grep -q 'ccsession-aaaaaaaa' "$TMP/live"; then ok
else fail "live не показал поднятый юнит: $(cat "$TMP/live")"; fi

echo "test-rc-up-down: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
