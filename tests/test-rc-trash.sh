#!/usr/bin/env bash
# Tests for `claude-rc rm|trash` - удаление сессии из бота.
#
# Ключевое решение: удаление НЕ трет файл, а переносит транскрипт в корзину с TTL.
# Причина - асимметрия цены ошибки: тап делается одним пальцем на ходу, а переписка
# невосстановима. Корзина стоит десяток строк и снимает целый класс сожалений.
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
export CLAUDE_RC_TRASH_DIR="$TMP/trash"
mkdir -p "$CLAUDE_RC_LOG_DIR"

PROJ="$TMP/proj"; mkdir -p "$PROJ"
printf 'proj: %s\n' "$PROJ" > "$CLAUDE_RC_PROJECTS_FILE"
SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
TDIR="$CLAUDE_CONFIG_DIR/projects/$SLUG"; mkdir -p "$TDIR"

SID="aaaaaaaa-1111-4111-8111-111111111111"
mk() { # пересоздать транскрипт
  {
    printf '{"type":"user","message":{"content":[{"type":"text","text":"первая"}]},"cwd":"%s"}\n' "$PROJ"
    printf '{"type":"custom-title","customTitle":"сессия 1","sessionId":"%s"}\n' "$SID"
  } > "$TDIR/$SID.jsonl"
}
mk

mkdir -p "$TMP/bin"
export STOP_ARGS="$TMP/stop-args" LIVE_UNITS="$TMP/live-units"
: > "$LIVE_UNITS"; : > "$STOP_ARGS"
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in
  *is-active*) want="${!#}"
               for u in $(cat "$LIVE_UNITS" 2>/dev/null); do
                 [ "$u" = "$want" ] && exit 0
               done; exit 3 ;;
  *stop*|*reset-failed*) printf '%s\n' "$@" >> "$STOP_ARGS"; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

# 1. Транскрипт уезжает в корзину, а не удаляется.
"$RC" rm proj "$SID" >"$TMP/out" 2>"$TMP/err"
rc=$?
if [[ "$rc" == 0 && ! -f "$TDIR/$SID.jsonl" ]]; then ok
else fail "rm: rc=$rc, исходный файл на месте? ($(head -c120 "$TMP/err"))"; fi

trashed="$(find "$CLAUDE_RC_TRASH_DIR" -name "*$SID*.jsonl" 2>/dev/null | head -1)"
if [[ -n "$trashed" ]]; then ok; else fail "в корзине нет файла сессии"; fi

# 2. Рядом лежит метка с исходным путем - иначе восстанавливать некуда.
meta="${trashed%.jsonl}.meta"
if [[ -f "$meta" ]] && grep -q "$TDIR" "$meta"; then ok
else fail "нет меты с исходным путем"; fi

# 3. Сессия пропала из списка.
if [[ "$("$RC" sessions proj --porcelain 2>/dev/null | wc -l)" == 0 ]]; then ok
else fail "удаленная сессия осталась в списке"; fi

# 4. restore возвращает файл на место.
"$RC" trash restore "$SID" >/dev/null 2>&1
if [[ -f "$TDIR/$SID.jsonl" ]]; then ok; else fail "restore не вернул транскрипт"; fi
if [[ "$("$RC" sessions proj --porcelain 2>/dev/null | wc -l)" == 1 ]]; then ok
else fail "после restore сессия не вернулась в список"; fi

# 5. Живая сессия перед удалением гасится: иначе процесс продолжит писать в файл,
#    которого уже нет на месте, и часть переписки утечет мимо корзины.
: > "$STOP_ARGS"; echo "ccsession-${SID//-/}" > "$LIVE_UNITS"
"$RC" rm proj "$SID" >/dev/null 2>&1
if grep -q "ccsession-${SID//-/}" "$STOP_ARGS"; then ok
else fail "живая сессия не погашена перед удалением"; fi
: > "$LIVE_UNITS"

# 6. trash list показывает, что лежит в корзине.
if "$RC" trash list 2>/dev/null | grep -q "$SID"; then ok
else fail "trash list не показал удаленную сессию"; fi

# 7. TTL: файл старше срока уходит при следующем обращении, свежий остается.
old="$CLAUDE_RC_TRASH_DIR/2000-01-01-bbbbbbbb-2222-4222-8222-222222222222.jsonl"
printf '{}\n' > "$old"; printf '{"orig":"/nowhere"}\n' > "${old%.jsonl}.meta"
touch -d '2000-01-01' "$old" "${old%.jsonl}.meta"
"$RC" trash list >/dev/null 2>&1
if [[ ! -f "$old" ]]; then ok; else fail "TTL не вычистил протухший файл"; fi
if [[ -n "$(find "$CLAUDE_RC_TRASH_DIR" -name "*$SID*.jsonl" 2>/dev/null)" ]]; then ok
else fail "TTL снес свежий файл"; fi

# 8. Кривой uuid и чужой проект отвергаются до любых действий.
mk
if ! "$RC" rm proj 'nonsense' >/dev/null 2>&1 && [[ -f "$TDIR/$SID.jsonl" ]]; then ok
else fail "rm принял кривой uuid"; fi
if ! "$RC" rm nosuch "$SID" >/dev/null 2>&1 && [[ -f "$TDIR/$SID.jsonl" ]]; then ok
else fail "rm принял неизвестный проект"; fi

echo "test-rc-trash: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
