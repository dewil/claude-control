#!/usr/bin/env bash
# Tests for V2.6 reminder-ladder (claude-agent-run question-reminders/
# question-snooze + честный код возврата доставки для question-путей).
# Контракт: docs/design-2026-07-26-v2.6-reminder-ladder.md §8 (кейсы R1-R13).
#
# Написано с чистого листа по спеке (SDD, RED-фаза): реализация V2.6 НЕ
# читана (bin/claude-agent-run, bin/claude-agent-reconciler,
# bin/claude-agent-tgbot сознательно не открывались через Read). Формат файла
# вопроса и detail-карточки взяты из уже прочитанных контрактов V2.3
# (design-2026-07-26-v2.3-question-fsm.md §1), V2.5
# (design-2026-07-26-v2.5-tg-cards.md §3/§9) и V2.4
# (design-2026-07-26-v2.4-permission-gate.md - контракт, для R12c читать
# разрешено явно); стиль тестов - из tests/test-agent-question.sh,
# tests/test-agent-tg-cards.sh и tests/test-agent-permit.sh (тесты, не
# реализация). Функции question_card/mode_send в R11 вызываются "как есть"
# тем же importlib-приемом, что и в test-agent-tg-cards.sh (публичный
# контракт V2.5 §3/§9), а не прочитаны как реализация.
#
# Правки после уточнения контракта (docs §2/§5/§8 дополнены координатором):
# аргументы alert-команды зафиксированы (агент/причина/qid/json-detail),
# код возврата question-reminders - про подкоманду, а не про исход вопросов,
# формат строки для битого файла вопроса зафиксирован, добавлен
# CLAUDE_AGENT_SNOOZE_S, R11 переформулирован на mode_send без 4-го
# аргумента, R12 получил третьего producer'а (claude-agent-permit).
#
# Ambiguity-заметки (см. итоговый отчет для полного списка):
# - do_alert-путь обычных алертов (реконсилер) намеренно НЕ гоняется -
#   публичного CLI-входа у него нет, а описанный риск этапа (честный
#   код возврата не должен протечь в путь обычных алертов) целиком
#   покрывается прямым вызовом mode_send без 4-го аргумента (R11);
# - точный текст, добавляемый после "агент %s: %s - %s" (V2.5 §3 упоминает
#   "agent_hints" в этом же предложении), не специфицирован - R11 проверяет
#   вхождение канонического куска строки, а не точное совпадение целиком.
set -u
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
ASK="$HERE/../bin/claude-agent-ask"
TGBOT="$HERE/../bin/claude-agent-tgbot"
PERMIT="$HERE/../bin/claude-agent-permit"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

jq_file() { # <file> <py-expr over dict/list d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
jq_str() { # <json-текст> <py-expr over d>
  python3 -c 'import json,sys
d=json.loads(sys.argv[1])
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
new_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

iso_diff_now() { # <iso8601 "...Z"> -> секунд от "сейчас" до метки (может быть отрицательным)
  python3 -c '
import datetime, sys
ts = sys.argv[1].replace("Z", "+00:00")
mark = datetime.datetime.fromisoformat(ts)
now = datetime.datetime.now(datetime.timezone.utc)
print((mark - now).total_seconds())
' "$1"
}

mk_event() { # <name> -> печатает путь к agent-dir
  local name="$1"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "reminder ladder unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
  echo "$ag"
}

ask_direct() { # <agent-dir> <event-key> <question> [options|-separated] -> stdout=qid
  # V2.3 §2: claude-agent-ask требует envelope_key реально в inflight -
  # синтетические ключи получают временный stub-конверт (как в
  # test-agent-question.sh / test-agent-tg-cards.sh).
  local dir="$1" key="$2" q="$3" opts="${4:-}"
  local stubbed=0
  if [[ ! -f "$dir/inbox/inflight/$key.json" ]]; then
    mkdir -p "$dir/inbox/inflight"
    printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"text":"stub-for-ask"}}\n' \
      "$key" > "$dir/inbox/inflight/$key.json"
    stubbed=1
  fi
  local args=(--question "$q")
  [[ -n "$opts" ]] && args+=(--options "$opts")
  CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" "$ASK" "${args[@]}"
  local rc=$?
  [[ "$stubbed" == 1 ]] && rm -f "$dir/inbox/inflight/$key.json"
  return $rc
}

mk_permit_agent() { # <name> -> agent-dir с ask-поясом ["Bash(git push:*)"] (V2.4 §2a, контракт для R12c)
  local name="$1"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "reminder ladder R12c - permission gate as third producer"
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
stage_inflight() { # <agent-dir> <key> - envelope_key обязан быть в inflight (V2.4 §2b/major 6)
  local dir="$1" key="$2"
  mkdir -p "$dir/inbox/inflight"
  printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"kind":"event","text":"stub-for-permit"}}\n' \
    "$key" > "$dir/inbox/inflight/$key.json"
}
unstage_inflight() { rm -f "$1/inbox/inflight/$2.json"; } # <agent-dir> <key>
call_hook() { # <agent-dir> <key> <tool_name> <tool_input-json> -> stdout хука, $? = exit code хука
  local dir="$1" key="$2" tool="$3" input="$4"
  python3 -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))
' "$tool" "$input" | CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" timeout 10 "$PERMIT" --hook
}

force_due() { # <qfile> - переставляет reminder.next_push_at в гарантированное прошлое
  python3 - "$1" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("reminder", {})["next_push_at"] = "2020-01-01T00:00:00Z"
json.dump(d, open(p, "w"), ensure_ascii=False)
PY
}

patch_question() { # <qfile> <key=json-value-литерал> ... - точечная правка полей файла вопроса
  local qf="$1"; shift
  python3 - "$qf" "$@" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    d[k] = json.loads(v)
json.dump(d, open(p, "w"), ensure_ascii=False)
PY
}

write_raw_question() { # <agent-dir> <qid> <envelope-key> <kind> <question-text> <options-json> <status> <next_push_at>
  local dir="$1" qid="$2" key="$3" kind="$4" q="$5" opts="$6" status="$7" npa="$8"
  mkdir -p "$dir/questions"
  python3 -c '
import json, sys
qid, key, kind, q, opts, status, npa, path = sys.argv[1:9]
d = {
  "qid": qid, "envelope_key": key, "asked_at": "2020-01-01T00:00:00Z", "kind": kind,
  "question": q, "options": json.loads(opts), "context": None,
  "status": status, "answer": None, "answered_at": None, "answered_by": None,
  "decision": None, "closed_by_envelope": None,
  "reminder": {"step": 0, "next_push_at": npa, "snoozed_until": None},
}
json.dump(d, open(path, "w"), ensure_ascii=False)
' "$qid" "$key" "$kind" "$q" "$opts" "$status" "$npa" "$dir/questions/$qid.json"
}

mk_alert_ok() { # <log-file> <script-path> - мок alert-команды: логирует argv, exit 0
  local log="$1" script="$2"
  cat > "$script" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$log"
printf '===\n' >> "$log"
EOF
  chmod +x "$script"
}
mk_alert_fail() { # <log-file> <script-path> - мок alert-команды: логирует argv, exit 1
  local log="$1" script="$2"
  cat > "$script" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$log"
printf '===\n' >> "$log"
exit 1
EOF
  chmod +x "$script"
}
alert_block_count() { # <log> -> число блоков (вызовов alert-команды)
  [[ -f "$1" ]] || { echo 0; return; }
  grep -c '^===$' "$1"
}
alert_block_argc() { # <log> <block-idx 1-based> -> число аргументов в этом блоке
  python3 - "$1" "$2" <<'PY'
import sys
path, bidx = sys.argv[1], int(sys.argv[2])
blocks, cur = [], []
for line in open(path):
    line = line.rstrip("\n")
    if line == "===":
        blocks.append(cur); cur = []
    else:
        cur.append(line)
print(len(blocks[bidx-1]) if bidx-1 < len(blocks) else -1)
PY
}
alert_block_field() { # <log> <block-idx 1-based> <arg-idx 0-based> -> значение позиционного аргумента
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, bidx, aidx = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
blocks, cur = [], []
for line in open(path):
    line = line.rstrip("\n")
    if line == "===":
        blocks.append(cur); cur = []
    else:
        cur.append(line)
b = blocks[bidx-1] if bidx-1 < len(blocks) else []
print(b[aidx] if aidx < len(b) else "")
PY
}

