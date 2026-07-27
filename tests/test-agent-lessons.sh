#!/usr/bin/env bash
# Tests for V2.9: дистилляция уроков (thread/done.json поправки -> кандидаты в
# уроки -> подтверждение через TG -> запись в файл проекта -> блок в промпте
# следующей задачи того же проекта).
# Контракт: docs/design-2026-07-27-v2.9-lesson-distillation.md §8 (кейсы L1-L31).
#
# Написано с чистого листа по спеке (SDD, RED-фаза): реализация V2.9 еще НЕ
# существует на момент написания (bin/claude-agent-run, bin/claude-agent-tgbot,
# bin/_rc_projects.sh ни разу не открывались через Read под этот файл) - только
# сама спека и установленный ранее публичный контракт соседних этапов
# (route_callback/authorized_cb/question_card из V2.5/V2.6/V2.7b,
# project_path/project_integrate из V2.7b, done-notify/CLAUDE_AGENT_ALERT_CMD
# из V2.7a) - взят из тестов и спек этих этапов, НЕ из их реализации.
#
# Ambiguity-заметки (полный список - в финальном отчете задачи; коротко):
# 1. Имя приватного обработчика тапа по кнопке урока НЕ названо спекой
#    буквально (спека называет только route_callback + "claude-agent-run
#    lesson-verdict"). По симметрии с уже существующими _handle_question_callback
#    и _handle_done_callback (V2.5/V2.7b) тест ИСХОДИТ из имени
#    _handle_lesson_callback; точная сигнатура (token, proxy, chat_id, agent,
#    kind, cid8) установлена черным ящиком через inspect.signature() (тот же
#    прием "публичный контракт", что в шапке tests/test-agent-tg-cards.sh) -
#    без чтения исходного текста функции через Read. kind - первый элемент
#    кортежа route_callback(data), передается как есть (не захардкожен).
# 2. Формат ответа модели (`claude -p` для дистилляции) спекой дан только на
#    уровне схемы ОДНОГО кандидата ({essence, why, how_to_apply, from}, §3) -
#    обертка verbatim не названа. Мок (ниже) воспроизводит ДИСЦИПЛИНУ
#    tests/mock-harvest-claude буквально: top-level {"result": "<json-текст>"}
#    (без поля "type", как у харвестера, НЕ как у обычного мока `claude -p`
#    в tests/test-agent-thread.sh), а inner-json - ГОЛЫЙ список кандидатов
#    (без обертки {"clusters":...}, которой в схеме §3 нет). Это единственное
#    предположение, от которого зависит "краснота по существу" всей группы
#    L7-L11/L29 - если реализация ждет другую обертку, вся группа покраснеет
#    на разборе мок-ответа, а не на проверяемой логике. Открытый вопрос §2.
# 3. Схема agents/<name>/lessons.json (файл состояния кандидатов, §2/§6)
#    спекой не дана буквально - тест читает его СТРУКТУРНО-АГНОСТИЧНО:
#    candidate_id ищется как sha256-hex (64 hex-символа) где угодно в сыром
#    тексте файла, без предположений о ключах/вложенности JSON.
# 4. Код возврата claude-agent-run lesson-verdict для "stale" не назван
#    явно - по прямой аналогии с done-verdict (B9 в test-agent-task-lifecycle.sh:
#    несовпадение CAS-идентификатора -> exit != 0) тест проверяет только
#    "!= 0", не конкретное число. Для applied/already - exit 0 (аналогия с
#    B47/N1/N2: идемпотентный положительный исход - это НЕ ошибка).
# 5. Точный текст маркера усечения промпта (§7: "явно пишется, сколько уроков
#    не поместилось") НЕ процитирован спекой буквально (в отличие от треда,
#    где design-2026-07-26-v2.2-thread-memory.md §дает "[тред усечен: ...]"
#    дословно) - L27 проверяет структурно (старые записи вытеснены, новые
#    остались, размер блока в пределах капа) и не привязывается к дословному
#    тексту маркера.
set -u
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
RC="$HERE/../bin/claude-rc"
ASK="$HERE/../bin/claude-agent-ask"
TGBOT="$HERE/../bin/claude-agent-tgbot"
RC_PROJECTS_HELPER="$HERE/../bin/_rc_projects.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt
export CLAUDE_RECONCILER_DIR="$TMP/reconciler"
mkdir -p "$CLAUDE_RECONCILER_DIR"
export CLAUDE_RC_PROJECTS_FILE="$TMP/projects.yaml"
: > "$CLAUDE_RC_PROJECTS_FILE"
export CLAUDE_AGENT_TG_SENT_MAP="$TMP/tgbot.sent.json"
TEST_WHITELIST_JSON='[1001]'

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

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
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

# ---------------------------------------------------------------- фикстуры --
mk_event() { # <name> -> печатает agent-dir (mkdir-фикстура, без реального create - проект не нужен)
  local name="$1"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "lesson distillation unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
  echo "$ag"
}

register_flat_project() { printf '%s: %s\n' "$1" "$2" >> "$CLAUDE_RC_PROJECTS_FILE"; } # <name> <path> - форма A
register_obj_project() { # <name> <path> [lessons-rel] [integrate] -> форма B (§6: 3-е поле - lessons)
  local name="$1" path="$2" lessons="${3:-}" integ="${4:-}"
  { printf '%s:\n  path: %s\n' "$name" "$path"
    [[ -n "$lessons" ]] && printf '  lessons: %s\n' "$lessons"
    [[ -n "$integ" ]] && printf '  integrate: %s\n' "$integ"
  } >> "$CLAUDE_RC_PROJECTS_FILE"
}
rc_project_lessons_path() { ( . "$RC_PROJECTS_HELPER" 2>/dev/null; project_lessons_path "$1" 2>/dev/null ); }

mk_project_agent() { # <name> <project-path> -> agent-dir через реальный "$RC agent create" (populates control.json.project_name, §6/В2.7a)
  local name="$1" proj="$2"
  local specfile="$TMP/spec-$name.yaml"
  cat > "$specfile" <<EOF
schema: 1
name: $name
type: event
role: none
project: $proj
goal: "lesson distillation project fixture"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: none
EOF
  "$RC" agent create "$name" --spec "$specfile" >/dev/null 2>"$TMP/create-$name.err"
  local rc=$?
  [[ "$rc" == 0 ]] && ok || fail "fixture: create $name (project=$proj) ($(cat "$TMP/create-$name.err"))"
  echo "$CLAUDE_AGENTS_DIR/$name"
}
mk_worktree_project_agent() { # <name> <project-path> -> agent-dir workspace:worktree (для L23)
  local name="$1" proj="$2"
  local specfile="$TMP/spec-$name.yaml"
  cat > "$specfile" <<EOF
schema: 1
name: $name
type: event
role: none
project: $proj
goal: "lesson distillation worktree fixture"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
  "$RC" agent create "$name" --spec "$specfile" >/dev/null 2>"$TMP/create-$name.err"
  local rc=$?
  [[ "$rc" == 0 ]] && ok || fail "fixture: create $name workspace:worktree (project=$proj) ($(cat "$TMP/create-$name.err"))"
  echo "$CLAUDE_AGENTS_DIR/$name"
}
mk_git_project() { # <dir> -> git-репозиторий с одним коммитом
  local dir="$1"
  git init -q --initial-branch=main "$dir"
  ( cd "$dir" && echo base > f.txt && git add f.txt \
    && git -c user.email=t@t -c user.name=t commit -qm init )
}

# claude-agent-ask требует envelope_key реально в inflight (V2.3 §2) - тот же
# прием stub-конверта, что в tests/test-agent-tg-cards.sh/test-agent-question.sh.
ask_direct() { # <agent-dir> <event-key> <question> -> stdout=qid
  local dir="$1" key="$2" q="$3"
  local stubbed=0
  if [[ ! -f "$dir/inbox/inflight/$key.json" ]]; then
    mkdir -p "$dir/inbox/inflight"
    printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"text":"stub-for-ask"}}\n' \
      "$key" > "$dir/inbox/inflight/$key.json"
    stubbed=1
  fi
  CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" "$ASK" --question "$q"
  local rc=$?
  [[ "$stubbed" == 1 ]] && rm -f "$dir/inbox/inflight/$key.json"
  return $rc
}
# Прием из test-agent-question.sh Q10: доверие треда - это существование
# questions/<qid>.json с непустым envelope_key, не поле в самой записи.
# Пишем thread.jsonl строки напрямую (whitebox-фикстура, не через полный
# прогон) - ровно тот же прием, что Q10/T3/T14 в соседних суитах.
append_trusted_answer() { # <agent-dir> <event-key> <real-qid> <text> [seq]
  local dir="$1" key="$2" qid="$3" text="$4" seq="${5:-9}"
  python3 -c 'import json, sys
d = {"key": sys.argv[1], "seq": int(sys.argv[5]), "at": "2026-07-27T09:00:00Z",
     "kind": "answer", "qid": sys.argv[2], "text": sys.argv[3]}
open(sys.argv[4], "a").write(json.dumps(d, ensure_ascii=False) + "\n")' \
    "$key" "$qid" "$text" "$dir/thread.jsonl" "$seq"
}
append_untrusted_answer() { # <agent-dir> <event-key> <text> [seq] -> qid выдуманный
  local dir="$1" key="$2" text="$3" seq="${4:-9}"
  python3 -c 'import json, sys, uuid
d = {"key": sys.argv[1], "seq": int(sys.argv[4]), "at": "2026-07-27T09:00:00Z",
     "kind": "answer", "qid": str(uuid.uuid4()), "text": sys.argv[2]}
open(sys.argv[3], "a").write(json.dumps(d, ensure_ascii=False) + "\n")' \
    "$key" "$text" "$dir/thread.jsonl" "$seq"
}

