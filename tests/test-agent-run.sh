#!/usr/bin/env bash
# Tests for bin/claude-agent-run: spool/intake/executor/dlq/restore (этап 4).
# Контракт: design §10-11 + design delta 2026-07-12 (Д1-Д6).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true   # infra здорова по умолчанию

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
assert() { # <desc> <expected-exit> <cmd...>
  local desc="$1" want="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [[ "$got" == "$want" ]]; then ok; else
    fail "$desc: exit $got != $want ($(head -c150 "$TMP/err"))"; fi
}
jq_file() { # <file> <py-expr over dict d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
key_of() { # <seq> -> key конверта (sha256(source_ns+native_id)[:32])
  python3 -c 'import hashlib,sys
print(hashlib.sha256(("spool:evt"+sys.argv[1]).encode()).hexdigest()[:32])' "$1"
}
drain() { # выгрести готовые pending, чтобы секции не мешали друг другу
  local i out
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out=$("$RUN" step "$AG" 2>/dev/null)
    [[ "$out" == "ran" ]] || break
  done
}

# --- fixture: event-агент вручную (без CLI - юнит-скоуп) ---
AG="$CLAUDE_AGENTS_DIR/evt"
IB="$AG/inbox"
SP="$CLAUDE_AGENT_SPOOL_BASE/evt"
mkdir -p "$AG" "$SP"
chmod 0700 "$SP"
cat > "$AG/spec.yaml" <<EOF
schema: 1
name: evt
type: event
role: none
goal: "unit test event agent"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt

# mock claude: исход управляется файлом $TMP/mock-mode
MOCK="$TMP/mock-claude"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # съесть промпт
mode=$(cat "$MOCK_MODE_FILE" 2>/dev/null || echo ok)
case "$mode" in
  ok)   echo '{"type":"result","result":"обработано","total_cost_usd":0.01}' ;;
  fail) echo "boom" >&2; exit 1 ;;
  hang) sleep 60 ;;
esac
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK" MOCK_MODE_FILE="$TMP/mock-mode"
echo ok > "$MOCK_MODE_FILE"

# ------------------------------------------------------------ spool-put (Д1)
assert "spool-put text"      0 "$RUN" spool-put evt --text "задача один"
[[ "$(cat "$TMP/out")" == "1" ]] && ok || fail "первый seq = 1"
assert "spool-put json"      0 "$RUN" spool-put evt --json '{"text":"два"}'
[[ "$(cat "$TMP/out")" == "2" ]] && ok || fail "второй seq = 2"
[[ -f "$SP/ev-0000000000001.json" && -f "$SP/ev-0000000000002.json" ]] \
  && ok || fail "файлы событий опубликованы"
[[ "$(cat "$SP/.seq")" == "2" ]] && ok || fail ".seq = 2"

# идемпотентность --id: повтор дает тот же seq, дубля нет
assert "spool-put --id"      0 "$RUN" spool-put evt --text "три" --id tg:777
SEQ3="$(cat "$TMP/out")"
assert "spool-put --id повтор" 0 "$RUN" spool-put evt --text "три" --id tg:777
[[ "$(cat "$TMP/out")" == "$SEQ3" ]] && ok || fail "--id повтор: тот же seq"
[[ "$(ls "$SP"/ev-*.json | wc -l | tr -d ' ')" == "3" ]] \
  && ok || fail "--id повтор: дубль не создан"

# crash-протокол: .seq впереди файлов (резерв без публикации) - не коллизия
echo 10 > "$SP/.seq"
assert "spool-put после дыры" 0 "$RUN" spool-put evt --text "после дыры"
[[ "$(cat "$TMP/out")" == "11" ]] && ok || fail "seq после дыры = 11"

# капы: событие > лимита отбито
big=$(python3 -c 'print("x" * 300000)')
assert "event too large"     6 "$RUN" spool-put evt --text "$big"

# безопасность: symlink вместо spool - отказ
mkdir -p "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$CLAUDE_AGENT_SPOOL_BASE/lnk"
assert "symlink spool отбит" 7 "$RUN" spool-put lnk --text x

# ------------------------------------------------------------- intake (Д2)
assert "intake" 0 "$RUN" intake "$AG"
[[ "$(ls "$IB/pending" | wc -l | tr -d ' ')" == "4" ]] \
  && ok || fail "intake: 4 pending (1,2,3,11)"
[[ "$(jq_file "$IB/cursor.json" 'd["position"]')" == "11" ]] \
  && ok || fail "cursor = 11 (дыра 4-10 не блокирует)"