# --- тестовый шов §9 V2.5 (для R11): чистые функции tgbot загружаются
#     importlib'ом, как в test-agent-tg-cards.sh ---
TG_OUT=""; TG_ERR=""
tg_call() { # <funcname> <json-args...>
  local func="$1"; shift
  TG_OUT=$(python3 - "$TGBOT" "$func" "$@" 2>"$TMP/.tgerr" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
tgbot_path, func = sys.argv[1], sys.argv[2]
args = [json.loads(a) for a in sys.argv[3:]]
loader = SourceFileLoader("agent_tgbot_under_test_reminders", tgbot_path)
spec = importlib.util.spec_from_file_location("agent_tgbot_under_test_reminders", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
fn = getattr(mod, func)
result = fn(*args)
print(json.dumps(result, ensure_ascii=False))
PY
)
  local rc=$?
  TG_ERR="$(cat "$TMP/.tgerr" 2>/dev/null)"
  return $rc
}

# --- mock claude: режим ask_ok реально вызывает claude-agent-ask (для R12) ---
MOCK="$TMP/mock-claude"
export MOCK_ASK_BIN="$ASK"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
mode=$(cat "${MOCK_MODE_FILE:-/dev/null}" 2>/dev/null || echo ok)
case "$mode" in
  ok) echo '{"type":"result","result":"processed","total_cost_usd":0.01}' ;;
  ask_ok)
    "$MOCK_ASK_BIN" --question "R12 mock spawned question needing operator input" \
      >"${TMP_ASK_OUT:-/dev/null}" 2>"${TMP_ASK_ERR:-/dev/null}"
    echo '{"type":"result","result":"asked","total_cost_usd":0.01}' ;;
esac
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK" MOCK_MODE_FILE="$TMP/mock-mode"
export TMP_ASK_OUT="$TMP/ask-stdout" TMP_ASK_ERR="$TMP/ask-stderr"
echo ok > "$MOCK_MODE_FILE"

# =============================================================== R1
echo "=== R1: открытый вопрос, next_push_at в прошлом -> ровно один вызов alert-команды с 4-м аргументом; step=1, next_push_at сдвинут ==="
export CLAUDE_AGENT_REMINDER_LADDER_S="5,10,15,20"
AGR1=$(mk_event evtr1)
QID1=$(ask_direct "$AGR1" "r1-key" "R1 продолжать деплой?" "yes|no")
[[ -n "$QID1" ]] && ok || fail "R1: setup - вопрос создан"
QF1="$AGR1/questions/$QID1.json"
force_due "$QF1"
ALERT_LOG1="$TMP/r1-alert.log"
mk_alert_ok "$ALERT_LOG1" "$TMP/alert-ok-r1.sh"
OUT1=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r1.sh" "$RUN" question-reminders "$AGR1" 2>"$TMP/r1.err"); RC1=$?
[[ "$RC1" == 0 ]] && ok || fail "R1: exit 0 (got $RC1: $(cat "$TMP/r1.err"))"
[[ "$OUT1" == "$QID1 sent" ]] && ok || fail "R1: stdout '<qid> sent' (got: $OUT1)"
[[ "$(alert_block_count "$ALERT_LOG1")" == "1" ]] && ok || fail "R1: ровно один вызов alert-команды"
[[ "$(alert_block_argc "$ALERT_LOG1" 1)" == "4" ]] \
  && ok || fail "R1: вызов с 4 позиционными аргументами (got $(alert_block_argc "$ALERT_LOG1" 1))"
# §2 (уточнено): аргументы зафиксированы буквально - <короткое имя агента>
# <"вопрос ждет ответа"> <qid> <json-detail>; текст вопроса в 2-3-й аргумент
# НЕ кладется (только в json-detail).
[[ "$(alert_block_field "$ALERT_LOG1" 1 0)" == "evtr1" ]] \
  && ok || fail "R1: 1-й аргумент - короткое имя агента (got: $(alert_block_field "$ALERT_LOG1" 1 0))"
[[ "$(alert_block_field "$ALERT_LOG1" 1 1)" == "вопрос ждет ответа" ]] \
  && ok || fail "R1: 2-й аргумент - постоянная строка 'вопрос ждет ответа' (got: $(alert_block_field "$ALERT_LOG1" 1 1))"
[[ "$(alert_block_field "$ALERT_LOG1" 1 2)" == "$QID1" ]] \
  && ok || fail "R1: 3-й аргумент - qid (got: $(alert_block_field "$ALERT_LOG1" 1 2))"
DETAIL1=$(alert_block_field "$ALERT_LOG1" 1 3)
[[ "$(jq_str "$DETAIL1" 'd.get("kind")')" == "question" ]] \
  && ok || fail "R1: 4-й аргумент - JSON с kind=question (got: $DETAIL1)"
[[ "$(jq_str "$DETAIL1" 'd.get("agent")')" == "evtr1" ]] && ok || fail "R1: detail.agent = короткое имя агента"
[[ "$(jq_str "$DETAIL1" 'd.get("qid")')" == "$QID1" ]] && ok || fail "R1: qid в detail совпадает с qid вопроса"
[[ "$(jq_str "$DETAIL1" 'd.get("qkind")')" == "info" ]] && ok || fail "R1: qkind=info"
[[ "$(jq_str "$DETAIL1" 'd.get("text")')" == "R1 продолжать деплой?" ]] \
  && ok || fail "R1: text = текст вопроса (только в json-detail, не во 2-3-м аргументе)"
[[ "$(jq_file "$QF1" 'd.get("reminder",{}).get("step")')" == "1" ]] && ok || fail "R1: step стал 1"
DIFF1=$(iso_diff_now "$(jq_file "$QF1" 'd.get("reminder",{}).get("next_push_at")')")
python3 -c '
import sys
d = float(sys.argv[1])
assert 2.0 <= d <= 9.0, d
' "$DIFF1" && ok || fail "R1: next_push_at сдвинут на первую ступень лесенки (~5с, got diff=${DIFF1}с)"

# =============================================================== R2
echo "=== R2: сразу повторный вызов -> skip, второго пуша нет (next_push_at в будущем) ==="
OUT2=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r1.sh" "$RUN" question-reminders "$AGR1" 2>"$TMP/r2.err"); RC2=$?
[[ "$RC2" == 0 ]] && ok || fail "R2: exit 0 (got $RC2: $(cat "$TMP/r2.err"))"
[[ "$OUT2" == "$QID1 skip" ]] && ok || fail "R2: stdout '<qid> skip' (got: $OUT2)"
[[ "$(alert_block_count "$ALERT_LOG1")" == "1" ]] && ok || fail "R2: второго вызова alert-команды не произошло (все еще 1)"
[[ "$(jq_file "$QF1" 'd.get("reminder",{}).get("step")')" == "1" ]] && ok || fail "R2: step не изменился"

# =============================================================== R3
echo "=== R3: лесенка идет по ступеням; после последней ступени интервал держится ==="
export CLAUDE_AGENT_REMINDER_LADDER_S="2,3,4"
LADDER3=(2 3 4)
AGR3=$(mk_event evtr3)
QID3=$(ask_direct "$AGR3" "r3-key" "R3 продолжать?" "")
QF3="$AGR3/questions/$QID3.json"
force_due "$QF3"
ALERT_LOG3="$TMP/r3-alert.log"
mk_alert_ok "$ALERT_LOG3" "$TMP/alert-ok-r3.sh"
EXPECT_STEPS=(1 2 3 4)
for i in 0 1 2 3; do
  OUTR3=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r3.sh" "$RUN" question-reminders "$AGR3" 2>"$TMP/r3-$i.err"); RCR3=$?
  { [[ "$RCR3" == 0 && "$OUTR3" == "$QID3 sent" ]] && ok; } \
    || fail "R3 итерация $i: sent (got rc=$RCR3 out='$OUTR3')"
  GOT_STEP=$(jq_file "$QF3" 'd.get("reminder",{}).get("step")')
  [[ "$GOT_STEP" == "${EXPECT_STEPS[$i]}" ]] \
    && ok || fail "R3 итерация $i: step=${EXPECT_STEPS[$i]} (got $GOT_STEP)"
  IDX=$i; (( IDX > 2 )) && IDX=2   # min(step-1, last)
  EXPECT_S=${LADDER3[$IDX]}
  DIFF=$(iso_diff_now "$(jq_file "$QF3" 'd.get("reminder",{}).get("next_push_at")')")
  python3 -c '
import sys
d, want = float(sys.argv[1]), float(sys.argv[2])
assert want - 1.2 <= d <= want + 1.5, (d, want)
' "$DIFF" "$EXPECT_S" && ok || fail "R3 итерация $i: интервал ~${EXPECT_S}с (got diff=${DIFF}с)"
  if [[ "$i" != 3 ]]; then
    sleep "$(python3 -c "print(${LADDER3[$IDX]} + 0.3)")"
  fi
done

