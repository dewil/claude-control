#!/usr/bin/env bash
# Tests for V2.4 permission gate (claude-agent-permit --hook + settings-генерация).
# Контракт: docs/design-2026-07-26-v2.4-permission-gate.md §6 (кейсы P1-P10).
# Написано с чистого листа по спеке (SDD, RED-фаза) - реализация не читана
# (bin/* сознательно не открывался при написании этого файла, кроме проверки
# самого факта отсутствия claude-agent-permit).
#
# Ambiguity-заметки (см. итоговый отчет):
# 1. Синтаксис матчинга "Bash(git push:*)" контракт описывает лишь ссылкой
#    "тот же синтаксис, что у Claude" - тесты используют общеизвестную
#    семантику: паттерн матчит команды, начинающиеся с указанного префикса.
#    Если фактическая семантика иная - P2/P3/P5/P9 упадут не из-за бага, а
#    из-за неверного допущения о синтаксисе, это стоит уточнить в спеке.
# 2. Точный алгоритм redact() не специфицирован (только "маскировать
#    токеноподобные последовательности, обрезать до 300 символов") - тесты
#    проверяют только наблюдаемые свойства (секрет не в файле открытым
#    текстом, полный tool_input не хранится, длина обрезана), не конкретный
#    regex.
# 3. Форма payload answer-конверта для permission-вопроса взята из §3
#    буквально: {"kind":"answer","question_id":"<qid>","approve":true|false}.
#    Спека не проговаривает, обязателен ли также "text" (как у V2.3 §4) для
#    permission-kind ответа - тесты его не передают; если реализация этого
#    не переживет, это находка, а не баг теста.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
PERMIT="$HERE/../bin/claude-agent-permit"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
assert() { # <desc> <expected-exit> <cmd...>
  local desc="$1" want="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [[ "$got" == "$want" ]]; then ok; else
    fail "$desc: exit $got != $want ($(head -c150 "$TMP/err"))"; fi
}
jq_file() { # <file> <py-expr over dict/list d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
thread_has() { # <thread.jsonl> <kind> <substr> -> True/False
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, kind, sub = sys.argv[1], sys.argv[2], sys.argv[3]
found = False
try:
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("kind") == kind and sub in str(d.get("text", "")):
            found = True
            break
except FileNotFoundError:
    pass
print(found)
PY
}
mask_prompt() { # <file> <key-hex> <native_id> - вычищаем волатильные поля (как в test-agent-question.sh)
  local f="$1" key="$2" nid="$3"
  sed -E \
    -e "s/${key}/<KEY>/g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' \
    -e "s/(\"native_id\"[:=] ?\"?)${nid}(\"?)/\\1<N>\\2/g" \
    "$f"
}
argv_has() { grep -qxF -- "$1" "$2"; }   # <expected-line> <dumpfile>

action_sha() { # <tool_name> <tool_input-json> -> sha256(tool_name + \0 + canonical_json(tool_input))
  python3 -c '
import json, hashlib, sys
tool_name = sys.argv[1]
tool_input = json.loads(sys.argv[2])
canon = json.dumps(tool_input, sort_keys=True, ensure_ascii=False, separators=(",",":"))
print(hashlib.sha256((tool_name + "\0" + canon).encode("utf-8")).hexdigest())
' "$1" "$2"
}
write_approval() { # <agent-dir> <action_sha256> <qid> - готовый неспаленный токен (§3)
  local dir="$1" sha="$2" qid="$3"
  mkdir -p "$dir/approvals"
  python3 -c '
import json, sys
d = {"action_sha256": sys.argv[1], "qid": sys.argv[2], "created_at": "2026-07-26T00:00:00Z", "spent": False}
json.dump(d, open(sys.argv[3], "w"))
' "$sha" "$qid" "$dir/approvals/$sha.json"
}
call_hook() { # <agent-dir> <event-key> <tool_name> <tool_input-json> -> stdout хука, $? = exit code хука
  local dir="$1" key="$2" tool="$3" input="$4"
  python3 -c '
import json,sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))
' "$tool" "$input" | CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" timeout 10 "$PERMIT" --hook
}
call_hook_to_file() { # <agent-dir> <event-key> <tool_name> <tool_input-json> <outfile>
  local dir="$1" key="$2" tool="$3" input="$4" outfile="$5"
  python3 -c '
import json,sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))
' "$tool" "$input" | CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" timeout 10 "$PERMIT" --hook > "$outfile" 2>/dev/null
}
hf() { # <hook-json-text> <py-expr over hookSpecificOutput dict d>
  python3 -c 'import json,sys
d=json.loads(sys.argv[1]).get("hookSpecificOutput",{})
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}

