#!/usr/bin/env bash
# Tests for claude-agent-waiting-hook - сигнал "сессия ждет твоего ответа".
#
# Сессия, задавшая уточняющий вопрос, снаружи неотличима от работающей: она
# просто молчит. Узнать об этом можно было, только открыв ее. Хук ловит событие
# Notification (Claude Code дергает его, когда ждет ввода) и говорит об этом в
# бота.
#
# Цена ошибки несимметрична в другую сторону, чем у голоса: пропущенный сигнал
# оставляет сессию стоять часами, а лишний - всего лишь одно сообщение. Поэтому
# фильтров тут меньше, но дедуп обязателен: ждущая сессия иначе напоминает о
# себе каждую минуту.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK_BIN:-$HERE/../bin/claude-agent-waiting-hook}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

export HOME="$TMP"
mkdir -p "$TMP/.claude-control/sessions" "$TMP/.cache" "$TMP/bin"
# Debug-лог моста: из него берется идентификатор сессии для ссылки в браузере.
# Побеждает ПОСЛЕДНИЙ cse_ - файл переживает несколько подъемов, и старый мост
# дал бы ссылку на сессию, которой уже нет.
# Формат строки СНЯТ С БОЕВОГО ЛОГА, а не выдуман: первая редакция фикстуры
# использовала "Created session cse_...", которого в реальном логе нет вовсе, и
# тест был зеленым при неработающей функции.
printf '%s\n' \
  '2026-09-10T10:00:00.000Z [DEBUG] [remote-bridge] v2 session URL: https://api.anthropic.com/v1/code/sessions/cse_01OldBridgeAAAAAAAAAAAA' \
  '2026-09-10T11:00:00.000Z [DEBUG] [remote-bridge] v2 session URL: https://api.anthropic.com/v1/code/sessions/cse_01TESTIDvvvvvvvvvvvvv' \
  > "$TMP/.claude-control/sessions/HR-11111111.debug.log"
STATE="$TMP/.claude-control/waiting-hook.json"
SENT="$TMP/sent"; : > "$SENT"

SID="11111111-1111-4111-8111-111111111111"
cat > "$TMP/bin/systemctl" <<MOCK
#!/usr/bin/env bash
case "\$*" in
  *ccsession-11111111111141118111111111111111*)
    echo '/usr/bin/script -qec "claude --remote-control --name HR\\\\ 9 --session-id $SID --debug-file /x.log" /y.log' ;;
  *) echo "" ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

BOTDIR="$TMP/botbin"; mkdir -p "$BOTDIR"
cp "$HOOK" "$BOTDIR/claude-agent-waiting-hook"
cat > "$BOTDIR/claude-agent-tgbot" <<MOCK
#!/usr/bin/env python3
import sys
open("$SENT", "a").write(repr(sys.argv[1:]) + "\\n")
MOCK
chmod +x "$BOTDIR/claude-agent-tgbot"
HOOK="$BOTDIR/claude-agent-waiting-hook"

TR="$TMP/transcript.jsonl"
mk_transcript() {
  python3 - "$TR" "$1" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "custom-title", "customTitle": "cv Коренева"}) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {
        "content": [{"type": "text", "text": sys.argv[2]}]}}) + "\n")
PY
}

run_hook() { # <message> [sid]
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Notification","message":"%s"}' \
    "${2:-$SID}" "$TR" "$1" | "$HOOK" >/dev/null 2>&1
}

mk_transcript "Какой вариант берем - первый или второй?"

echo "=== ожидание ввода уходит в бота ==="
run_hook "Claude is waiting for your input"
[[ -s "$SENT" ]] && ok || fail "сигнал не отправлен"
grep -q "cv Коренева" "$SENT" \
  && ok || fail "сессия названа тем именем, что видно в браузере ($(cat "$SENT"))"
grep -q "Какой вариант" "$SENT" \
  && ok || fail "видно, О ЧЕМ спрашивают, а не только что ждут"
grep -q -- "--button" "$SENT" \
  && ok || fail "кнопка перехода к сессиям не приложена"
grep -q -- "--no-preview" "$SENT" \
  && ok || fail "превью ссылки не отключено - карточка съест пол-экрана"

echo "=== в сообщении есть ссылка на сессию в браузере ==="
grep -q "claude.ai/code/session_01TESTIDvvvvvvvvvvvvv" "$SENT" \
  && ok || fail "ссылка не собрана из cse_ в debug-логе ($(cat "$SENT"))"

echo "=== упоминание cse_ в тексте работы не подделывает ссылку ==="
# CLI пишет в тот же debug-лог содержимое сессии, поэтому обсуждение чужого
# идентификатора попадает в файл наравне с событиями моста. Так и вышло на
# живых данных: строки из этого теста осели в логе рабочей сессии и подменили
# ссылку. Признак берем ЯКОРЕННЫЙ - строку события моста, а не подстроку.
cat >> "$TMP/.claude-control/sessions/HR-11111111.debug.log" <<'POISON'
2026-09-10T12:00:00.000Z [DEBUG] [auto-mode] обсуждаем cse_01PoisonXXXXXXXXXXXXXX в тексте
POISON
rm -f "$STATE"; : > "$SENT"
run_hook "Claude is waiting for your input"
grep -q "session_01TESTIDvvvvvvvvvvvvv" "$SENT" \
  && ok || fail "ссылка подменилась текстом работы ($(cat "$SENT"))"
grep -q "01Poison" "$SENT" \
  && fail "в ссылку попал идентификатор из тела лога" || ok

echo "=== запрос разрешения отличается формулировкой ==="
rm -f "$STATE"; : > "$SENT"
run_hook "Claude needs your permission to use Bash"
[[ -s "$SENT" ]] && ok || fail "запрос разрешения не отправлен"
grep -qiE "разрешен|доступ|гейт" "$SENT" \
  && ok || fail "текст не отличает разрешение от обычного ожидания ($(cat "$SENT"))"

echo "=== дедуп: повтор в окне тишины подавлен ==="
: > "$SENT"
run_hook "Claude is waiting for your input"
[[ ! -s "$SENT" ]] && ok || fail "повтор ушел сразу - телефон будет звенеть каждую минуту"

echo "=== по истечении окна напоминает снова ==="
python3 - "$STATE" "$SID" <<'PY'
import json, sys, time
json.dump({sys.argv[2]: time.time() - 9999}, open(sys.argv[1], "w"))
PY
: > "$SENT"
run_hook "Claude is waiting for your input"
[[ -s "$SENT" ]] && ok || fail "напоминание не возобновилось"

echo "=== сессия не из бота - молчим ==="
rm -f "$STATE"; : > "$SENT"
run_hook "Claude is waiting for your input" "99999999-9999-4999-8999-999999999999"
[[ ! -s "$SENT" ]] && ok || fail "терминальная сессия перед глазами не озвучивается"

echo "=== битый вход не роняет хук ==="
echo 'не json' | "$HOOK" >/dev/null 2>&1
[[ "$?" == 0 ]] && ok || fail "битый stdin - выход 0"

echo "=== отказ виден в логе, а не проглочен ==="
rm -f "$STATE"; : > "$SENT"
run_hook "Claude is waiting for your input" "99999999-9999-4999-8999-999999999999"
grep -qiE "не из бота|юнит" "$TMP/.cache/waiting-hook.log" 2>/dev/null \
  && ok || fail "причина молчания не записана ($(tail -2 "$TMP/.cache/waiting-hook.log" 2>/dev/null))"

echo
echo "test-waiting-hook: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