# =============================================================== R4
echo "=== R4: alert-команда вернула ненулевой код -> fail; step/next_push_at не изменились; повтор на следующем тике доходит ==="
export CLAUDE_AGENT_REMINDER_LADDER_S="5,10"
AGR4=$(mk_event evtr4)
QID4=$(ask_direct "$AGR4" "r4-key" "R4 продолжать?" "")
QF4="$AGR4/questions/$QID4.json"
force_due "$QF4"
ALERT_LOG4="$TMP/r4-alert.log"
mk_alert_fail "$ALERT_LOG4" "$TMP/alert-fail-r4.sh"
STEP_BEFORE4=$(jq_file "$QF4" 'd.get("reminder",{}).get("step")')
NPA_BEFORE4=$(jq_file "$QF4" 'd.get("reminder",{}).get("next_push_at")')
OUT4=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-fail-r4.sh" "$RUN" question-reminders "$AGR4" 2>"$TMP/r4.err"); RC4=$?
# §2 (уточнено): код возврата подкоманды - про саму подкоманду, не про исход
# по вопросам: 0, сколько бы fail ни было в строках; ненулевой - только на
# ошибке употребления (см. R4b ниже).
[[ "$RC4" == 0 ]] \
  && ok || fail "R4: код возврата подкоманды остается 0 несмотря на fail по вопросу (got $RC4: $(cat "$TMP/r4.err"))"
[[ "$OUT4" == "$QID4 fail" ]] && ok || fail "R4: stdout '<qid> fail' (got: $OUT4)"
[[ "$(alert_block_count "$ALERT_LOG4")" == "1" ]] && ok || fail "R4: alert-команда реально вызвана один раз"
[[ "$(jq_file "$QF4" 'd.get("reminder",{}).get("step")')" == "$STEP_BEFORE4" ]] \
  && ok || fail "R4: step не изменился при неуспехе доставки"
[[ "$(jq_file "$QF4" 'd.get("reminder",{}).get("next_push_at")')" == "$NPA_BEFORE4" ]] \
  && ok || fail "R4: next_push_at не изменился при неуспехе доставки"
ALERT_LOG4B="$TMP/r4b-alert.log"
mk_alert_ok "$ALERT_LOG4B" "$TMP/alert-ok-r4.sh"
OUT4B=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r4.sh" "$RUN" question-reminders "$AGR4" 2>"$TMP/r4b.err")
[[ "$OUT4B" == "$QID4 sent" ]] \
  && ok || fail "R4: на следующем тике (с рабочей alert-командой) та же ступень доходит - sent (got: $OUT4B)"
[[ "$(jq_file "$QF4" 'd.get("reminder",{}).get("step")')" == "1" ]] \
  && ok || fail "R4: после успешного повтора step наконец стал 1"

echo "--- R4b: ненулевой код возврата бывает только на ошибке употребления (несуществующий agent-dir) ---"
"$RUN" question-reminders "$TMP/does-not-exist-agent-dir-r4" >/dev/null 2>"$TMP/r4misuse.err"; RC4MISUSE=$?
[[ "$RC4MISUSE" != 0 ]] \
  && ok || fail "R4b: несуществующий agent-dir -> ненулевой код возврата (ошибка употребления, got $RC4MISUSE)"

# =============================================================== R5
echo "=== R5: вопрос с непустым answered_at -> skip, пуша нет ==="
AGR5=$(mk_event evtr5)
QID5=$(ask_direct "$AGR5" "r5-key" "R5 вопрос?" "")
QF5="$AGR5/questions/$QID5.json"
force_due "$QF5"
patch_question "$QF5" 'answered_at="2020-01-01T00:00:00Z"'
ALERT_LOG5="$TMP/r5-alert.log"
mk_alert_ok "$ALERT_LOG5" "$TMP/alert-ok-r5.sh"
OUT5=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r5.sh" "$RUN" question-reminders "$AGR5" 2>"$TMP/r5.err")
[[ "$OUT5" == "$QID5 skip" ]] && ok || fail "R5: stdout '<qid> skip' (got: $OUT5)"
[[ ! -f "$ALERT_LOG5" ]] && ok || fail "R5: alert-команда не вызывалась (answered_at непуст)"
[[ "$(jq_file "$QF5" 'd.get("reminder",{}).get("step")')" == "0" ]] && ok || fail "R5: step не изменился"

# =============================================================== R6
echo "=== R6: закрытый вопрос -> skip, пуша нет ==="
AGR6=$(mk_event evtr6)
QID6=$(ask_direct "$AGR6" "r6-key" "R6 вопрос?" "")
QF6="$AGR6/questions/$QID6.json"
force_due "$QF6"
patch_question "$QF6" 'status="closed"'
ALERT_LOG6="$TMP/r6-alert.log"
mk_alert_ok "$ALERT_LOG6" "$TMP/alert-ok-r6.sh"
OUT6=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r6.sh" "$RUN" question-reminders "$AGR6" 2>"$TMP/r6.err")
[[ "$OUT6" == "$QID6 skip" ]] && ok || fail "R6: stdout '<qid> skip' (got: $OUT6)"
[[ ! -f "$ALERT_LOG6" ]] && ok || fail "R6: alert-команда не вызывалась (status=closed)"

# =============================================================== R7
echo "=== R7a: снуз (CLAUDE_AGENT_SNOOZE_S=50) -> snoozed_until=now+50с, пуша нет, step не двигается; повторный снуз переустанавливает то же (абсолютность, не аддитивность) ==="
# Длинная (относительно паузы между тапами) длительность снуза нужна, чтобы
# отличить "абсолютную переустановку" от аддитивного (+=) бага: при баге
# разница между двумя snoozed_until была бы ~50с, при правильном поведении -
# ~1.1с (реальное время между вызовами). Более короткая длительность (как в
# фазе R7b) не дала бы такого разделения.
export CLAUDE_AGENT_SNOOZE_S=50
AGR7A=$(mk_event evtr7a)
QID7A=$(ask_direct "$AGR7A" "r7a-key" "R7a продолжать?" "")
QF7A="$AGR7A/questions/$QID7A.json"
force_due "$QF7A"
STEP_BEFORE7A=$(jq_file "$QF7A" 'd.get("reminder",{}).get("step")')
"$RUN" question-snooze "$AGR7A" --qid "$QID7A" >/dev/null 2>"$TMP/r7a1.err"; RCS7A=$?
[[ "$RCS7A" == 0 ]] && ok || fail "R7a: снуз на открытом вопросе - exit 0 (got $RCS7A: $(cat "$TMP/r7a1.err"))"
SU7A=$(jq_file "$QF7A" 'd.get("reminder",{}).get("snoozed_until")')
DIFF7A=$(iso_diff_now "$SU7A")
python3 -c '
import sys
d = float(sys.argv[1])
assert 45.0 <= d <= 58.0, d
' "$DIFF7A" && ok || fail "R7a: snoozed_until ~= now+CLAUDE_AGENT_SNOOZE_S (50с, got diff=${DIFF7A}с)"
[[ "$(jq_file "$QF7A" 'd.get("reminder",{}).get("step")')" == "$STEP_BEFORE7A" ]] \
  && ok || fail "R7a: снуз не двигает step"
ALERT_LOG7A="$TMP/r7a-alert.log"
mk_alert_ok "$ALERT_LOG7A" "$TMP/alert-ok-r7a.sh"
OUT7A=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r7a.sh" "$RUN" question-reminders "$AGR7A" 2>"$TMP/r7a2.err")
[[ "$OUT7A" == "$QID7A skip" ]] \
  && ok || fail "R7a: пуша нет пока snoozed_until в будущем, несмотря на просроченный next_push_at (got: $OUT7A)"