assert "intake повтор" 0 "$RUN" intake "$AG"
[[ "$(ls "$IB/pending" | wc -l | tr -d ' ')" == "4" ]] \
  && ok || fail "re-intake: дублей нет"

# конверт: schema + meta
K1=$(ls "$IB/pending" | head -1 | sed 's/.json//')
[[ "$(jq_file "$IB/pending/$K1.json" 'd["meta"]["attempts"]')" == "0" ]] \
  && ok || fail "конверт: attempts=0"

# ------------------------------------------------------- executor OK (§11.2)
assert "step ok" 0 "$RUN" step "$AG"
[[ "$(cat "$TMP/out")" == "ran" ]] && ok || fail "step: ran"
[[ "$(ls "$IB/done" | wc -l | tr -d ' ')" == "1" ]] && ok || fail "done: 1"
DONEK=$(ls "$IB/done" | sed 's/.json//')
grep -q "$DONEK" "$IB/dedup.jsonl" && ok || fail "дедуп-леджер пополнен"
[[ "$(jq_file "$IB/done/$DONEK.json" 'd["meta"]["result"]')" == "обработано" ]] \
  && ok || fail "result в done-конверте"
[[ "$(jq_file "$IB/usage.json" 'd["day_runs"]')" == "1" ]] \
  && ok || fail "usage: day_runs=1"
[[ -f "$AG/state.1.json" ]] && ok || fail "state.1.json написан"

# ---------------------------------------------- наблюдаемый FAIL + DLQ (§11.2)
echo fail > "$MOCK_MODE_FILE"
assert "step fail#1" 0 "$RUN" step "$AG"
PK=$(ls "$IB/pending" | while read -r f; do
  a=$(jq_file "$IB/pending/$f" 'd["meta"]["attempts"]'); [[ "$a" == "1" ]] && echo "${f%.json}"; done | head -1)
[[ -n "$PK" ]] && ok || fail "fail: attempts=1, конверт в pending"
clear_backoff() { python3 - "$IB/pending/$1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["meta"]["next_attempt_at"] = None
json.dump(d, open(sys.argv[1], "w"))
PY
}
clear_backoff "$PK"; assert "step fail#2" 0 "$RUN" step "$AG"
clear_backoff "$PK"; assert "step fail#3" 0 "$RUN" step "$AG"
[[ -f "$IB/deadletter/$PK.json" ]] && ok || fail "attempts>=3 -> deadletter"
[[ "$(jq_file "$IB/deadletter/$PK.json" 'd["meta"]["attempts"]')" == "3" ]] \
  && ok || fail "deadletter: attempts=3"

# очередь живет: следующее событие обрабатывается
echo ok > "$MOCK_MODE_FILE"
assert "step после DLQ" 0 "$RUN" step "$AG"
[[ "$(cat "$TMP/out")" == "ran" ]] && ok || fail "ядовитое не клинит очередь"

# --------------------------------------------------------------- dlq CLI (Д6)
assert "dlq list" 0 "$RUN" dlq "$AG"
grep -q "$PK" "$TMP/out" && ok || fail "dlq list содержит key"
assert "dlq requeue" 0 "$RUN" dlq "$AG" --requeue "$PK"
[[ "$(jq_file "$IB/pending/$PK.json" 'd["meta"]["attempts"]')" == "0" ]] \
  && ok || fail "requeue: attempts=0, в pending"
echo fail > "$MOCK_MODE_FILE"
assert "re-fail#1" 0 "$RUN" step "$AG"
clear_backoff "$PK"; assert "re-fail#2" 0 "$RUN" step "$AG"
clear_backoff "$PK"; assert "re-fail#3" 0 "$RUN" step "$AG"
[[ -f "$IB/deadletter/$PK.json" ]] && ok || fail "re-deadletter"
assert "dlq drop" 0 "$RUN" dlq "$AG" --drop "$PK"
[[ -f "$IB/done/$PK.json" ]] && ok || fail "drop -> done tombstone"
grep -q "$PK" "$IB/dedup.jsonl" && ok || fail "drop -> dedup"
echo ok > "$MOCK_MODE_FILE"

# ------------------------------------------------- infra-гейт: FAIL не считан
drain
IS=$("$RUN" spool-put evt --text "инфра-тест"); IK=$(key_of "$IS")
"$RUN" intake "$AG" >/dev/null
echo fail > "$MOCK_MODE_FILE"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/false
assert "step infra-fail" 0 "$RUN" step "$AG"
[[ "$(jq_file "$IB/pending/$IK.json" 'd["meta"]["attempts"]')" == "0" ]] \
  && ok || fail "инфра больна: attempt НЕ засчитан"
