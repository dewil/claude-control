#!/usr/bin/env bash
# Tests for bin/claude-agent-run: подкоманда `drain` (этап v2, §6 T1-T7).
# Контракт: docs/design-2026-07-25-v2-runtime-drain.md
# T8 (регресс step/loop) покрыт tests/test-agent-run.sh - здесь не дублируется.
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
set_meta() { # <state-dir> <key> <python-dict-literal с обновлениями meta>
  python3 - "$IB/$1/$2.json" "$3" <<'PY'
import json, sys
path, updates = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["meta"].update(eval(updates))
json.dump(d, open(path, "w"))
PY
}
set_usage() { # <day_runs> [day] - без exhausted_until (чистое состояние)
  local runs="$1" day="${2:-$(date -u +%Y-%m-%d)}"
  python3 - "$IB/usage.json" "$runs" "$day" <<'PY'
import json, os, sys
path, runs, day = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = json.load(open(path)) if os.path.exists(path) else {}
d["day"] = day; d["day_runs"] = runs
d.pop("exhausted_until", None)
json.dump(d, open(path, "w"))
PY
}
pending_count() { ls "$IB/pending" 2>/dev/null | wc -l | tr -d ' '; }
last_state() { ls "$AG"/state.*.json 2>/dev/null | sort -t. -k2 -n | tail -1; }
state_status() { # <state-file> -> значение status/status_line (спека называет
                  # его "status", наблюдаемая схема в других файлах - "status_line";
                  # проверяем оба кандидата, см. вопрос в итоговом отчете)
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("status_line", d.get("status")))' "$1"
}

# --- fixture: event-агент вручную (без CLI - юнит-скоуп), как в test-agent-run.sh ---
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
goal: "unit test drain"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt

MOCK="$TMP/mock-claude"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # съесть промпт
mode=$(cat "$MOCK_MODE_FILE" 2>/dev/null || echo ok)
case "$mode" in
  ok)   echo '{"type":"result","result":"обработано","total_cost_usd":0.01}' ;;
  fail) echo "boom" >&2; exit 1 ;;
esac
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK" MOCK_MODE_FILE="$TMP/mock-mode"
echo ok > "$MOCK_MODE_FILE"

# =============================================================== T5: занятый lock
# Держим .executor.lock снаружи - drain обязан отказать exit 5, не ждать.
# Путь - $IB/.executor.lock (executor.lock живет в inbox/, как у loop/step).
mkdir -p "$IB"
exec 9>"$IB/.executor.lock"
if flock -n 9; then ok; else fail "T5: не удалось захватить lock для теста"; fi
assert "T5 drain при занятом lock" 5 "$RUN" drain "$AG"
flock -u 9
exec 9>&-

# =============================================================== T1: пустой inbox
assert "T1 drain на пустом inbox" 0 "$RUN" drain "$AG"
[[ "$(cat "$TMP/out")" == "idle" ]] && ok || fail "T1: stdout = idle ($(cat "$TMP/out"))"
ST="$(last_state)"
[[ -n "$ST" ]] && ok || fail "T1: state.N.json написан"
[[ "$(jq_file "$ST" 'd["phase"]')" == "sleeping" ]] && ok || fail "T1: phase=sleeping"
[[ "$(state_status "$ST")" == "drained:idle" ]] \
  && ok || fail "T1: status=drained:idle ($(state_status "$ST"))"

# =============================================================== T2: N=3 ready
"$RUN" spool-put evt --text "один" >/dev/null
"$RUN" spool-put evt --text "два" >/dev/null
"$RUN" spool-put evt --text "три" >/dev/null
"$RUN" intake "$AG" >/dev/null
[[ "$(pending_count)" == "3" ]] && ok || fail "T2: 3 конверта intake'нуты"
assert "T2 drain N=3 ready" 0 "$RUN" drain "$AG"
[[ "$(ls "$IB/done" | wc -l | tr -d ' ')" == "3" ]] && ok || fail "T2: все 3 в done"
[[ "$(pending_count)" == "0" ]] && ok || fail "T2: pending пуст после drain"

