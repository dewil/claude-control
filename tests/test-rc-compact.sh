#!/usr/bin/env bash
# Tests for `claude-rc compact <project> <uuid> [--up]`.
#
# Сжатие контекста - это полноценный запрос к модели по ВСЕЙ переписке: на
# большой сессии минуты и заметные деньги. Поэтому:
#   - оно уходит в свой транзиентный юнит, а не выполняется в лоб: бот вызывает
#     claude-rc синхронно, и минутная блокировка заморозила бы весь опрос;
#   - живую сессию сжимать нельзя - транскрипт держит ее процесс, и второй
#     claude --resume на тот же файл дает то самое задвоение, на котором мы уже
#     обжигались;
#   - stdin закрывается явно: без </dev/null процесс ждет ввода до EOF, которого
#     в юните не будет (те же грабли, что у codex).
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
export RUN_ARGS="$TMP/run-args" LIVE_UNITS="$TMP/live-units"
: > "$LIVE_UNITS"; : > "$RUN_ARGS"
cat > "$TMP/bin/systemd-run" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$RUN_ARGS"
exit 0
MOCK
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in
  *is-active*) want="${!#}"
               for u in $(cat "$LIVE_UNITS" 2>/dev/null); do
                 [ "$u" = "$want" ] && exit 0
               done; exit 3 ;;
  *list-units*) for u in $(cat "$LIVE_UNITS" 2>/dev/null); do
                  echo "$u.service loaded active running"
                done; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/systemd-run" "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

# 1. Сжатие уходит в ОТДЕЛЬНЫЙ юнит, не в юнит сессии: иначе гашение сжатия
#    убило бы сессию, а список поднятых показал бы сжатие как работающую сессию.
"$RC" compact proj "$SID" >/dev/null 2>&1
unit="$(grep -A1 -- '^--unit$' "$RUN_ARGS" | tail -1)"
if [[ -n "$unit" && "$unit" != "ccsession-${SID//-/}" ]]; then ok
else fail "юнит сжатия '$unit' совпал с юнитом сессии или пуст"; fi

# 2. В команде - resume нужной сессии и сам /compact.
if grep -q -- "--resume" "$RUN_ARGS" && grep -q "$SID" "$RUN_ARGS"; then ok
else fail "в argv нет resume нужной сессии"; fi
if grep -q -- "/compact" "$RUN_ARGS"; then ok
else fail "в argv нет /compact"; fi

# 3. stdin закрыт явно - без этого процесс ждет ввода, которого не будет.
if grep -q '/dev/null' "$RUN_ARGS"; then ok
else fail "stdin не закрыт: процесс повиснет в ожидании ввода"; fi

# 4. Живую сессию не сжимаем: ее транскрипт держит живой процесс.
: > "$RUN_ARGS"; echo "ccsession-${SID//-/}" > "$LIVE_UNITS"
out="$("$RC" compact proj "$SID" 2>&1)"; rc=$?
if [[ "$rc" != 0 && ! -s "$RUN_ARGS" ]]; then ok
else fail "сжатие поднятой сессии не отбито (rc=$rc)"; fi
if [[ "$out" == *"поднят"* || "$out" == *"up"* ]]; then ok
else fail "причина отказа не названа: '$out'"; fi
: > "$LIVE_UNITS"

# 5. --up дописывает подъем ПОСЛЕ сжатия: сначала сжали, потом подняли готовой.
: > "$RUN_ARGS"
"$RC" compact proj "$SID" --up >/dev/null 2>&1
if grep -q "claude-rc" "$RUN_ARGS" && grep -q "up" "$RUN_ARGS"; then ok
else fail "--up не дописал подъем после сжатия"; fi
# Без флага подъема быть не должно - иначе сжатие молча поднимает сессию.
: > "$RUN_ARGS"
"$RC" compact proj "$SID" >/dev/null 2>&1
if ! grep -q "claude-rc.*up" "$RUN_ARGS"; then ok
else fail "сжатие без --up все равно поднимает сессию"; fi

# 6. Повторный запуск, пока сжатие идет, не плодит второй прогон по тому же
#    транскрипту.
: > "$RUN_ARGS"; echo "cccompact-${SID//-/}" > "$LIVE_UNITS"
rc=0; "$RC" compact proj "$SID" >/dev/null 2>&1 || rc=$?
if [[ "$rc" != 0 && ! -s "$RUN_ARGS" ]]; then ok
else fail "второе сжатие той же сессии не отбито"; fi
: > "$LIVE_UNITS"

# 7. Кривой uuid и чужой проект отвергаются до любых действий.
: > "$RUN_ARGS"
if ! "$RC" compact proj 'nonsense' >/dev/null 2>&1 && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "compact принял кривой uuid"; fi
if ! "$RC" compact nosuch "$SID" >/dev/null 2>&1 && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "compact принял неизвестный проект"; fi

# 8. Несуществующая сессия - отказ, а не пустой прогон.
: > "$RUN_ARGS"
if ! "$RC" compact proj "dddddddd-4444-4444-8444-444444444444" >/dev/null 2>&1 \
   && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "compact принял несуществующую сессию"; fi

echo "test-rc-compact: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