[[ "$(jq_file "$IB/runner-status.json" 'bool(d["probe_failed_since"])')" == "True" ]] \
  && ok || fail "probe_failed_since выставлен"
# executor стоит, пока probe болен
assert "step infra_wait" 0 "$RUN" step "$AG"
[[ "$(cat "$TMP/out")" == "infra_wait" ]] && ok || fail "step: infra_wait"
# выздоровление
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
echo ok > "$MOCK_MODE_FILE"
assert "step после infra" 0 "$RUN" step "$AG"
[[ "$(cat "$TMP/out")" == "ran" ]] && ok || fail "после probe ok - ran"

# --------------------------------------------- recovery мертвого runner (N5)
drain
RS=$("$RUN" spool-put evt --text "recovery-тест"); RK=$(key_of "$RS")
"$RUN" intake "$AG" >/dev/null
dead_runner() { # <state-dir> <key>: пометить мертвым и увести в inflight
  python3 - "$IB/$1/$2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["meta"]["runner_pid"] = 999999; d["meta"]["runner_pid_start"] = "42"
json.dump(d, open(sys.argv[1], "w"))
PY
  mv "$IB/$1/$2.json" "$IB/inflight/$2.json"
}
dead_runner pending "$RK"
assert "step recovery" 0 "$RUN" step "$AG"
# recovery вернул в pending (recoveries=1), PICK того же цикла доработал в done
[[ -f "$IB/done/$RK.json" ]] && ok || fail "recovery: конверт восстановлен и дожат"
[[ "$(jq_file "$IB/done/$RK.json" 'd["meta"]["recoveries"]')" == "1" ]] \
  && ok || fail "recovery: recoveries=1 (не attempts)"

# recovery с key в дедупе -> доводится в done (crash между append и rename)
D2=$("$RUN" spool-put evt --text "recovery-done-тест"); DK=$(key_of "$D2")
"$RUN" intake "$AG" >/dev/null
dead_runner pending "$DK"
python3 -c 'import json,sys
open(sys.argv[1],"a").write(json.dumps({"key":sys.argv[2],"done_at":"t"})+"\n")' \
  "$IB/dedup.jsonl" "$DK"
assert "step recovery done" 0 "$RUN" step "$AG"
[[ -f "$IB/done/$DK.json" ]] && ok || fail "key в дедупе -> done идемпотентно"

# ------------------------------------------------ quarantine (recoveries > 5)
drain
QS=$("$RUN" spool-put evt --text "quarantine-тест"); QK=$(key_of "$QS")
"$RUN" intake "$AG" >/dev/null
python3 - "$IB/pending/$QK.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["meta"].update(recoveries=5, runner_pid=999999, runner_pid_start="42")
json.dump(d, open(sys.argv[1], "w"))
PY
mv "$IB/pending/$QK.json" "$IB/inflight/$QK.json"
assert "step quarantine" 0 "$RUN" step "$AG"
[[ "$(jq_file "$IB/pending/$QK.json" 'd["meta"]["quarantined"]')" == "True" ]] \
  && ok || fail "recoveries>5 -> quarantined"
