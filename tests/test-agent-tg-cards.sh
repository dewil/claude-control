#!/usr/bin/env bash
# Tests for V2.5 TG-карточки вопросов (question_card/route_callback/
# answer_action/reply_target + роутинг ответа на claude-agent-answer, без
# сети/Telegram).
# Контракт: docs/design-2026-07-26-v2.5-tg-cards.md §9-11 (кейсы T1-T23).
# Фикс-пак после adversarial-аудита (2026-07-26): T17-T23 добавлены по
# исправленному контракту (blocker гонки reject->approve, major 1-4,
# minor формы sent_map); T9/T11 обновлены под новую 5-аргументную сигнатуру
# answer_action(qkind, status, answered_at, published_at, source) - §9.
# Написано с чистого листа по спеке (SDD, RED-фаза): реализация V2.5 НЕ
# читана (bin/claude-agent-tgbot, bin/claude-agent-run, bin/claude-agent-permit
# сознательно не открывались - ни разу не открыты через Read). bin/claude-agent-answer
# прочитан только как публичный контракт (usage-строка §7 usage:
# claude-agent-answer <agent-dir> --qid <qid> (--text T|--approve|--reject)
# [--by NAME]); внутренняя логика (durable_write, RMW под локом и т.п.) не
# использовалась при написании тестов - только наблюдаемое поведение файла
# вопроса/spool. Четыре функции §9 (authorized_cb/authorized/sent_map_register/
# sent_map_lookup) вызываются "как есть" по указанию задачи; их точные
# сигнатуры и форма аргументов (Update-словарь Telegram Bot API, whitelist как
# список int, схема sent_map-записи {agent,gen,at}) установлены черным ящиком
# через inspect.signature() и пробные вызовы модуля (importlib), БЕЗ чтения
# исходного текста функций через Read - тот же принцип "публичный контракт",
# что и usage-строка claude-agent-answer.
#
# Ambiguity-заметки (см. итоговый отчет для полного списка):
# 1. §9 явно называет 4 существующие функции для прямого вызова (authorized_cb/
#    authorized/sent_map_register/sent_map_lookup), но не дает "единой точки
#    входа" уровня "обработать один Telegram-апдейт целиком" - поэтому T6-T9/
#    T11/T12 по-прежнему собраны тонкими тестовыми обертками (sim_callback/
#    sim_reply), которые дергают РЕАЛЬНЫЕ пять чистых функций §9 в том порядке,
#    что описан в §1/§6, но сам порядок вызовов - решение теста, не код бота.
# 2. Порядок кнопок permission (T4) взят буквально из текста §4 ("разрешить"
#    первой, "отклонить" второй) - если реализация меняет порядок, это не
#    обязательно баг, но тест на это чувствителен.
set -u
shopt -s nullglob  # непойманный glob (напр. inbox/pending/*.json на пустом каталоге)
                   # должен давать пустой массив, а не буквальный паттерн из 1 элемента

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
ASK="$HERE/../bin/claude-agent-ask"
ANSWER="$HERE/../bin/claude-agent-answer"
TGBOT="$HERE/../bin/claude-agent-tgbot"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# HOME переопределен: любой путь вида "~/.claude-control/..." (sent_map и
# т.п., см. §5) резолвится в одноразовый каталог, а не в реальный $HOME.
export HOME="$TMP/home"
mkdir -p "$HOME"

export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt

# whitelist для authorized/authorized_cb (форма установлена черным ящиком -
# список int; см. шапку файла) и путь sent_map (T12/T13, §5/§9: переопределяется
# CLAUDE_AGENT_TG_SENT_MAP, поэтому реальный ~/.claude-control/tgbot.sent.json
# не трогается ни при каких обстоятельствах).
TEST_WHITELIST_JSON='[1001]'
export CLAUDE_AGENT_TG_SENT_MAP="$TMP/tgbot.sent.json"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1" >&2; }

jq_file() { # <file> <py-expr over dict/list d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
jq_str() { # <json-текст> <py-expr over d, распарсенного из этого текста>
  python3 -c 'import json,sys
d=json.loads(sys.argv[1])
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; } # <строка> -> JSON-строка
new_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

cb_update() { # <from-id> <callback-data> -> JSON Telegram Update с callback_query (приватный чат)
  python3 -c 'import json,sys
fid, data = int(sys.argv[1]), sys.argv[2]
print(json.dumps({"callback_query": {"id": "1", "from": {"id": fid},
  "message": {"chat": {"id": fid, "type": "private"}, "message_id": 1}, "data": data}}))' "$1" "$2"
}
msg_update() { # <from-id> <text> -> JSON Telegram Update с message (приватный чат)
  python3 -c 'import json,sys
fid, text = int(sys.argv[1]), sys.argv[2]
print(json.dumps({"message": {"chat": {"id": fid, "type": "private"}, "from": {"id": fid}, "text": text}}))' "$1" "$2"
}

# --- тестовый шов §9: чистые функции загружаются importlib'ом из файла без
#     расширения .py; модуль при импорте не выполняет побочных действий ---
TG_OUT=""; TG_ERR=""
tg_call() { # <funcname> <json-args...> -> $TG_OUT = JSON-сериализация возврата; $? = exit code python
  local func="$1"; shift
  TG_OUT=$(python3 - "$TGBOT" "$func" "$@" 2>"$TMP/.tgerr" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
tgbot_path, func = sys.argv[1], sys.argv[2]
args = [json.loads(a) for a in sys.argv[3:]]
loader = SourceFileLoader("agent_tgbot_under_test", tgbot_path)
spec = importlib.util.spec_from_file_location("agent_tgbot_under_test", tgbot_path, loader=loader)
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
expect_tg() { # <desc> <func> <py-bool-expr over d> <json-args...>
  local desc="$1" func="$2" expr="$3"; shift 3
  if tg_call "$func" "$@"; then
    local got
    got=$(jq_str "$TG_OUT" "$expr" 2>"$TMP/.experr")
    [[ "$got" == "True" ]] && ok || fail "$desc (д=$TG_OUT, expr='$expr': $(cat "$TMP/.experr"))"
  else
    fail "$desc: вызов функции упал ($TG_ERR)"
  fi
}

qcard_detail() { # <agent> <qid> <qkind> <text> <опции через \x1f, может быть пусто>
  python3 -c '
import json, sys
agent, qid, qkind, text, optcsv = sys.argv[1:6]
options = optcsv.split("\x1f") if optcsv else []
d = {"kind": "question", "agent": agent, "qid": qid, "qkind": qkind, "text": text, "options": options}
print(json.dumps(d, ensure_ascii=False))
' "$1" "$2" "$3" "$4" "$5"
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
goal: "tg-cards unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
  echo "$ag"
}

ask_direct() { # <agent-dir> <event-key> <question> [options|-separated by |] -> stdout=qid
  # V2.3 §2: claude-agent-ask требует envelope_key реально в inflight -
  # синтетические ключи получают временный stub-конверт (как в
  # test-agent-question.sh), удаляемый сразу после вызова.
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

write_permission_question() { # <agent-dir> <qid> <envelope-key> <question-text> -> файл kind=permission, status=open
  local dir="$1" qid="$2" key="$3" q="$4"
  mkdir -p "$dir/questions"
  python3 -c '
import json, sys
d = {
  "qid": sys.argv[1], "envelope_key": sys.argv[2],
  "asked_at": "2026-07-26T00:00:00Z", "kind": "permission",
  "question": sys.argv[3], "options": None, "context": None,
  "status": "open", "answer": None, "answered_at": None, "answered_by": None,
  "decision": None, "closed_by_envelope": None,
  "reminder": {"step": 0, "next_push_at": "2026-07-26T00:00:00Z", "snoozed_until": None},
}
json.dump(d, open(sys.argv[4], "w"), ensure_ascii=False)
' "$qid" "$key" "$q" "$dir/questions/$qid.json"
}

# Обрабатывает один тап по кнопке "тонкой оберткой" теста: authorized_cb
# (реальный, §1) -> route_callback (реальный) -> answer_action (реальный,
# source=button, §6.3) -> при apply реальный claude-agent-answer.
sim_callback() { # <agent-dir> <from-id> <callback-data> -> печатает исход в stdout
  local dir="$1" from="$2" data="$3"
  tg_call authorized_cb "$(cb_update "$from" "$data")" "$TEST_WHITELIST_JSON" \
    || { echo "auth_error:$TG_ERR"; return; }
  [[ "$TG_OUT" == "true" ]] || { echo "unauthorized"; return; }
  tg_call route_callback "$(json_str "$data")" || { echo "route_error:$TG_ERR"; return; }
  local kind qid arg
  kind=$(jq_str "$TG_OUT" 'd[0]')
  case "$kind" in
    menu|none) echo "$kind"; return ;;
  esac
  qid=$(jq_str "$TG_OUT" 'd[1]')
  arg=$(jq_str "$TG_OUT" 'd[2]')
  local qf="$dir/questions/$qid.json"
  [[ -f "$qf" ]] || { echo "no_question_file"; return; }
  local status answered_at published_at qkind at_arg pub_arg
  status=$(jq_file "$qf" 'd.get("status")')
  answered_at=$(jq_file "$qf" 'd.get("answered_at")')
  published_at=$(jq_file "$qf" 'd.get("event_published_at")')
  qkind=$(jq_file "$qf" 'd.get("kind")')
  at_arg="null"; [[ "$answered_at" != "None" ]] && at_arg="$(json_str "$answered_at")"
  pub_arg="null"; [[ "$published_at" != "None" ]] && pub_arg="$(json_str "$published_at")"
  tg_call answer_action "$(json_str "$qkind")" "$(json_str "$status")" "$at_arg" "$pub_arg" '"button"' \
    || { echo "action_error:$TG_ERR"; return; }
  local decision
  decision=$(jq_str "$TG_OUT" 'd')
  if [[ "$decision" != "apply" ]]; then echo "$decision"; return; fi
  case "$kind" in
    answer_option)
      local optval
      optval=$(jq_file "$qf" "d.get('options',[])[$arg]")
      "$ANSWER" "$dir" --qid "$qid" --text "$optval" --by "tg:$from" >/dev/null 2>"$TMP/.simerr"
      ;;
    approve) "$ANSWER" "$dir" --qid "$qid" --approve --by "tg:$from" >/dev/null 2>"$TMP/.simerr" ;;
    reject)  "$ANSWER" "$dir" --qid "$qid" --reject  --by "tg:$from" >/dev/null 2>"$TMP/.simerr" ;;
  esac
  echo "applied"
}

