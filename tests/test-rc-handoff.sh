#!/usr/bin/env bash
# Tests for `claude-rc handoff <project> <uuid>` - передача работы в свежую сессию.
#
# Зачем это отдельно от сжатия. Сжатие оставляет сводку "про все понемногу" и
# продолжает ту же сессию: на замере 745 000 токенов ужались до 95 400 (74% -> 10%
# окна). Ранбук в чистой сессии дает втрое меньше - пустая сессия небольшого
# проекта весит ~24 000, плюс сам ранбук. Плюс артефакт, который можно прочитать.
#
# Порядок намеренно такой: сперва поднимается НОВАЯ сессия с ранбуком, старая
# остается опущенной - "заморожена", а не удалена. Ничего необратимого команда не
# делает: удалить старую - отдельный тап, и тот в корзину.
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
export CLAUDE_RC_STATE_DIR="$TMP/state"
export CLAUDE_RC_HANDOFF_DIR="$TMP/handoffs"
mkdir -p "$CLAUDE_RC_LOG_DIR"

PROJ="$TMP/proj"; mkdir -p "$PROJ"
printf 'proj: %s\n' "$PROJ" > "$CLAUDE_RC_PROJECTS_FILE"
SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
TDIR="$CLAUDE_CONFIG_DIR/projects/$SLUG"; mkdir -p "$TDIR"

SID="aaaaaaaa-1111-4111-8111-111111111111"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"первая"}]},"cwd":"%s"}\n' "$PROJ"
  printf '{"type":"custom-title","customTitle":"ShopHack","sessionId":"%s"}\n' "$SID"
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

# 1. Работа уходит в СВОЙ юнит: генерация ранбука - полный запрос по всей
#    переписке, минуты. Бот вызывает CLI синхронно и не имеет права столько ждать.
"$RC" handoff proj "$SID" >/dev/null 2>&1
unit="$(grep -A1 -- '^--unit$' "$RUN_ARGS" | tail -1)"
if [[ "$unit" == cchandoff-* ]]; then ok
else fail "юнит передачи назван '$unit'"; fi
if [[ "$unit" != "ccsession-${SID//-/}" && "$unit" != "cccompact-${SID//-/}" ]]; then ok
else fail "юнит передачи совпал с чужим"; fi

# 2. Внутри - resume исходной сессии: ранбук пишется по ЕЕ переписке.
if grep -q -- "--resume" "$RUN_ARGS" && grep -q "$SID" "$RUN_ARGS"; then ok
else fail "в argv нет resume исходной сессии"; fi
if grep -q '/dev/null' "$RUN_ARGS"; then ok
else fail "stdin не закрыт - процесс повиснет в ожидании ввода"; fi

# 3. Живую сессию не трогаем: ее транскрипт держит живой процесс.
: > "$RUN_ARGS"; echo "ccsession-${SID//-/}" > "$LIVE_UNITS"
out="$("$RC" handoff proj "$SID" 2>&1)"; rc=$?
if [[ "$rc" != 0 && ! -s "$RUN_ARGS" ]]; then ok
else fail "передача с поднятой сессии не отбита (rc=$rc)"; fi
: > "$LIVE_UNITS"

# 4. Повторный запуск поверх идущего не плодит второй прогон.
: > "$RUN_ARGS"; echo "cchandoff-${SID//-/}" > "$LIVE_UNITS"
rc=0; "$RC" handoff proj "$SID" >/dev/null 2>&1 || rc=$?
if [[ "$rc" != 0 && ! -s "$RUN_ARGS" ]]; then ok
else fail "вторая передача той же сессии не отбита"; fi
: > "$LIVE_UNITS"

# 5. Кривой ввод отвергается до любых действий.
: > "$RUN_ARGS"
if ! "$RC" handoff proj 'nonsense' >/dev/null 2>&1 && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "handoff принял кривой uuid"; fi
if ! "$RC" handoff nosuch "$SID" >/dev/null 2>&1 && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "handoff принял неизвестный проект"; fi