mk_event() { # <name> <extra-yaml-lines> -> печатает путь к agent-dir (settings/prompt-регресс, P1/P10)
  local name="$1" extra="$2"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "permission gate settings/prompt regression test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
$extra
EOF
  echo "$ag"
}
mk_permit_agent() { # <name> -> печатает путь к agent-dir; ask-пояс = "Bash(git push:*)"
  local name="$1"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "permission gate hook unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
permissions:
  allow: []
  ask: ["Bash(git push:*)"]
EOF
  echo "$ag"
}

# --- mock claude: дампит prompt/argv (если заданы файлы), метит вызов, всегда ok ---
MOCK="$TMP/mock-claude"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${PROMPT_DUMP_FILE:-}" ]]; then cat > "$PROMPT_DUMP_FILE"; else cat > /dev/null; fi
if [[ -n "${ARGV_DUMP_FILE:-}" ]]; then printf '%s\n' "$@" > "$ARGV_DUMP_FILE"; fi
if [[ -n "${CLAUDE_INVOKED_MARKER:-}" ]]; then echo x >> "$CLAUDE_INVOKED_MARKER"; fi
MOCK_RESULT_TEXT="${MOCK_RESULT_TEXT:-processed}" python3 -c '
import json, os
print(json.dumps({"type": "result", "result": os.environ["MOCK_RESULT_TEXT"], "total_cost_usd": 0.01}))'
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK"
export CLAUDE_INVOKED_MARKER="$TMP/claude-invoked-marker"
: > "$CLAUDE_INVOKED_MARKER"