# Обрабатывает reply-текст: answer_action(source=reply, §9) решает apply/stale/
# wrong_kind однозначно (permission+reply -> wrong_kind, §4/§9).
sim_reply() { # <agent-dir> <from-id> <qid> <reply-text> -> печатает исход
  local dir="$1" from="$2" qid="$3" text="$4"
  local qf="$dir/questions/$qid.json"
  [[ -f "$qf" ]] || { echo "no_question_file"; return; }
  local qkind status answered_at published_at at_arg pub_arg
  qkind=$(jq_file "$qf" 'd.get("kind")')
  status=$(jq_file "$qf" 'd.get("status")')
  answered_at=$(jq_file "$qf" 'd.get("answered_at")')
  published_at=$(jq_file "$qf" 'd.get("event_published_at")')
  at_arg="null"; [[ "$answered_at" != "None" ]] && at_arg="$(json_str "$answered_at")"
  pub_arg="null"; [[ "$published_at" != "None" ]] && pub_arg="$(json_str "$published_at")"
  tg_call answer_action "$(json_str "$qkind")" "$(json_str "$status")" "$at_arg" "$pub_arg" '"reply"' \
    || { echo "action_error:$TG_ERR"; return; }
  local decision
  decision=$(jq_str "$TG_OUT" 'd')
  if [[ "$decision" != "apply" ]]; then echo "$decision"; return; fi
  "$ANSWER" "$dir" --qid "$qid" --text "$text" --by "tg:$from" >/dev/null 2>"$TMP/.simerr"
  echo "applied"
}

# --- mock claude: дампит промпт если задан PROMPT_DUMP_FILE, режимы ok/ask_ok ---
MOCK="$TMP/mock-claude"
export MOCK_ASK_BIN="$ASK"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${PROMPT_DUMP_FILE:-}" ]]; then cat > "$PROMPT_DUMP_FILE"; else cat > /dev/null; fi
mode=$(cat "${MOCK_MODE_FILE:-/dev/null}" 2>/dev/null || echo ok)
case "$mode" in
  ok) echo '{"type":"result","result":"processed","total_cost_usd":0.01}' ;;
  ask_ok)
    "$MOCK_ASK_BIN" --question "mock spawned question needing operator input" \
      >"${TMP_ASK_OUT:-/dev/null}" 2>"${TMP_ASK_ERR:-/dev/null}"
    echo '{"type":"result","result":"asked","total_cost_usd":0.01}' ;;
esac
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK" MOCK_MODE_FILE="$TMP/mock-mode"
export TMP_ASK_OUT="$TMP/ask-stdout" TMP_ASK_ERR="$TMP/ask-stderr"
echo ok > "$MOCK_MODE_FILE"

# =============================================================== T1
echo "=== T1: mode_send без detail (аргумент отсутствует) -> question_card дает (None, None) ==="
# 'argument absent' моделируем и как detail=None, и как detail={} (обе формы
# правдоподобны для 'отсутствует/не разбирается' - см. ambiguity-заметка 2 в
# финальном отчете); question_card(detail: dict) - по контракту detail=dict.
expect_tg "T1: detail=None -> (text,reply_markup)=(None,None)" question_card 'd[0] is None and d[1] is None' 'null'
expect_tg "T1: detail={} -> (text,reply_markup)=(None,None)" question_card 'd[0] is None and d[1] is None' '{}'

# =============================================================== T2
echo "=== T2: detail - валидный JSON без kind:question -> тот же (None, None) ==="
expect_tg "T2: detail без поля kind -> (None,None)" question_card 'd[0] is None and d[1] is None' '{"foo":"bar"}'
expect_tg "T2: detail с kind!=question -> (None,None)" question_card 'd[0] is None and d[1] is None' '{"kind":"other"}'

# =============================================================== T3
echo "=== T3: kind=question, qkind=info, три опции -> reply_markup q:<qid>:0..2, подсказка про reply, никаких кнопок при пустых options ==="
QID3=$(new_uuid)
DETAIL3=$(qcard_detail "agent3" "$QID3" "info" "Что делать с сервером?" "$(printf 'вариант A\x1fвариант B\x1fвариант C')")
if tg_call question_card "$DETAIL3"; then
  python3 - "$TG_OUT" "$QID3" <<'PY' >"$TMP/t3.out" 2>"$TMP/t3.err"
import json, sys
d = json.loads(sys.argv[1]); qid = sys.argv[2]
text, rm = d[0], d[1]
assert text is not None, "text не должен быть None для kind=question"
assert "reply" in text.lower() or "reply-ем" in text, f"нет подсказки про reply в тексте: {text!r}"
assert rm is not None, "reply_markup не должен быть None при непустых options"
btns = [b for row in rm.get("inline_keyboard", []) for b in row]
cbs = [b.get("callback_data") for b in btns]
assert cbs == [f"q:{qid}:0", f"q:{qid}:1", f"q:{qid}:2"], f"callback_data не совпадают/не по порядку: {cbs}"
labels = [b.get("text") for b in btns]
assert labels == ["вариант A", "вариант B", "вариант C"], f"подписи кнопок не совпадают с options: {labels}"
print("OK")
PY
  [[ "$(cat "$TMP/t3.out")" == "OK" ]] && ok || fail "T3: карточка info с тремя опциями ($(cat "$TMP/t3.err"))"
