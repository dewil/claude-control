#!/usr/bin/env bash
# Tests for claude-agent-voice-hook - озвучка итога сессии на остановке.
#
# Хук висит на КАЖДОЙ остановке сессии, поэтому цена ошибки несимметрична:
# лишняя отправка будит человека и слышна окружающим, пропущенная - всего лишь
# оставляет итог непрослушанным. Отсюда все фильтры проверяются в обе стороны:
# и что пропускают нужное, и что давят лишнее.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK_BIN:-$HERE/../bin/claude-agent-voice-hook}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

export HOME="$TMP"
mkdir -p "$TMP/.claude-control" "$TMP/.cache" "$TMP/bin"

VOICE_PREF="$TMP/.claude-control/tgbot.voice.json"
STATE="$TMP/.claude-control/voice-hook.json"
SENT="$TMP/sent"; : > "$SENT"

# Подменяем и systemctl (чтобы сессия "существовала"), и сам бот (чтобы ни один
# прогон не мог отправить сообщение живому человеку - тот же урок, что у жнеца).
cat > "$TMP/bin/systemctl" <<MOCK
#!/usr/bin/env bash
case "\$*" in
  *ccsession-11111111111141118111111111111111*)
    echo '/usr/bin/script -qec "claude --remote-control --name HR\\\\ 9 --session-id 11111111-1111-4111-8111-111111111111 --debug-file /x.log" /y.log' ;;
  *) echo "" ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

BOTDIR="$TMP/botbin"; mkdir -p "$BOTDIR"
cp "$HOOK" "$BOTDIR/claude-agent-voice-hook"
cat > "$BOTDIR/claude-agent-tgbot" <<MOCK
#!/usr/bin/env python3
import sys
open("$SENT", "a").write(repr(sys.argv[1:]) + "\\n")
MOCK
chmod +x "$BOTDIR/claude-agent-tgbot"
HOOK="$BOTDIR/claude-agent-voice-hook"

SID="11111111-1111-4111-8111-111111111111"
TR="$TMP/transcript.jsonl"

mk_transcript() { # <текст ответа>
  python3 - "$TR" "$1" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "message": {"content": "вопрос"}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {
        "content": [{"type": "text", "text": text}]}}) + "\n")
PY
}

run_hook() { # [sid] -> запускает хук с текущим транскриптом
  local sid="${1:-$SID}"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' \
    "$sid" "$TR" "$TMP" | "$HOOK" >/dev/null 2>&1
  # Отправка уходит ОТВЯЗАННЫМ процессом, и это не деталь реализации, а
  # требование: хук не имеет права ждать синтез. Значит тесту надо дать ему
  # дописать файл - без паузы цикл ожидания крутится вхолостую и всегда видит
  # пустоту (на этом первый прогон дал пять ложных красных).
  local i=0
  while (( i < 40 )); do
    [[ -s "$SENT" ]] && break
    sleep 0.05
    i=$((i+1))
  done
}

LONG="$(python3 -c "print('Итог работы. ' * 60)")"
SHORT="готово"

echo "=== тумблер выключен - молчим ==="
printf '{"enabled": false}' > "$VOICE_PREF"
mk_transcript "$LONG"; : > "$SENT"
run_hook
[[ ! -s "$SENT" ]] && ok || fail "при выключенном тумблере ничего не отправлено"

echo "=== тумблера нет вовсе - тоже молчим (fail-closed) ==="
rm -f "$VOICE_PREF"; : > "$SENT"
run_hook
[[ ! -s "$SENT" ]] && ok || fail "без файла состояния молчим"

echo "=== включен и ответ длинный - отправляем ==="
printf '{"enabled": true}' > "$VOICE_PREF"
: > "$SENT"; rm -f "$STATE"
run_hook
[[ -s "$SENT" ]] && ok || fail "длинный ответ при включенном тумблере уходит"
grep -q -- "--session" "$SENT" \
  && ok || fail "отправка помечена как сессионная (got $(cat "$SENT"))"
grep -q "HR 9" "$SENT" \
  && ok || fail "имя сессии распознано из юнита и подставлено ($(cat "$SENT"))"

echo "=== переименованная сессия зовется НОВЫМ именем ==="
rm -f "$STATE"; : > "$SENT"
python3 - "$TR" "$LONG" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "custom-title", "customTitle": "старое"}) + "\n")
    fh.write(json.dumps({"type": "custom-title", "customTitle": "happ sub"}) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {
        "content": [{"type": "text", "text": text}]}}) + "\n")
PY
run_hook
grep -q "happ sub" "$SENT" \
  && ok || fail "имя из транскрипта побеждает стартовое имя юнита ($(cat "$SENT"))"
grep -q "HR 9" "$SENT" \
  && fail "стартовое имя юнита больше не звучит" || ok
mk_transcript "$LONG"

echo "=== пауза: второй итог подряд не уходит ==="
: > "$SENT"
run_hook
[[ ! -s "$SENT" ]] && ok || fail "повтор в окне тишины подавлен"

echo "=== после паузы снова можно ==="
python3 - "$STATE" <<'PY'
import json, sys, time
json.dump({"11111111-1111-4111-8111-111111111111": time.time() - 9999},
          open(sys.argv[1], "w"))
PY
: > "$SENT"
run_hook
[[ -s "$SENT" ]] && ok || fail "по истечении окна отправка возобновляется"

echo "=== короткий ответ не озвучиваем ==="
rm -f "$STATE"; mk_transcript "$SHORT"; : > "$SENT"
run_hook
[[ ! -s "$SENT" ]] && ok || fail "короткий ответ отсеян"

echo "=== ответ без текста (одни инструменты) не озвучиваем ==="
rm -f "$STATE"; : > "$SENT"
python3 - "$TR" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "assistant", "message": {
        "content": [{"type": "tool_use", "name": "Bash", "input": {}}]}}) + "\n")
PY
run_hook
[[ ! -s "$SENT" ]] && ok || fail "ответ из одних вызовов инструментов не озвучен"

echo "=== сессия не из бота - тишина ==="
rm -f "$STATE"; mk_transcript "$LONG"; : > "$SENT"
run_hook "99999999-9999-4999-8999-999999999999"
[[ ! -s "$SENT" ]] && ok || fail "сессия без юнита не озвучивается"

echo "=== повторный вход хука не зацикливается ==="
rm -f "$STATE"; : > "$SENT"
printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":true}' \
  "$SID" "$TR" | "$HOOK" >/dev/null 2>&1
[[ ! -s "$SENT" ]] && ok || fail "stop_hook_active гасит повторный вход"

echo "=== битый вход не роняет хук ==="
echo 'не json' | "$HOOK" >/dev/null 2>&1
[[ "$?" == 0 ]] && ok || fail "битый stdin - выход 0"
printf '{"session_id":"%s","transcript_path":"/нет/такого"}' "$SID" \
  | "$HOOK" >/dev/null 2>&1
[[ "$?" == 0 ]] && ok || fail "пропавший транскрипт - выход 0"

echo "=== отказ виден в логе, а не проглочен молча ==="
rm -f "$STATE"; mk_transcript "$SHORT"; : > "$SENT"
run_hook
grep -q "коротк" "$TMP/.cache/voice-hook.log" 2>/dev/null \
  && ok || fail "причина отказа записана в лог"

echo
echo "test-voice-hook: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