# =============================================================== P1
echo "=== P1: ask в спеке -> hooks.PreToolUse в agent-settings.json; пустой/отсутствующий ask -> секции нет ==="
AGP1=$(mk_event evtaskperm 'permissions:
  allow: ["Bash(claude-agent-ask:*)"]
  ask: ["Bash(git push:*)", "WebFetch"]
permission_mode: acceptEdits')
"$RUN" spool-put evtaskperm --text "p1" >/dev/null
"$RUN" intake "$AGP1" >/dev/null
"$RUN" step "$AGP1" >/dev/null 2>"$TMP/errp1"
SETP1="$AGP1/agent-settings.json"
[[ -f "$SETP1" ]] && ok || fail "P1: agent-settings.json создан"
[[ "$(jq_file "$SETP1" 'isinstance(d.get("hooks",{}).get("PreToolUse"), list) and len(d["hooks"]["PreToolUse"])>=1' 2>/dev/null)" == "True" ]] \
  && ok || fail "P1: hooks.PreToolUse - непустой список"
MATCHER1=$(jq_file "$SETP1" 'd["hooks"]["PreToolUse"][0]["matcher"]' 2>/dev/null)
[[ "$MATCHER1" == *Bash* ]] && ok || fail "P1: матчер ссылается на Bash (из ask)"
[[ "$MATCHER1" == *WebFetch* ]] && ok || fail "P1: матчер ссылается на WebFetch (из ask)"
CMD1=$(jq_file "$SETP1" 'd["hooks"]["PreToolUse"][0]["hooks"][0]["command"]' 2>/dev/null)
[[ "$CMD1" == *claude-agent-permit* ]] && ok || fail "P1: команда хука - claude-agent-permit"
[[ "$CMD1" == *--hook* ]] && ok || fail "P1: команда хука содержит --hook"
[[ "$(jq_file "$SETP1" '"Bash(git push:*)" not in d["permissions"].get("allow",[])' 2>/dev/null)" == "True" ]] \
  && ok || fail "P1: ask-паттерн не попал в permissions.allow"
[[ "$(jq_file "$SETP1" '"Bash(git push:*)" not in d["permissions"].get("deny",[])' 2>/dev/null)" == "True" ]] \
  && ok || fail "P1: ask-паттерн не попал в permissions.deny"

AGP1B=$(mk_event evtnoask 'permissions:
  allow: ["Bash(git commit:*)"]
  deny: ["WebFetch"]
permission_mode: acceptEdits')
"$RUN" spool-put evtnoask --text "p1b" >/dev/null
"$RUN" intake "$AGP1B" >/dev/null
"$RUN" step "$AGP1B" >/dev/null 2>"$TMP/errp1b"
SETP1B="$AGP1B/agent-settings.json"
[[ -f "$SETP1B" ]] && ok || fail "P1: (без ask) agent-settings.json все равно создан (allow/deny есть)"
[[ "$(jq_file "$SETP1B" '"hooks" not in d' 2>/dev/null)" == "True" ]] \
  && ok || fail "P1: пустой/отсутствующий ask -> секция hooks не генерируется вовсе"

# =============================================================== P2
echo "=== P2: вызов под ask без токена -> deny, вопрос kind=permission, редакция (секрет не в файле) ==="
AGP2=$(mk_permit_agent evtp2)
SECRET_TOKEN=$(python3 -c 'print("x"*40)')
CMDP2="git push origin main --token=$SECRET_TOKEN"
OUT2=$(call_hook "$AGP2" "p2-envelope-key" Bash "{\"command\":\"$CMDP2\"}"); RC2=$?
[[ "$RC2" == 0 ]] && ok || fail "P2: exit 0 (rc=$RC2)"
[[ "$(hf "$OUT2" 'd.get("hookEventName")')" == "PreToolUse" ]] && ok || fail "P2: hookEventName=PreToolUse"
[[ "$(hf "$OUT2" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P2: permissionDecision=deny"
QFILES2=("$AGP2"/questions/*.json)
[[ -f "${QFILES2[0]}" ]] && ok || fail "P2: файл вопроса создан"
QF2="${QFILES2[0]}"
[[ "$(jq_file "$QF2" 'd.get("kind")')" == "permission" ]] && ok || fail "P2: kind=permission"
[[ "$(jq_file "$QF2" 'd.get("envelope_key")')" == "p2-envelope-key" ]] && ok || fail "P2: envelope_key = CLAUDE_AGENT_EVENT_KEY"
[[ "$(jq_file "$QF2" 'd.get("status")')" == "open" ]] && ok || fail "P2: status=open"
SHA2_EXPECT=$(action_sha Bash "{\"command\":\"$CMDP2\"}")
[[ "$(jq_file "$QF2" 'd.get("tool_request",{}).get("action_sha256")')" == "$SHA2_EXPECT" ]] \
  && ok || fail "P2: action_sha256 = sha256(tool_name\\0canonical_json(tool_input))"
[[ "$(jq_file "$QF2" 'd.get("tool_request",{}).get("tool")')" == "Bash" ]] && ok || fail "P2: tool_request.tool=Bash"
[[ "$(jq_file "$QF2" '"tool_input" not in d.get("tool_request",{})')" == "True" ]] \
  && ok || fail "P2: полный tool_input НЕ хранится в tool_request (только input_redacted)"
Q2TEXT=$(jq_file "$QF2" 'd.get("question","")')
[[ "$Q2TEXT" == "разрешить:"* ]] && ok || fail "P2: текст вопроса начинается с 'разрешить:' ($Q2TEXT)"
grep -qF "$SECRET_TOKEN" "$QF2" \
  && fail "P2: токеноподобная последовательность не должна попасть в файл в открытом виде" || ok

echo "--- P2b: длинная команда - редакция обрезает до ~300 символов ---"
AGP2B=$(mk_permit_agent evtp2b)
LONGTAIL=$(python3 -c 'print("a"*450)')
CMDP2B="git push origin main --note=$LONGTAIL"
OUT2B=$(call_hook "$AGP2B" "p2b-key" Bash "{\"command\":\"$CMDP2B\"}")
[[ "$(hf "$OUT2B" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P2b: deny"
QFILES2B=("$AGP2B"/questions/*.json)
QF2B="${QFILES2B[0]}"
grep -qF "$CMDP2B" "$QF2B" \
  && fail "P2b: полная нередактированная длинная команда не должна попадать в файл целиком" || ok
REDLEN=$(jq_file "$QF2B" 'len(d.get("tool_request",{}).get("input_redacted",""))' 2>/dev/null)
[[ -n "$REDLEN" && "$REDLEN" -le 320 ]] && ok || fail "P2b: input_redacted обрезан до ~300 символов (got '$REDLEN')"

# =============================================================== P3
echo "=== P3: вызов НЕ под ask (пойман только грубым матчером) -> allow, вопрос не создан ==="
AGP3=$(mk_permit_agent evtp3)
OUT3=$(call_hook "$AGP3" "p3-key" Bash '{"command":"ls -la"}'); RC3=$?
[[ "$RC3" == 0 ]] && ok || fail "P3: exit 0 (rc=$RC3)"
[[ "$(hf "$OUT3" 'd.get("permissionDecision")')" == "allow" ]] && ok || fail "P3: не под ask -> allow"
[[ ! -d "$AGP3/questions" || -z "$(ls -A "$AGP3/questions" 2>/dev/null)" ]] \
  && ok || fail "P3: вопрос не создан"

# =============================================================== P4
echo "=== P4: токен spent:false -> allow + spent:true; повторный тот же вызов -> deny + новый запрос ==="
AGP4=$(mk_permit_agent evtp4)
CMDP4='git push origin release-p4'
SHAP4=$(action_sha Bash "{\"command\":\"$CMDP4\"}")
write_approval "$AGP4" "$SHAP4" "fake-qid-p4"
OUT4A=$(call_hook "$AGP4" "p4-key" Bash "{\"command\":\"$CMDP4\"}"); RC4A=$?
[[ "$RC4A" == 0 ]] && ok || fail "P4: exit 0"
[[ "$(hf "$OUT4A" 'd.get("permissionDecision")')" == "allow" ]] && ok || fail "P4: токен spent:false -> allow"
[[ "$(jq_file "$AGP4/approvals/$SHAP4.json" 'd.get("spent")')" == "True" ]] \
  && ok || fail "P4: токен помечен spent=true после использования"
QCOUNT_BEFORE4=$(ls "$AGP4/questions" 2>/dev/null | wc -l | tr -d ' ')
OUT4B=$(call_hook "$AGP4" "p4-key" Bash "{\"command\":\"$CMDP4\"}")
[[ "$(hf "$OUT4B" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P4: повторный тот же вызов -> deny (одноразовость)"
QCOUNT_AFTER4=$(ls "$AGP4/questions" 2>/dev/null | wc -l | tr -d ' ')
[[ "$QCOUNT_AFTER4" -gt "$QCOUNT_BEFORE4" ]] \
  && ok || fail "P4: повторный вызов создал новый запрос ($QCOUNT_BEFORE4 -> $QCOUNT_AFTER4)"

# =============================================================== P5
echo "=== P5: токен на другую команду того же инструмента -> deny (identity по action_sha256) ==="
AGP5=$(mk_permit_agent evtp5)
CMDP5A='git push origin main'
CMDP5B='git push origin develop'
SHAP5A=$(action_sha Bash "{\"command\":\"$CMDP5A\"}")
write_approval "$AGP5" "$SHAP5A" "fake-qid-p5"
OUT5=$(call_hook "$AGP5" "p5-key" Bash "{\"command\":\"$CMDP5B\"}")
[[ "$(hf "$OUT5" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P5: токен другой команды не подходит -> deny"
[[ "$(jq_file "$AGP5/approvals/$SHAP5A.json" 'd.get("spent")')" == "False" ]] \
  && ok || fail "P5: токен под чужую команду остался неспаленным"

# =============================================================== P6
echo "=== P6: два параллельных вызова на один токен -> ровно один allow (атомарность под локом) ==="
AGP6=$(mk_permit_agent evtp6)
CMDP6='git push origin p6-branch'
SHAP6=$(action_sha Bash "{\"command\":\"$CMDP6\"}")
write_approval "$AGP6" "$SHAP6" "fake-qid-p6"
call_hook_to_file "$AGP6" "p6-key" Bash "{\"command\":\"$CMDP6\"}" "$TMP/p6a.out" &
call_hook_to_file "$AGP6" "p6-key" Bash "{\"command\":\"$CMDP6\"}" "$TMP/p6b.out" &
wait
ALLOW6=$(python3 -c '
import json
n = 0
for f in ["'"$TMP"'/p6a.out", "'"$TMP"'/p6b.out"]:
    try:
        d = json.load(open(f))
        if d.get("hookSpecificOutput", {}).get("permissionDecision") == "allow":
            n += 1
    except Exception:
        pass
print(n)
')
[[ "$ALLOW6" == "1" ]] && ok || fail "P6: ровно один allow среди двух параллельных вызовов (got $ALLOW6)"
[[ "$(jq_file "$AGP6/approvals/$SHAP6.json" 'd.get("spent")')" == "True" ]] \
  && ok || fail "P6: токен после гонки помечен spent=true"

# =============================================================== P7
echo "=== P7: answer approve=true -> токен создан ровно один; дубль-ответ не создает второй/не сбрасывает spent ==="
AGP7=$(mk_permit_agent evtp7)
CMDP7='git push origin p7-branch'
OUT7SETUP=$(call_hook "$AGP7" "p7-envelope-key" Bash "{\"command\":\"$CMDP7\"}")
[[ "$(hf "$OUT7SETUP" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P7 setup: вопрос создан (deny)"
QFILES7=("$AGP7"/questions/*.json)
[[ -f "${QFILES7[0]}" ]] && ok || fail "P7 setup: файл вопроса на месте"
QID7=$(jq_file "${QFILES7[0]}" 'd.get("qid")')
SHA7=$(jq_file "${QFILES7[0]}" 'd.get("tool_request",{}).get("action_sha256")')
[[ -n "$QID7" && -n "$SHA7" ]] && ok || fail "P7 setup: qid и action_sha256 присутствуют"

"$RUN" spool-put evtp7 --json "{\"kind\":\"answer\",\"question_id\":\"$QID7\",\"approve\":true}" >/dev/null
"$RUN" intake "$AGP7" >/dev/null
assert "P7 answer-прогон approve=true" 0 "$RUN" step "$AGP7"
TOKFILE7="$AGP7/approvals/$SHA7.json"
[[ -f "$TOKFILE7" ]] && ok || fail "P7: approvals/<action_sha256>.json создан"
[[ "$(jq_file "$TOKFILE7" 'd.get("spent")')" == "False" ]] && ok || fail "P7: новый токен spent=false"
[[ "$(jq_file "$TOKFILE7" 'd.get("qid")')" == "$QID7" ]] && ok || fail "P7: токен привязан к qid"
COUNT7A=$(ls "$AGP7/approvals" 2>/dev/null | wc -l | tr -d ' ')
[[ "$COUNT7A" == "1" ]] && ok || fail "P7: ровно один токен создан (got $COUNT7A)"

OUT7CONSUME=$(call_hook "$AGP7" "p7-envelope-key" Bash "{\"command\":\"$CMDP7\"}")
[[ "$(hf "$OUT7CONSUME" 'd.get("permissionDecision")')" == "allow" ]] \
  && ok || fail "P7: выданный токен реально разрешает исходное действие"
[[ "$(jq_file "$TOKFILE7" 'd.get("spent")')" == "True" ]] && ok || fail "P7: после использования spent=true"

MARK_BEFORE7=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
"$RUN" spool-put evtp7 --json "{\"kind\":\"answer\",\"question_id\":\"$QID7\",\"approve\":true}" >/dev/null
"$RUN" intake "$AGP7" >/dev/null
assert "P7 повторный (дубль) тот же ответ на уже закрытый qid" 0 "$RUN" step "$AGP7"
MARK_AFTER7=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
[[ "$MARK_AFTER7" == "$MARK_BEFORE7" ]] \
  && ok || fail "P7: claude не спавнится на дубль-ответе (stale, V2.3 инв.6)"
COUNT7B=$(ls "$AGP7/approvals" 2>/dev/null | wc -l | tr -d ' ')
[[ "$COUNT7B" == "1" ]] && ok || fail "P7: второго токена не появилось после дубля (got $COUNT7B)"
[[ "$(jq_file "$TOKFILE7" 'd.get("spent")')" == "True" ]] && ok || fail "P7: spent не сброшен дублем ответа"

# =============================================================== P8
echo "=== P8: answer approve=false -> токен не создан, note об отказе в треде, вопрос закрыт ==="
AGP8=$(mk_permit_agent evtp8)
CMDP8='git push origin p8-branch'
OUT8SETUP=$(call_hook "$AGP8" "p8-envelope-key" Bash "{\"command\":\"$CMDP8\"}")
[[ "$(hf "$OUT8SETUP" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P8 setup: вопрос создан (deny)"
QFILES8=("$AGP8"/questions/*.json)
QID8=$(jq_file "${QFILES8[0]}" 'd.get("qid")')
"$RUN" spool-put evtp8 --json "{\"kind\":\"answer\",\"question_id\":\"$QID8\",\"approve\":false}" >/dev/null
"$RUN" intake "$AGP8" >/dev/null
assert "P8 answer-прогон approve=false" 0 "$RUN" step "$AGP8"
[[ ! -d "$AGP8/approvals" || -z "$(ls -A "$AGP8/approvals" 2>/dev/null)" ]] \
  && ok || fail "P8: токен не создан при отказе"
[[ "$(jq_file "${QFILES8[0]}" 'd.get("status")')" == "closed" ]] && ok || fail "P8: вопрос закрыт"
THP8="$AGP8/thread.jsonl"
[[ "$(thread_has "$THP8" "note" "отклон")" == "True" ]] \
  && ok || fail "P8: в треде note об отказе оператора"

# =============================================================== P9
echo "=== P9: открытый вопрос есть -> новый вызов (другое действие) не создает второй, просто deny ==="
AGP9=$(mk_permit_agent evtp9)
CMDP9A='git push origin p9-a'
CMDP9B='git push origin p9-b'
OUT9A=$(call_hook "$AGP9" "p9-key" Bash "{\"command\":\"$CMDP9A\"}")
[[ "$(hf "$OUT9A" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P9: первый вызов создал вопрос (deny)"
QCOUNT9A=$(ls "$AGP9/questions" 2>/dev/null | wc -l | tr -d ' ')
[[ "$QCOUNT9A" == "1" ]] && ok || fail "P9: ровно один открытый вопрос после первого вызова"
OUT9B=$(call_hook "$AGP9" "p9-key" Bash "{\"command\":\"$CMDP9B\"}")
[[ "$(hf "$OUT9B" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P9: второй вызов (другое действие) тоже deny, singleton держит"
QCOUNT9B=$(ls "$AGP9/questions" 2>/dev/null | wc -l | tr -d ' ')
[[ "$QCOUNT9B" == "1" ]] && ok || fail "P9: второй вопрос не создан (got $QCOUNT9B файлов)"

# =============================================================== P10 (регресс)
echo "=== P10: спека без ask - прогон, argv и промпт байт-в-байт как без permission-гейта ==="
AGP10A=$(mk_event evtp10a '')
"$RUN" spool-put evtp10a --text "p10-golden-shared-text" >/dev/null
"$RUN" intake "$AGP10A" >/dev/null
KP10A=$(ls "$AGP10A/inbox/pending" | sed 's/.json//')
PROMPTP10A="$TMP/promptp10a.txt"
MOCK_RESULT_TEXT="p10-golden-result" PROMPT_DUMP_FILE="$PROMPTP10A" "$RUN" step "$AGP10A" >/dev/null 2>"$TMP/errp10a"
[[ -s "$PROMPTP10A" ]] && ok || fail "P10: baseline-промпт (без permissions вовсе) сдампен"
GOLDENP10=$(mask_prompt "$PROMPTP10A" "$KP10A" "1")

AGP10B=$(mk_event evtp10b 'permissions:
  allow: ["Bash(git commit:*)"]
  deny: ["WebFetch"]
permission_mode: acceptEdits')
"$RUN" spool-put evtp10b --text "p10-golden-shared-text" >/dev/null
"$RUN" intake "$AGP10B" >/dev/null
KP10B=$(ls "$AGP10B/inbox/pending" | sed 's/.json//')
ARGVP10B="$TMP/argvp10b.txt"
PROMPTP10B="$TMP/promptp10b.txt"
MOCK_RESULT_TEXT="p10-golden-result" ARGV_DUMP_FILE="$ARGVP10B" PROMPT_DUMP_FILE="$PROMPTP10B" \
  "$RUN" step "$AGP10B" >/dev/null 2>"$TMP/errp10b"
[[ -s "$PROMPTP10B" ]] && ok || fail "P10: промпт агента с permissions(без ask) сдампен"
MASKEDP10B=$(mask_prompt "$PROMPTP10B" "$KP10B" "2")
[[ "$GOLDENP10" == "$MASKEDP10B" ]] \
  && ok || fail "P10: наличие permissions без ask не меняет текст промпта (регресс байт-в-байт)"
argv_has "--settings" "$ARGVP10B" && ok || fail "P10: argv по-прежнему содержит --settings (V2.1 не сломан)"
argv_has "--disallowedTools" "$ARGVP10B" \
  && fail "P10: --disallowedTools не должен появляться при наличии permissions" || ok
SETP10B="$AGP10B/agent-settings.json"
[[ -f "$SETP10B" ]] && ok || fail "P10: agent-settings.json создан (allow/deny присутствуют)"
[[ "$(jq_file "$SETP10B" '"hooks" not in d' 2>/dev/null)" == "True" ]] \
  && ok || fail "P10: без ask секция hooks не появляется в реальном прогоне"

echo
echo "test-agent-permit: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