else
  fail "T3: question_card упал ($TG_ERR)"
fi

echo "--- T3b: options пуст -> кнопок нет (reply-подсказка все равно есть) ---"
QID3B=$(new_uuid)
DETAIL3B=$(qcard_detail "agent3b" "$QID3B" "info" "Открытый вопрос без вариантов?" "")
if tg_call question_card "$DETAIL3B"; then
  python3 - "$TG_OUT" <<'PY' >"$TMP/t3b.out" 2>"$TMP/t3b.err"
import json, sys
d = json.loads(sys.argv[1])
text, rm = d[0], d[1]
btns = [b for row in (rm or {}).get("inline_keyboard", []) for b in row] if rm else []
assert btns == [], f"кнопок не должно быть при пустых options: {btns}"
assert text is not None and ("reply" in text.lower())
print("OK")
PY
  [[ "$(cat "$TMP/t3b.out")" == "OK" ]] && ok || fail "T3b: пустые options -> нет кнопок ($(cat "$TMP/t3b.err"))"
else
  fail "T3b: question_card упал ($TG_ERR)"
fi

# =============================================================== T4
echo "=== T4: qkind=permission -> ровно две кнопки p:<qid>:a / p:<qid>:r, без reply-подсказки ==="
QID4=$(new_uuid)
DETAIL4=$(qcard_detail "agent4" "$QID4" "permission" "разрешить: rm -rf /tmp/x?" "")
if tg_call question_card "$DETAIL4"; then
  python3 - "$TG_OUT" "$QID4" <<'PY' >"$TMP/t4.out" 2>"$TMP/t4.err"
import json, sys
d = json.loads(sys.argv[1]); qid = sys.argv[2]
text, rm = d[0], d[1]
assert rm is not None, "reply_markup обязателен для permission"
btns = [b for row in rm.get("inline_keyboard", []) for b in row]
cbs = [b.get("callback_data") for b in btns]
assert cbs == [f"p:{qid}:a", f"p:{qid}:r"], f"ожидались ровно 2 кнопки p:.. :a/:r по порядку: {cbs}"
labels = " ".join(b.get("text", "") for b in btns).lower()
assert "разреш" in labels, f"нет подписи 'разрешить': {labels}"
assert "отклон" in labels, f"нет подписи 'отклонить': {labels}"
assert text is None or "reply" not in text.lower(), "permission-карточка не должна советовать reply"
print("OK")
PY
  [[ "$(cat "$TMP/t4.out")" == "OK" ]] && ok || fail "T4: permission-карточка с двумя кнопками ($(cat "$TMP/t4.err"))"
else
  fail "T4: question_card упал ($TG_ERR)"
fi

# =============================================================== T5
echo "=== T5: секрет в тексте вопроса не уезжает в исходящий текст карточки (redact) ==="
QID5=$(new_uuid)
SECRET_TEXT='PASSWORD=hunter2 curl -H "Authorization: Bearer abc.def.ghi" https://x'
DETAIL5=$(qcard_detail "agent5" "$QID5" "info" "$SECRET_TEXT" "")
if tg_call question_card "$DETAIL5"; then
  TEXT5=$(jq_str "$TG_OUT" 'd[0]')
  [[ "$TEXT5" != *"hunter2"* ]] && ok || fail "T5: секрет 'hunter2' не должен быть в тексте карточки"
  [[ "$TEXT5" != *"abc.def.ghi"* ]] && ok || fail "T5: секрет 'abc.def.ghi' не должен быть в тексте карточки"
else
  fail "T5: question_card упал ($TG_ERR)"
fi

# =============================================================== T6
echo "=== T6: callback q:<qid>:1 от авторизованного -> claude-agent-answer с --text <второй вариант>; ровно один конверт в spool без текста в payload ==="
AGT6=$(mk_event evtt6)
QID6=$(ask_direct "$AGT6" "t6-key" "Т6 какой вариант?" "opt-A|opt-B|opt-C")
[[ -n "$QID6" ]] && ok || fail "T6: setup - вопрос создан"
RES6=$(sim_callback "$AGT6" 1001 "q:$QID6:1")
[[ "$RES6" == "applied" ]] && ok || fail "T6: тап применен ($RES6, $(cat "$TMP/.simerr" 2>/dev/null))"
QF6="$AGT6/questions/$QID6.json"
[[ "$(jq_file "$QF6" 'd.get("answer")')" == "opt-B" ]] \
  && ok || fail "T6: answer = второй вариант (opt-B)"
[[ "$(jq_file "$QF6" 'd.get("answered_by")')" == "tg:1001" ]] \
  && ok || fail "T6: answered_by = tg:1001"