# --- имя новой сессии ---
# Имя наследуется от исходной с номером на конце: в списке сразу видно, что это
# продолжение, а не отдельная работа. Второй проход дает следующий номер, а не
# повторяет предыдущий.
n1="$("$RC" handoff-name proj "$SID" 2>/dev/null)"
if [[ "$n1" == "ShopHack 2" ]]; then ok
else fail "имя продолжения '$n1', ожидалось 'ShopHack 2'"; fi

SID2="bbbbbbbb-2222-4222-8222-222222222222"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"вторая"}]},"cwd":"%s"}\n' "$PROJ"
  printf '{"type":"custom-title","customTitle":"ShopHack 2","sessionId":"%s"}\n' "$SID2"
} > "$TDIR/$SID2.jsonl"
n2="$("$RC" handoff-name proj "$SID2" 2>/dev/null)"
if [[ "$n2" == "ShopHack 3" ]]; then ok
else fail "продолжение продолжения '$n2', ожидалось 'ShopHack 3'"; fi

# Занятое имя не выдается повторно: иначе в списке две одинаковые строки.
SID3="cccccccc-3333-4333-8333-333333333333"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"третья"}]},"cwd":"%s"}\n' "$PROJ"
  printf '{"type":"custom-title","customTitle":"ShopHack 3","sessionId":"%s"}\n' "$SID3"
} > "$TDIR/$SID3.jsonl"
n3="$("$RC" handoff-name proj "$SID" 2>/dev/null)"
if [[ "$n3" == "ShopHack 4" ]]; then ok
else fail "занятое имя выдано повторно: '$n3'"; fi

# Безымянная сессия: имя берем от проекта, чтобы продолжение не осталось без
# опознавательных знаков.
SID4="dddddddd-4444-4444-8444-444444444444"
printf '{"type":"user","message":{"content":[{"type":"text","text":"без имени"}]},"cwd":"%s"}\n' "$PROJ" \
  > "$TDIR/$SID4.jsonl"
n4="$("$RC" handoff-name proj "$SID4" 2>/dev/null)"
if [[ "$n4" == proj* ]]; then ok
else fail "безымянная сессия дала имя '$n4'"; fi

# --- new с готовым именем и ранбуком ---
# Передача поднимает продолжение через `new`, поэтому ему нужны два флага:
# готовое имя (иначе получится "<проект> N" вместо "ShopHack 2") и текст
# ранбука первой репликой. Текст ВСТАВЛЯЕТСЯ, а не читается по пути: файл лежит
# вне каталога проекта, и сессии пришлось бы спрашивать разрешение на чтение.
: > "$RUN_ARGS"
printf '# Ранбук\n\nСделано: раз, два.\nДальше: три.\n' > "$TMP/runbook.md"
"$RC" new proj --name "ShopHack 2" --prompt-file "$TMP/runbook.md" >/dev/null 2>&1
line="$(grep -F 'remote-control' "$RUN_ARGS" | head -1)"
if [[ "$line" == *'--name ShopHack\ 2'* ]]; then ok
else fail "new не взял готовое имя: $line"; fi
if [[ "$line" == *Ранбук* && "$line" == *Дальше* ]]; then ok
else fail "ранбук не ушел первой репликой: $line"; fi
# Без флагов поведение прежнее - имя по проекту, промпта нет.
: > "$RUN_ARGS"
"$RC" new proj >/dev/null 2>&1
line="$(grep -F 'remote-control' "$RUN_ARGS" | head -1)"
if [[ "$line" == *"--name proj"* && "$line" != *Ранбук* ]]; then ok
else fail "new без флагов изменил поведение: $line"; fi
# Несуществующий файл ранбука - отказ до запуска, а не пустая реплика.
: > "$RUN_ARGS"
if ! "$RC" new proj --prompt-file "$TMP/нет-такого.md" >/dev/null 2>&1 \
   && [[ ! -s "$RUN_ARGS" ]]; then ok
else fail "new принял несуществующий файл ранбука"; fi

echo "test-rc-handoff: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
