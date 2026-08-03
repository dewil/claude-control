#!/usr/bin/env bash
# Tests for `claude-rc live --porcelain` - что запущено прямо сейчас, по всем
# проектам сразу.
#
# Зачем отдельный глагол: иначе, чтобы понять, что работает, надо обойти все
# проекты и высматривать кружки. Плюс здесь же различается "работает" и "поднята,
# но молчит" - сессия, залипшая на setup-экране, снаружи неотличима от рабочей
# (юнит active, в мосту Registered), и ровно на этом мы обожглись с trust-диалогом.
# Признак живости - heartbeat в --debug-file: у здоровой сессии он капает каждые
# ~20 секунд, у залипшей файл замирает.
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

# Два проекта, чтобы проверить: live обходит их все, а не только первый.
PA="$TMP/alpha"; PB="$TMP/beta"; mkdir -p "$PA" "$PB"
printf 'alpha: %s\nbeta: %s\n' "$PA" "$PB" > "$CLAUDE_RC_PROJECTS_FILE"
slug() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
DA="$CLAUDE_CONFIG_DIR/projects/$(slug "$PA")"; mkdir -p "$DA"
DB="$CLAUDE_CONFIG_DIR/projects/$(slug "$PB")"; mkdir -p "$DB"

SID_A="aaaaaaaa-1111-4111-8111-111111111111"   # жива и здорова
SID_B="bbbbbbbb-2222-4222-8222-222222222222"   # поднята, но молчит
SID_C="cccccccc-3333-4333-8333-333333333333"   # лежит
mk() { # <dir> <uuid> <title>
  {
    printf '{"type":"user","message":{"content":[{"type":"text","text":"реплика"}]},"cwd":"%s"}\n' "$2"
    printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$4" "$3"
  } > "$1/$3.jsonl"
}
mk "$DA" "$PA" "$SID_A" "рабочая"
mk "$DA" "$PA" "$SID_B" "залипшая"
mk "$DB" "$PB" "$SID_C" "спящая"

# debug-логи: у A свежий, у B - замерший час назад.
: > "$CLAUDE_RC_LOG_DIR/alpha-${SID_A:0:8}.debug.log"
: > "$CLAUDE_RC_LOG_DIR/alpha-${SID_B:0:8}.debug.log"
touch -d '-1 hour' "$CLAUDE_RC_LOG_DIR/alpha-${SID_B:0:8}.debug.log"

mkdir -p "$TMP/bin"
export LIVE_UNITS="$TMP/live-units"
printf 'ccsession-%s\nccsession-%s\n' "${SID_A//-/}" "${SID_B//-/}" > "$LIVE_UNITS"
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in
  *is-active*) want="${!#}"
               for u in $(cat "$LIVE_UNITS" 2>/dev/null); do
                 [ "$u" = "$want" ] && exit 0
               done; exit 3 ;;
  *list-units*) for u in $(cat "$LIVE_UNITS" 2>/dev/null); do echo "$u.service"; done; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

OUT="$TMP/out"
"$RC" live --porcelain > "$OUT" 2>"$TMP/err"

# 1. Строка на каждую поднятую сессию, лежащей тут нет.
if [[ "$(wc -l < "$OUT")" == 2 ]]; then ok
else fail "строк $(wc -l < "$OUT"), ожидалось 2 ($(head -c150 "$TMP/err"))"; fi
if ! grep -q "$SID_C" "$OUT"; then ok; else fail "в live попала лежащая сессия"; fi

# 2. Формат: uuid, проект, имя, состояние, время, занятость окна. Время и
#    занятость - чтобы корневой экран показывал то же, что список проекта: без
#    них про сжатие вспоминают, только когда сессия уже уперлась.
bad="$(awk -F'\t' 'NF!=6 {c++} END {print c+0}' "$OUT")"
if [[ "$bad" == 0 ]]; then ok; else fail "$bad строк не с 6 полями"; fi

mt="$(awk -F'\t' -v s="$SID_A" '$1==s {print $5}' "$OUT")"
if [[ "$mt" =~ ^[0-9]+$ ]]; then ok; else fail "время последнего сообщения не число: '$mt'"; fi

# 3. Проект подставлен - иначе из списка не понять, куда проваливаться.
if [[ "$(awk -F'\t' -v s="$SID_A" '$1==s {print $2}' "$OUT")" == "alpha" ]]; then ok
else fail "проект не определен: $(grep "$SID_A" "$OUT")"; fi

# 4. Имя сессии - свое, а не короткий id.
if [[ "$(awk -F'\t' -v s="$SID_A" '$1==s {print $3}' "$OUT")" == "рабочая" ]]; then ok
else fail "имя не подставлено"; fi

# 5. Состояние: свежий heartbeat -> ok, замерший -> stale.
if [[ "$(awk -F'\t' -v s="$SID_A" '$1==s {print $4}' "$OUT")" == "ok" ]]; then ok
else fail "здоровая сессия не помечена ok"; fi
if [[ "$(awk -F'\t' -v s="$SID_B" '$1==s {print $4}' "$OUT")" == "stale" ]]; then ok
else fail "залипшая сессия не помечена stale: $(grep "$SID_B" "$OUT")"; fi

# 6. Нет debug-файла вовсе (сессию подняли не нами) - не пугаем "stale",
#    состояние неизвестно.
rm -f "$CLAUDE_RC_LOG_DIR/alpha-${SID_A:0:8}.debug.log"
"$RC" live --porcelain > "$OUT" 2>/dev/null
if [[ "$(awk -F'\t' -v s="$SID_A" '$1==s {print $4}' "$OUT")" == "unknown" ]]; then ok
else fail "без debug-файла состояние должно быть unknown"; fi

# 7. Человеческий вывод без --porcelain не сломан.
"$RC" live > "$TMP/human" 2>/dev/null
if grep -q 'ccsession-' "$TMP/human"; then ok; else fail "live без флага потерял вывод"; fi

echo "test-rc-live: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