write_done_requested() { # <agent-dir> <key> <summary> [comment|-] -> done.json requested, pushed_at:null (V2.7a/V2.7b поля)
  local dir="$1" key="$2" summary="$3" comment="${4:--}"
  local comment_json="null"
  [[ "$comment" != "-" ]] && comment_json="$(json_str "$comment")"
  python3 -c 'import json, sys
d = {"state": "requested", "requested_at": "2026-01-01T00:00:00Z", "envelope_key": sys.argv[2],
     "workspace": "none", "summary": sys.argv[3],
     "branch": None, "base": None, "commit_sha": None, "empty": None, "changes": None,
     "pushed_at": None, "accepted_at": None, "integrated_at": None, "cleaned_at": None, "archived_at": None,
     "verdict_at": None, "verdict_by": None, "verdict_comment": json.loads(sys.argv[4])}
json.dump(d, open(sys.argv[1] + "/done.json", "w"), ensure_ascii=False)' \
    "$dir" "$key" "$summary" "$comment_json"
}
mk_done_envelope() { # <agent-dir> <key> - реальный конверт в inbox/done (аудит V2.7a major 6: envelope_key обязан быть реальным)
  local dir="$1" key="$2"
  mkdir -p "$dir/inbox/done"
  printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"text":"stub-for-done"}}\n' \
    "$key" > "$dir/inbox/done/$key.json"
}

mk_alert_ok() { # <log-file> <script-path>
  local log="$1" script="$2"
  cat > "$script" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$log"
printf '===\n' >> "$log"
EOF
  chmod +x "$script"
}
alert_block_count() { [[ -f "$1" ]] && grep -c '^===$' "$1" || echo 0; }

# lessons.json - схема не дана буквально (§2/§6): читаем структурно-агностично
# (candidate_id = sha256-hex, 64 hex-символа, ищется в сыром тексте файла).
lesson_ids() { # <lessons.json> -> отсортированные уникальные candidate_id (64-hex), по одному на строку
  python3 -c 'import re, sys
text = open(sys.argv[1]).read() if __import__("os").path.exists(sys.argv[1]) else ""
for i in sorted(set(re.findall(r"[0-9a-f]{64}", text))): print(i)' "$1"
}
lesson_id_count() { lesson_ids "$1" | grep -c . || true; }
lesson_first_cid8() { lesson_ids "$1" | head -n1 | cut -c1-8; }

# --- мок мод модели для лестной дистилляции (по образцу tests/mock-harvest-claude,
#     см. ambiguity-заметку 2) ---
LESSON_MOCK="$TMP/mock-lesson-claude"
cat > "$LESSON_MOCK" <<'PYEOF'
#!/usr/bin/env python3
import json, os, re, sys
data = sys.stdin.read()
dump = os.environ.get("PROMPT_DUMP_FILE")
if dump:
    open(dump, "w").write(data)
called = os.environ.get("MOCK_LESSON_CALLED_FILE")
if called:
    open(called, "w").close()
ids = sorted(set(re.findall(r"[0-9a-f]{16}", data)))
mode = os.environ.get("MOCK_LESSON_MODE", "one")
essence = os.environ.get("MOCK_LESSON_ESSENCE", "l-default-essence-marker")
why = os.environ.get("MOCK_LESSON_WHY", "l-default-why-marker")
how = os.environ.get("MOCK_LESSON_HOW", "l-default-how-marker")

def cand(fr, ess=None):
    return {"essence": essence if ess is None else ess, "why": why,
            "how_to_apply": how, "from": fr}

def emit(cands):
    sys.stdout.write(json.dumps({"result": json.dumps(cands, ensure_ascii=False)}, ensure_ascii=False))

if mode == "fail":
    sys.stderr.write("boom\n")
    sys.exit(1)
elif mode == "empty":
    emit([])
elif mode == "one":
    emit([cand(ids)])
elif mode == "unknown":
    emit([cand(ids + ["deadbeefdeadbeef"])])
elif mode == "empty_essence":
    emit([cand(ids, ess="")])
elif mode == "many":
    emit([cand(ids, ess="l-many-candidate-%d" % i) for i in range(1, 6)])
elif mode == "mixed_dup":
    emit([cand(ids, ess="l11-marker-A"), cand(ids, ess="l11-marker-A"), cand(ids, ess="l11-marker-B")])
else:
    emit([])
PYEOF
chmod +x "$LESSON_MOCK"

# --- мок claude для обычных прогонов "step" (по образцу tests/test-agent-thread.sh:75-89) ---
STEP_MOCK="$TMP/mock-claude-step"
cat > "$STEP_MOCK" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${PROMPT_DUMP_FILE:-}" ]]; then cat > "$PROMPT_DUMP_FILE"; else cat > /dev/null; fi
echo '{"type":"result","result":"'"${MOCK_RESULT_TEXT:-processed}"'","total_cost_usd":0.01}'
EOF
chmod +x "$STEP_MOCK"