[[ ! -f "$ALERT_LOG7A" ]] && ok || fail "R7a: alert-команда не вызывалась во время снуза"
sleep 1.1
"$RUN" question-snooze "$AGR7A" --qid "$QID7A" >/dev/null 2>"$TMP/r7a3.err"
SU7B=$(jq_file "$QF7A" 'd.get("reminder",{}).get("snoozed_until")')
[[ "$SU7A" != "$SU7B" ]] && ok || fail "R7a: повторный снуз реально переустановил значение"
DIFF_BETWEEN=$(python3 -c '
import datetime, sys
def p(s): return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
a, b = p(sys.argv[1]), p(sys.argv[2])
print((b - a).total_seconds())
' "$SU7A" "$SU7B")
# Абсолютность (не аддитивность): разница между двумя snoozed_until обязана
# равняться реальному времени между вызовами (~1.1с), а не +50с, которые
# накопились бы при аддитивном (+=) баге.
python3 -c '
import sys
d = float(sys.argv[1])
assert 0.5 <= d <= 5.0, d
' "$DIFF_BETWEEN" \
  && ok || fail "R7a: повторный снуз не накапливает длительность (абсолютная переустановка), diff=${DIFF_BETWEEN}с"

echo "=== R7b: после истечения снуза (короткий CLAUDE_AGENT_SNOOZE_S) лесенка продолжается с ТОЙ ЖЕ ступени, а не с первой ==="
export CLAUDE_AGENT_REMINDER_LADDER_S="3,6,9"
LADDER7B=(3 6 9)
AGR7B=$(mk_event evtr7b)
QID7B=$(ask_direct "$AGR7B" "r7b-key" "R7b продолжать?" "")
QF7B="$AGR7B/questions/$QID7B.json"
force_due "$QF7B"
ALERT_LOG7B="$TMP/r7b-alert.log"
mk_alert_ok "$ALERT_LOG7B" "$TMP/alert-ok-r7b.sh"
OUT7B1=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r7b.sh" "$RUN" question-reminders "$AGR7B" 2>"$TMP/r7b1.err")
[[ "$OUT7B1" == "$QID7B sent" ]] && ok || fail "R7b: setup - первая отправка (got: $OUT7B1)"
[[ "$(jq_file "$QF7B" 'd.get("reminder",{}).get("step")')" == "1" ]] \
  && ok || fail "R7b: setup - step стал 1 после первой отправки"
force_due "$QF7B"   # изолируем переменную: next_push_at снова в прошлом, единственная причина skip ниже - снуз
export CLAUDE_AGENT_SNOOZE_S=2
"$RUN" question-snooze "$AGR7B" --qid "$QID7B" >/dev/null 2>"$TMP/r7b2.err"
OUT7B2=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r7b.sh" "$RUN" question-reminders "$AGR7B" 2>"$TMP/r7b3.err")
[[ "$OUT7B2" == "$QID7B skip" ]] \
  && ok || fail "R7b: пуша нет пока короткий снуз не истек, несмотря на просроченный next_push_at (got: $OUT7B2)"
sleep 2.3
OUT7B3=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r7b.sh" "$RUN" question-reminders "$AGR7B" 2>"$TMP/r7b4.err")
[[ "$OUT7B3" == "$QID7B sent" ]] \
  && ok || fail "R7b: после истечения снуза пуш идет снова (got: $OUT7B3)"
[[ "$(jq_file "$QF7B" 'd.get("reminder",{}).get("step")')" == "2" ]] \
  && ok || fail "R7b: step продолжился со 2 (не сброшен обратно на 1 снузом)"
DIFF7B=$(iso_diff_now "$(jq_file "$QF7B" 'd.get("reminder",{}).get("next_push_at")')")
# Если бы снуз ошибочно сбрасывал ступень на первую, интервал был бы
# LADDER7B[0]=3с, а не LADDER7B[1]=6с - именно это и отличает баг от фикса.
python3 -c '
import sys
d, want = float(sys.argv[1]), float(sys.argv[2])
assert want - 1.2 <= d <= want + 1.5, (d, want)
' "$DIFF7B" "${LADDER7B[1]}" \
  && ok || fail "R7b: интервал после снуза = ступень ${LADDER7B[1]}с (та же, что до снуза + 1), не сброшен на первую (got diff=${DIFF7B}с)"
unset CLAUDE_AGENT_SNOOZE_S

# =============================================================== R8
echo "=== R8: снуз на закрытый/отвеченный вопрос -> exit 2, файл не изменен ==="
AGR8=$(mk_event evtr8)
QID8C=$(ask_direct "$AGR8" "r8c-key" "R8 закрытый?" "")
QF8C="$AGR8/questions/$QID8C.json"
patch_question "$QF8C" 'status="closed"' 'answer="x"' 'answered_at="2020-01-01T00:00:00Z"'
BEFORE8C=$(cat "$QF8C")
"$RUN" question-snooze "$AGR8" --qid "$QID8C" >/dev/null 2>"$TMP/r8c.err"; RC8C=$?
# ВАЖНО: claude-agent-run возвращает exit 2 и для "unknown command" (общий
# фолбэк несуществующей подкоманды) - тот же код, что спека требует для
# "снуз на закрытом вопросе". Голый check на exit-код 2 был бы зеленым
# ПРОСТО ПОТОМУ, ЧТО подкоманды еще нет - ложноположительный результат.
# Поэтому дополнительно исключаем совпадение с этим фолбэком по stderr.
[[ "$RC8C" == 2 && "$(cat "$TMP/r8c.err")" != *"unknown command"* ]] \
  && ok || fail "R8: снуз на закрытом вопросе -> exit 2 (got $RC8C: $(cat "$TMP/r8c.err"))"
AFTER8C=$(cat "$QF8C")
[[ "$BEFORE8C" == "$AFTER8C" ]] && ok || fail "R8: файл закрытого вопроса не изменен снузом"

QID8A=$(ask_direct "$AGR8" "r8a-key" "R8 отвеченный?" "")
QF8A="$AGR8/questions/$QID8A.json"
patch_question "$QF8A" 'answered_at="2020-01-01T00:00:00Z"'   # status остается open, но уже отвечен
BEFORE8A=$(cat "$QF8A")
"$RUN" question-snooze "$AGR8" --qid "$QID8A" >/dev/null 2>"$TMP/r8a.err"; RC8A=$?
[[ "$RC8A" == 2 && "$(cat "$TMP/r8a.err")" != *"unknown command"* ]] \
  && ok || fail "R8: снуз на отвеченном (answered_at непуст) вопросе -> exit 2 (got $RC8A: $(cat "$TMP/r8a.err"))"
AFTER8A=$(cat "$QF8A")
[[ "$BEFORE8A" == "$AFTER8A" ]] && ok || fail "R8: файл отвеченного вопроса не изменен снузом"

# =============================================================== R9
echo "=== R9: битый JSON одного файла вопроса -> skip по нему, остальные вопросы того же агента обрабатываются ==="
AGR9=$(mk_event evtr9)
QID9A=$(ask_direct "$AGR9" "r9a-key" "R9 первый вопрос?" "")
force_due "$AGR9/questions/$QID9A.json"
QID9B=$(new_uuid)
write_raw_question "$AGR9" "$QID9B" "r9b-key" "info" "R9 второй вопрос?" '[]' "open" "2020-01-01T00:00:00Z"
CORRUPT9=$(new_uuid)
printf '{not valid json' > "$AGR9/questions/$CORRUPT9.json"
ALERT_LOG9="$TMP/r9-alert.log"
mk_alert_ok "$ALERT_LOG9" "$TMP/alert-ok-r9.sh"
OUT9=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r9.sh" "$RUN" question-reminders "$AGR9" 2>"$TMP/r9.err"); RC9=$?
[[ "$RC9" == 0 ]] && ok || fail "R9: подкоманда не падает на битом файле (exit 0, got $RC9: $(cat "$TMP/r9.err"))"
echo "$OUT9" | grep -qxF "$QID9A sent" \
  && ok || fail "R9: первый (валидный) вопрос отправлен несмотря на соседний битый файл (out: $OUT9)"
echo "$OUT9" | grep -qxF "$QID9B sent" \
  && ok || fail "R9: второй (валидный) вопрос отправлен несмотря на соседний битый файл (out: $OUT9)"
# §2 (уточнено): битый файл дает строку "<basename-без-.json> skip".
echo "$OUT9" | grep -qxF "$CORRUPT9 skip" \
  && ok || fail "R9: битый файл дает строку '<basename> skip' (out: $OUT9)"
[[ "$(echo "$OUT9" | grep -c .)" == "3" ]] \
  && ok || fail "R9: ровно три строки на выходе - 2 валидных + 1 битый (out: $OUT9)"
[[ "$(alert_block_count "$ALERT_LOG9")" == "2" ]] \
  && ok || fail "R9: ровно два вызова alert-команды - только по валидным вопросам (got $(alert_block_count "$ALERT_LOG9"))"

# =============================================================== R10
echo "=== R10 (переформулирован, аудит V2.6 minor 1): CLAUDE_AGENT_ALERT_CMD не задан -> ни пушей, ни изменений файла, код возврата 0, строка 'skip' (не 'fail' - полный no-op) ==="
AGR10=$(mk_event evtr10)
QID10=$(ask_direct "$AGR10" "r10-key" "R10 вопрос?" "")
QF10="$AGR10/questions/$QID10.json"
force_due "$QF10"
BEFORE10=$(cat "$QF10")
unset CLAUDE_AGENT_ALERT_CMD
OUT10=$("$RUN" question-reminders "$AGR10" 2>"$TMP/r10.err"); RC10=$?
[[ "$RC10" == 0 ]] && ok || fail "R10: exit 0 без alert-команды (got $RC10: $(cat "$TMP/r10.err"))"
[[ "$OUT10" == "$QID10 skip" ]] \
  && ok || fail "R10: строка '<qid> skip', не 'fail' - §2 контракта: это полный no-op (got: $OUT10)"
AFTER10=$(cat "$QF10")
[[ "$BEFORE10" == "$AFTER10" ]] && ok || fail "R10: файл вопроса не изменился без alert-команды"

# =============================================================== R11
echo "=== R11 (переформулирован): mode_send БЕЗ 4-го аргумента - голден V2.5 (текст, отсутствие клавиатуры, код возврата); честный код доставки не протекает в обычный путь ==="
echo "--- R11a: успешная доставка - текст в формате 'агент %s: %s - %s', reply_markup отсутствует ---"
R11_AGENT="agentR11"; R11_REASON="some-reason"; R11_DETAIL="some human detail text"
CALLS_R11A=$(CLAUDE_AGENT_TG_TOKEN="TESTTOKEN" CLAUDE_AGENT_TG_WHITELIST="7001" python3 - "$TGBOT" "$R11_AGENT" "$R11_REASON" "$R11_DETAIL" <<'PY' 2>"$TMP/r11a.pyerr"
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
tgbot_path, agent, reason, detail = sys.argv[1:5]
loader = SourceFileLoader("r11a_mod", tgbot_path)
spec = importlib.util.spec_from_file_location("r11a_mod", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
calls = []
def fake_api(token, proxy, method, http_timeout=30, **kw):
    calls.append({"method": method, "text": kw.get("text"), "has_markup": "reply_markup" in kw})
    return {"result": {"message_id": 1}}
mod.api = fake_api
rc = mod.mode_send([agent, reason, detail])
print(json.dumps({"rc": rc, "calls": calls}))
PY
); RC_R11A=$?
[[ "$RC_R11A" == 0 ]] && ok || fail "R11a: обертка не падает ($(cat "$TMP/r11a.pyerr"))"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(len(d["calls"]))' "$CALLS_R11A")" == "1" ]] \
  && ok || fail "R11a: ровно один вызов api() (sendMessage) (got: $CALLS_R11A)"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["calls"][0]["method"])' "$CALLS_R11A")" == "sendMessage" ]] \
  && ok || fail "R11a: метод - sendMessage (got: $CALLS_R11A)"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["calls"][0]["has_markup"])' "$CALLS_R11A")" == "False" ]] \
  && ok || fail "R11a: reply_markup отсутствует - как в V2.4/V2.5 голден (got: $CALLS_R11A)"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(("агент agentR11: some-reason - some human detail text") in (d["calls"][0]["text"] or ""))' "$CALLS_R11A")" == "True" ]] \
  && ok || fail "R11a: текст содержит канонический формат 'агент %s: %s - %s' (got: $CALLS_R11A)"

