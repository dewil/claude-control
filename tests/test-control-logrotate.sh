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

# 8. INV-RECON-21: опрос живых сессий - три исхода, а не два. Вывод шел через
# конвейер с подавленным stderr, код возврата не смотрелся вовсе - удаление
# лога живой сессии выдергивало файл из-под открытого дескриптора. Каждая
# проверка ниже смотрит на ДВА факта - файлы и код возврата прогона.
recon_rot_setup() { local d; d="$(mktemp -d)"; mkdir -p "$d/sessions"; echo "$d"; }
recon_rot_reason_logged() { grep -qiE "отказ|не удал|skip|fail" "$1" 2>/dev/null; }

# Критерий 5: ненулевой код опроса - старые логи мертвых сессий не удаляются,
# в журнал (watchdog.log) уходит строка с причиной, весь прогон - не 0.
R5="$(recon_rot_setup)"
printf 'старье\n' > "$R5/sessions/proj-aaaaaaaa.log"
touch -d '-30 days' "$R5/sessions/proj-aaaaaaaa.log"
BIN5="$(mktemp -d)"
cat > "$BIN5/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in *list-units*) exit 1 ;; esac
exit 0
MOCK
chmod +x "$BIN5/systemctl"
env CLAUDE_CONTROL_DIR="$R5" PATH="$BIN5:$PATH" CLAUDE_CONTROL_LOG_TTL_D=7 "$ROT" >/dev/null 2>&1; rc=$?
if [[ "$rc" != 0 ]]; then ok
else fail "INV-RECON-21: ненулевой код опроса в логротейте дал rc=0"; fi
if [[ -f "$R5/sessions/proj-aaaaaaaa.log" ]]; then ok
else fail "INV-RECON-21: старый лог мертвой сессии удален при непроверенном опросе (rc=$rc)"; fi
if recon_rot_reason_logged "$R5/watchdog.log"; then ok
else fail "INV-RECON-21: в watchdog.log нет причины отказа опроса"; fi
rm -rf "$R5" "$BIN5"

# Критерий 6: обрезание размера живых файлов идет как прежде, даже когда опрос
# недоступен - оно не разрушает данные и от списка живых не зависит.
R6="$(recon_rot_setup)"
big x "$R6/control.log"
BIN6="$(mktemp -d)"
cat > "$BIN6/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in *list-units*) exit 1 ;; esac
exit 0
MOCK
chmod +x "$BIN6/systemctl"
env CLAUDE_CONTROL_DIR="$R6" PATH="$BIN6:$PATH" \
  CLAUDE_CONTROL_LOG_MAX_BYTES=10000 CLAUDE_CONTROL_LOG_KEEP_LINES=50 "$ROT" >/dev/null 2>&1; rc=$?
if [[ "$(wc -c < "$R6/control.log")" -lt 10000 ]]; then ok
else fail "INV-RECON-21: обрез размера не сработал при недоступном опросе"; fi
if [[ "$rc" != 0 ]]; then ok
else fail "INV-RECON-21: обрез прошел, но код возврата 0 несмотря на проваленный опрос"; fi
rm -rf "$R6" "$BIN6"

# Критерий 7: нулевой код опроса - прежнее поведение сохраняется (живая
# сессия цела, погашенная удалена), и прогон завершается нулем.
R7="$(recon_rot_setup)"
BIN7="$(mktemp -d)"
LIVE7="deadbeef11114111811111111111"
cat > "$BIN7/systemctl" <<MOCK
#!/usr/bin/env bash
case "\$*" in *list-units*) echo "ccsession-${LIVE7}.service loaded active running";; esac
exit 0
MOCK
chmod +x "$BIN7/systemctl"
for ext in log debug.log; do
  printf 'подвисла\n' > "$R7/sessions/proj-deadbeef.$ext"
  touch -d '-30 days' "$R7/sessions/proj-deadbeef.$ext"
done
printf 'старье\n' > "$R7/sessions/proj-aaaaaaaa.log"
touch -d '-30 days' "$R7/sessions/proj-aaaaaaaa.log"
env CLAUDE_CONTROL_DIR="$R7" PATH="$BIN7:$PATH" CLAUDE_CONTROL_LOG_TTL_D=7 "$ROT" >/dev/null 2>&1; rc=$?
if [[ "$rc" == 0 ]]; then ok
else fail "INV-RECON-21: исправный опрос дал ненулевой код ($rc)"; fi
if [[ -f "$R7/sessions/proj-deadbeef.log" && -f "$R7/sessions/proj-deadbeef.debug.log" ]]; then ok
else fail "INV-RECON-21: живая сессия удалена при исправном опросе"; fi
if [[ ! -e "$R7/sessions/proj-aaaaaaaa.log" ]]; then ok
else fail "INV-RECON-21: погашенная сессия не удалена при исправном опросе"; fi
rm -rf "$R7" "$BIN7"

echo "test-control-logrotate: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
