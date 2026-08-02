#!/usr/bin/env bash
# Tests for claude-control-logrotate.
#
# Логротейт умел ровно одно - обрезать файл по размеру. Числа файлов это не
# трогало: каждая поднятая сессия оставляет пару <проект>-<sid8>.log/.debug.log
# навсегда, и каталог растет без предела (49 файлов за полтора месяца). Плюс в
# списке обрезаемых не было tgbot.log/tgbot.err - логов главного компонента
# после V3. Здесь закрыты обе дыры плюс регрессия на сам обрез.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROT="$HERE/../bin/claude-control-logrotate"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

export CLAUDE_CONTROL_DIR="$TMP/cc"
SESS="$CLAUDE_CONTROL_DIR/sessions"
mkdir -p "$SESS"

# Живой юнит ровно один - сессия deadbeef.
mkdir -p "$TMP/bin"
export LIVE_UNITS="$TMP/live-units"
printf 'ccsession-deadbeef11114111811111111111\n' > "$LIVE_UNITS"
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in
  *list-units*) for u in $(cat "$LIVE_UNITS" 2>/dev/null); do
                  echo "$u.service loaded active running"
                done; exit 0 ;;
  *is-active*)  want="${!#}"
                for u in $(cat "$LIVE_UNITS" 2>/dev/null); do
                  [ "$u" = "$want" ] && exit 0
                done; exit 3 ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

big() { yes "строка лога $1" | head -n 40000 > "$2"; }   # ~800 КБ при лимите 10 КБ
export CLAUDE_CONTROL_LOG_MAX_BYTES=10000
export CLAUDE_CONTROL_LOG_KEEP_LINES=50
export CLAUDE_CONTROL_LOG_TTL_D=7

# 1. Регрессия: распухший файл обрезается, короткий не трогаем.
big a "$CLAUDE_CONTROL_DIR/control.log"
printf 'коротко\n' > "$CLAUDE_CONTROL_DIR/control.err"
"$ROT" >/dev/null 2>&1
if [[ "$(wc -c < "$CLAUDE_CONTROL_DIR/control.log")" -lt 10000 ]]; then ok
else fail "распухший control.log не обрезан"; fi
if [[ "$(cat "$CLAUDE_CONTROL_DIR/control.err")" == "коротко" ]]; then ok
else fail "короткий файл тронут зря"; fi

# 2. Логи бота тоже под обрезом - после V3 это главный компонент, а его в
#    списке не было вовсе.
big b "$CLAUDE_CONTROL_DIR/tgbot.log"
big c "$CLAUDE_CONTROL_DIR/tgbot.err"
"$ROT" >/dev/null 2>&1
if [[ "$(wc -c < "$CLAUDE_CONTROL_DIR/tgbot.log")" -lt 10000 ]]; then ok
else fail "tgbot.log не обрезан"; fi
if [[ "$(wc -c < "$CLAUDE_CONTROL_DIR/tgbot.err")" -lt 10000 ]]; then ok
else fail "tgbot.err не обрезан"; fi

# 3. Логи давно погашенной сессии удаляются целиком: обрез размера оставлял бы
#    их навсегда, и каталог рос бы числом файлов.
for ext in log debug.log; do
  printf 'старье\n' > "$SESS/proj-aaaaaaaa.$ext"
  touch -d '-30 days' "$SESS/proj-aaaaaaaa.$ext"
done
"$ROT" >/dev/null 2>&1
if [[ ! -e "$SESS/proj-aaaaaaaa.log" && ! -e "$SESS/proj-aaaaaaaa.debug.log" ]]; then ok
else fail "старые логи мертвой сессии не удалены"; fi

# 4. Свежие логи остаются - "несколько дней хранить" (dwl).
printf 'свежак\n' > "$SESS/proj-bbbbbbbb.log"
"$ROT" >/dev/null 2>&1
if [[ -f "$SESS/proj-bbbbbbbb.log" ]]; then ok
else fail "свежий лог удален"; fi

# 5. Живую сессию не трогаем, даже если ее лог давно не двигался: удалить файл
#    из-под открытого дескриптора - значит потерять весь дальнейший вывод.
for ext in log debug.log; do
  printf 'подвисла\n' > "$SESS/proj-deadbeef.$ext"
  touch -d '-30 days' "$SESS/proj-deadbeef.$ext"
done
"$ROT" >/dev/null 2>&1
if [[ -f "$SESS/proj-deadbeef.log" && -f "$SESS/proj-deadbeef.debug.log" ]]; then ok
else fail "удален лог живой сессии"; fi

# 6. Срок настраивается: с TTL в 60 дней тридцатидневка переживает прогон.
printf 'старье\n' > "$SESS/proj-cccccccc.log"
touch -d '-30 days' "$SESS/proj-cccccccc.log"
CLAUDE_CONTROL_LOG_TTL_D=60 "$ROT" >/dev/null 2>&1
if [[ -f "$SESS/proj-cccccccc.log" ]]; then ok
else fail "TTL из окружения не учтен"; fi

# 7. Мусорный TTL откатывается к дефолту, а не к нулю: свежий файл переживает,
#    тридцатидневный уходит.
printf 'двухдневка\n' > "$SESS/proj-dddddddd.log"
touch -d '-2 days' "$SESS/proj-dddddddd.log"   # внутри дефолтных 7 дней, но старше суток:
printf 'старье\n' > "$SESS/proj-eeeeeeee.log"
touch -d '-30 days' "$SESS/proj-eeeeeeee.log"
CLAUDE_CONTROL_LOG_TTL_D='ой' "$ROT" >/dev/null 2>&1
if [[ -f "$SESS/proj-dddddddd.log" ]]; then ok
else fail "мусорный TTL снес двухдневный файл (откат к нулю вместо дефолта)"; fi
if [[ ! -e "$SESS/proj-eeeeeeee.log" ]]; then ok
else fail "при мусорном TTL чистка вообще не сработала"; fi

echo "test-control-logrotate: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