# --- importlib-загрузка чистых функций бота (по образцу test-agent-tg-cards.sh:100-106) ---
TG_OUT=""; TG_ERR=""
tg_call() { # <funcname> <json-args...> -> $TG_OUT = json-сериализация возврата
  local func="$1"; shift
  TG_OUT=$(python3 - "$TGBOT" "$func" "$@" 2>"$TMP/.tgerr" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
tgbot_path, func = sys.argv[1], sys.argv[2]
args = [json.loads(a) for a in sys.argv[3:]]
loader = SourceFileLoader("agent_tgbot_lessons_under_test", tgbot_path)
spec = importlib.util.spec_from_file_location("agent_tgbot_lessons_under_test", tgbot_path, loader=loader)
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
cb_update() { # <from-id> <callback-data> -> Telegram Update (приватный чат)
  python3 -c 'import json,sys
fid, data = int(sys.argv[1]), sys.argv[2]
print(json.dumps({"callback_query": {"id": "1", "from": {"id": fid},
  "message": {"chat": {"id": fid, "type": "private"}, "message_id": 1}, "data": data}}))' "$1" "$2"
}

####################################################################
# Отбор поправок (§1, L1-L6)
####################################################################

# =============================================================== L1
echo "=== L1: доверенный ответ в треде попадает на вход дистилляции (модель вызвана) ==="
AGL1=$(mk_event evtl1)
"$RUN" spool-put evtl1 --text "l1-event" >/dev/null
"$RUN" intake "$AGL1" >/dev/null
KL1=$(ls "$AGL1/inbox/pending" | sed 's/.json//')
QL1=$(ask_direct "$AGL1" "l1-asker-key" "L1 реальный вопрос?")
append_trusted_answer "$AGL1" "$KL1" "$QL1" "l1-trusted-correction-text-marker-long-enough"
write_done_requested "$AGL1" "$KL1" "L1 summary"
mk_done_envelope "$AGL1" "$KL1"
mk_alert_ok "$TMP/l1-alert.log" "$TMP/l1-alert.sh"
MOCK_CALLED_L1="$TMP/l1-called"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L1" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l1-alert.sh" "$RUN" done-notify "$AGL1" >/dev/null 2>"$TMP/l1.err"; RCL1=$?
[[ "$RCL1" == 0 ]] && ok || fail "L1: done-notify exit 0 (got $RCL1: $(cat "$TMP/l1.err"))"
[[ -f "$MOCK_CALLED_L1" ]] && ok || fail "L1: модель дистилляции вызвана (доверенный ответ - валидная поправка)"
[[ -f "$AGL1/lessons.json" ]] && ok || fail "L1: lessons.json создан"

# =============================================================== L2
echo "=== L2: недоверенная запись треда (выдуманный qid) не попадает на вход - модель не вызвана ==="
AGL2=$(mk_event evtl2)
"$RUN" spool-put evtl2 --text "l2-event" >/dev/null
"$RUN" intake "$AGL2" >/dev/null
KL2=$(ls "$AGL2/inbox/pending" | sed 's/.json//')
append_untrusted_answer "$AGL2" "$KL2" "l2-untrusted-correction-text-marker-long-enough"
write_done_requested "$AGL2" "$KL2" "L2 summary"
mk_done_envelope "$AGL2" "$KL2"
mk_alert_ok "$TMP/l2-alert.log" "$TMP/l2-alert.sh"
MOCK_CALLED_L2="$TMP/l2-called"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L2" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l2-alert.sh" "$RUN" done-notify "$AGL2" >/dev/null 2>"$TMP/l2.err"; RCL2=$?
[[ "$RCL2" == 0 ]] && ok || fail "L2: done-notify exit 0 (got $RCL2: $(cat "$TMP/l2.err"))"
[[ ! -f "$MOCK_CALLED_L2" ]] && ok || fail "L2: модель НЕ вызвана (единственная запись - недоверенная)"
[[ ! -f "$AGL2/lessons.json" ]] && ok || fail "L2: lessons.json не создан"
[[ "$(alert_block_count "$TMP/l2-alert.log")" == "1" ]] && ok || fail "L2: карточка готовности все равно ушла"

# =============================================================== L3
echo "=== L3: verdict_comment из отказа готовности - законная поправка (модель вызвана) ==="
AGL3=$(mk_event evtl3)
KL3="l3-key"
write_done_requested "$AGL3" "$KL3" "L3 summary" "l3-verdict-comment-correction-marker-long-enough"
mk_done_envelope "$AGL3" "$KL3"
mk_alert_ok "$TMP/l3-alert.log" "$TMP/l3-alert.sh"
MOCK_CALLED_L3="$TMP/l3-called"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L3" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l3-alert.sh" "$RUN" done-notify "$AGL3" >/dev/null 2>"$TMP/l3.err"; RCL3=$?
[[ "$RCL3" == 0 ]] && ok || fail "L3: done-notify exit 0 (got $RCL3: $(cat "$TMP/l3.err"))"
[[ -f "$MOCK_CALLED_L3" ]] && ok || fail "L3: модель вызвана (verdict_comment - валидная поправка)"
[[ -f "$AGL3/lessons.json" ]] && ok || fail "L3: lessons.json создан"

# =============================================================== L4
echo "=== L4: тап без текста (verdict_comment пуст) - не поправка, модель не вызвана ==="
AGL4=$(mk_event evtl4)
KL4="l4-key"
write_done_requested "$AGL4" "$KL4" "L4 summary"   # comment по умолчанию null (accept/reject без текста)
mk_done_envelope "$AGL4" "$KL4"
mk_alert_ok "$TMP/l4-alert.log" "$TMP/l4-alert.sh"
MOCK_CALLED_L4="$TMP/l4-called"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L4" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l4-alert.sh" "$RUN" done-notify "$AGL4" >/dev/null 2>"$TMP/l4.err"; RCL4=$?
[[ "$RCL4" == 0 ]] && ok || fail "L4: done-notify exit 0 (got $RCL4: $(cat "$TMP/l4.err"))"
[[ ! -f "$MOCK_CALLED_L4" ]] && ok || fail "L4: модель НЕ вызвана (тап без текста - не поправка)"
[[ ! -f "$AGL4/lessons.json" ]] && ok || fail "L4: lessons.json не создан"

# =============================================================== L5
echo "=== L5: короткий ответ ('ок', <24 байт) - не поправка, модель не вызвана ==="
AGL5=$(mk_event evtl5)
"$RUN" spool-put evtl5 --text "l5-event" >/dev/null
"$RUN" intake "$AGL5" >/dev/null
KL5=$(ls "$AGL5/inbox/pending" | sed 's/.json//')
QL5=$(ask_direct "$AGL5" "l5-asker-key" "L5 продолжать?")
append_trusted_answer "$AGL5" "$KL5" "$QL5" "ок"
write_done_requested "$AGL5" "$KL5" "L5 summary"
mk_done_envelope "$AGL5" "$KL5"
mk_alert_ok "$TMP/l5-alert.log" "$TMP/l5-alert.sh"
MOCK_CALLED_L5="$TMP/l5-called"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L5" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l5-alert.sh" "$RUN" done-notify "$AGL5" >/dev/null 2>"$TMP/l5.err"; RCL5=$?
[[ "$RCL5" == 0 ]] && ok || fail "L5: done-notify exit 0 (got $RCL5: $(cat "$TMP/l5.err"))"
[[ ! -f "$MOCK_CALLED_L5" ]] && ok || fail "L5: модель НЕ вызвана (короткий ответ - согласие, не знание)"
[[ ! -f "$AGL5/lessons.json" ]] && ok || fail "L5: lessons.json не создан"

# =============================================================== L6
echo "=== L6: поправок нет вовсе - ни прогона модели, ни файла состояния; карточка готовности все равно уходит ==="
AGL6=$(mk_event evtl6)
KL6="l6-key"
write_done_requested "$AGL6" "$KL6" "L6 summary"
mk_done_envelope "$AGL6" "$KL6"
mk_alert_ok "$TMP/l6-alert.log" "$TMP/l6-alert.sh"
MOCK_CALLED_L6="$TMP/l6-called"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L6" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l6-alert.sh" "$RUN" done-notify "$AGL6" >/dev/null 2>"$TMP/l6.err"; RCL6=$?
[[ "$RCL6" == 0 ]] && ok || fail "L6: done-notify exit 0 (got $RCL6: $(cat "$TMP/l6.err"))"
[[ ! -f "$MOCK_CALLED_L6" ]] && ok || fail "L6: модель не вызвана вовсе"
[[ ! -f "$AGL6/lessons.json" ]] && ok || fail "L6: файла состояния кандидатов нет"
[[ "$(alert_block_count "$TMP/l6-alert.log")" == "1" ]] && ok || fail "L6: карточка готовности все равно ушла (ровно один вызов)"

####################################################################
# Прогон и проверка (§3/§4, L7-L11)
####################################################################

# =============================================================== L7
echo "=== L7: маскировка - секрет в поправке не доходит до модели и не попадает в кандидата ==="
AGL7=$(mk_event evtl7)
"$RUN" spool-put evtl7 --text "l7-event" >/dev/null
"$RUN" intake "$AGL7" >/dev/null
KL7=$(ls "$AGL7/inbox/pending" | sed 's/.json//')
QL7=$(ask_direct "$AGL7" "l7-asker-key" "L7 продолжать?")
SECRET_L7='PASSWORD=hunter2seclong curl -H "Authorization: Bearer abc.def.ghi.secretlong" https://x'
append_trusted_answer "$AGL7" "$KL7" "$QL7" "$SECRET_L7"
write_done_requested "$AGL7" "$KL7" "L7 summary"
mk_done_envelope "$AGL7" "$KL7"
mk_alert_ok "$TMP/l7-alert.log" "$TMP/l7-alert.sh"
PROMPT_L7="$TMP/l7-prompt.txt"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one PROMPT_DUMP_FILE="$PROMPT_L7" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l7-alert.sh" "$RUN" done-notify "$AGL7" >/dev/null 2>"$TMP/l7.err"
[[ -s "$PROMPT_L7" ]] && ok || fail "L7: промпт модели дистилляции сдампен (модель вызвана)"
grep -qF "hunter2seclong" "$PROMPT_L7" && fail "L7: секрет 'hunter2seclong' не должен дойти до модели" || ok
grep -qF "abc.def.ghi.secretlong" "$PROMPT_L7" && fail "L7: секрет Bearer не должен дойти до модели" || ok
if [[ -f "$AGL7/lessons.json" ]]; then
  grep -qF "hunter2seclong" "$AGL7/lessons.json" && fail "L7: секрет не должен попасть в lessons.json" || ok
else
  ok  # файла нет вовсе - секрет тем более не утек
fi

# =============================================================== L8 (falsifiability: см. финальный ответ)
echo "=== L8: candidate с ссылкой на несуществующий correction_id отбрасывается ЦЕЛИКОМ ==="
AGL8=$(mk_event evtl8)
"$RUN" spool-put evtl8 --text "l8-event" >/dev/null
"$RUN" intake "$AGL8" >/dev/null
KL8=$(ls "$AGL8/inbox/pending" | sed 's/.json//')
QL8=$(ask_direct "$AGL8" "l8-asker-key" "L8 продолжать?")
append_trusted_answer "$AGL8" "$KL8" "$QL8" "l8-correction-text-marker-long-enough-value"
write_done_requested "$AGL8" "$KL8" "L8 summary"
mk_done_envelope "$AGL8" "$KL8"
mk_alert_ok "$TMP/l8-alert.log" "$TMP/l8-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=unknown MOCK_LESSON_ESSENCE="l8-should-be-dropped-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l8-alert.sh" "$RUN" done-notify "$AGL8" >/dev/null 2>"$TMP/l8.err"; RCL8=$?
[[ "$RCL8" == 0 ]] && ok || fail "L8: done-notify exit 0 даже если единственный кандидат отброшен (got $RCL8)"
if [[ -f "$AGL8/lessons.json" ]]; then
  grep -qF "l8-should-be-dropped-marker" "$AGL8/lessons.json" \
    && fail "L8: кандидат со ссылкой на выдуманный correction_id не должен попасть в lessons.json" || ok
else
  ok  # весь список пуст после отбрасывания единственного кандидата - тоже валидный исход
fi
# контрольный прогон (та же поправка, MODE=one - без выдуманного id) ДОЛЖЕН
# оставить маркер: доказывает, что отсутствие маркера выше - следствие именно
# валидации from, а не совпадения (иначе оба прогона дали бы одинаковый nil-результат).
AGL8B=$(mk_event evtl8b)
"$RUN" spool-put evtl8b --text "l8b-event" >/dev/null
"$RUN" intake "$AGL8B" >/dev/null
KL8B=$(ls "$AGL8B/inbox/pending" | sed 's/.json//')
QL8B=$(ask_direct "$AGL8B" "l8b-asker-key" "L8b продолжать?")
append_trusted_answer "$AGL8B" "$KL8B" "$QL8B" "l8b-correction-text-marker-long-enough-value"
write_done_requested "$AGL8B" "$KL8B" "L8b summary"
mk_done_envelope "$AGL8B" "$KL8B"
mk_alert_ok "$TMP/l8b-alert.log" "$TMP/l8b-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l8-should-be-dropped-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l8b-alert.sh" "$RUN" done-notify "$AGL8B" >/dev/null 2>"$TMP/l8b.err"
[[ -f "$AGL8B/lessons.json" ]] && grep -qF "l8-should-be-dropped-marker" "$AGL8B/lessons.json" \
  && ok || fail "L8: контроль - валидный from ОСТАЕТСЯ в lessons.json (доказывает падаемость L8)"

# =============================================================== L9
echo "=== L9: пустая essence отбрасывается ==="
AGL9=$(mk_event evtl9)
"$RUN" spool-put evtl9 --text "l9-event" >/dev/null
"$RUN" intake "$AGL9" >/dev/null
KL9=$(ls "$AGL9/inbox/pending" | sed 's/.json//')
QL9=$(ask_direct "$AGL9" "l9-asker-key" "L9 продолжать?")
append_trusted_answer "$AGL9" "$KL9" "$QL9" "l9-correction-text-marker-long-enough-value"
write_done_requested "$AGL9" "$KL9" "L9 summary"
mk_done_envelope "$AGL9" "$KL9"
mk_alert_ok "$TMP/l9-alert.log" "$TMP/l9-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=empty_essence MOCK_LESSON_WHY="l9-should-be-dropped-why-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l9-alert.sh" "$RUN" done-notify "$AGL9" >/dev/null 2>"$TMP/l9.err"; RCL9=$?
[[ "$RCL9" == 0 ]] && ok || fail "L9: done-notify exit 0 (got $RCL9)"
if [[ -f "$AGL9/lessons.json" ]]; then
  grep -qF "l9-should-be-dropped-why-marker" "$AGL9/lessons.json" \
    && fail "L9: кандидат с пустой essence не должен попасть в lessons.json" || ok
else
  ok
fi

# =============================================================== L10
echo "=== L10: больше трех кандидатов - лишние отброшены (ровно 3 остаются) ==="
AGL10=$(mk_event evtl10)
"$RUN" spool-put evtl10 --text "l10-event" >/dev/null
"$RUN" intake "$AGL10" >/dev/null
KL10=$(ls "$AGL10/inbox/pending" | sed 's/.json//')
QL10=$(ask_direct "$AGL10" "l10-asker-key" "L10 продолжать?")
append_trusted_answer "$AGL10" "$KL10" "$QL10" "l10-correction-text-marker-long-enough-value"
write_done_requested "$AGL10" "$KL10" "L10 summary"
mk_done_envelope "$AGL10" "$KL10"
mk_alert_ok "$TMP/l10-alert.log" "$TMP/l10-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=many \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l10-alert.sh" "$RUN" done-notify "$AGL10" >/dev/null 2>"$TMP/l10.err"
[[ -f "$AGL10/lessons.json" ]] && ok || fail "L10: lessons.json создан (5 кандидатов на входе)"
CNT_L10=$(lesson_id_count "$AGL10/lessons.json" 2>/dev/null || echo 0)
[[ "$CNT_L10" == "3" ]] && ok || fail "L10: ровно 3 кандидата остаются, лишние (5-3=2) отброшены (got $CNT_L10)"

# =============================================================== L11 (falsifiability: см. финальный ответ)
echo "=== L11: candidate_id считается от содержимого (essence/why/how_to_apply/from) ==="
AGL11=$(mk_event evtl11)
"$RUN" spool-put evtl11 --text "l11-event" >/dev/null
"$RUN" intake "$AGL11" >/dev/null
KL11=$(ls "$AGL11/inbox/pending" | sed 's/.json//')
QL11=$(ask_direct "$AGL11" "l11-asker-key" "L11 продолжать?")
append_trusted_answer "$AGL11" "$KL11" "$QL11" "l11-correction-text-marker-long-enough-value"
write_done_requested "$AGL11" "$KL11" "L11 summary"
mk_done_envelope "$AGL11" "$KL11"
mk_alert_ok "$TMP/l11-alert.log" "$TMP/l11-alert.sh"
# mixed_dup: 2 кандидата с ОДИНАКОВЫМ essence "l11-marker-A" (дубли по
# candidate_id, §4 - должны схлопнуться в одну запись) + 1 с ДРУГИМ essence
# "l11-marker-B" (должен получить ДРУГОЙ candidate_id). Falsifiable в обе
# стороны: id "от counter/random" провалил бы дедуп (получили бы 3 записи,
# не 2); id "игнорирующий essence" схлопнул бы ВСЕ 3 в одну (получили бы 1).
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=mixed_dup \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l11-alert.sh" "$RUN" done-notify "$AGL11" >/dev/null 2>"$TMP/l11.err"
[[ -f "$AGL11/lessons.json" ]] && ok || fail "L11: lessons.json создан"
CNT_L11=$(lesson_id_count "$AGL11/lessons.json" 2>/dev/null || echo 0)
[[ "$CNT_L11" == "2" ]] \
  && ok || fail "L11: ровно 2 различных candidate_id (дубль essence схлопнут, разный essence - разный id), got $CNT_L11"
grep -qF "l11-marker-A" "$AGL11/lessons.json" && ok || fail "L11: essence-A (после дедупа) присутствует"
grep -qF "l11-marker-B" "$AGL11/lessons.json" && ok || fail "L11: essence-B присутствует"

####################################################################
# Подтверждение (§5, L12-L17)
####################################################################

# --- общая фикстура: реальный проект + один подтвержденный-готовый кандидат ---
PROJ_L1x="$TMP/proj-l1x"; mkdir -p "$PROJ_L1x"
register_flat_project projl1x "$PROJ_L1x"
mk_lesson_candidate() { # <agent-name> <ask-key> <essence-marker> -> печатает "agent-dir cid8"
  local name="$1" essence="$3"
  local dir; dir=$(mk_project_agent "$name" "$PROJ_L1x")
  "$RUN" spool-put "$name" --text "$name-event" >/dev/null
  "$RUN" intake "$dir" >/dev/null
  local key; key=$(ls "$dir/inbox/pending" | sed 's/.json//')
  local qid; qid=$(ask_direct "$dir" "$2" "$name продолжать?")
  append_trusted_answer "$dir" "$key" "$qid" "$name-correction-text-marker-long-enough-value"
  write_done_requested "$dir" "$key" "$name summary"
  mk_done_envelope "$dir" "$key"
  mk_alert_ok "$TMP/$name-alert.log" "$TMP/$name-alert.sh"
  CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="$essence" \
    CLAUDE_AGENT_ALERT_CMD="$TMP/$name-alert.sh" "$RUN" done-notify "$dir" >/dev/null 2>"$TMP/$name-notify.err"
  echo "$dir $(lesson_first_cid8 "$dir/lessons.json")"
}

# =============================================================== L12
echo "=== L12: подтверждение (accept) идет через реальный route_callback + обработчик бота (не собранный руками CLI-вызов) ==="
read -r AGL12 CID8_L12 < <(mk_lesson_candidate agtl12 l12-key l12-accept-essence-marker)
[[ -n "$CID8_L12" ]] && ok || fail "L12: fixture - кандидат создан, cid8 извлечен"
# callback_data - буквально по формату спеки §5 (l:<agent>:<cid8>:y), а не
# из белого списка захардкоженных строк - но НЕ через ручной вызов CLI
# lesson-verdict в обход бота: сначала реальный authorized_cb+route_callback,
# потом (см. ambiguity-заметка 1) предполагаемый реальный обработчик.
DATA_L12="l:agtl12:${CID8_L12}:y"
tg_call authorized_cb "$(cb_update 1001 "$DATA_L12")" "$TEST_WHITELIST_JSON"
AUTH_L12="$TG_OUT"
[[ "$AUTH_L12" == "true" ]] && ok || fail "L12: authorized_cb(whitelisted) -> true (got $AUTH_L12, $TG_ERR)"
tg_call route_callback "$(json_str "$DATA_L12")"
ROUTE_L12="$TG_OUT"
echo "$ROUTE_L12" | grep -qF "agtl12" && ok || fail "L12: route_callback распознал имя агента из l:-callback (route=$ROUTE_L12, $TG_ERR)"
echo "$ROUTE_L12" | grep -qF "$CID8_L12" && ok || fail "L12: route_callback распознал cid8 (route=$ROUTE_L12)"
KIND_L12=$(jq_str "$ROUTE_L12" 'd[0]')
CALLS_L12=$(python3 - "$TGBOT" "agtl12" "$CID8_L12" "$KIND_L12" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent, cid8, kind = sys.argv[1:5]
loader = SourceFileLoader("tgbot_l12", path)
spec = importlib.util.spec_from_file_location("tgbot_l12", path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
calls = []
def fake_api(token, proxy, method, http_timeout=30, **kw):
    calls.append((method, kw.get("text")))
    return {}
mod.api = fake_api
try:
    # Сигнатура (token, proxy, chat_id, agent, kind, cid8) установлена черным
    # ящиком через inspect.signature() (см. ambiguity-заметку 1) - тот же
    # прием "публичный контракт", что в tests/test-agent-tg-cards.sh (шапка
    # файла) - без чтения исходного текста функции через Read.
    mod._handle_lesson_callback("TOK", None, 1001, agent, kind, cid8)
    print(json.dumps({"ok": True, "calls": calls}, ensure_ascii=False))
except (AttributeError, TypeError) as e:
    print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
PY
)
OK_L12=$(jq_str "$CALLS_L12" 'd.get("ok")')
[[ "$OK_L12" == "True" ]] && ok || fail "L12: обработчик _handle_lesson_callback существует и не упал (см. ambiguity-заметку 1: имя предположено; $CALLS_L12)"
[[ -f "$PROJ_L1x/.claude/rules/lessons.md" ]] && grep -qF "l12-accept-essence-marker" "$PROJ_L1x/.claude/rules/lessons.md" \
  && ok || fail "L12: реальный путь бота (route_callback+обработчик) довел кандидата до файла проекта ($(cat "$PROJ_L1x/.claude/rules/lessons.md" 2>/dev/null))"

# =============================================================== L13
echo "=== L13: отказ (reject) - в файл уроков не пишется ничего ==="
read -r AGL13 CID8_L13 < <(mk_lesson_candidate agtl13 l13-key l13-reject-essence-marker)
"$RUN" lesson-verdict "$AGL13" --reject --id "$CID8_L13" >"$TMP/l13.out" 2>"$TMP/l13.err"; RCL13=$?
[[ "$RCL13" == 0 ]] && ok || fail "L13: lesson-verdict --reject exit 0 (got $RCL13: $(cat "$TMP/l13.err"))"
OUT13=$(cat "$TMP/l13.out")
[[ "$OUT13" == "applied" ]] && ok || fail "L13: исход отклонения - applied (вердикт применен), got '$OUT13'"
[[ ! -f "$PROJ_L1x/.claude/rules/lessons.md" ]] || ! grep -qF "l13-reject-essence-marker" "$PROJ_L1x/.claude/rules/lessons.md" \
  && ok || fail "L13: essence отклоненного кандидата не должна попасть в файл уроков"

# =============================================================== L14
echo "=== L14: повторный тап - no-op (already), файл уроков не меняется ==="
read -r AGL14 CID8_L14 < <(mk_lesson_candidate agtl14 l14-key l14-repeat-essence-marker)
"$RUN" lesson-verdict "$AGL14" --accept --id "$CID8_L14" >/dev/null 2>"$TMP/l14a.err"
CNT_L14_1=$(grep -c "l14-repeat-essence-marker" "$PROJ_L1x/.claude/rules/lessons.md" 2>/dev/null || echo 0)
"$RUN" lesson-verdict "$AGL14" --accept --id "$CID8_L14" >"$TMP/l14b.out" 2>"$TMP/l14b.err"; RCL14B=$?
OUT14B=$(cat "$TMP/l14b.out")
[[ "$RCL14B" == 0 ]] && ok || fail "L14: повторный тап exit 0 (got $RCL14B)"
[[ "$OUT14B" == "already" ]] && ok || fail "L14: повторный тап -> already, got '$OUT14B'"
CNT_L14_2=$(grep -c "l14-repeat-essence-marker" "$PROJ_L1x/.claude/rules/lessons.md" 2>/dev/null || echo 0)
[[ "$CNT_L14_2" == "$CNT_L14_1" ]] && ok || fail "L14: файл уроков не изменился повторным тапом ($CNT_L14_1 -> $CNT_L14_2)"

# =============================================================== L15
echo "=== L15: подтверждение несуществующего/изменившегося id - 'устарело' ==="
read -r AGL15 CID8_L15 < <(mk_lesson_candidate agtl15 l15-key l15-stale-essence-marker)
"$RUN" lesson-verdict "$AGL15" --accept --id "deadbeef" >"$TMP/l15.out" 2>"$TMP/l15.err"; RCL15=$?
[[ "$RCL15" != 0 ]] && ok || fail "L15: несуществующий id -> exit != 0 (got $RCL15; см. ambiguity-заметку 4)"
OUT15=$(cat "$TMP/l15.out")
[[ "$OUT15" == "stale" ]] && ok || fail "L15: исход - stale, got '$OUT15'"
! grep -qF "l15-stale-essence-marker" "$PROJ_L1x/.claude/rules/lessons.md" 2>/dev/null \
  && ok || fail "L15: устаревшее подтверждение не должно записать урок"

# =============================================================== L16
echo "=== L16: чужой chat_id игнорируется (гейт до обработчика, как у /new) ==="
read -r AGL16 CID8_L16 < <(mk_lesson_candidate agtl16 l16-key l16-foreign-essence-marker)
tg_call authorized_cb "$(cb_update 9999 "l:agtl16:${CID8_L16}:y")" "$TEST_WHITELIST_JSON"
[[ "$TG_OUT" == "false" ]] && ok || fail "L16: authorized_cb(чужой from.id) -> false (got $TG_OUT)"
# гейт останавливает обработку ДО обработчика (тот же порядок, что в
# sim_callback тестов V2.5/V2.7b: authorized_cb -> route_callback -> handler);
# раз authorized_cb уже вернул false, реальный процесс бота handler не зовет -
# проверяем итог: файл уроков не тронут посторонним тапом.
! grep -qF "l16-foreign-essence-marker" "$PROJ_L1x/.claude/rules/lessons.md" 2>/dev/null \
  && ok || fail "L16: чужой тап не должен применить вердикт"

# =============================================================== L17
echo "=== L17: структурный - бот не открывает lessons.json ни на чтение, ни на запись ==="
CNT_L17=$(python3 - "$TGBOT" <<'PY'
import ast, sys
path = sys.argv[1]
src = open(path).read()
tree = ast.parse(src, filename=path)
targets = {"open", "remove", "unlink", "durable_write", "durable_json"}
hits = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    func = node.func
    name = func.id if isinstance(func, ast.Name) else getattr(func, "attr", None)
    if name not in targets:
        continue
    seg = ast.get_source_segment(src, node) or ""
    if "lessons.json" in seg:
        hits.append((node.lineno, seg.replace("\n", " ")[:100]))
print(len(hits))
for ln, seg in hits:
    print("%d: %s" % (ln, seg), file=sys.stderr)
PY
)
[[ "${CNT_L17:-0}" == "0" ]] \
  && ok || fail "L17: bin/claude-agent-tgbot обращается к lessons.json файлово (got $CNT_L17)"

####################################################################
# Запись (§6, L18-L23)
####################################################################

# =============================================================== L18
echo "=== L18: урок дописан в файл по пути из реестра (дефолт .claude/rules/lessons.md, форма A) ==="
PROJ_L18="$TMP/proj-l18"; mkdir -p "$PROJ_L18"
register_flat_project projl18 "$PROJ_L18"
DEF_L18=$(rc_project_lessons_path projl18)
DEF_L18_ABS="$PROJ_L18/.claude/rules/lessons.md"
# project_lessons_path может отдавать либо уже склеенный абсолютный путь
# (по аналогии с project_path), либо только относительный фрагмент (по
# аналогии с project_integrate, где склейку с project_path делает вызывающий)
# - спека не уточняет форму возврата, только СОДЕРЖИМОЕ ("путь относительно
# корня проекта"). Проверяем суффикс, не конкретную форму.
[[ "$DEF_L18" == *".claude/rules/lessons.md" ]] \
  && ok || fail "L18: project_lessons_path дает дефолт .../.claude/rules/lessons.md (got '$DEF_L18')"
AGL18=$(mk_project_agent agtl18 "$PROJ_L18")
"$RUN" spool-put agtl18 --text "l18-event" >/dev/null
"$RUN" intake "$AGL18" >/dev/null
KL18=$(ls "$AGL18/inbox/pending" | sed 's/.json//')
QL18=$(ask_direct "$AGL18" "l18-asker-key" "L18 продолжать?")
append_trusted_answer "$AGL18" "$KL18" "$QL18" "l18-correction-text-marker-long-enough-value"
write_done_requested "$AGL18" "$KL18" "L18 summary"
mk_done_envelope "$AGL18" "$KL18"
mk_alert_ok "$TMP/l18-alert.log" "$TMP/l18-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l18-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l18-alert.sh" "$RUN" done-notify "$AGL18" >/dev/null 2>"$TMP/l18.err"
CID8_L18=$(lesson_first_cid8 "$AGL18/lessons.json")
"$RUN" lesson-verdict "$AGL18" --accept --id "$CID8_L18" >/dev/null 2>"$TMP/l18v.err"
[[ -f "$DEF_L18_ABS" ]] && ok || fail "L18: файл уроков создан по дефолтному пути ($DEF_L18_ABS)"
grep -qF "l18-essence-marker" "$DEF_L18_ABS" && ok || fail "L18: essence урока записана в файл"

# =============================================================== L19
echo "=== L19: путь из формы B перекрывает дефолт ==="
PROJ_L19="$TMP/proj-l19"; mkdir -p "$PROJ_L19"
register_obj_project projl19 "$PROJ_L19" "docs/team-lessons.md"
PATH_L19=$(rc_project_lessons_path projl19)
[[ "$PATH_L19" == *"docs/team-lessons.md" ]] \
  && ok || fail "L19: project_lessons_path резолвит явный путь формы B (got '$PATH_L19')"
AGL19=$(mk_project_agent agtl19 "$PROJ_L19")
"$RUN" spool-put agtl19 --text "l19-event" >/dev/null
"$RUN" intake "$AGL19" >/dev/null
KL19=$(ls "$AGL19/inbox/pending" | sed 's/.json//')
QL19=$(ask_direct "$AGL19" "l19-asker-key" "L19 продолжать?")
append_trusted_answer "$AGL19" "$KL19" "$QL19" "l19-correction-text-marker-long-enough-value"
write_done_requested "$AGL19" "$KL19" "L19 summary"
mk_done_envelope "$AGL19" "$KL19"
mk_alert_ok "$TMP/l19-alert.log" "$TMP/l19-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l19-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l19-alert.sh" "$RUN" done-notify "$AGL19" >/dev/null 2>"$TMP/l19.err"
CID8_L19=$(lesson_first_cid8 "$AGL19/lessons.json")
"$RUN" lesson-verdict "$AGL19" --accept --id "$CID8_L19" >/dev/null 2>"$TMP/l19v.err"
[[ -f "$PROJ_L19/docs/team-lessons.md" ]] && ok || fail "L19: файл уроков создан по явному пути формы B, не по дефолту"
[[ ! -f "$PROJ_L19/.claude/rules/lessons.md" ]] && ok || fail "L19: дефолтный путь НЕ использован"
grep -qF "l19-essence-marker" "$PROJ_L19/docs/team-lessons.md" && ok || fail "L19: essence урока в явном файле"

# =============================================================== L20 (falsifiability: см. финальный ответ)
echo "=== L20: дедуп по candidate_id - повторная запись не дублирует строку в файле ==="
PROJ_L20="$TMP/proj-l20"; mkdir -p "$PROJ_L20"
register_flat_project projl20 "$PROJ_L20"
AGL20=$(mk_project_agent agtl20 "$PROJ_L20")
"$RUN" spool-put agtl20 --text "l20-event" >/dev/null
"$RUN" intake "$AGL20" >/dev/null
KL20=$(ls "$AGL20/inbox/pending" | sed 's/.json//')
QL20=$(ask_direct "$AGL20" "l20-asker-key" "L20 продолжать?")
append_trusted_answer "$AGL20" "$KL20" "$QL20" "l20-correction-text-marker-long-enough-value"
write_done_requested "$AGL20" "$KL20" "L20 summary"
mk_done_envelope "$AGL20" "$KL20"
mk_alert_ok "$TMP/l20-alert.log" "$TMP/l20-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l20-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l20-alert.sh" "$RUN" done-notify "$AGL20" >/dev/null 2>"$TMP/l20.err"
CID8_L20=$(lesson_first_cid8 "$AGL20/lessons.json")
"$RUN" lesson-verdict "$AGL20" --accept --id "$CID8_L20" >/dev/null 2>"$TMP/l20v1.err"
"$RUN" lesson-verdict "$AGL20" --accept --id "$CID8_L20" >/dev/null 2>"$TMP/l20v2.err"
LESSONS_L20="$PROJ_L20/.claude/rules/lessons.md"
[[ -f "$LESSONS_L20" ]] && ok || fail "L20: файл уроков создан"
CNT_L20=$(grep -c "l20-essence-marker" "$LESSONS_L20" 2>/dev/null || echo 0)
[[ "$CNT_L20" == "1" ]] && ok || fail "L20: essence встречается РОВНО один раз после двух --accept подряд (got $CNT_L20)"

# =============================================================== L21
echo "=== L21: коммит не сделан - дерево проекта осталось грязным ровно на один файл ==="
PROJ_L21="$TMP/proj-l21"; mkdir -p "$PROJ_L21"
mk_git_project "$PROJ_L21"
register_flat_project projl21 "$PROJ_L21"
AGL21=$(mk_project_agent agtl21 "$PROJ_L21")
"$RUN" spool-put agtl21 --text "l21-event" >/dev/null
"$RUN" intake "$AGL21" >/dev/null
KL21=$(ls "$AGL21/inbox/pending" | sed 's/.json//')
QL21=$(ask_direct "$AGL21" "l21-asker-key" "L21 продолжать?")
append_trusted_answer "$AGL21" "$KL21" "$QL21" "l21-correction-text-marker-long-enough-value"
write_done_requested "$AGL21" "$KL21" "L21 summary"
mk_done_envelope "$AGL21" "$KL21"
mk_alert_ok "$TMP/l21-alert.log" "$TMP/l21-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l21-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l21-alert.sh" "$RUN" done-notify "$AGL21" >/dev/null 2>"$TMP/l21.err"
CID8_L21=$(lesson_first_cid8 "$AGL21/lessons.json")
"$RUN" lesson-verdict "$AGL21" --accept --id "$CID8_L21" >/dev/null 2>"$TMP/l21v.err"
STATUS_L21=$(git -C "$PROJ_L21" status --porcelain)
[[ -n "$STATUS_L21" ]] && ok || fail "L21: дерево проекта не чистое (урок не закоммичен)"
UNTRACKED_L21=$(git -C "$PROJ_L21" status --porcelain | grep -c '^??')
[[ "$UNTRACKED_L21" -ge 1 ]] && ok || fail "L21: есть непровожденный (untracked/modified) файл уроков"
LOG_L21=$(git -C "$PROJ_L21" log --oneline | wc -l | tr -d ' ')
[[ "$LOG_L21" == "1" ]] && ok || fail "L21: история проекта не выросла (только исходный init-коммит), got $LOG_L21"

# =============================================================== L22
echo "=== L22: проекта нет в реестре - отказ шага с attention, урок не потерян молча ==="
PROJ_L22="$TMP/proj-l22"; mkdir -p "$PROJ_L22"
# Регистрируем и создаем агента ЧЕРЕЗ реальный create (control.json настоящий,
# валидный - иначе attention через control-cas негде проверить, см. финальный
# ответ), затем СНИМАЕМ регистрацию проекта из реестра - симулирует дрейф
# "проект был в реестре при создании агента, пропал к моменту подтверждения
# урока" (create бы сам отказал на незарегистрированном имени, поэтому
# регистрация снимается ПОСЛЕ create, не до).
register_flat_project projl22 "$PROJ_L22"
AGL22=$(mk_project_agent agtl22 "$PROJ_L22")
: > "$CLAUDE_RC_PROJECTS_FILE"  # проект пропал из реестра
"$RUN" spool-put agtl22 --text "l22-event" >/dev/null
"$RUN" intake "$AGL22" >/dev/null
KL22=$(ls "$AGL22/inbox/pending" | sed 's/.json//')
QL22=$(ask_direct "$AGL22" "l22-asker-key" "L22 продолжать?")
append_trusted_answer "$AGL22" "$KL22" "$QL22" "l22-correction-text-marker-long-enough-value"
write_done_requested "$AGL22" "$KL22" "L22 summary"
mk_done_envelope "$AGL22" "$KL22"
mk_alert_ok "$TMP/l22-alert.log" "$TMP/l22-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l22-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l22-alert.sh" "$RUN" done-notify "$AGL22" >/dev/null 2>"$TMP/l22.err"
CID8_L22=$(lesson_first_cid8 "$AGL22/lessons.json" 2>/dev/null)
if [[ -n "$CID8_L22" ]]; then
  "$RUN" lesson-verdict "$AGL22" --accept --id "$CID8_L22" >"$TMP/l22v.out" 2>"$TMP/l22v.err"; RCL22=$?
  [[ "$RCL22" != 0 ]] && ok || fail "L22: accept на незарегистрированном проекте -> отказ (exit != 0, got $RCL22)"
  [[ -s "$TMP/l22v.err" ]] && ok || fail "L22: сообщение об ошибке непусто"
  ATT_L22=$(jq_file "$AGL22/control.json" 'd.get("attention")')
  [[ "$ATT_L22" != "None" ]] && ok || fail "L22: attention выставлен на агенте (незарегистрированный проект)"
else
  fail "L22: fixture - кандидат не создан (нельзя проверить отказ на записи)"
  fail "L22: fixture - кандидат не создан (нельзя проверить attention)"
fi

# =============================================================== L23
echo "=== L23: запись идет в основной каталог проекта, не в worktree - переживает уборку задачи ==="
PROJ_L23="$TMP/proj-l23"; mkdir -p "$PROJ_L23"
mk_git_project "$PROJ_L23"
register_flat_project projl23 "$PROJ_L23"
AGL23=$(mk_worktree_project_agent agtl23 "$PROJ_L23")
"$RUN" spool-put agtl23 --text "l23-event" >/dev/null
"$RUN" intake "$AGL23" >/dev/null
KL23=$(ls "$AGL23/inbox/pending" | sed 's/.json//')
QL23=$(ask_direct "$AGL23" "l23-asker-key" "L23 продолжать?")
append_trusted_answer "$AGL23" "$KL23" "$QL23" "l23-correction-text-marker-long-enough-value"
( cd "$AGL23/work" && echo "l23 change" > l23.txt && git add l23.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "l23 commit" )
write_done_requested "$AGL23" "$KL23" "L23 summary"
mk_done_envelope "$AGL23" "$KL23"
mk_alert_ok "$TMP/l23-alert.log" "$TMP/l23-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l23-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l23-alert.sh" "$RUN" done-notify "$AGL23" >/dev/null 2>"$TMP/l23.err"
CID8_L23=$(lesson_first_cid8 "$AGL23/lessons.json")
"$RUN" lesson-verdict "$AGL23" --accept --id "$CID8_L23" >/dev/null 2>"$TMP/l23v.err"
[[ -f "$PROJ_L23/.claude/rules/lessons.md" ]] && ok || fail "L23: файл уроков в ОСНОВНОМ каталоге проекта (не worktree)"
[[ ! -f "$AGL23/work/.claude/rules/lessons.md" ]] && ok || fail "L23: файла уроков нет внутри worktree задачи"
# симулируем уборку задачи (снос worktree) - урок обязан пережить это
rm -rf "$AGL23/work"
grep -qF "l23-essence-marker" "$PROJ_L23/.claude/rules/lessons.md" \
  && ok || fail "L23: урок пережил снос worktree задачи"

####################################################################
# Промпт (§7, L24-L28)
####################################################################

run_step_prompt() { # <agent-dir> <event-key-suffix> <event-text> <dump-file> -> прогоняет step с реальным ok-моком, дампит промпт
  local dir="$1" name="$2" text="$3" dump="$4"
  "$RUN" spool-put "$name" --text "$text" >/dev/null
  "$RUN" intake "$dir" >/dev/null
  CLAUDE_BIN="$STEP_MOCK" PROMPT_DUMP_FILE="$dump" "$RUN" step "$dir" >/dev/null 2>"$TMP/$name-step.err"
}

# =============================================================== L24
echo "=== L24: подтвержденный урок появляется в промпте следующей задачи того же проекта ==="
PROJ_L24="$TMP/proj-l24"; mkdir -p "$PROJ_L24"
register_flat_project projl24 "$PROJ_L24"
# задача A: рождает и подтверждает урок
AGL24A=$(mk_project_agent agtl24a "$PROJ_L24")
"$RUN" spool-put agtl24a --text "l24a-event" >/dev/null
"$RUN" intake "$AGL24A" >/dev/null
KL24A=$(ls "$AGL24A/inbox/pending" | sed 's/.json//')
QL24A=$(ask_direct "$AGL24A" "l24a-asker-key" "L24a продолжать?")
append_trusted_answer "$AGL24A" "$KL24A" "$QL24A" "l24-correction-text-marker-long-enough-value"
write_done_requested "$AGL24A" "$KL24A" "L24a summary"
mk_done_envelope "$AGL24A" "$KL24A"
mk_alert_ok "$TMP/l24a-alert.log" "$TMP/l24a-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l24-confirmed-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l24a-alert.sh" "$RUN" done-notify "$AGL24A" >/dev/null 2>"$TMP/l24a.err"
CID8_L24=$(lesson_first_cid8 "$AGL24A/lessons.json")
"$RUN" lesson-verdict "$AGL24A" --accept --id "$CID8_L24" >/dev/null 2>"$TMP/l24av.err"
# задача B: новая задача того же проекта - должна увидеть урок в промпте
AGL24B=$(mk_project_agent agtl24b "$PROJ_L24")
PROMPT_L24B="$TMP/l24b-prompt.txt"
run_step_prompt "$AGL24B" agtl24b "l24b-event" "$PROMPT_L24B"
[[ -s "$PROMPT_L24B" ]] && ok || fail "L24: промпт задачи B сдампен"
grep -qF "l24-confirmed-essence-marker" "$PROMPT_L24B" \
  && ok || fail "L24: подтвержденный урок присутствует в промпте следующей задачи того же проекта"

# =============================================================== L25
echo "=== L25: неподтвержденный кандидат не появляется нигде в промпте ==="
PROJ_L25="$TMP/proj-l25"; mkdir -p "$PROJ_L25"
register_flat_project projl25 "$PROJ_L25"
AGL25A=$(mk_project_agent agtl25a "$PROJ_L25")
"$RUN" spool-put agtl25a --text "l25a-event" >/dev/null
"$RUN" intake "$AGL25A" >/dev/null
KL25A=$(ls "$AGL25A/inbox/pending" | sed 's/.json//')
QL25A=$(ask_direct "$AGL25A" "l25a-asker-key" "L25a продолжать?")
append_trusted_answer "$AGL25A" "$KL25A" "$QL25A" "l25-correction-text-marker-long-enough-value"
write_done_requested "$AGL25A" "$KL25A" "L25a summary"
mk_done_envelope "$AGL25A" "$KL25A"
mk_alert_ok "$TMP/l25a-alert.log" "$TMP/l25a-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l25-unconfirmed-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l25a-alert.sh" "$RUN" done-notify "$AGL25A" >/dev/null 2>"$TMP/l25a.err"
# НЕ подтверждаем (нет lesson-verdict --accept)
AGL25B=$(mk_project_agent agtl25b "$PROJ_L25")
PROMPT_L25B="$TMP/l25b-prompt.txt"
run_step_prompt "$AGL25B" agtl25b "l25b-event" "$PROMPT_L25B"
[[ -s "$PROMPT_L25B" ]] && ok || fail "L25: промпт задачи B сдампен"
grep -qF "l25-unconfirmed-essence-marker" "$PROMPT_L25B" \
  && fail "L25: неподтвержденный кандидат не должен попасть в промпт" || ok

# =============================================================== L26
echo "=== L26: задача другого проекта уроков не видит ==="
PROJ_L26A="$TMP/proj-l26a"; mkdir -p "$PROJ_L26A"
PROJ_L26B="$TMP/proj-l26b"; mkdir -p "$PROJ_L26B"
register_flat_project projl26a "$PROJ_L26A"
register_flat_project projl26b "$PROJ_L26B"
AGL26A=$(mk_project_agent agtl26a "$PROJ_L26A")
"$RUN" spool-put agtl26a --text "l26a-event" >/dev/null
"$RUN" intake "$AGL26A" >/dev/null
KL26A=$(ls "$AGL26A/inbox/pending" | sed 's/.json//')
QL26A=$(ask_direct "$AGL26A" "l26a-asker-key" "L26a продолжать?")
append_trusted_answer "$AGL26A" "$KL26A" "$QL26A" "l26-correction-text-marker-long-enough-value"
write_done_requested "$AGL26A" "$KL26A" "L26a summary"
mk_done_envelope "$AGL26A" "$KL26A"
mk_alert_ok "$TMP/l26a-alert.log" "$TMP/l26a-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l26-cross-project-essence-marker" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l26a-alert.sh" "$RUN" done-notify "$AGL26A" >/dev/null 2>"$TMP/l26a.err"
CID8_L26=$(lesson_first_cid8 "$AGL26A/lessons.json")
"$RUN" lesson-verdict "$AGL26A" --accept --id "$CID8_L26" >/dev/null 2>"$TMP/l26av.err"
grep -qF "l26-cross-project-essence-marker" "$PROJ_L26A/.claude/rules/lessons.md" \
  && ok || fail "L26: fixture - урок реально записан в проект A"
AGL26B=$(mk_project_agent agtl26b "$PROJ_L26B")
PROMPT_L26B="$TMP/l26b-prompt.txt"
run_step_prompt "$AGL26B" agtl26b "l26b-event" "$PROMPT_L26B"
[[ -s "$PROMPT_L26B" ]] && ok || fail "L26: промпт задачи проекта B сдампен"
grep -qF "l26-cross-project-essence-marker" "$PROMPT_L26B" \
  && fail "L26: урок проекта A не должен попасть в промпт задачи проекта B" || ok

# =============================================================== L27
echo "=== L27: кап CLAUDE_AGENT_LESSONS_MAX_BYTES - отброшены самые старые записи, новые остаются ==="
PROJ_L27="$TMP/proj-l27"; mkdir -p "$PROJ_L27"
register_flat_project projl27 "$PROJ_L27"
mkdir -p "$PROJ_L27/.claude/rules"
python3 -c 'import sys
lines = []
for i in range(1, 21):
    lines.append("- l27-lesson-%02d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" % i)
open(sys.argv[1], "w").write("\n".join(lines) + "\n")' "$PROJ_L27/.claude/rules/lessons.md"
AGL27=$(mk_project_agent agtl27 "$PROJ_L27")
PROMPT_L27="$TMP/l27-prompt.txt"
CLAUDE_AGENT_LESSONS_MAX_BYTES=800
export CLAUDE_AGENT_LESSONS_MAX_BYTES
"$RUN" spool-put agtl27 --text "l27-event" >/dev/null
"$RUN" intake "$AGL27" >/dev/null
CLAUDE_BIN="$STEP_MOCK" PROMPT_DUMP_FILE="$PROMPT_L27" "$RUN" step "$AGL27" >/dev/null 2>"$TMP/l27.err"
unset CLAUDE_AGENT_LESSONS_MAX_BYTES
[[ -s "$PROMPT_L27" ]] && ok || fail "L27: промпт сдампен"
grep -qF "l27-lesson-01-" "$PROMPT_L27" \
  && fail "L27: самая старая запись не должна поместиться в урезанный (800 байт) блок уроков" || ok
grep -qF "l27-lesson-20-" "$PROMPT_L27" \
  && ok || fail "L27: самая свежая запись присутствует"
# маркер усечения дословно зафиксирован контрактом (§7): "[уроки усечены:
# не поместилось N]" - проверяем литеральный текст, не общее "что-то про
# усечение" (см. ambiguity-заметку 5 - контракт с тех пор дополнен).
grep -qF "[уроки усечены: не поместилось " "$PROMPT_L27" \
  && ok || fail "L27: маркер усечения '[уроки усечены: не поместилось N]' присутствует дословно"

# =============================================================== L28
echo "=== L28: файла уроков нет/пуст - блока нет вовсе, промпт байт-в-байт как без уроков ==="
PROJ_L28A="$TMP/proj-l28a"; mkdir -p "$PROJ_L28A"   # без .claude/rules/lessons.md вовсе
PROJ_L28B="$TMP/proj-l28b"; mkdir -p "$PROJ_L28B/.claude/rules"
: > "$PROJ_L28B/.claude/rules/lessons.md"           # файл есть, но пуст
register_flat_project projl28a "$PROJ_L28A"
register_flat_project projl28b "$PROJ_L28B"
AGL28A=$(mk_project_agent agtl28a "$PROJ_L28A")
AGL28B=$(mk_project_agent agtl28b "$PROJ_L28B")
PROMPT_L28A="$TMP/l28a-prompt.txt"; PROMPT_L28B="$TMP/l28b-prompt.txt"
run_step_prompt "$AGL28A" agtl28a "l28-shared-marker-text" "$PROMPT_L28A"
run_step_prompt "$AGL28B" agtl28b "l28-shared-marker-text" "$PROMPT_L28B"
[[ -s "$PROMPT_L28A" && -s "$PROMPT_L28B" ]] && ok || fail "L28: оба промпта сдампены"
mask_agentname() { # маскируем несущественные различия фикстур: имя агента,
  # случайный event-key и wall-clock таймстемп spooled_at (spool-put
  # генерирует новые на каждый вызов, к дистилляции уроков отношения нет)
  sed -E \
    -e "s/agtl28[ab]/<AGENT>/g" \
    -e "s/^key: [0-9a-f]+$/key: <KEY>/" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/g' \
    "$1"
}
[[ "$(mask_agentname "$PROMPT_L28A")" == "$(mask_agentname "$PROMPT_L28B")" ]] \
  && ok || fail "L28: промпт 'файла нет' и промпт 'файл пуст' идентичны (после маскировки имени агента)"

####################################################################
# Живучесть (§8, L29-L31)
####################################################################

# =============================================================== L29 (falsifiability: см. финальный ответ)
echo "=== L29: падение прогона модели - карточка уходит без хвоста, attention выставлен, приемка не сломана ==="
# реальный create (не голая mk_event-фикстура): attention пишется через
# control-cas, которому нужен настоящий валидный control.json (seq/generation/
# lease/acceptance/hold) - см. финальный ответ.
PROJ_L29="$TMP/proj-l29"; mkdir -p "$PROJ_L29"
register_flat_project projl29 "$PROJ_L29"
AGL29=$(mk_project_agent agtl29 "$PROJ_L29")
"$RUN" spool-put agtl29 --text "l29-event" >/dev/null
"$RUN" intake "$AGL29" >/dev/null
KL29=$(ls "$AGL29/inbox/pending" | sed 's/.json//')
QL29=$(ask_direct "$AGL29" "l29-asker-key" "L29 продолжать?")
append_trusted_answer "$AGL29" "$KL29" "$QL29" "l29-correction-text-marker-long-enough-value"
write_done_requested "$AGL29" "$KL29" "L29 summary"
mk_done_envelope "$AGL29" "$KL29"
mk_alert_ok "$TMP/l29-alert.log" "$TMP/l29-alert.sh"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=fail \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l29-alert.sh" "$RUN" done-notify "$AGL29" >/dev/null 2>"$TMP/l29.err"; RCL29=$?
[[ "$RCL29" == 0 ]] && ok || fail "L29: done-notify exit 0 даже при падении модели (приемка не сломана, got $RCL29)"
[[ "$(alert_block_count "$TMP/l29-alert.log")" == "1" ]] \
  && ok || fail "L29: карточка готовности все равно отправлена (ровно один вызов alert-команды)"
[[ ! -f "$AGL29/lessons.json" ]] && ok || fail "L29: lessons.json не создан при падении модели"
if [[ -f "$AGL29/control.json" ]]; then
  ATT_L29=$(jq_file "$AGL29/control.json" 'd.get("attention")')
  [[ "$ATT_L29" != "None" ]] && ok || fail "L29: attention выставлен с причиной lessons (got $ATT_L29)"
else
  fail "L29: control.json не создан - attention негде проверить (нет сигнала об отказе шага)"
fi

# =============================================================== L30
echo "=== L30: обрыв между записью lessons.json и отправкой карточки - доигрывание без задвоения (модель не перезапускается) ==="
AGL30=$(mk_event evtl30)
"$RUN" spool-put evtl30 --text "l30-event" >/dev/null
"$RUN" intake "$AGL30" >/dev/null
KL30=$(ls "$AGL30/inbox/pending" | sed 's/.json//')
QL30=$(ask_direct "$AGL30" "l30-asker-key" "L30 продолжать?")
append_trusted_answer "$AGL30" "$KL30" "$QL30" "l30-correction-text-marker-long-enough-value"
write_done_requested "$AGL30" "$KL30" "L30 summary"
mk_done_envelope "$AGL30" "$KL30"
mk_alert_ok "$TMP/l30-alert.log" "$TMP/l30-alert.sh"
MOCK_CALLED_L30_1="$TMP/l30-called-1"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l30-essence-marker" \
  MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L30_1" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l30-alert.sh" "$RUN" done-notify "$AGL30" >/dev/null 2>"$TMP/l30a.err"
[[ -f "$MOCK_CALLED_L30_1" ]] && ok || fail "L30: fixture - первый проход реально вызвал модель"
[[ -f "$AGL30/lessons.json" ]] && ok || fail "L30: fixture - lessons.json записан первым проходом"
CNT_L30_1=$(alert_block_count "$TMP/l30-alert.log")
# симулируем обрыв ПОСЛЕ записи lessons.json, ДО отправки карточки: сбрасываем
# pushed_at обратно на null (шов, который уже использует §2/N12-N15 - "гейт
# 'шлем ровно один раз' по pushed_at"), карточка в этом прогоне УЖЕ была
# отправлена штатно (mk_alert_ok сработал), поэтому явно откатываем счетчик
# лога отдельно и проверяем повторный проход как "доигрывание".
MOCK_CALLED_L30_2="$TMP/l30-called-2"
python3 -c 'import json,sys
p = sys.argv[1] + "/done.json"
d = json.load(open(p)); d["pushed_at"] = None
json.dump(d, open(p, "w"), ensure_ascii=False)' "$AGL30"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="l30-essence-marker" \
  MOCK_LESSON_CALLED_FILE="$MOCK_CALLED_L30_2" \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l30-alert.sh" "$RUN" done-notify "$AGL30" >/dev/null 2>"$TMP/l30b.err"
[[ ! -f "$MOCK_CALLED_L30_2" ]] \
  && ok || fail "L30: повторный проход НЕ перезапускает модель (lessons.json уже есть для этой задачи)"
CID_COUNT_L30=$(lesson_id_count "$AGL30/lessons.json")
[[ "$CID_COUNT_L30" == "1" ]] && ok || fail "L30: повторный проход не задвоил кандидатов (got $CID_COUNT_L30)"
CNT_L30_2=$(alert_block_count "$TMP/l30-alert.log")
[[ "$CNT_L30_2" -gt "$CNT_L30_1" ]] \
  && ok || fail "L30: карточка все же доставлена доигрыванием после сброса pushed_at ($CNT_L30_1 -> $CNT_L30_2)"

# =============================================================== L31
echo "=== L31: два агента одного проекта финишируют одновременно - обе записи в файле, ни одна не потеряна ==="
PROJ_L31="$TMP/proj-l31"; mkdir -p "$PROJ_L31"
register_flat_project projl31 "$PROJ_L31"
mk_lesson_ready_for_verdict() { # <name> <essence-marker> -> печатает "agent-dir cid8" (готов к lesson-verdict, но еще не подтвержден)
  local name="$1" essence="$2"
  local dir; dir=$(mk_project_agent "$name" "$PROJ_L31")
  "$RUN" spool-put "$name" --text "$name-event" >/dev/null
  "$RUN" intake "$dir" >/dev/null
  local key; key=$(ls "$dir/inbox/pending" | sed 's/.json//')
  local qid; qid=$(ask_direct "$dir" "$name-asker-key" "$name продолжать?")
  append_trusted_answer "$dir" "$key" "$qid" "$name-correction-text-marker-long-enough-value"
  write_done_requested "$dir" "$key" "$name summary"
  mk_done_envelope "$dir" "$key"
  mk_alert_ok "$TMP/$name-alert.log" "$TMP/$name-alert.sh"
  CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one MOCK_LESSON_ESSENCE="$essence" \
    CLAUDE_AGENT_ALERT_CMD="$TMP/$name-alert.sh" "$RUN" done-notify "$dir" >/dev/null 2>"$TMP/$name-notify.err"
  echo "$dir $(lesson_first_cid8 "$dir/lessons.json")"
}
read -r AGL31A CID8_L31A < <(mk_lesson_ready_for_verdict agtl31a l31a-concurrent-essence-marker)
read -r AGL31B CID8_L31B < <(mk_lesson_ready_for_verdict agtl31b l31b-concurrent-essence-marker)
"$RUN" lesson-verdict "$AGL31A" --accept --id "$CID8_L31A" >"$TMP/l31a.out" 2>"$TMP/l31a.err" &
PID31A=$!
"$RUN" lesson-verdict "$AGL31B" --accept --id "$CID8_L31B" >"$TMP/l31b.out" 2>"$TMP/l31b.err" &
PID31B=$!
wait "$PID31A"; RC31A=$?
wait "$PID31B"; RC31B=$?
[[ "$RC31A" == 0 ]] && ok || fail "L31: агент A - exit 0 ($(cat "$TMP/l31a.err"))"
[[ "$RC31B" == 0 ]] && ok || fail "L31: агент B - exit 0 ($(cat "$TMP/l31b.err"))"
LESSONS_L31="$PROJ_L31/.claude/rules/lessons.md"
[[ -f "$LESSONS_L31" ]] && ok || fail "L31: файл уроков создан"
grep -qF "l31a-concurrent-essence-marker" "$LESSONS_L31" && ok || fail "L31: запись агента A не потеряна"
grep -qF "l31b-concurrent-essence-marker" "$LESSONS_L31" && ok || fail "L31: запись агента B не потеряна"

# =============================================================== L32
echo "=== L32: кап CLAUDE_AGENT_LESSONS_INPUT_MAX_BYTES - в промпт дистилляции ушли только свежие поправки ==="
AGL32=$(mk_event evtl32)
"$RUN" spool-put evtl32 --text "l32-event" >/dev/null
"$RUN" intake "$AGL32" >/dev/null
KL32=$(ls "$AGL32/inbox/pending" | sed 's/.json//')
QL32=$(ask_direct "$AGL32" "l32-asker-key" "L32 продолжать?")
PAD_L32=$(python3 -c 'print(" ".join("pad%d" % j for j in range(20)))')
for i in 1 2 3 4 5; do
  append_trusted_answer "$AGL32" "$KL32" "$QL32" "l32-marker-$i-$PAD_L32" "$((8 + i))"
done
write_done_requested "$AGL32" "$KL32" "L32 summary"
mk_done_envelope "$AGL32" "$KL32"
mk_alert_ok "$TMP/l32-alert.log" "$TMP/l32-alert.sh"
PROMPT_L32="$TMP/l32-prompt.txt"
CLAUDE_BIN="$LESSON_MOCK" MOCK_LESSON_MODE=one PROMPT_DUMP_FILE="$PROMPT_L32" \
  CLAUDE_AGENT_LESSONS_INPUT_MAX_BYTES=300 \
  CLAUDE_AGENT_ALERT_CMD="$TMP/l32-alert.sh" "$RUN" done-notify "$AGL32" >/dev/null 2>"$TMP/l32.err"
[[ -s "$PROMPT_L32" ]] && ok || fail "L32: промпт дистилляции сдампен (модель вызвана)"
grep -qF "l32-marker-1-" "$PROMPT_L32" \
  && fail "L32: самая старая поправка (1) не должна поместиться в урезанный (250 байт) вход" || ok
grep -qF "l32-marker-3-" "$PROMPT_L32" \
  && fail "L32: третья по старшинству поправка (3) тоже не должна поместиться" || ok
grep -qF "l32-marker-5-" "$PROMPT_L32" \
  && ok || fail "L32: самая свежая поправка (5) присутствует"
grep -qF "l32-marker-4-" "$PROMPT_L32" \
  && ok || fail "L32: предпоследняя поправка (4) присутствует"
grep -qE '\[поправки усечены: не поместилось 3 самых старых\]' "$PROMPT_L32" \
  && ok || fail "L32: промпт явно называет число непоместившихся поправок (3)"

echo
echo "test-agent-lessons: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
