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
#
# --- фикс-пак после adversarial-аудита (docs/design-2026-07-26-v2.4-
#     permission-gate.md, §2/§2a/§2b/§3 переписаны) ---
# P3 переписан: контракт исправлен на нейтральный исход (не allow, аудит
# blocker 1). P12-P17 - новые кейсы под blocker 2/3, major 4/5/6.
# call_hook()/call_hook_to_file() теперь ставят/снимают stub-конверт в
# inbox/inflight (M6 требует envelope_key реально в inflight) - тот же
# прием, что ask_direct() в test-agent-question.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
PERMIT="$HERE/../bin/claude-agent-permit"
ANSWER="$HERE/../bin/claude-agent-answer"
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
# envelope_key должен реально быть в inflight (M6 - регресс уже закрытого
# V2.3 major 6, см. ask_direct() в test-agent-question.sh): синтетические
# ключи получают временный stub-конверт, снимаемый сразу после вызова -
# иначе следующий "$RUN" step обработал бы его как мертвый runner.
stage_inflight() { # <agent-dir> <key> -> rc=0 если создали (наш), 1 если уже был
  local dir="$1" key="$2"
  mkdir -p "$dir/inbox/inflight"
  [[ -f "$dir/inbox/inflight/$key.json" ]] && return 1
  printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"kind":"event","text":"stub-for-permit-test"}}\n' \
    "$key" > "$dir/inbox/inflight/$key.json"
  return 0
}
unstage_inflight() { rm -f "$1/inbox/inflight/$2.json"; }  # <agent-dir> <key>
_hook_pipe() { # <tool_name> <tool_input-json> <agent-dir> <event-key> -> stdout хука, $? = exit code хука
  # СЫРОЙ вызов БЕЗ авто-staging - для P16 (envelope_key намеренно вне inflight)
  local tool="$1" input="$2" dir="$3" key="$4"
  python3 -c '
import json,sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))
' "$tool" "$input" | CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" timeout 10 "$PERMIT" --hook
}
call_hook() { # <agent-dir> <event-key> <tool_name> <tool_input-json> -> stdout хука, $? = exit code хука
  local dir="$1" key="$2" tool="$3" input="$4"
  local staged=0
  stage_inflight "$dir" "$key" && staged=1
  _hook_pipe "$tool" "$input" "$dir" "$key"
  local rc=$?
  [[ "$staged" == 1 ]] && unstage_inflight "$dir" "$key"
  return $rc
}
call_hook_to_file() { # <agent-dir> <event-key> <tool_name> <tool_input-json> <outfile>
  local dir="$1" key="$2" tool="$3" input="$4" outfile="$5"
  local staged=0
  stage_inflight "$dir" "$key" && staged=1
  _hook_pipe "$tool" "$input" "$dir" "$key" > "$outfile" 2>/dev/null
  local rc=$?
  [[ "$staged" == 1 ]] && unstage_inflight "$dir" "$key"
  return $rc
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
mk_ask_agent() { # <name> <ask-yaml-flow-list> -> agent dir; ask-пояс произвольный (P13/P14/P17)
  local name="$1" ask_yaml="$2"
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
  ask: $ask_yaml
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
echo "=== P3 (переписан после аудита blocker 1): вызов НЕ под ask -> НЕЙТРАЛЬНЫЙ исход (пустой stdout, БЕЗ allow), вопрос не создан ==="
AGP3=$(mk_permit_agent evtp3)
OUT3=$(call_hook "$AGP3" "p3-key" Bash '{"command":"ls -la"}'); RC3=$?
[[ "$RC3" == 0 ]] && ok || fail "P3: exit 0 (rc=$RC3)"
[[ -z "$OUT3" ]] && ok || fail "P3: stdout пуст - permissionDecision вообще отсутствует (got: $OUT3)"
[[ ! -d "$AGP3/questions" || -z "$(ls -A "$AGP3/questions" 2>/dev/null)" ]] \
  && ok || fail "P3: вопрос не создан"

echo "--- P3b (blocker 1): ask=[\"Bash(git push:*)\"] - матчер PreToolUse ловит Bash целиком, но Bash(git reset --hard) не получает allow от хука ---"
OUT3B=$(call_hook "$AGP3" "p3b-key" Bash '{"command":"git reset --hard"}'); RC3B=$?
[[ "$RC3B" == 0 ]] && ok || fail "P3b: exit 0"
[[ -z "$OUT3B" ]] && ok || fail "P3b: нейтральный исход, не allow (got: $OUT3B)"

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
# staging заранее (один раз, синхронно) - иначе два параллельных call_hook_to_file
# гонялись бы за созданием одного и того же stub-конверта (M6)
stage_inflight "$AGP6" "p6-key"
call_hook_to_file "$AGP6" "p6-key" Bash "{\"command\":\"$CMDP6\"}" "$TMP/p6a.out" &
call_hook_to_file "$AGP6" "p6-key" Bash "{\"command\":\"$CMDP6\"}" "$TMP/p6b.out" &
wait
unstage_inflight "$AGP6" "p6-key"
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
echo "=== P7: claude-agent-answer --approve -> токен создан ровно один; дубль адресующего события безопасен ==="
AGP7=$(mk_permit_agent evtp7)
CMDP7='git push origin p7-branch'
OUT7SETUP=$(call_hook "$AGP7" "p7-envelope-key" Bash "{\"command\":\"$CMDP7\"}")
[[ "$(hf "$OUT7SETUP" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P7 setup: вопрос создан (deny)"
QFILES7=("$AGP7"/questions/*.json)
[[ -f "${QFILES7[0]}" ]] && ok || fail "P7 setup: файл вопроса на месте"
QID7=$(jq_file "${QFILES7[0]}" 'd.get("qid")')
SHA7=$(jq_file "${QFILES7[0]}" 'd.get("tool_request",{}).get("action_sha256")')
[[ -n "$QID7" && -n "$SHA7" ]] && ok || fail "P7 setup: qid и action_sha256 присутствуют"

# v2.4 §3 (контракт исправлен после аудита): решение кладет ТОЛЬКО доверенный
# писатель claude-agent-answer - под questions/.lock decision="approve" в
# файл, и только потом адресующее событие (payload несет только question_id)
"$ANSWER" "$AGP7" --qid "$QID7" --approve >/dev/null 2>"$TMP/p7ans_err"
[[ "$(jq_file "${QFILES7[0]}" 'd.get("decision")')" == "approve" ]] \
  && ok || fail "P7: decision=approve записан в файл вопроса ($(cat "$TMP/p7ans_err"))"
"$RUN" intake "$AGP7" >/dev/null
assert "P7 answer-прогон (decision=approve из файла)" 0 "$RUN" step "$AGP7"
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

echo "--- P7b: дубль адресующего события (напр. редоставка) на уже закрытый qid - безопасен ---"
MARK_BEFORE7=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
"$RUN" spool-put evtp7 --json "{\"kind\":\"answer\",\"question_id\":\"$QID7\"}" >/dev/null
"$RUN" intake "$AGP7" >/dev/null
assert "P7b повторное адресующее событие на уже закрытый qid" 0 "$RUN" step "$AGP7"
MARK_AFTER7=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
[[ "$MARK_AFTER7" == "$MARK_BEFORE7" ]] \
  && ok || fail "P7b: claude не спавнится на дубле (stale, V2.3 инв.6)"
COUNT7B=$(ls "$AGP7/approvals" 2>/dev/null | wc -l | tr -d ' ')
[[ "$COUNT7B" == "1" ]] && ok || fail "P7b: второго токена не появилось после дубля (got $COUNT7B)"
[[ "$(jq_file "$TOKFILE7" 'd.get("spent")')" == "True" ]] && ok || fail "P7b: spent не сброшен дублем события"

# =============================================================== P8
echo "=== P8: claude-agent-answer --reject -> токен не создан, note об отказе в треде, вопрос закрыт ==="
AGP8=$(mk_permit_agent evtp8)
CMDP8='git push origin p8-branch'
OUT8SETUP=$(call_hook "$AGP8" "p8-envelope-key" Bash "{\"command\":\"$CMDP8\"}")
[[ "$(hf "$OUT8SETUP" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P8 setup: вопрос создан (deny)"
QFILES8=("$AGP8"/questions/*.json)
QID8=$(jq_file "${QFILES8[0]}" 'd.get("qid")')
"$ANSWER" "$AGP8" --qid "$QID8" --reject >/dev/null 2>"$TMP/p8ans_err"
[[ "$(jq_file "${QFILES8[0]}" 'd.get("decision")')" == "reject" ]] \
  && ok || fail "P8: decision=reject записан в файл вопроса ($(cat "$TMP/p8ans_err"))"
"$RUN" intake "$AGP8" >/dev/null
assert "P8 answer-прогон (decision=reject из файла)" 0 "$RUN" step "$AGP8"
[[ ! -d "$AGP8/approvals" || -z "$(ls -A "$AGP8/approvals" 2>/dev/null)" ]] \
  && ok || fail "P8: токен не создан при отказе"
[[ "$(jq_file "${QFILES8[0]}" 'd.get("status")')" == "closed" ]] && ok || fail "P8: вопрос закрыт"
THP8="$AGP8/thread.jsonl"
[[ "$(thread_has "$THP8" "note" "отклон")" == "True" ]] \
  && ok || fail "P8: в треде note об отказе оператора"

# =============================================================== P11 (аудит V2.4, исправление контракта)
echo "=== P11: payload.approve=true БЕЗ decision в файле - stale_answer, токен не создан (подделка) ==="
AGP11=$(mk_permit_agent evtp11)
CMDP11='git push origin p11-branch'
OUT11SETUP=$(call_hook "$AGP11" "p11-envelope-key" Bash "{\"command\":\"$CMDP11\"}")
[[ "$(hf "$OUT11SETUP" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P11 setup: вопрос создан (deny)"
QFILES11=("$AGP11"/questions/*.json)
QID11=$(jq_file "${QFILES11[0]}" 'd.get("qid")')
SHA11=$(jq_file "${QFILES11[0]}" 'd.get("tool_request",{}).get("action_sha256")')
# claude-agent-answer НЕ вызывается - decision в файле отсутствует; продюсер
# подделывает payload.approve=true напрямую в адресующем событии
MARK_BEFORE11=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
"$RUN" spool-put evtp11 --json "{\"kind\":\"answer\",\"question_id\":\"$QID11\",\"approve\":true}" >/dev/null
"$RUN" intake "$AGP11" >/dev/null
KADDR11=$(ls "$AGP11/inbox/pending" | sed 's/.json//')
assert "P11 адресующее событие без decision обрабатывается" 0 "$RUN" step "$AGP11"
MARK_AFTER11=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
[[ "$MARK_AFTER11" == "$MARK_BEFORE11" ]] \
  && ok || fail "P11: claude не спавнится (нет decision в файле - stale)"
[[ -f "$AGP11/inbox/done/$KADDR11.json" ]] && ok || fail "P11: конверт сразу в done (stale_answer)"
[[ "$(jq_file "${QFILES11[0]}" 'd.get("status")')" == "open" ]] \
  && ok || fail "P11: вопрос остается открытым (подделка не закрыла его)"
[[ ! -f "$AGP11/approvals/$SHA11.json" ]] \
  && ok || fail "P11: токен НЕ создан - payload.approve не является решением"

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

# =============================================================== P12 (blocker 3, фикс-пак)
echo "=== P12 (blocker 3, полный цикл через runner): токен выдается ДО спавна - подставной claude видит allow ВО ВРЕМЯ прогона ==="
MOCK_P12="$TMP/mock-claude-p12"
cat > "$MOCK_P12" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": os.environ["INNER_HOOK_CMD"]}}))
' | "$PERMIT_BIN" --hook > "$INNER_HOOK_OUT" 2>/dev/null
MOCK_RESULT_TEXT="${MOCK_RESULT_TEXT:-processed}" python3 -c '
import json, os
print(json.dumps({"type": "result", "result": os.environ["MOCK_RESULT_TEXT"], "total_cost_usd": 0.01}))'
EOF
chmod +x "$MOCK_P12"

AGP12=$(mk_permit_agent evtp12)
CMDP12='git push origin p12-branch'
OUT12SETUP=$(call_hook "$AGP12" "p12-envelope-key" Bash "{\"command\":\"$CMDP12\"}")
[[ "$(hf "$OUT12SETUP" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P12 setup: вопрос создан (deny)"
QFILES12=("$AGP12"/questions/*.json)
QID12=$(jq_file "${QFILES12[0]}" 'd.get("qid")')
SHA12=$(jq_file "${QFILES12[0]}" 'd.get("tool_request",{}).get("action_sha256")')
"$ANSWER" "$AGP12" --qid "$QID12" --approve >/dev/null 2>"$TMP/p12ans_err"
[[ "$(jq_file "${QFILES12[0]}" 'd.get("decision")')" == "approve" ]] \
  && ok || fail "P12: decision=approve записан ($(cat "$TMP/p12ans_err"))"
"$RUN" intake "$AGP12" >/dev/null

INNEROUT12="$TMP/p12-inner-hook.out"
: > "$INNEROUT12"
CLAUDE_BIN="$MOCK_P12" PERMIT_BIN="$PERMIT" INNER_HOOK_CMD="$CMDP12" \
  INNER_HOOK_OUT="$INNEROUT12" "$RUN" step "$AGP12" >/dev/null 2>"$TMP/p12run_err"
RC12RUN=$?
[[ "$RC12RUN" == 0 ]] && ok || fail "P12: run step exit 0 ($(cat "$TMP/p12run_err"))"
[[ -s "$INNEROUT12" ]] && ok || fail "P12: подставной claude реально вызвал хук изнутри прогона"
[[ "$(hf "$(cat "$INNEROUT12")" 'd.get("permissionDecision")')" == "allow" ]] \
  && ok || fail "P12: токен уже существовал ВО ВРЕМЯ прогона (allow изнутри мока), не после"
[[ "$(jq_file "$AGP12/approvals/$SHA12.json" 'd.get("spent")')" == "True" ]] \
  && ok || fail "P12: токен потрачен внутренним вызовом хука во время прогона"

echo "--- P12b (контроль): тот же сценарий, но decision в файле отсутствует - stale_answer, спавна нет, токена нет ---"
AGP12B=$(mk_permit_agent evtp12b)
CMDP12B='git push origin p12b-branch'
OUT12BSETUP=$(call_hook "$AGP12B" "p12b-envelope-key" Bash "{\"command\":\"$CMDP12B\"}")
[[ "$(hf "$OUT12BSETUP" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P12b setup: вопрос создан"
QFILES12B=("$AGP12B"/questions/*.json)
QID12B=$(jq_file "${QFILES12B[0]}" 'd.get("qid")')
SHA12B=$(jq_file "${QFILES12B[0]}" 'd.get("tool_request",{}).get("action_sha256")')
MARK_BEFORE12B=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
"$RUN" spool-put evtp12b --json "{\"kind\":\"answer\",\"question_id\":\"$QID12B\"}" >/dev/null
"$RUN" intake "$AGP12B" >/dev/null
assert "P12b answer-прогон без decision" 0 "$RUN" step "$AGP12B"
MARK_AFTER12B=$(wc -l < "$CLAUDE_INVOKED_MARKER" | tr -d ' ')
[[ "$MARK_AFTER12B" == "$MARK_BEFORE12B" ]] \
  && ok || fail "P12b: claude не спавнится (нет decision в файле - stale_answer)"
[[ ! -f "$AGP12B/approvals/$SHA12B.json" ]] \
  && ok || fail "P12b: токен не создан"

# =============================================================== P13 (blocker 2, фикс-пак)
echo "=== P13 (blocker 2, синтаксис §2a): WebFetch(domain:), Edit(prefix по file_path), mcp__server-префикс ==="
AGP13=$(mk_ask_agent evtp13 '["WebFetch(domain:example.com)", "Edit(/etc/*)", "mcp__srv"]')

OUT13A=$(call_hook "$AGP13" "p13a-key" WebFetch '{"url":"https://example.com/x"}')
[[ "$(hf "$OUT13A" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P13: WebFetch(domain:example.com) совпадает с https://example.com/x"

OUT13B=$(call_hook "$AGP13" "p13b-key" WebFetch '{"url":"https://evil.com/x"}')
[[ -z "$OUT13B" ]] \
  && ok || fail "P13: WebFetch(domain:example.com) НЕ совпадает с https://evil.com/x (нейтрально, got: $OUT13B)"

OUT13C=$(call_hook "$AGP13" "p13c-key" Edit '{"file_path":"/etc/passwd"}')
[[ "$(hf "$OUT13C" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P13: Edit(/etc/*) совпадает по file_path"

OUT13D=$(call_hook "$AGP13" "p13d-key" mcp__srv__tool '{"a":1}')
[[ "$(hf "$OUT13D" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P13: mcp__srv совпадает с mcp__srv__tool"

# =============================================================== P14 (blocker 2, валидация, фикс-пак)
echo "=== P14 (blocker 2, валидация): create с ask вне подмножества -> exit 2; хук на такой паттерн - deny, не тихое несовпадение ==="
RCAGENT="$HERE/../bin/claude-rc-agent"
SPEC14="$TMP/spec-p14.yaml"
cat > "$SPEC14" <<EOF
schema: 1
name: evtp14
type: event
role: none
goal: "P14 invalid ask pattern"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
permissions:
  allow: []
  ask: ["Bash(git * main)"]
EOF
"$RCAGENT" create evtp14 --spec "$SPEC14" >"$TMP/p14out" 2>"$TMP/p14err"; RC14=$?
[[ "$RC14" == 2 ]] && ok || fail "P14: create с невалидным ask-паттерном -> exit 2 (got $RC14: $(cat "$TMP/p14err"))"
[[ ! -e "$CLAUDE_AGENTS_DIR/evtp14" ]] && ok || fail "P14: задача НЕ создана"
grep -qi "поддерж" "$TMP/p14err" && ok || fail "P14: сообщение перечисляет поддерживаемые формы"

echo "--- P14b: тот же паттерн - спека отредактирована руками мимо валидации create, хук видит его напрямую ---"
AGP14B=$(mk_ask_agent evtp14b '["Bash(git * main)"]')
OUT14B=$(call_hook "$AGP14B" "p14b-key" Bash '{"command":"git checkout main"}')
[[ "$(hf "$OUT14B" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P14b: невалидный паттерн в хуке -> deny (fail-closed, не тихое несовпадение)"
[[ ! -d "$AGP14B/questions" || -z "$(ls -A "$AGP14B/questions" 2>/dev/null)" ]] \
  && ok || fail "P14b: вопрос не создан (сбой конфигурации - не легитимный запрос подтверждения)"

# =============================================================== P15 (major 4, фикс-пак)
echo "=== P15 (major 4, fail-closed): битая/недоступная spec.yaml -> deny; CLAUDE_AGENT_DIR отсутствует -> deny ==="
AGP15=$(mk_permit_agent evtp15)
echo "not: [valid, yaml" > "$AGP15/spec.yaml"   # умышленно битый YAML
OUT15A=$(call_hook "$AGP15" "p15a-key" Bash '{"command":"git push origin main"}')
[[ "$(hf "$OUT15A" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P15: битая spec.yaml -> deny (пустой ask-пояс здесь означал бы разрешение)"
[[ ! -d "$AGP15/questions" || -z "$(ls -A "$AGP15/questions" 2>/dev/null)" ]] \
  && ok || fail "P15: битая spec.yaml - deny БЕЗ создания вопроса (сбой конфигурации, не легитимный ask)"

OUT15B=$(_hook_pipe Bash '{"command":"git push origin main"}' "$TMP/no-such-agent-dir" "p15b-key")
[[ "$(hf "$OUT15B" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P15: CLAUDE_AGENT_DIR отсутствует -> deny"

# =============================================================== P16 (major 6, фикс-пак)
echo "=== P16 (major 6, регресс V2.3): CLAUDE_AGENT_EVENT_KEY не в inflight -> deny, вопрос не создан; claude-agent-ask ведет себя так же ==="
AGP16=$(mk_permit_agent evtp16)
OUT16=$(_hook_pipe Bash '{"command":"git push origin p16-branch"}' "$AGP16" "orphan-key-not-in-inflight")
[[ "$(hf "$OUT16" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P16: envelope_key вне inflight -> deny"
[[ ! -d "$AGP16/questions" || -z "$(ls -A "$AGP16/questions" 2>/dev/null)" ]] \
  && ok || fail "P16: вопрос НЕ создан (осиротевший вопрос не морозит очередь)"

echo "--- P16b: claude-agent-ask в том же сценарии - тот же регресс V2.3, не сломан ---"
ASK="$HERE/../bin/claude-agent-ask"
CLAUDE_AGENT_DIR="$AGP16" CLAUDE_AGENT_EVENT_KEY="orphan-key-not-in-inflight" \
  "$ASK" --question "q?" >/dev/null 2>"$TMP/p16b_err"
RC16B=$?
[[ "$RC16B" == 2 ]] && ok || fail "P16b: claude-agent-ask exit 2 (got $RC16B)"
grep -qi "inflight" "$TMP/p16b_err" && ok || fail "P16b: сообщение об ошибке ссылается на inflight"
[[ ! -d "$AGP16/questions" || -z "$(ls -A "$AGP16/questions" 2>/dev/null)" ]] \
  && ok || fail "P16b: вопрос по-прежнему не создан"

echo "--- P16c: traversal-ключ не проходит проверку конверта даже при существующем чужом .json ---"
# без валидации формы ключа "../../<чужой>.json" дал бы isfile()==true и создал
# бы ровно тот осиротевший вопрос, ради которого проверка и заводилась
mkdir -p "$AGP16/inbox/inflight"
echo '{}' > "$TMP/outsider.json"
OUT16C=$(_hook_pipe Bash '{"command":"git push origin p16c"}' "$AGP16" "../../../$TMP/outsider")
[[ "$(hf "$OUT16C" 'd.get("permissionDecision")')" == "deny" ]] \
  && ok || fail "P16c: traversal-ключ -> deny"
[[ ! -d "$AGP16/questions" || -z "$(ls -A "$AGP16/questions" 2>/dev/null)" ]] \
  && ok || fail "P16c: вопрос НЕ создан"

# =============================================================== P17 (major 5, фикс-пак)
echo "=== P17 (major 5, редакция по ключу): Bearer/token/password не оседают в файле вопроса и в thread.jsonl ==="
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

AGP17=$(mk_ask_agent evtp17 '["Bash"]')
CMDP17A="curl -H 'Authorization: Bearer abc.def.ghi' https://x/?token=s3cr3t"
OUT17A=$(call_hook "$AGP17" "p17a-key" Bash "{\"command\":$(json_str "$CMDP17A")}")
[[ "$(hf "$OUT17A" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P17a: вопрос создан (deny)"
QF17A=$(ls "$AGP17"/questions/*.json | head -1)
for secret in "abc.def.ghi" "s3cr3t"; do
  grep -qF "$secret" "$QF17A" \
    && fail "P17a: секрет '$secret' не должен попадать в файл вопроса открытым текстом" || ok
done
QID17A=$(jq_file "$QF17A" 'd.get("qid")')
"$ANSWER" "$AGP17" --qid "$QID17A" --approve >/dev/null 2>"$TMP/p17ans_err"
"$RUN" intake "$AGP17" >/dev/null
"$RUN" step "$AGP17" >/dev/null 2>"$TMP/p17run_err"
THP17="$AGP17/thread.jsonl"
for secret in "abc.def.ghi" "s3cr3t"; do
  grep -qF "$secret" "$THP17" 2>/dev/null \
    && fail "P17a: секрет '$secret' не должен попадать в thread.jsonl" || ok
done

AGP17B=$(mk_ask_agent evtp17b '["Bash"]')
CMDP17B="PASSWORD=hunter2 ./deploy.sh"
OUT17B=$(call_hook "$AGP17B" "p17b-key" Bash "{\"command\":$(json_str "$CMDP17B")}")
[[ "$(hf "$OUT17B" 'd.get("permissionDecision")')" == "deny" ]] && ok || fail "P17b: вопрос создан (deny)"
QF17B=$(ls "$AGP17B"/questions/*.json | head -1)
grep -qF "hunter2" "$QF17B" \
  && fail "P17b: пароль не должен попадать в файл вопроса открытым текстом" || ok

echo
echo "test-agent-permit: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