echo "--- R11b: доставка упала (симулированный сбой Telegram) - код возврата ВСЕ РАВНО не протекает в обычный путь (регресс V2.4 §4) ---"
python3 - "$TGBOT" <<'PY' >"$TMP/r11b.out" 2>"$TMP/r11b.err"
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
tgbot_path = sys.argv[1]
loader = SourceFileLoader("r11b_mod", tgbot_path)
spec = importlib.util.spec_from_file_location("r11b_mod", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
def failing_api(token, proxy, method, http_timeout=30, **kw):
    raise RuntimeError("simulated telegram network failure")
mod.api = failing_api
rc = mod.mode_send(["agentR11fail", "some-reason", "some detail text"])
print(json.dumps({"rc": rc}))
PY
RC_R11B=$?
# §4: "Обычные алерты (без четвертого аргумента): поведение и код возврата НЕ
# меняются". Если бы honest-код доставки (введенный этим этапом для
# question-пути) протек в обычный путь, исключение fake_api дошло бы наружу
# и уронило бы сам python-процесс (ненулевой $?) - это и есть наблюдаемый
# сигнал утечки, без чтения реализации mode_send.
[[ "$RC_R11B" == 0 ]] \
  && ok || fail "R11b: сбой доставки НЕ протекает как исключение/ненулевой код в обычный путь (got rc=$RC_R11B: $(cat "$TMP/r11b.err"))"

# =============================================================== R12
echo "=== R12 (регресс §1): claude-agent-ask, обычный прогон и хук подтверждений не зовут alert-команду с question-detail ==="
echo "--- R12a: claude-agent-ask сам никогда не вызывает alert-команду ---"
AGR12A=$(mk_event evtr12a)
ALERT_LOG12A="$TMP/r12a-alert.log"
mk_alert_ok "$ALERT_LOG12A" "$TMP/alert-ok-r12a.sh"
export CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r12a.sh"
QID12A=$(ask_direct "$AGR12A" "r12a-key" "R12a вопрос?" "")
unset CLAUDE_AGENT_ALERT_CMD
[[ -n "$QID12A" ]] && ok || fail "R12a: setup - вопрос создан"
[[ ! -f "$ALERT_LOG12A" ]] && ok || fail "R12a: claude-agent-ask не вызывает alert-команду вовсе"

echo "--- R12b: прогон, завершившийся вопросом, не шлет alert-команду с question-detail ---"
AGR12B=$(mk_event evtr12b)
"$RUN" spool-put evtr12b --text "r12b-event" >/dev/null
"$RUN" intake "$AGR12B" >/dev/null
ALERT_LOG12B="$TMP/r12b-alert.log"
mk_alert_ok "$ALERT_LOG12B" "$TMP/alert-ok-r12b.sh"
echo ask_ok > "$MOCK_MODE_FILE"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r12b.sh" "$RUN" step "$AGR12B" >/dev/null 2>"$TMP/r12b.err"
echo ok > "$MOCK_MODE_FILE"
QFILES12B=("$AGR12B"/questions/*.json)
[[ -f "${QFILES12B[0]:-/nonexistent}" ]] && ok || fail "R12b: setup - вопрос реально создан мок-агентом в прогоне"
if [[ -f "$ALERT_LOG12B" ]]; then
  python3 - "$ALERT_LOG12B" <<'PY' >"$TMP/r12b_check.out" 2>"$TMP/r12b_check.err"
import json, sys
log = sys.argv[1]
blocks, cur = [], []
for line in open(log):
    line = line.rstrip("\n")
    if line == "===":
        blocks.append(cur); cur = []
    else:
        cur.append(line)
for block in blocks:
    for arg in block:
        try:
            d = json.loads(arg)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("kind") == "question":
            raise AssertionError("прогон вызвал alert-команду с question-detail: %r" % (d,))
print("OK")
PY
  [[ "$(cat "$TMP/r12b_check.out")" == "OK" ]] \
    && ok || fail "R12b: прогон не шлет question-detail напрямую ($(cat "$TMP/r12b_check.err"))"
else
  ok  # alert-команда вообще не вызвана прогоном - тоже валидно ("ни runner... не шлет карточку")
fi

echo "--- R12c: хук подтверждений (claude-agent-permit --hook, контракт V2.4) - третий producer, тоже не зовет alert-команду ---"
# V2.4 §2/§2b: вызов Bash-команды, попадающей под permissions.ask, без
# погашенного токена -> хук создает вопрос kind=permission (тем же кодом,
# что claude-agent-ask) и возвращает deny. Барьер V2.6 §1 требует, чтобы ЭТО
# создание вопроса тоже не сопровождалось прямым вызовом alert-команды.
AGR12C=$(mk_permit_agent evtr12c)
ALERT_LOG12C="$TMP/r12c-alert.log"
mk_alert_ok "$ALERT_LOG12C" "$TMP/alert-ok-r12c.sh"
stage_inflight "$AGR12C" "r12c-key"
HOOKOUT12C=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r12c.sh" call_hook "$AGR12C" "r12c-key" "Bash" '{"command":"git push origin main"}' 2>"$TMP/r12c.err")
unstage_inflight "$AGR12C" "r12c-key"
QFILES12C=("$AGR12C"/questions/*.json)
[[ -f "${QFILES12C[0]:-/nonexistent}" ]] \
  && ok || fail "R12c: setup - хук подтверждений реально создал вопрос (kind=permission) (hook stdout: $HOOKOUT12C, stderr: $(cat "$TMP/r12c.err"))"
if [[ -n "${QFILES12C[0]:-}" ]]; then
  [[ "$(jq_file "${QFILES12C[0]}" 'd.get("kind")')" == "permission" ]] \
    && ok || fail "R12c: setup - вопрос действительно kind=permission"
fi
if [[ -f "$ALERT_LOG12C" ]]; then
  python3 - "$ALERT_LOG12C" <<'PY' >"$TMP/r12c_check.out" 2>"$TMP/r12c_check.err"
import json, sys
log = sys.argv[1]
blocks, cur = [], []
for line in open(log):
    line = line.rstrip("\n")
    if line == "===":
        blocks.append(cur); cur = []
    else:
        cur.append(line)
for block in blocks:
    for arg in block:
        try:
            d = json.loads(arg)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("kind") == "question":
            raise AssertionError("хук подтверждений вызвал alert-команду с question-detail: %r" % (d,))
print("OK")
PY
  [[ "$(cat "$TMP/r12c_check.out")" == "OK" ]] \
    && ok || fail "R12c: хук подтверждений не шлет question-detail напрямую ($(cat "$TMP/r12c_check.err"))"
else
  ok  # alert-команда вообще не вызвана хуком - тоже валидно (третий producer барьера)
fi

# =============================================================== R13
echo "=== R13: агент без открытых вопросов -> подкоманда ничего не печатает и ничего не пишет ==="
AGR13=$(mk_event evtr13)
ALERT_LOG13="$TMP/r13-alert.log"
mk_alert_ok "$ALERT_LOG13" "$TMP/alert-ok-r13.sh"
OUT13=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r13.sh" "$RUN" question-reminders "$AGR13" 2>"$TMP/r13.err"); RC13=$?
[[ "$RC13" == 0 ]] && ok || fail "R13: exit 0 для агента без вопросов (got $RC13: $(cat "$TMP/r13.err"))"
[[ -z "$OUT13" ]] && ok || fail "R13: stdout пуст (got: $OUT13)"
[[ ! -f "$ALERT_LOG13" ]] && ok || fail "R13: alert-команда не вызывалась"
[[ ! -d "$AGR13/questions" || -z "$(ls -A "$AGR13/questions" 2>/dev/null)" ]] \
  && ok || fail "R13: каталог questions/ не создан и не изменен"

# =========================================================== R15 (фикс-пак)
echo "=== R15 (blocker, сквозной стык): argv ровно как формирует alert_question -> json-detail из 4-го аргумента, карточка с кнопками, запись в sent_map ==="
QID15=$(new_uuid)
DETAIL15=$(python3 -c 'import json,sys
print(json.dumps({"kind":"question","agent":"evtr15","qid":sys.argv[1],
                  "qkind":"info","text":"R15 продолжать?","options":["yes","no"]},
                 ensure_ascii=False))' "$QID15")
SENT15="$TMP/sent15.json"
RES15=$(CLAUDE_AGENT_TG_TOKEN="TESTTOKEN" CLAUDE_AGENT_TG_WHITELIST="7001" \
  CLAUDE_AGENT_TG_SENT_MAP="$SENT15" python3 - "$TGBOT" "$QID15" "$DETAIL15" <<'PY'
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
tgbot_path, qid, detail = sys.argv[1:4]
loader = SourceFileLoader("r15_mod", tgbot_path)
spec = importlib.util.spec_from_file_location("r15_mod", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
calls = []
def fake_api(token, proxy, method, http_timeout=30, **kw):
    calls.append({"method": method, "text": kw.get("text"),
                  "reply_markup": kw.get("reply_markup")})
    return {"result": {"message_id": 1}}
mod.api = fake_api
# argv - ровно то, что alert_question (bin/claude-agent-run) реально кладет
# в CLAUDE_AGENT_ALERT_CMD: [agent, "вопрос ждет ответа", qid, json-detail]
rc = mod.mode_send(["evtr15", "вопрос ждет ответа", qid, detail])
print(json.dumps({"rc": rc, "calls": calls}))
PY
); RC_R15=$?
[[ "$RC_R15" == 0 ]] && ok || fail "R15: обертка не падает"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["rc"])' "$RES15")" == "0" ]] \
  && ok || fail "R15: доставка успешна -> код 0 (got: $RES15)"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(len(d["calls"]))' "$RES15")" == "1" ]] \
  && ok || fail "R15: ровно один вызов api() (got: $RES15)"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("вопрос" in (d["calls"][0]["text"] or ""))' "$RES15")" == "True" ]] \
  && ok || fail "R15: текст - карточка вопроса (заголовок содержит 'вопрос'), не обычный алерт (got: $RES15)"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["calls"][0]["reply_markup"] is not None)' "$RES15")" == "True" ]] \
  && ok || fail "R15: карточка с клавиатурой - json-detail реально распознан из 4-го аргумента (got: $RES15)"
[[ -f "$SENT15" ]] && ok || fail "R15: sent_map записан"
REGOK15=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(any(v.get("kind") == "question" and v.get("qid") == sys.argv[2] for v in d.values()))
' "$SENT15" "$QID15" 2>/dev/null || echo False)
[[ "$REGOK15" == "True" ]] \
  && ok || fail "R15: запись в sent_map с kind=question и правильным qid (файл: $(cat "$SENT15" 2>/dev/null))"

echo "--- R15b: 4-й аргумент мусором (не JSON) -> обычный текст-алерт, но код возврата честный (это question-вызов по числу аргументов) ---"
RES15B=$(CLAUDE_AGENT_TG_TOKEN="TESTTOKEN" CLAUDE_AGENT_TG_WHITELIST="7001" \
  python3 - "$TGBOT" "$QID15" <<'PY'
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
tgbot_path, qid = sys.argv[1], sys.argv[2]
loader = SourceFileLoader("r15b_mod", tgbot_path)
spec = importlib.util.spec_from_file_location("r15b_mod", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
def failing_api(token, proxy, method, http_timeout=30, **kw):
    raise RuntimeError("simulated transport failure")
mod.api = failing_api
rc = mod.mode_send(["evtr15b", "вопрос ждет ответа", qid, "not-a-json-blob"])
print(json.dumps({"rc": rc}))
PY
); RC_R15B=$?
[[ "$RC_R15B" == 0 ]] && ok || fail "R15b: обертка не падает"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["rc"])' "$RES15B")" != "0" ]] \
  && ok || fail "R15b: 4-й аргумент - мусор, доставка не удалась -> ненулевой код (got: $RES15B)"

# =============================================================== R16
echo "=== R16 (major): нет токена/whitelist -> question-вызов дает ненулевой код; обычный алерт - код 0 (регресс) ==="
DETAIL16=$(python3 -c 'import json, uuid
print(json.dumps({"kind":"question","agent":"evtr16","qid":str(uuid.uuid4()),
                  "qkind":"info","text":"r16?","options":[]}, ensure_ascii=False))')
RC16Q=$(CLAUDE_AGENT_TG_TOKEN= CLAUDE_AGENT_TG_WHITELIST= python3 - "$TGBOT" "$DETAIL16" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
tgbot_path, detail = sys.argv[1], sys.argv[2]
loader = SourceFileLoader("r16q", tgbot_path)
spec = importlib.util.spec_from_file_location("r16q", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(mod.mode_send(["evtr16", "вопрос ждет ответа", "qid-arg", detail]))
PY
)
[[ "$RC16Q" != "0" ]] && ok || fail "R16: question-вызов без токена/whitelist -> ненулевой код (got: $RC16Q)"
RC16O=$(CLAUDE_AGENT_TG_TOKEN= CLAUDE_AGENT_TG_WHITELIST= python3 - "$TGBOT" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
tgbot_path = sys.argv[1]
loader = SourceFileLoader("r16o", tgbot_path)
spec = importlib.util.spec_from_file_location("r16o", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(mod.mode_send(["evtr16", "reason", "detail-text"]))
PY
)
[[ "$RC16O" == "0" ]] \
  && ok || fail "R16: обычный алерт без токена/whitelist -> код 0 (регресс, got: $RC16O)"

# =============================================================== R17
echo "=== R17 (major): решение о ступени - заново под локом; вмешательство между чтением и записью не даёт ступени продвинуться ==="
export CLAUDE_AGENT_REMINDER_LADDER_S="5,10"
echo "--- R17a: конкурентно (в момент доставки) вопрос стал answered -> step не продвинут ---"
AGR17A=$(mk_event evtr17a)
QID17A=$(ask_direct "$AGR17A" "r17a-key" "R17a?" "")
QF17A="$AGR17A/questions/$QID17A.json"
force_due "$QF17A"
cat > "$TMP/alert-race-answer.sh" <<EOF
#!/bin/sh
python3 -c "
import json
p = '$QF17A'
d = json.load(open(p))
d['answered_at'] = '2020-01-01T00:00:00Z'
json.dump(d, open(p, 'w'), ensure_ascii=False)
"
exit 0
EOF
chmod +x "$TMP/alert-race-answer.sh"
OUT17A=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-race-answer.sh" "$RUN" question-reminders "$AGR17A" 2>"$TMP/r17a.err")
[[ "$OUT17A" == "$QID17A sent" ]] && ok || fail "R17a: доставка отработала (got: $OUT17A)"
[[ "$(jq_file "$QF17A" 'd.get("reminder",{}).get("step")')" == "0" ]] \
  && ok || fail "R17a: конкурентный ответ между чтением и записью -> step НЕ продвинут"
[[ "$(jq_file "$QF17A" 'd.get("answered_at")')" == "2020-01-01T00:00:00Z" ]] \
  && ok || fail "R17a: answered_at из гонки сохранился (мутатор не затер его)"

echo "--- R17b: конкурентно вопрос закрыт -> step не продвинут ---"
AGR17B=$(mk_event evtr17b)
QID17B=$(ask_direct "$AGR17B" "r17b-key" "R17b?" "")
QF17B="$AGR17B/questions/$QID17B.json"
force_due "$QF17B"
cat > "$TMP/alert-race-close.sh" <<EOF
#!/bin/sh
python3 -c "
import json
p = '$QF17B'
d = json.load(open(p))
d['status'] = 'closed'
json.dump(d, open(p, 'w'), ensure_ascii=False)
"
exit 0
EOF
chmod +x "$TMP/alert-race-close.sh"
OUT17B=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-race-close.sh" "$RUN" question-reminders "$AGR17B" 2>"$TMP/r17b.err")
[[ "$OUT17B" == "$QID17B sent" ]] && ok || fail "R17b: доставка отработала (got: $OUT17B)"
[[ "$(jq_file "$QF17B" 'd.get("reminder",{}).get("step")')" == "0" ]] \
  && ok || fail "R17b: конкурентное закрытие -> step НЕ продвинут"

echo "--- R17c: конкурентно step уже изменен (второй проход успел раньше) -> наш инкремент не проезжает поверх ---"
AGR17C=$(mk_event evtr17c)
QID17C=$(ask_direct "$AGR17C" "r17c-key" "R17c?" "")
QF17C="$AGR17C/questions/$QID17C.json"
force_due "$QF17C"
cat > "$TMP/alert-race-step.sh" <<EOF
#!/bin/sh
python3 -c "
import json
p = '$QF17C'
d = json.load(open(p))
d.setdefault('reminder', {})['step'] = 5
json.dump(d, open(p, 'w'), ensure_ascii=False)
"
exit 0
EOF
chmod +x "$TMP/alert-race-step.sh"
OUT17C=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-race-step.sh" "$RUN" question-reminders "$AGR17C" 2>"$TMP/r17c.err")
[[ "$OUT17C" == "$QID17C sent" ]] && ok || fail "R17c: доставка отработала (got: $OUT17C)"
[[ "$(jq_file "$QF17C" 'd.get("reminder",{}).get("step")')" == "5" ]] \
  && ok || fail "R17c: конкурентно измененный step не перезаписан повторным инкрементом (got $(jq_file "$QF17C" 'd.get("reminder",{}).get("step")'))"

echo "--- R17d: конкурентно выставлен snoozed_until в будущее -> step не продвинут ---"
AGR17D=$(mk_event evtr17d)
QID17D=$(ask_direct "$AGR17D" "r17d-key" "R17d?" "")
QF17D="$AGR17D/questions/$QID17D.json"
force_due "$QF17D"
cat > "$TMP/alert-race-snooze.sh" <<EOF
#!/bin/sh
python3 -c "
import json, datetime
p = '$QF17D'
d = json.load(open(p))
future = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=4)).strftime('%Y-%m-%dT%H:%M:%SZ')
d.setdefault('reminder', {})['snoozed_until'] = future
json.dump(d, open(p, 'w'), ensure_ascii=False)
"
exit 0
EOF
chmod +x "$TMP/alert-race-snooze.sh"
OUT17D=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-race-snooze.sh" "$RUN" question-reminders "$AGR17D" 2>"$TMP/r17d.err")
[[ "$OUT17D" == "$QID17D sent" ]] && ok || fail "R17d: доставка отработала (got: $OUT17D)"
[[ "$(jq_file "$QF17D" 'd.get("reminder",{}).get("step")')" == "0" ]] \
  && ok || fail "R17d: конкурентный снуз в будущее -> step не продвинут"

echo "--- R17e: два прохода внахлест -> ровно один реально отработал вопрос (questions/.reminders.lock), ровно одно продвижение ступени ---"
AGR17E=$(mk_event evtr17lock)
QID17E=$(ask_direct "$AGR17E" "r17lock-key" "R17e?" "")
QF17E="$AGR17E/questions/$QID17E.json"
force_due "$QF17E"
ALERT17E="$TMP/r17lock-alert.log"
cat > "$TMP/alert-slow-r17.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$ALERT17E"
printf '===\n' >> "$ALERT17E"
sleep 1.5
exit 0
EOF
chmod +x "$TMP/alert-slow-r17.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-slow-r17.sh" "$RUN" question-reminders "$AGR17E" \
  >"$TMP/r17e-out1.txt" 2>"$TMP/r17e-err1.txt" &
PID17E1=$!
sleep 0.3
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-slow-r17.sh" "$RUN" question-reminders "$AGR17E" \
  >"$TMP/r17e-out2.txt" 2>"$TMP/r17e-err2.txt" &
PID17E2=$!
wait "$PID17E1"; RC17E1=$?
wait "$PID17E2"; RC17E2=$?
OUT17E1=$(cat "$TMP/r17e-out1.txt"); OUT17E2=$(cat "$TMP/r17e-out2.txt")
[[ "$RC17E1" == 0 && "$RC17E2" == 0 ]] \
  && ok || fail "R17e: оба прохода вернули 0 (rc1=$RC17E1 rc2=$RC17E2)"
NONEMPTY17E=0
[[ -n "$OUT17E1" ]] && NONEMPTY17E=$((NONEMPTY17E+1))
[[ -n "$OUT17E2" ]] && NONEMPTY17E=$((NONEMPTY17E+1))
[[ "$NONEMPTY17E" == 1 ]] \
  && ok || fail "R17e: ровно один из двух параллельных проходов реально отработал вопрос (out1='$OUT17E1' out2='$OUT17E2')"
[[ "$(alert_block_count "$ALERT17E")" == "1" ]] \
  && ok || fail "R17e: ровно один вызов alert-команды - второй проход занял неблокирующий лок и вышел (got $(alert_block_count "$ALERT17E"))"
[[ "$(jq_file "$QF17E" 'd.get("reminder",{}).get("step")')" == "1" ]] \
  && ok || fail "R17e: step продвинулся ровно один раз"

# =============================================================== R18
echo "=== R18 (major): валидный JSON с испорченной схемой (reminder: 'x', step: '0') -> skip по этому вопросу, соседи обработаны, бесконечного повтора нет ==="
export CLAUDE_AGENT_REMINDER_LADDER_S="900,3600"
AGR18=$(mk_event evtr18)
mkdir -p "$AGR18/questions"
QID18A=$(new_uuid)
python3 -c "
import json
d = {'qid': '$QID18A', 'status': 'open', 'answered_at': None, 'kind': 'info',
     'question': 'R18a?', 'options': [], 'reminder': 'x'}
json.dump(d, open('$AGR18/questions/$QID18A.json', 'w'), ensure_ascii=False)
"
QID18B=$(new_uuid)
python3 -c "
import json
d = {'qid': '$QID18B', 'status': 'open', 'answered_at': None, 'kind': 'info',
     'question': 'R18b?', 'options': [],
     'reminder': {'step': '0', 'next_push_at': '2020-01-01T00:00:00Z', 'snoozed_until': None}}
json.dump(d, open('$AGR18/questions/$QID18B.json', 'w'), ensure_ascii=False)
"
QID18C=$(new_uuid)
write_raw_question "$AGR18" "$QID18C" "r18c-key" "info" "R18c?" '[]' "open" "2020-01-01T00:00:00Z"
ALERT_LOG18="$TMP/r18-alert.log"
mk_alert_ok "$ALERT_LOG18" "$TMP/alert-ok-r18.sh"
OUT18=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r18.sh" "$RUN" question-reminders "$AGR18" 2>"$TMP/r18.err"); RC18=$?
[[ "$RC18" == 0 ]] && ok || fail "R18: подкоманда не падает на схемных ошибках (got $RC18: $(cat "$TMP/r18.err"))"
echo "$OUT18" | grep -qxF "$QID18A skip" && ok || fail "R18: reminder: 'x' -> skip (out: $OUT18)"
echo "$OUT18" | grep -qxF "$QID18B skip" && ok || fail "R18: step: '0' -> skip (out: $OUT18)"
echo "$OUT18" | grep -qxF "$QID18C sent" && ok || fail "R18: соседний валидный вопрос все равно обработан (out: $OUT18)"
[[ "$(alert_block_count "$ALERT_LOG18")" == "1" ]] \
  && ok || fail "R18: alert-команда вызвана только по валидному вопросу, не по битым схемам (got $(alert_block_count "$ALERT_LOG18"))"
OUT18B=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r18.sh" "$RUN" question-reminders "$AGR18" 2>"$TMP/r18b.err")
echo "$OUT18B" | grep -qxF "$QID18B skip" \
  && ok || fail "R18: повторный тик - step:'0' снова skip, не бесконечная отправка (out: $OUT18B)"
[[ "$(alert_block_count "$ALERT_LOG18")" == "1" ]] \
  && ok || fail "R18: повторный тик не породил новый вызов alert-команды для битой схемы (нет бессрочного спама)"

# =============================================================== R19
echo "=== R19 (major): CLAUDE_AGENT_REMINDER_LADDER_S=-1/0 -> фолбэк на боевую лесенку, а не срок в прошлом ==="
AGR19A=$(mk_event evtr19a)
QID19A=$(ask_direct "$AGR19A" "r19a-key" "R19a?" "")
QF19A="$AGR19A/questions/$QID19A.json"
force_due "$QF19A"
export CLAUDE_AGENT_REMINDER_LADDER_S="-1"
ALERT_LOG19A="$TMP/r19a-alert.log"
mk_alert_ok "$ALERT_LOG19A" "$TMP/alert-ok-r19a.sh"
OUT19A=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r19a.sh" "$RUN" question-reminders "$AGR19A" 2>"$TMP/r19a.err")
[[ "$OUT19A" == "$QID19A sent" ]] && ok || fail "R19: доставка проходит при '-1' (got: $OUT19A)"
DIFF19A=$(iso_diff_now "$(jq_file "$QF19A" 'd.get("reminder",{}).get("next_push_at")')")
python3 -c '
import sys
d = float(sys.argv[1])
assert d > 60.0, d   # боевая первая ступень 900с - точно не в прошлом и не в ближайшие 60с
' "$DIFF19A" && ok || fail "R19: '-1' -> фолбэк на боевую лесенку (got diff=${DIFF19A}с)"

AGR19B=$(mk_event evtr19b)
QID19B=$(ask_direct "$AGR19B" "r19b-key" "R19b?" "")
QF19B="$AGR19B/questions/$QID19B.json"
force_due "$QF19B"
export CLAUDE_AGENT_REMINDER_LADDER_S="0"
ALERT_LOG19B="$TMP/r19b-alert.log"
mk_alert_ok "$ALERT_LOG19B" "$TMP/alert-ok-r19b.sh"
OUT19B=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-r19b.sh" "$RUN" question-reminders "$AGR19B" 2>"$TMP/r19b.err")
[[ "$OUT19B" == "$QID19B sent" ]] && ok || fail "R19: доставка проходит при '0' (got: $OUT19B)"
DIFF19B=$(iso_diff_now "$(jq_file "$QF19B" 'd.get("reminder",{}).get("next_push_at")')")
python3 -c '
import sys
d = float(sys.argv[1])
assert d > 60.0, d
' "$DIFF19B" && ok || fail "R19: '0' -> фолбэк на боевую лесенку (got diff=${DIFF19B}с)"
unset CLAUDE_AGENT_REMINDER_LADDER_S

# =============================================================== R20
echo "=== R20 (major): questions/ без прав на чтение -> ненулевой код и строка в логе, а не тихий 0 ==="
AGR20=$(mk_event evtr20)
mkdir -p "$AGR20/questions"
touch "$AGR20/questions/.keep"
chmod 0300 "$AGR20/questions"
OUT20=$("$RUN" question-reminders "$AGR20" 2>"$TMP/r20.err"); RC20=$?
chmod 0700 "$AGR20/questions"
[[ "$RC20" != 0 ]] && ok || fail "R20: недоступный questions/ -> ненулевой код (got $RC20)"
[[ -s "$TMP/r20.err" ]] && ok || fail "R20: строка в stderr/лог о недоступности каталога (пусто)"

# =============================================================== R21
echo "=== R21 (major): первый fail в проходе прекращает попытки - остальные due-вопросы получают skip, ступени не двигаются ==="
export CLAUDE_AGENT_REMINDER_LADDER_S="5,10"
AGR21=$(mk_event evtr21)
QID21A=$(new_uuid)
write_raw_question "$AGR21" "$QID21A" "r21a-key" "info" "R21a?" '[]' "open" "2020-01-01T00:00:00Z"
QID21B=$(new_uuid)
write_raw_question "$AGR21" "$QID21B" "r21b-key" "info" "R21b?" '[]' "open" "2020-01-01T00:00:00Z"
mapfile -t ORDER21 < <(ls "$AGR21/questions" | sort | sed 's/\.json$//')
FIRST21="${ORDER21[0]}"; SECOND21="${ORDER21[1]}"
ALERT_LOG21="$TMP/r21-alert.log"
mk_alert_fail "$ALERT_LOG21" "$TMP/alert-fail-r21.sh"
OUT21=$(CLAUDE_AGENT_ALERT_CMD="$TMP/alert-fail-r21.sh" "$RUN" question-reminders "$AGR21" 2>"$TMP/r21.err")
echo "$OUT21" | grep -qxF "$FIRST21 fail" && ok || fail "R21: первый (по сортировке) вопрос - fail (out: $OUT21)"
echo "$OUT21" | grep -qxF "$SECOND21 skip" \
  && ok || fail "R21: второй вопрос - skip без попытки отправки после первого fail (out: $OUT21)"
[[ "$(echo "$OUT21" | grep -c .)" == "2" ]] && ok || fail "R21: ровно две строки на выходе (out: $OUT21)"
[[ "$(alert_block_count "$ALERT_LOG21")" == "1" ]] \
  && ok || fail "R21: alert-команда вызвана только один раз за весь проход (got $(alert_block_count "$ALERT_LOG21"))"
[[ "$(jq_file "$AGR21/questions/$FIRST21.json" 'd.get("reminder",{}).get("step")')" == "0" ]] \
  && ok || fail "R21: step первого вопроса не изменился"
[[ "$(jq_file "$AGR21/questions/$SECOND21.json" 'd.get("reminder",{}).get("step")')" == "0" ]] \
  && ok || fail "R21: step второго вопроса не изменился"

# =============================================================== R22
echo "=== R22 (major): снуз по карточке, чья запись в sent_map не несет qid -> устарело, question-snooze не вызван ==="
SENT22="$TMP/sent22.json"
python3 -c 'import json; json.dump({}, open("'"$SENT22"'", "w"))'
QID22=$(new_uuid)
CLAUDE_AGENT_TG_SENT_MAP="$SENT22" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m22reg", sys.argv[1])
spec = importlib.util.spec_from_file_location("m22reg", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sent_map_register(2200, [220], "evtr22", None)   # legacy-запись, без kind/qid
' "$TGBOT"
RES22=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT22" python3 - "$TGBOT" "$QID22" <<'PY'
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
tgbot_path, qid = sys.argv[1], sys.argv[2]
loader = SourceFileLoader("m22run", tgbot_path)
spec = importlib.util.spec_from_file_location("m22run", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
calls, subs = [], []
def fake_api(token, proxy, method, http_timeout=30, **kw):
    calls.append(kw.get("text"))
    return {}
class FakeResult:
    returncode = 0
    stderr = ""
def fake_run(args, **kw):
    subs.append(args)
    return FakeResult()
mod.api = fake_api
mod.subprocess.run = fake_run
mod._handle_question_snooze("TOK", None, 2200, 220, qid)
print(json.dumps({"calls": calls, "subs": subs}))
PY
); RC_R22=$?
[[ "$RC_R22" == 0 ]] && ok || fail "R22: обертка не падает"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(any(t and "устар" in t for t in d["calls"]))' "$RES22")" == "True" ]] \
  && ok || fail "R22: запись без qid -> 'устарело' (got: $RES22)"
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(len(d["subs"]))' "$RES22")" == "0" ]] \
  && ok || fail "R22: question-snooze (subprocess) не вызван (got: $RES22)"

# =============================================================== R23
echo "=== R23 (minor): лишний позиционный аргумент у question-reminders -> ненулевой код ==="
AGR23=$(mk_event evtr23)
"$RUN" question-reminders "$AGR23" extra-garbage-arg >/dev/null 2>"$TMP/r23.err"; RC23=$?
[[ "$RC23" != 0 ]] && ok || fail "R23: лишний аргумент -> ненулевой код (got $RC23)"

echo
echo "test-agent-reminders: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
