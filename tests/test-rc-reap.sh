#!/usr/bin/env bash
# Tests for `claude-rc reap` - жнец зомби-сессий.
#
# Зомби заводится так: dwl архивирует карточку сессии в браузере. Приложение
# шлет CLI end_session, тот отвечает result=error, дальше epoch mismatch (409),
# транспорт закрывается ("no longer the active worker") и через десять секунд
# мост сносится (Teardown complete). А вот ПРОЦЕСС не умирает: замерено на живом
# стенде - через 10 минут юнит active, claude жив 19 минут и держит 304 МБ.
#
# Снаружи это ловушка: бот показывает такую сессию как работающую, а достучаться
# до нее нельзя уже никогда - мост снесен. Лечится только гашением юнита.
#
# Признак берется из НАШЕГО debug-лога (того же, что слушает `down`, ожидая
# прощания), а не опросом API: проверено, что файл обнуляется на каждый подъем,
# поэтому последнее событие моста в нем описывает текущий прогон.
#
# Дренаж жнец пропускает осознанно: ждать строку прощания бессмысленно, мост уже
# снесен - и снесен с skipArchive, то есть этой строки не будет никогда.
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
mkdir -p "$CLAUDE_RC_LOG_DIR" "$CLAUDE_CONFIG_DIR"
PROJ="$TMP/proj"; mkdir -p "$PROJ"
printf 'proj: %s\n' "$PROJ" > "$CLAUDE_RC_PROJECTS_FILE"

SID_LIVE="11111111-1111-4111-8111-111111111111"   # здоровая
SID_DEAD="22222222-2222-4222-8222-222222222222"   # мост снесен
SID_BACK="33333333-3333-4333-8333-333333333333"   # снесен, но потом поднята
SID_NOLOG="44444444-4444-4444-8444-444444444444"  # лога нет вовсе
SID_LEGACY="55555555-5555-4555-8555-555555555555" # юнит в старой схеме имен

unit_of()        { printf 'ccsession-%s' "${1//-/}"; }
unit_of_legacy() { printf 'ccsession-%s' "${1:0:8}"; }

mk_log() { # <sid> <строки моста...>
  local sid="$1"; shift
  local f="$CLAUDE_RC_LOG_DIR/proj-${sid:0:8}.debug.log"
  : > "$f"
  local l
  for l in "$@"; do printf '2026-08-05T06:00:00.000Z [DEBUG] %s\n' "$l" >> "$f"; done
}

CREATED='[remote-bridge] Created session cse_01AAA'
REATTACH='[remote-bridge] Reattaching to session cse_01AAA'
TEARDOWN='[remote-bridge] Teardown complete (skipArchive): session=cse_01AAA'
FAILED='[bridge:repl] notifyBridgeFailed detail="Transport closed: this connection is no longer the active worker"'
NOISE='MCP server "asana": Connection error: SSE error: undefined'

mk_log "$SID_LIVE"   "$CREATED" "$NOISE"
mk_log "$SID_DEAD"   "$CREATED" "$FAILED" "$TEARDOWN" "$NOISE"
mk_log "$SID_BACK"   "$CREATED" "$TEARDOWN" "$REATTACH" "$NOISE"
mk_log "$SID_LEGACY" "$CREATED" "$TEARDOWN"

# Мок systemctl: список активных юнитов отдается ОДНИМ ответом на list-units,
# stop записывается в файл - по нему и проверяем, кого жнец тронул.
STOPPED="$TMP/stopped"; : > "$STOPPED"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<MOCK
#!/usr/bin/env bash
case "\${*}" in
  *list-units*)
    echo "$(unit_of "$SID_LIVE").service loaded active running"
    echo "$(unit_of "$SID_DEAD").service loaded active running"
    echo "$(unit_of "$SID_BACK").service loaded active running"
    echo "$(unit_of "$SID_NOLOG").service loaded active running"
    echo "$(unit_of_legacy "$SID_LEGACY").service loaded active running"
    exit 0 ;;
esac
for a in "\$@"; do
  case "\$a" in
    stop) : ;;
    ccsession-*)
      for b in "\$@"; do [[ "\$b" == stop ]] && echo "\$a" >> "$STOPPED"; done ;;
  esac
done
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

reaped_report() { grep -c "$1" "$TMP/out" 2>/dev/null || true; }

echo "=== жнец без ARM: только докладывает, никого не гасит ==="
CLAUDE_RC_REAP_ARM=0 "$RC" reap > "$TMP/out" 2>"$TMP/err"
rc=$?
[[ "$rc" == 0 ]] && ok || fail "reap без ARM выходит с 0 (got $rc: $(head -c200 "$TMP/err"))"
[[ "$(reaped_report "${SID_DEAD:0:8}")" -ge 1 ]] \
  && ok || fail "reap назвал зомби в отчете (out: $(head -c200 "$TMP/out"))"
grep -qi "would" "$TMP/out" \
  && ok || fail "reap без ARM говорит, что только СОБИРАЛСЯ гасить"
[[ ! -s "$STOPPED" ]] \
  && ok || fail "reap без ARM никого не погасил (погашено: $(cat "$STOPPED"))"