assert "step skip quarantined" 0 "$RUN" step "$AG"
[[ "$(cat "$TMP/out")" == "idle" ]] && ok || fail "PICK пропускает кварантин"
ST=$("$RUN" inbox-status "$AG")
[[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["quarantined"])' "$ST")" == "1" ]] \
  && ok || fail "inbox-status: quarantined=1"
assert "dlq requeue quarantined" 0 "$RUN" dlq "$AG" --requeue "$QK"
[[ "$(jq_file "$IB/pending/$QK.json" 'd["meta"]["quarantined"]')" == "False" ]] \
  && ok || fail "requeue снимает карантин"
assert "step после карантина" 0 "$RUN" step "$AG"
[[ "$(cat "$TMP/out")" == "ran" ]] && ok || fail "после requeue - ran"

# ----------------------------------------------------------- бюджет (Д5)
sed -i.bak 's/runs_per_day: 100/runs_per_day: 1/' "$AG/spec.yaml"
python3 - "$IB/usage.json" <<'PY'
import json, sys
from datetime import datetime, timezone
d = json.load(open(sys.argv[1]))
d["day"] = datetime.now(timezone.utc).strftime("%Y-%m-%d")
d["day_runs"] = 5
json.dump(d, open(sys.argv[1], "w"))
PY
"$RUN" spool-put evt --text "за капом" >/dev/null
"$RUN" intake "$AG" >/dev/null
assert "step exhausted" 0 "$RUN" step "$AG"
[[ "$(cat "$TMP/out")" == "exhausted" ]] && ok || fail "кап -> exhausted"
[[ "$(jq_file "$IB/usage.json" 'bool(d["exhausted_until"])')" == "True" ]] \
  && ok || fail "exhausted_until durable"
# intake продолжает при капе (§10.2)
"$RUN" spool-put evt --text "интейк при капе" >/dev/null
assert "intake при капе" 0 "$RUN" intake "$AG"
mv "$AG/spec.yaml.bak" "$AG/spec.yaml"

# откат часов не сбрасывает счетчики (Д5): stored day в "будущем" (2099)
# симулирует машину, у которой часы откатились назад
python3 - "$IB/usage.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["day"] = "2099-01-01"; d["day_runs"] = 77
d.pop("exhausted_until", None)
json.dump(d, open(sys.argv[1], "w"))
PY
"$RUN" step "$AG" >/dev/null 2>&1
[[ "$(jq_file "$IB/usage.json" 'd["day"]')" == "2099-01-01" ]] \
  && ok || fail "откат часов: период не откатился"
[[ "$(jq_file "$IB/usage.json" 'd["day_runs"] >= 77')" == "True" ]] \
  && ok || fail "откат часов: счетчики не сброшены"
python3 - "$IB/usage.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["day"] = "2020-01-01"; d["day_runs"] = 0
json.dump(d, open(sys.argv[1], "w"))
PY

# ------------------------------------------------------- wedge/backpressure
# свежий агент: кап inbox=2 (spool-кап 2x2=4 - хватает на 3 события)
AG2="$CLAUDE_AGENTS_DIR/evt2"; IB2="$AG2/inbox"
mkdir -p "$AG2" "$CLAUDE_AGENT_SPOOL_BASE/evt2"
chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/evt2"
sed 's/name: evt/name: evt2/' "$AG/spec.yaml" > "$AG2/spec.yaml"
export CLAUDE_AGENT_INBOX_MAX_EVENTS=2
for i in 1 2 3; do "$RUN" spool-put evt2 --text "событие $i" >/dev/null; done
assert "intake wedged" 0 "$RUN" intake "$AG2"
[[ "$(jq_file "$IB2/intake-status.json" 'd["state"]')" == "wedged" ]] \
  && ok || fail "backpressure: wedged"
[[ "$(ls "$IB2/pending" | wc -l | tr -d ' ')" == "2" ]] \
  && ok || fail "wedged: pending = кап (2)"
CUR=$(jq_file "$IB2/cursor.json" 'd["position"]')
"$RUN" intake "$AG2" >/dev/null
[[ "$(jq_file "$IB2/cursor.json" 'd["position"]')" == "$CUR" ]] \
  && ok || fail "wedged: курсор стоит"
# drain лечит: одно событие ушло в done -> intake продолжает
K2=$(ls "$IB2/pending" | head -1 | sed 's/.json//')
mv "$IB2/pending/$K2.json" "$IB2/done/$K2.json"
"$RUN" intake "$AG2" >/dev/null
[[ "$(jq_file "$IB2/cursor.json" 'd["position"]')" != "$CUR" ]] \
  && ok || fail "после drain курсор двинулся"
unset CLAUDE_AGENT_INBOX_MAX_EVENTS

# ----------------------------------------------------------- restore (Д6)
DONE_BEFORE=$(ls "$IB/done" | wc -l | tr -d ' ')
assert "restore" 0 "$RUN" restore "$AG"
MINSEQ=$(ls "$SP"/ev-*.json | head -1 | sed 's/.*ev-0*//; s/\.json//')
[[ "$(jq_file "$IB/cursor.json" 'd["position"]')" == "$((MINSEQ - 1))" ]] \
  && ok || fail "restore: курсор = min-1 (re-scan, хвост не потерян)"
grep -c key "$IB/dedup.jsonl" >/dev/null && ok || fail "restore: леджер пересобран"
assert "intake после restore" 0 "$RUN" intake "$AG"
[[ "$(ls "$IB/done" | wc -l | tr -d ' ')" == "$DONE_BEFORE" ]] \
  && ok || fail "re-scan не дублирует done"

echo
echo "test-agent-run: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