"$RUN" intake "$AGT6" >/dev/null
PEND6=("$AGT6"/inbox/pending/*.json)
[[ "${#PEND6[@]}" == "1" ]] && ok || fail "T6: ровно один конверт в spool (${#PEND6[@]})"
[[ "$(jq_file "${PEND6[0]:-/nonexistent}" 'd["payload"].get("kind")')" == "answer" ]] \
  && ok || fail "T6: payload.kind=answer"
[[ "$(jq_file "${PEND6[0]:-/nonexistent}" 'd["payload"].get("question_id")')" == "$QID6" ]] \
  && ok || fail "T6: payload.question_id=qid"
[[ "$(jq_file "${PEND6[0]:-/nonexistent}" '"text" not in d["payload"]')" == "True" ]] \
  && ok || fail "T6: payload без текста ответа"

# =============================================================== T7
echo "=== T7: тот же callback от НЕавторизованного from.id -> claude-agent-answer не вызван, файл не изменен ==="
# Сначала - реальная authorized_cb напрямую (позитив и негатив), а не только
# косвенно через sim_callback: whitelisted+private -> True; чужой from.id,
# групповой чат -> False (§1 буквально).
expect_tg "T7: authorized_cb(whitelisted, private) -> True" authorized_cb 'd is True' \
  "$(cb_update 1001 "q:x:0")" "$TEST_WHITELIST_JSON"
expect_tg "T7: authorized_cb(чужой from.id, private) -> False" authorized_cb 'd is False' \
  "$(cb_update 9999 "q:x:0")" "$TEST_WHITELIST_JSON"
GROUP_UPDATE=$(python3 -c 'import json; print(json.dumps({"callback_query": {"id": "1", "from": {"id": 1001}, "message": {"chat": {"id": -500, "type": "group"}, "message_id": 1}, "data": "q:x:0"}}))')
expect_tg "T7: authorized_cb(whitelisted, групповой чат) -> False" authorized_cb 'd is False' "$GROUP_UPDATE" "$TEST_WHITELIST_JSON"

# Теперь интеграционный сценарий: тап от неавторизованного from.id не должен
# дойти до claude-agent-answer, файл вопроса не меняется.
AGT7=$(mk_event evtt7)
QID7=$(ask_direct "$AGT7" "t7-key" "Т7 вопрос?" "yes|no")
RES7=$(sim_callback "$AGT7" 9999 "q:$QID7:0")
[[ "$RES7" == "unauthorized" ]] && ok || fail "T7: неавторизованный тап отклонен на уровне gate ($RES7)"
QF7="$AGT7/questions/$QID7.json"
[[ "$(jq_file "$QF7" 'd.get("answer")')" == "None" ]] && ok || fail "T7: answer не заполнен"
[[ "$(jq_file "$QF7" 'd.get("answered_at")')" == "None" ]] && ok || fail "T7: answered_at не заполнен"
[[ "$(jq_file "$QF7" 'd.get("status")')" == "open" ]] && ok || fail "T7: status остается open"

# =============================================================== T8
echo "=== T8: p:<qid>:a -> decision=approve; p:<qid>:r -> decision=reject ==="
AGT8=$(mk_event evtt8)
QID8A=$(new_uuid)
write_permission_question "$AGT8" "$QID8A" "t8a-key" "Т8a разрешить: git push?"
RES8A=$(sim_callback "$AGT8" 1001 "p:$QID8A:a")
[[ "$RES8A" == "applied" ]] && ok || fail "T8a: тап 'разрешить' применен ($RES8A, $(cat "$TMP/.simerr" 2>/dev/null))"
[[ "$(jq_file "$AGT8/questions/$QID8A.json" 'd.get("decision")')" == "approve" ]] \
  && ok || fail "T8a: decision=approve"

QID8B=$(new_uuid)
write_permission_question "$AGT8" "$QID8B" "t8b-key" "Т8b разрешить: git push?"
RES8B=$(sim_callback "$AGT8" 1001 "p:$QID8B:r")
[[ "$RES8B" == "applied" ]] && ok || fail "T8b: тап 'отклонить' применен ($RES8B, $(cat "$TMP/.simerr" 2>/dev/null))"
[[ "$(jq_file "$AGT8/questions/$QID8B.json" 'd.get("decision")')" == "reject" ]] \
  && ok || fail "T8b: decision=reject"

# =============================================================== T9
echo "=== T9: двойной тап по одной кнопке -> второй 'устарело', answered_at не переписан, второго конверта нет ==="
# Состояние доводится до осмысленного НАПРЯМУЮ через реальный claude-agent-answer
# (не через route_callback, которого еще нет) - чтобы answered_at к моменту
# проверки gate был реальным значением, а не совпадением двух провалов.
AGT9=$(mk_event evtt9)
QID9=$(ask_direct "$AGT9" "t9-key" "Т9 какой вариант?" "aa|bb")
"$ANSWER" "$AGT9" --qid "$QID9" --text "aa" --by "tg:1001" >/dev/null 2>"$TMP/t9a.err"
QF9="$AGT9/questions/$QID9.json"
AT9_1=$(jq_file "$QF9" 'd.get("answered_at")')
[[ "$AT9_1" != "None" ]] && ok || fail "T9: первый (настоящий) ответ применен, answered_at заполнен ($(cat "$TMP/t9a.err"))"
[[ "$(jq_file "$QF9" 'd.get("answer")')" == "aa" ]] && ok || fail "T9: answer = aa после первого ответа"
"$RUN" intake "$AGT9" >/dev/null
PEND9=("$AGT9"/inbox/pending/*.json)
[[ "${#PEND9[@]}" == "1" ]] && ok || fail "T9: после первого (настоящего) ответа в spool ровно один конверт (${#PEND9[@]})"

# Рубеж 1 (§7, best-effort UI-дедуп): чистая функция answer_action на РЕАЛЬНОМ
# уже отвеченном состоянии обязана сказать "stale" - это содержательная
# проверка (может покраснеть по существу, если implementation не распознает
# already-answered), а не совпадение двух ошибок. Реальный ответ выше прошел
# через полный claude-agent-answer (обе фазы), поэтому event_published_at
# тоже реально проставлен - завершенная пара (§9: stale только когда ОБЕ
# метки непусты).
PUB9_1=$(jq_file "$QF9" 'd.get("event_published_at")')
[[ "$PUB9_1" != "None" ]] && ok || fail "T9: event_published_at проставлен после полного ответа"
expect_tg "T9: answer_action(info, open, <реальный answered_at>, <реальный published_at>, button) -> stale" \
  answer_action 'd=="stale"' '"info"' '"open"' "$(json_str "$AT9_1")" "$(json_str "$PUB9_1")" '"button"'

# Рубеж 2 (§7.2, настоящий backstop claude-agent-answer): прямой повторный
# вызов (в обход любого gate бота) должен получить exit 2 и НЕ переписать answer.
# sleep 1 - answered_at в файле вопроса имеет секундную точность (видно по
# формату уже записанных значений), без паузы "не переписан" мог бы совпасть
# по таймстампу случайно, даже если бы answer реально перезаписался - пауза
# делает проверку недвусмысленной.
sleep 1
"$ANSWER" "$AGT9" --qid "$QID9" --text "bb" --by "tg:1001" >/dev/null 2>"$TMP/t9b.err"; RC9B=$?
[[ "$RC9B" == 2 ]] && ok || fail "T9: повторный ответ (bb после aa) -> exit 2 (got $RC9B)"
AT9_2=$(jq_file "$QF9" 'd.get("answered_at")')
[[ "$AT9_2" == "$AT9_1" ]] && ok || fail "T9: answered_at не переписан отвергнутым вторым ответом"
[[ "$(jq_file "$QF9" 'd.get("answer")')" == "aa" ]] && ok || fail "T9: answer остался от первого ответа (aa), не bb"
"$RUN" intake "$AGT9" >/dev/null
PEND9B=("$AGT9"/inbox/pending/*.json)
[[ "${#PEND9B[@]}" == "1" ]] \
  && ok || fail "T9: отвергнутый второй ответ не породил второй конверт в spool (${#PEND9B[@]})"

# И собственно "двойной тап по кнопке" целиком через реальный путь бота
# (authorized_cb+route_callback+answer_action): на уже отвеченном (реально)
# вопросе повторный тап обязан вернуть stale и не создать еще один конверт.
RES9C=$(sim_callback "$AGT9" 1001 "q:$QID9:1")
[[ "$RES9C" == "stale" ]] && ok || fail "T9: тап по кнопке на уже отвеченный вопрос -> stale ($RES9C)"
"$RUN" intake "$AGT9" >/dev/null
PEND9C=("$AGT9"/inbox/pending/*.json)
[[ "${#PEND9C[@]}" == "1" ]] \
  && ok || fail "T9: тап по кнопке на уже отвеченный вопрос не породил конверт (${#PEND9C[@]})"

# =============================================================== T16
echo "=== T16 (§7.2): незавершенная запись ответа (событие не опубликовано) не запирает вопрос навсегда ==="
# Запись ответа двухфазна: сначала durable в файл вопроса, потом конверт в
# spool. Если между фазами упасть, вопрос остается open с проставленным
# answered_at - и строгий запрет перезаписи сделал бы его вечным: прогон о
# таком ответе никогда не узнает, а повтор был бы отбит. Запирает вопрос
# только ЗАВЕРШЕННАЯ пара (answered_at + event_published_at).
AGT16=$(mk_event evtt16)
QID16=$(ask_direct "$AGT16" "t16-key" "Т16 продолжать?" "да|нет")
QF16="$AGT16/questions/$QID16.json"
python3 - "$QF16" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["answer"] = "да"                      # фаза 1 прошла
d["answered_at"] = "2026-07-26T00:00:00Z"
d["answered_by"] = "tg:1001"
d.pop("event_published_at", None)       # фаза 2 НЕ прошла
json.dump(d, open(p, "w"), ensure_ascii=False)
PY
"$ANSWER" "$AGT16" --qid "$QID16" --text "да" --by "tg:1001" >/dev/null 2>"$TMP/t16.err"; RC16=$?
[[ "$RC16" == 0 ]] \
  && ok || fail "T16: повтор незавершенной записи проходит (got $RC16: $(cat "$TMP/t16.err"))"
[[ "$(jq_file "$QF16" 'bool(d.get("event_published_at"))')" == "True" ]] \
  && ok || fail "T16: после успешного повтора обе фазы отмечены"
"$RUN" intake "$AGT16" >/dev/null
PEND16=("$AGT16"/inbox/pending/*.json)
[[ "${#PEND16[@]}" == "1" ]] \
  && ok || fail "T16: конверт опубликован ровно один (${#PEND16[@]})"
"$ANSWER" "$AGT16" --qid "$QID16" --text "нет" --by "tg:1001" >/dev/null 2>&1; RC16B=$?
[[ "$RC16B" == 2 ]] \
  && ok || fail "T16: после завершенной пары перезапись снова заперта (got $RC16B)"

# =============================================================== T17
echo "=== T17 (§7.2, blocker): два параллельных claude-agent-answer на один вопрос -> решение победителя, второй exit 2, конверт один ==="
# Копия claude-agent-answer в отдельный bin-каталог рядом с оберткой над
# claude-agent-run, которая искусственно тормозит именно spool-put (0.5с):
# claude-agent-answer вычисляет bin_dir = dirname(__file__), поэтому найдет
# ИМЕННО эту обертку, а не настоящий claude-agent-run. Это дает щедрое окно,
# достаточное, чтобы гонка гарантированно проявилась в обе стороны: под
# багом (лок отпускается между фазами) оба вызова успевают дойти до конца
# СВОЕЙ фазы 1 и оба вернут exit 0 с разными decision; под фиксом (лок
# держится на обе фазы) второй вызов блокируется на locked() до тех пор,
# пока первый не завершит publish, и получает честный exit 2.
mkdir -p "$TMP/slowbin"
cp "$ANSWER" "$TMP/slowbin/claude-agent-answer"
chmod +x "$TMP/slowbin/claude-agent-answer"
cat > "$TMP/slowbin/claude-agent-run" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "spool-put" ]]; then sleep 0.5; fi
exec "$RUN" "\$@"
EOF
chmod +x "$TMP/slowbin/claude-agent-run"
SLOW_ANSWER="$TMP/slowbin/claude-agent-answer"

AGT17=$(mk_event evtt17)
QID17=$(new_uuid)
write_permission_question "$AGT17" "$QID17" "t17-key" "Т17 гонка reject->approve?"
QF17="$AGT17/questions/$QID17.json"
"$SLOW_ANSWER" "$AGT17" --qid "$QID17" --reject --by "tg:reject-caller" \
  >"$TMP/t17r.out" 2>"$TMP/t17r.err" &
PIDR=$!
"$SLOW_ANSWER" "$AGT17" --qid "$QID17" --approve --by "tg:approve-caller" \
  >"$TMP/t17a.out" 2>"$TMP/t17a.err" &
PIDA=$!
wait "$PIDR"; RCR=$?
wait "$PIDA"; RCA=$?
# ровно один из двух обязан победить (exit 0), другой - exit 2 (§7.2 blocker).
# Под багом лок отпускается между фазами - оба видят "не полностью отвечено"
# и оба возвращают 0 (RCR==0 && RCA==0), поэтому это условие красное по
# существу, не по опечатке.
[[ ( "$RCR" == 0 && "$RCA" == 2 ) || ( "$RCR" == 2 && "$RCA" == 0 ) ]] \
  && ok || fail "T17: ровно один вызов должен победить (exit 0), другой - exit 2 (got reject=$RCR approve=$RCA)"
DEC17=$(jq_file "$QF17" 'd.get("decision")')
if [[ "$RCR" == 0 ]]; then
  [[ "$DEC17" == "reject" ]] && ok || fail "T17: в файле должно остаться решение победителя reject (got $DEC17)"
else
  [[ "$DEC17" == "approve" ]] && ok || fail "T17: в файле должно остаться решение победителя approve (got $DEC17)"
fi
[[ "$(jq_file "$QF17" 'bool(d.get("event_published_at"))')" == "True" ]] \
  && ok || fail "T17: событие отмечено опубликованным"
"$RUN" intake "$AGT17" >/dev/null
PEND17=("$AGT17"/inbox/pending/*.json)
[[ "${#PEND17[@]}" == "1" ]] \
  && ok || fail "T17: конверт в spool ровно один, соответствующий записанному решению (${#PEND17[@]})"
[[ "$(jq_file "${PEND17[0]:-/nonexistent}" 'd["payload"].get("question_id")')" == "$QID17" ]] \
  && ok || fail "T17: конверт адресует правильный qid"

# =============================================================== T18
echo "=== T18 (§7.2, major): режим ответа обязан соответствовать виду вопроса ==="
AGT18=$(mk_event evtt18)
QID18I=$(ask_direct "$AGT18" "t18i-key" "Т18 info-вопрос?" "yes|no")
"$ANSWER" "$AGT18" --qid "$QID18I" --approve --by "tg:1001" >/dev/null 2>"$TMP/t18a.err"; RC18A=$?
[[ "$RC18A" == 2 ]] && ok || fail "T18: --approve на kind=info -> exit 2 (got $RC18A)"
[[ "$(jq_file "$AGT18/questions/$QID18I.json" 'd.get("decision")')" == "None" ]] \
  && ok || fail "T18: decision не записан после отклоненного --approve на info (стейл-гейт V2.3 не закрыл бы вопрос без текста)"
[[ "$(jq_file "$AGT18/questions/$QID18I.json" 'd.get("answered_at")')" == "None" ]] \
  && ok || fail "T18: answered_at не заполнен после отклоненного --approve на info"

QID18P=$(new_uuid)
write_permission_question "$AGT18" "$QID18P" "t18p-key" "Т18 разрешить: rm -rf /tmp/w?"
"$ANSWER" "$AGT18" --qid "$QID18P" --text "неверный режим" --by "tg:1001" >/dev/null 2>"$TMP/t18b.err"; RC18B=$?
[[ "$RC18B" == 2 ]] && ok || fail "T18: --text на kind=permission -> exit 2 (got $RC18B)"
[[ "$(jq_file "$AGT18/questions/$QID18P.json" 'd.get("answer")')" == "None" ]] \
  && ok || fail "T18: answer не записан после отклоненного --text на permission"

# =============================================================== T19
echo "=== T19 (§6, major): qid в sent_map не совпадает с qid из callback_data -> устарело, writer не вызван ==="
AGT19=$(mk_event evtt19)
QID19=$(ask_direct "$AGT19" "t19-key" "Т19 какой вариант?" "x|y")
QID19_OTHER=$(new_uuid)
SENT19="$TMP/sent19.json"
python3 -c 'import json; json.dump({}, open("'"$SENT19"'", "w"))'
CLAUDE_AGENT_TG_SENT_MAP="$SENT19" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m19a", sys.argv[1])
spec = importlib.util.spec_from_file_location("m19a", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sent_map_register(1900, [190], "evtt19", None, kind="question", qid=sys.argv[2])
' "$TGBOT" "$QID19_OTHER"
CALLS19=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT19" CLAUDE_AGENTS_DIR="$CLAUDE_AGENTS_DIR" python3 -c '
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m19b", sys.argv[1])
spec = importlib.util.spec_from_file_location("m19b", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
calls = []
def fake_api(token, proxy, method, http_timeout=30, **kw):
    calls.append((method, kw.get("text")))
    return {}
mod.api = fake_api
mod._handle_question_callback("TOK", None, 1900, 190, "answer_option", sys.argv[2], "0", 1001)
print(json.dumps(calls))
' "$TGBOT" "$QID19")
STALE19=$(python3 -c '
import json, sys
calls = json.loads(sys.argv[1])
print(any(t and "устар" in t for _, t in calls))
' "$CALLS19")
APPLIED19=$(python3 -c '
import json, sys
calls = json.loads(sys.argv[1])
print(any(t and "принят" in t for _, t in calls))
' "$CALLS19")
[[ "$STALE19" == "True" ]] \
  && ok || fail "T19: qid-рассинхрон sent_map/callback_data -> 'устарело' (calls=$CALLS19)"
[[ "$APPLIED19" == "False" ]] \
  && ok || fail "T19: успешная ветка не должна была сработать при рассинхроне qid (calls=$CALLS19)"
[[ "$(jq_file "$AGT19/questions/$QID19.json" 'd.get("answer")')" == "None" ]] \
  && ok || fail "T19: writer не вызван, answer не записан"

# =============================================================== T20
echo "=== T20 (§7.2/§9, major): ответ записан без публикации -> apply, не stale; повторный тап дожимает публикацию ==="
expect_tg "T20: answer_action(info, open, <answered_at>, None, button) -> apply (не stale)" \
  answer_action 'd=="apply"' '"info"' '"open"' '"2026-07-26T00:00:00Z"' 'null' '"button"'

AGT20=$(mk_event evtt20)
QID20=$(ask_direct "$AGT20" "t20-key" "Т20 какой вариант?" "p|q")
QF20="$AGT20/questions/$QID20.json"
python3 - "$QF20" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["answer"] = "p"                       # первый тап уже записал ответ (фаза 1)
d["answered_at"] = "2026-07-26T00:00:00Z"
d["answered_by"] = "tg:1001"
d.pop("event_published_at", None)       # spool-put упал, бот все же закоммитил offset
json.dump(d, open(p, "w"), ensure_ascii=False)
PY
RES20=$(sim_callback "$AGT20" 1001 "q:$QID20:0")
[[ "$RES20" == "applied" ]] \
  && ok || fail "T20: повторный тап дожимает незавершенную публикацию, а не 'устарело' ($RES20)"
[[ "$(jq_file "$QF20" 'bool(d.get("event_published_at"))')" == "True" ]] \
  && ok || fail "T20: после дожатия обе фазы отмечены"
"$RUN" intake "$AGT20" >/dev/null
PEND20=("$AGT20"/inbox/pending/*.json)
[[ "${#PEND20[@]}" == "1" ]] \
  && ok || fail "T20: конверт опубликован ровно один (${#PEND20[@]})"

# =============================================================== T21
echo "=== T21 (§4, major): подпись опции обрезается по utf-8 границе; длинный текст уходит entity-safe, карточка не теряется молча ==="
QID21=$(new_uuid)
LONGLABEL=$(python3 -c 'print("оченьдлиннаяопция" * 6)')
DETAIL21=$(qcard_detail "agent21" "$QID21" "info" "Т21 длинная подпись?" "$LONGLABEL")
if tg_call question_card "$DETAIL21"; then
  python3 - "$TG_OUT" <<'PY' >"$TMP/t21.out" 2>"$TMP/t21.err"
import json, sys
d = json.loads(sys.argv[1])
rm = d[1]
btns = [b for row in rm.get("inline_keyboard", []) for b in row]
label = btns[0].get("text", "")
assert len(label.encode("utf-8")) <= 64, f"подпись длиннее 64 байт: {len(label.encode('utf-8'))}"
assert label.endswith("…") or label.endswith("..."), f"нет многоточия на обрезанной подписи: {label!r}"
label.encode("utf-8").decode("utf-8")  # граница utf-8 не разрезает символ
print("OK")
PY
  [[ "$(cat "$TMP/t21.out")" == "OK" ]] && ok || fail "T21: подпись обрезана по utf-8 границе с многоточием ($(cat "$TMP/t21.err"))"
else
  fail "T21: question_card упал ($TG_ERR)"
fi

echo "--- T21b: длинный текст вопроса уходит entity-safe отправителем (send_message), карточка не теряется молча ---"
LONGQ=$(python3 -c 'print("длинный вопрос текст " * 300)')
DETAIL21B=$(qcard_detail "agent21b" "$(new_uuid)" "info" "$LONGQ" "")
CALLS21B=$(CLAUDE_AGENT_TG_TOKEN="TESTTOKEN" CLAUDE_AGENT_TG_WHITELIST="7001" \
  python3 - "$TGBOT" "$DETAIL21B" <<'PY'
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
tgbot_path, detail_json = sys.argv[1], sys.argv[2]
loader = SourceFileLoader("m21b", tgbot_path)
spec = importlib.util.spec_from_file_location("m21b", tgbot_path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
calls = []
def fake_api(token, proxy, method, http_timeout=30, **kw):
    # мок ведет себя как настоящий Telegram: текст свыше 4096 - отказ
    if method == "sendMessage" and len(kw.get("text", "")) > 4096:
        raise RuntimeError("Bad Request: message is too long")
    calls.append((method, len(kw.get("text", "")), "reply_markup" in kw))
    return {"result": {"message_id": len(calls)}}
mod.api = fake_api
mod.mode_send(["agent21b", "asked", detail_json])
print(json.dumps(calls))
PY
)
python3 - "$CALLS21B" <<'PY' >"$TMP/t21b.out" 2>"$TMP/t21b.err"
import json, sys
calls = json.loads(sys.argv[1])
assert calls, "sendMessage не вызван вовсе - карточка потеряна молча"
assert all(m == "sendMessage" for m, _, _ in calls), calls
assert all(n <= 4096 for _, n, _ in calls), f"чанк превысил лимит Telegram: {calls}"
assert len(calls) > 1, f"длинный текст должен уйти несколькими чанками (entity-safe): {calls}"
print("OK")
PY
[[ "$(cat "$TMP/t21b.out")" == "OK" ]] \
  && ok || fail "T21b: длинный текст карточки уходит entity-safe чанками, не теряется ($(cat "$TMP/t21b.err"), calls=$CALLS21B)"

# =============================================================== T22
echo "=== T22 (§4, major): секрет в подписи опции, самостоятельный Bearer и JSON-форма password маскируются во всех строках карточки ==="
expect_tg "T22: redact маскирует самостоятельный Bearer без слова Authorization" \
  redact '"abc.def.ghi" not in d' "$(json_str "curl -H 'Bearer abc.def.ghi' https://x")"
expect_tg "T22: redact маскирует JSON-форму password" \
  redact '"hunter2" not in d' "$(json_str '{"password":"hunter2","x":1}')"

QID22=$(new_uuid)
DETAIL22=$(qcard_detail "agent22" "$QID22" "info" "Т22 выбери:" \
  "$(printf 'PASSWORD=hunter2\x1fBearer abc.def.ghi\x1f{"password":"hunter2"}')")
if tg_call question_card "$DETAIL22"; then
  python3 - "$TG_OUT" <<'PY' >"$TMP/t22.out" 2>"$TMP/t22.err"
import json, sys
d = json.loads(sys.argv[1])
rm = d[1]
labels = [b.get("text", "") for row in rm.get("inline_keyboard", []) for b in row]
joined = " ".join(labels)
assert "hunter2" not in joined, labels
assert "abc.def.ghi" not in joined, labels
print("OK")
PY
  [[ "$(cat "$TMP/t22.out")" == "OK" ]] && ok || fail "T22: подписи опций маскируются ($(cat "$TMP/t22.err"))"
else
  fail "T22: question_card упал ($TG_ERR)"
fi

# =============================================================== T23
echo "=== T23 (§5, minor): sent_map [] / null / dict со скалярными значениями -> пустая карта, без AttributeError ==="
SENT23="$TMP/sent23.json"
for bad in '[]' 'null' '"scalar"' '{"1:1": "не-объект", "1:2": 42}'; do
  printf '%s' "$bad" > "$SENT23"
  RES23=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT23" python3 -c '
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m23", sys.argv[1])
spec = importlib.util.spec_from_file_location("m23", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(json.dumps(mod.sent_map_lookup(1, 1)))
' "$TGBOT" 2>"$TMP/t23.err")
  [[ "$RES23" == "null" ]] \
    && ok || fail "T23: битая форма ($bad) не роняет lookup, дает null (got $RES23: $(cat "$TMP/t23.err"))"
done

echo "--- T23b: смешанная форма (валидные + скалярные записи) - скалярные игнорируются, валидные читаются, регистрация работает дальше ---"
printf '%s' '{"1:1": "не-объект", "1:2": {"agent":"good","gen":1,"at":1.0}}' > "$SENT23"
GOOD23=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT23" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m23b", sys.argv[1])
spec = importlib.util.spec_from_file_location("m23b", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
e = mod.sent_map_lookup(1, 2)
print(e.get("agent") if e else None)
' "$TGBOT" 2>"$TMP/t23b.err")
[[ "$GOOD23" == "good" ]] \
  && ok || fail "T23b: валидная запись рядом со скалярной читается нормально ($GOOD23: $(cat "$TMP/t23b.err"))"
BAD23=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT23" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m23c", sys.argv[1])
spec = importlib.util.spec_from_file_location("m23c", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(mod.sent_map_lookup(1, 1))
' "$TGBOT" 2>"$TMP/t23c.err")
[[ "$BAD23" == "None" ]] \
  && ok || fail "T23b: скалярная запись игнорируется, не выдается как валидная ($BAD23: $(cat "$TMP/t23c.err"))"

printf '[]' > "$SENT23"
CLAUDE_AGENT_TG_SENT_MAP="$SENT23" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m23d", sys.argv[1])
spec = importlib.util.spec_from_file_location("m23d", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sent_map_register(2, [3], "agentx23", 1)
' "$TGBOT" 2>"$TMP/t23d.err"
REG23=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT23" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m23e", sys.argv[1])
spec = importlib.util.spec_from_file_location("m23e", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
e = mod.sent_map_lookup(2, 3)
print(e.get("agent") if e else None)
' "$TGBOT" 2>"$TMP/t23e.err")
[[ "$REG23" == "agentx23" ]] \
  && ok || fail "T23: регистрация поверх ранее битой формы ([]) работает и читается назад ($REG23: $(cat "$TMP/t23d.err") $(cat "$TMP/t23e.err"))"

# =============================================================== T10
echo "=== T10: тап 'разрешить' после 'отклонить' -> exit 2 у claude-agent-answer, decision остается reject (§7.2) ==="
AGT10=$(mk_event evtt10)
QID10=$(new_uuid)
write_permission_question "$AGT10" "$QID10" "t10-key" "Т10 разрешить: rm -rf /tmp/y?"
"$ANSWER" "$AGT10" --qid "$QID10" --reject --by "tg:1001" >/dev/null 2>"$TMP/t10a.err"
[[ "$(jq_file "$AGT10/questions/$QID10.json" 'd.get("decision")')" == "reject" ]] \
  && ok || fail "T10: первый ответ (reject) записан ($(cat "$TMP/t10a.err"))"
"$ANSWER" "$AGT10" --qid "$QID10" --approve --by "tg:1001" >/dev/null 2>"$TMP/t10b.err"; RC10B=$?
[[ "$RC10B" == 2 ]] && ok || fail "T10: повторный ответ (approve после reject) -> exit 2 (got $RC10B)"
[[ "$(jq_file "$AGT10/questions/$QID10.json" 'd.get("decision")')" == "reject" ]] \
  && ok || fail "T10: decision остается reject после отвергнутой перезаписи"

# =============================================================== T11
echo "=== T11: reply на карточку вопроса -> claude-agent-answer --text; reply на permission-карточку -> отказ, ответ не записан ==="
AGT11=$(mk_event evtt11)
QID11=$(ask_direct "$AGT11" "t11-key" "Т11 свободный вопрос?")
RES11A=$(sim_reply "$AGT11" 1001 "$QID11" "мой свободный ответ Т11")
[[ "$RES11A" == "applied" ]] && ok || fail "T11: reply на info-вопрос применен ($RES11A)"
[[ "$(jq_file "$AGT11/questions/$QID11.json" 'd.get("answer")')" == "мой свободный ответ Т11" ]] \
  && ok || fail "T11: answer = текст reply"

# V2.5 фикс-пак (major 2, §7.2): claude-agent-answer теперь САМ по себе тоже
# отбивает --text на kind=permission (exit 2) - двойной рубеж, проверен
# отдельно в T18. Здесь остается только проверка чистой функции
# answer_action(source=reply) - она отбивает permission-reply НЕЗАВИСИМО от
# CLI-рубежа, тем же single-случаем wrong_kind, что и раньше.
QID11P=$(new_uuid)
write_permission_question "$AGT11" "$QID11P" "t11p-key" "Т11 разрешить: rm -rf /tmp/z?"
# §9: wrong_kind однозначен - qkind=permission и source=reply, независимо от
# published_at. Дополнительно убеждаемся напрямую в чистой функции (не только
# через sim_reply), чтобы проверка не зависела от обертки теста.
expect_tg "T11: answer_action(permission, open, None, None, reply) -> wrong_kind" \
  answer_action 'd=="wrong_kind"' '"permission"' '"open"' 'null' 'null' '"reply"'
RES11B=$(sim_reply "$AGT11" 1001 "$QID11P" "текст, который не должен пройти")
[[ "$RES11B" == "wrong_kind" ]] && ok || fail "T11: reply на permission-карточку отклонен как wrong_kind ($RES11B)"
[[ "$(jq_file "$AGT11/questions/$QID11P.json" 'd.get("decision")')" == "None" ]] \
  && ok || fail "T11: decision не записан после отклоненного reply"
[[ "$(jq_file "$AGT11/questions/$QID11P.json" 'd.get("answer")')" == "None" ]] \
  && ok || fail "T11: answer не записан после отклоненного reply"

# =============================================================== T12
echo "=== T12: reply на сообщение, чья запись в sent_map без qid -> прежний mission_comment (регресс), с qid -> question ==="
expect_tg "T12: reply_target(None) -> (mission, None)" reply_target 'd[0]=="mission" and d[1] is None' 'null'
expect_tg "T12: reply_target(запись без qid) -> (mission, None)" reply_target \
  'd[0]=="mission" and d[1] is None' '{"agent":"a","gen":1,"at":123.0}'
QID12T=$(new_uuid)
expect_tg "T12: reply_target(запись с qid) -> (question, qid)" reply_target \
  "d[0]==\"question\" and d[1]==\"$QID12T\"" \
  "{\"agent\":\"a\",\"gen\":1,\"at\":123.0,\"kind\":\"question\",\"qid\":\"$QID12T\"}"

echo "--- T12b: реальная sent_map-запись (sent_map_register сегодня без qid) через reply_target -> mission, ANSWER не вызывается ---"
SENTCHAT12=4200
python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m", sys.argv[1])
spec = importlib.util.spec_from_file_location("m", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sent_map_register(int(sys.argv[3]), [77], "agentz", 1)
' "$TGBOT" x "$SENTCHAT12"
ENTRY12=$(python3 -c '
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m", sys.argv[1])
spec = importlib.util.spec_from_file_location("m", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(json.dumps(mod.sent_map_lookup(int(sys.argv[2]), 77), ensure_ascii=False))
' "$TGBOT" "$SENTCHAT12")
if tg_call reply_target "$ENTRY12"; then
  DK12=$(jq_str "$TG_OUT" 'd[0]')
  [[ "$DK12" == "mission" ]] && ok || fail "T12b: реальная запись sent_map (без qid) -> mission, не question ($TG_OUT)"
  # диспетчеризация реально следует за решением reply_target: если бы оно
  # ошибочно вернуло "question", тест попытался бы вызвать claude-agent-answer
  # (провалится - нет такого agent-dir/qid) и это стало бы видимым FAIL, а не
  # тавтологией "мы и так не звонили".
  if [[ "$DK12" == "question" ]]; then
    "$ANSWER" "$TMP/nonexistent-agent-dir" --qid "$(jq_str "$TG_OUT" 'd[1]')" --text x --by tg:1001 \
      >/dev/null 2>"$TMP/t12b_wrong.err"
    fail "T12b: диспетчер по ошибке вызвал claude-agent-answer для mission-записи ($(cat "$TMP/t12b_wrong.err"))"
  fi
else
  fail "T12b: reply_target упал на реальной sent_map-записи ($TG_ERR)"
fi

# =============================================================== T13
echo "=== T13: sent_map - конкурентные регистрации не теряют запись (flock) ==="
SENT13="$TMP/sent13.json"
: > "$SENT13"
python3 -c 'import json; json.dump({}, open("'"$SENT13"'", "w"))'
CONC13=10
for i in $(seq 1 "$CONC13"); do
  ( CLAUDE_AGENT_TG_SENT_MAP="$SENT13" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m", sys.argv[1])
spec = importlib.util.spec_from_file_location("m", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sent_map_register(9000, [int(sys.argv[2])], "agentc13", 1)
' "$TGBOT" "$i" ) &
done
wait
COUNT13=$(python3 -c 'import json; print(len(json.load(open("'"$SENT13"'"))))')
[[ "$COUNT13" == "$CONC13" ]] \
  && ok || fail "T13: $CONC13 конкурентных регистраций -> $CONC13 записей в sent_map, ни одна не потеряна (got $COUNT13)"

echo "=== T13b: TTL-прунинг щадит запись с открытым qid, прунит с закрытым ==="
AGT13=$(mk_event agentp13)
QID13OPEN=$(ask_direct "$AGT13" "t13open-key" "Т13 открытый вопрос?")
QID13CLOSED=$(new_uuid)
write_permission_question "$AGT13" "$QID13CLOSED" "t13closed-key" "Т13 закрытый вопрос?"
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["status"] = "closed"; d["decision"] = "approve"; d["answered_at"] = "2026-01-01T00:00:00Z"
json.dump(d, open(p, "w"))
' "$AGT13/questions/$QID13CLOSED.json"

SENT13B="$TMP/sent13b.json"
python3 -c '
import json, sys, time
sentpath, qid_open, qid_closed = sys.argv[1], sys.argv[2], sys.argv[3]
old_at = time.time() - 20 * 86400  # 20 суток назад - за пределами TTL=14 суток
seed = {
  "9100:1": {"agent": "agentp13", "gen": 1, "at": old_at, "kind": "question", "qid": qid_open},
  "9100:2": {"agent": "agentp13", "gen": 1, "at": old_at, "kind": "question", "qid": qid_closed},
}
json.dump(seed, open(sentpath, "w"))
' "$SENT13B" "$QID13OPEN" "$QID13CLOSED"

# триггерим RMW/прунинг-проход обычной (свежей) регистрацией
CLAUDE_AGENT_TG_SENT_MAP="$SENT13B" python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m", sys.argv[1])
spec = importlib.util.spec_from_file_location("m", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sent_map_register(9100, [3], "agentp13", 2)
' "$TGBOT"

LOOKUP13_OPEN=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT13B" python3 -c '
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m", sys.argv[1])
spec = importlib.util.spec_from_file_location("m", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(json.dumps(mod.sent_map_lookup(9100, 1)))
' "$TGBOT")
[[ "$LOOKUP13_OPEN" != "null" ]] \
  && ok || fail "T13b: запись с открытым qid переживает TTL-прунинг (14 суток), got $LOOKUP13_OPEN"

LOOKUP13_CLOSED=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT13B" python3 -c '
import importlib.util, sys, json
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("m", sys.argv[1])
spec = importlib.util.spec_from_file_location("m", sys.argv[1], loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(json.dumps(mod.sent_map_lookup(9100, 2)))
' "$TGBOT")
[[ "$LOOKUP13_CLOSED" == "null" ]] \
  && ok || fail "T13b: запись с закрытым qid прунится обычным порядком, got $LOOKUP13_CLOSED"

# =============================================================== T14 (регресс)
echo "=== T14: callback m: и m:sum: маршрутизируются как раньше; мусор -> none ==="
expect_tg "T14: 'm:foo' -> (menu, None, 'm:foo')" route_callback 'd[0]=="menu" and d[1] is None and d[2]=="m:foo"' '"m:foo"'
expect_tg "T14: 'm:sum:bar' -> (menu, None, 'm:sum:bar')" route_callback 'd[0]=="menu" and d[1] is None and d[2]=="m:sum:bar"' '"m:sum:bar"'
expect_tg "T14: мусор -> kind=none" route_callback 'd[0]=="none"' '"совершенно левая строка"'

# =============================================================== T15
echo "=== T15 (§2, переписан): прогон, закончившийся вопросом, НЕ шлет карточку - единственный владелец пушей по вопросам - контур V2.6 ==="
AGT15=$(mk_event evtt15)
"$RUN" spool-put evtt15 --text "t15-event" >/dev/null
"$RUN" intake "$AGT15" >/dev/null
: > "$TMP/alert-argv.log"
cat > "$TMP/mock-alert.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$TMP/alert-argv.log"
printf '===\n' >> "$TMP/alert-argv.log"
EOF
chmod +x "$TMP/mock-alert.sh"
echo ask_ok > "$MOCK_MODE_FILE"
CLAUDE_AGENT_ALERT_CMD="$TMP/mock-alert.sh" "$RUN" step "$AGT15" >/dev/null 2>"$TMP/t15run.err"
echo ok > "$MOCK_MODE_FILE"
QFILES15=("$AGT15"/questions/*.json)
[[ -f "${QFILES15[0]}" ]] && ok || fail "T15: вопрос реально создан мок-агентом"
QID15=$(jq_file "${QFILES15[0]}" 'd.get("qid")')
# барьер против второго producer'а: если alert и вызван (обычный исход
# прогона), то в нем НЕ должно быть question-detail с qid
python3 - "$TMP/alert-argv.log" "$QID15" <<'PY' >"$TMP/t15.out" 2>"$TMP/t15.err"
import json, sys
log, qid = sys.argv[1], sys.argv[2]
try:
    raw = open(log).read()
except OSError:
    raw = ""
for call in [c for c in raw.split("===\n") if c.strip()]:
    for line in call.splitlines():
        try:
            detail = json.loads(line)
        except ValueError:
            continue
        if isinstance(detail, dict) and detail.get("kind") == "question":
            raise AssertionError(
                "прогон отправил карточку вопроса сам (detail=%s) - "
                "пуши по вопросам принадлежат контуру V2.6" % detail)
print("OK")
PY
[[ "$(cat "$TMP/t15.out")" == "OK" ]] && ok || fail "T15: прогон не шлет question-карточку ($(cat "$TMP/t15.err"))"
[[ "$(jq_file "${QFILES15[0]}" 'd.get("reminder",{}).get("step")')" == "0" ]] \
  && ok || fail "T15: reminder.step остается 0 - шаг двигает контур, не прогон"
[[ "$(jq_file "${QFILES15[0]}" 'bool(d.get("reminder",{}).get("next_push_at"))')" == "True" ]] \
  && ok || fail "T15: reminder.next_push_at выставлен при создании вопроса"

echo
echo "test-agent-tg-cards: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" == 0 ]]