echo "=== --dry-run поверх ARM: тоже не гасит ==="
: > "$STOPPED"
CLAUDE_RC_REAP_ARM=1 "$RC" reap --dry-run > "$TMP/out" 2>/dev/null
[[ ! -s "$STOPPED" ]] \
  && ok || fail "--dry-run сильнее ARM (погашено: $(cat "$STOPPED"))"
[[ "$(reaped_report "${SID_DEAD:0:8}")" -ge 1 ]] \
  && ok || fail "--dry-run все равно докладывает о зомби"

echo "=== с ARM: гасит ровно зомби ==="
: > "$STOPPED"
CLAUDE_RC_REAP_ARM=1 "$RC" reap > "$TMP/out" 2>/dev/null
grep -qxF "$(unit_of "$SID_DEAD")" "$STOPPED" \
  && ok || fail "зомби погашен (погашено: $(cat "$STOPPED"))"
grep -qxF "$(unit_of "$SID_LIVE")" "$STOPPED" \
  && fail "здоровая сессия НЕ погашена" || ok
grep -qxF "$(unit_of "$SID_NOLOG")" "$STOPPED" \
  && fail "сессия без лога НЕ погашена (нет данных - не трогаем)" || ok
[[ "$(wc -l < "$STOPPED")" == 2 ]] \
  && ok || fail "погашены ровно два юнита - зомби и legacy (погашено: $(tr '\n' ' ' < "$STOPPED"))"

echo "--- поднятая заново (тирдаун, а ПОСЛЕ него подъем) не считается зомби ---"
grep -qxF "$(unit_of "$SID_BACK")" "$STOPPED" \
  && fail "сессия, поднятая после сноса моста, не тронута" || ok

echo "--- юнит в старой схеме имен тоже жнется ---"
grep -qxF "$(unit_of_legacy "$SID_LEGACY")" "$STOPPED" \
  && ok || fail "legacy-юнит погашен (погашено: $(tr '\n' ' ' < "$STOPPED"))"

echo "--- строки моста в ПОЛЕЗНОЙ НАГРУЗКЕ не считаются событиями моста ---"
# Поймано сухим прогоном на живой машине 2026-08-05: жнец нацелился на сессию,
# в которой шла эта самая работа. CLI пишет в тот же debug-лог каждое действие
# ("[auto-mode] new action being classified: {...}") вместе с текстом команд и
# файлов - а в них весь день попадались "Teardown complete" и "Torn down".
# Детектор читал собственный текст сессии как событие ее моста и погасил бы
# живую работу. Событие обязано стоять сразу после тега моста, а не где угодно.
: > "$STOPPED"
{
  printf '2026-08-05T06:00:00.000Z [DEBUG] %s\n' "$CREATED"
  printf '2026-08-05T06:01:00.000Z [DEBUG] [auto-mode] new action being classified: {"Write":"tests/x.sh: grep Teardown complete / Torn down (archive="}\n'
  printf '2026-08-05T06:02:00.000Z [DEBUG] [auto-mode] new action being classified: {"Bash":"echo [remote-bridge] Teardown complete (skipArchive)"}\n'
} > "$CLAUDE_RC_LOG_DIR/proj-${SID_DEAD:0:8}.debug.log"
CLAUDE_RC_REAP_ARM=1 "$RC" reap > "$TMP/out" 2>/dev/null
grep -qxF "$(unit_of "$SID_DEAD")" "$STOPPED" \
  && fail "сессия, лишь УПОМЯНУВШАЯ снос моста в своей работе, не погашена" || ok

echo "--- оборванный транспорт БЕЗ сноса моста - не зомби (сетевой всплеск) ---"
# Тот же урок, что у claude-control-watchdog: соединение, которое отвалилось и
# переподключается, гасить нельзя. Терминальным считаем только снос моста.
: > "$STOPPED"
mk_log "$SID_DEAD" "$CREATED" "$FAILED" "$NOISE"
CLAUDE_RC_REAP_ARM=1 "$RC" reap > "$TMP/out" 2>/dev/null
grep -qxF "$(unit_of "$SID_DEAD")" "$STOPPED" \
  && fail "сессия с оборванным транспортом, но живым мостом, не тронута" || ok

echo "=== нечего жать - тишина и код 0 ==="
: > "$STOPPED"
mk_log "$SID_DEAD" "$CREATED" "$NOISE"
mk_log "$SID_LEGACY" "$CREATED"
CLAUDE_RC_REAP_ARM=1 "$RC" reap > "$TMP/out" 2>/dev/null
rc=$?
[[ "$rc" == 0 ]] && ok || fail "reap выходит с 0, когда жать нечего (got $rc)"
[[ ! -s "$STOPPED" ]] && ok || fail "reap никого не тронул (погашено: $(cat "$STOPPED"))"

echo "=== отчет годится для журнала: одна строка на сессию, с причиной ==="
mk_log "$SID_DEAD" "$CREATED" "$TEARDOWN"
CLAUDE_RC_REAP_ARM=0 "$RC" reap > "$TMP/out" 2>/dev/null
[[ "$(grep -c "${SID_DEAD:0:8}" "$TMP/out")" == 1 ]] \
  && ok || fail "ровно одна строка на зомби"
grep -qi "bridge" "$TMP/out" \
  && ok || fail "в строке названа причина (снесенный мост)"

echo
echo "test-rc-reap: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