# =============================================================== T6: next_attempt_at в будущем
"$RUN" spool-put evt --text "будущее" >/dev/null
"$RUN" intake "$AG" >/dev/null
T6K=$(ls "$IB/pending" | head -1 | sed 's/.json//')
set_meta pending "$T6K" '{"next_attempt_at": "2099-01-01T00:00:00Z"}'
assert "T6 drain с будущим next_attempt_at" 0 "$RUN" drain "$AG"
[[ "$(cat "$TMP/out")" == "idle" ]] && ok || fail "T6: stdout = idle ($(cat "$TMP/out"))"
[[ -f "$IB/pending/$T6K.json" ]] && ok || fail "T6: конверт не взят, остался в pending"
rm -f "$IB/pending/$T6K.json"   # прибрать перед следующими секциями

# =============================================================== T3: бюджет исчерпан
sed -i.bak 's/runs_per_day: 100/runs_per_day: 1/' "$AG/spec.yaml"
set_usage 5
"$RUN" spool-put evt --text "за капом" >/dev/null
"$RUN" intake "$AG" >/dev/null
T3K=$(ls "$IB/pending" | head -1 | sed 's/.json//')
assert "T3 drain при исчерпанном бюджете" 0 "$RUN" drain "$AG"
[[ "$(cat "$TMP/out")" == "exhausted" ]] && ok || fail "T3: stdout = exhausted ($(cat "$TMP/out"))"
[[ -f "$IB/pending/$T3K.json" ]] && ok || fail "T3: конверт не тронут, остался в pending"
[[ "$(jq_file "$IB/pending/$T3K.json" 'd["meta"]["attempts"]')" == "0" ]] \
  && ok || fail "T3: attempts не увеличен"
mv "$AG/spec.yaml.bak" "$AG/spec.yaml"
rm -f "$IB/pending/$T3K.json"
set_usage 0

# =============================================================== T4: infra-фейл
# Наблюдаемый FAIL (мок падает) - только он гейтит infra-probe (§11.2 stage4);
# первый цикл drain реально прогоняет и получает fail, второй ловит infra_wait.
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/false
echo fail > "$MOCK_MODE_FILE"
"$RUN" spool-put evt --text "инфра" >/dev/null
"$RUN" intake "$AG" >/dev/null
T4K=$(ls "$IB/pending" | head -1 | sed 's/.json//')
assert "T4 drain при infra-фейле" 0 "$RUN" drain "$AG"
[[ "$(cat "$TMP/out")" == "infra_wait" ]] && ok || fail "T4: stdout = infra_wait ($(cat "$TMP/out"))"
[[ -f "$IB/pending/$T4K.json" ]] && ok || fail "T4: конверт остается pending"
[[ "$(jq_file "$IB/pending/$T4K.json" 'd["meta"]["attempts"]')" == "0" ]] \
  && ok || fail "T4: attempts не увеличен (probe нездоров)"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
echo ok > "$MOCK_MODE_FILE"
rm -f "$IB/pending/$T4K.json"

# =============================================================== T7: inbox-status.ready
"$RUN" spool-put evt --text "готов" >/dev/null
"$RUN" spool-put evt --text "в карантине" >/dev/null
"$RUN" spool-put evt --text "с будущим ретраем" >/dev/null
"$RUN" intake "$AG" >/dev/null
[[ "$(pending_count)" == "3" ]] && ok || fail "T7: 3 pending перед разметкой"
KEYS=($(ls "$IB/pending" | sed 's/.json//'))
set_meta pending "${KEYS[0]}" '{"quarantined": True}'
set_meta pending "${KEYS[1]}" '{"next_attempt_at": "2099-01-01T00:00:00Z"}'
# KEYS[2] остается обычным готовым конвертом
IS=$("$RUN" inbox-status "$AG")
echo "$IS" > "$TMP/inbox-status.json"
[[ "$(jq_file "$TMP/inbox-status.json" 'd["ready"]')" == "1" ]] \
  && ok || fail "T7: ready=1 из 3 pending (1 quarantined, 1 future) ($IS)"

echo
echo "test-agent-drain: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
