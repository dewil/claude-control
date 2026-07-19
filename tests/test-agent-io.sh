#!/usr/bin/env bash
# Unit tests for bin/claude-agent-io (state machine design §1.1-§1.2, §2-§3).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
IO="$HERE/../bin/claude-agent-io"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
# assert <desc> <expected-exit> <cmd...>
assert() {
  local desc="$1" want="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [[ "$got" == "$want" ]]; then ok; else
    fail "$desc: exit $got != $want ($(head -c200 "$TMP/err"))"; fi
}

AGENT="$TMP/agents/test-agent"
mkdir -p "$AGENT"
printf 'stub' > "$AGENT/spec.yaml"
printf 'stub' > "$AGENT/mission.md"

CONTROL='{"schema":1,"seq":0,"desired":"paused","generation":0,
"session_id":null,"started_at":null,"deadline_extension_h":0,
"mission_base":null,
"lease":{"state":"none","start_attempt_id":null,"gen_base":null,
"socket":null,"unit":null,"main_pid":null,"pid_start":null,
"granted_at":null,"renewed_at":null,"ttl_s":300},
"acceptance":{"status":"pending","artifact":null,"verdict_by":null,
"checked_at":null,"note":null,"check_job":null,"check_runs":[]},
"attention":null,"hold":null,"handoff":null}'

# --- durable-write ---
echo -n "hello" | "$IO" durable-write "$TMP/f.txt"
[[ "$(cat "$TMP/f.txt")" == "hello" ]] && ok || fail "durable-write content"
ls "$TMP"/.f.txt.tmp.* 2>/dev/null && fail "tmp left behind" || ok

# --- control-init ---
assert "init"          0 "$IO" control-init "$AGENT" "$CONTROL"
assert "init twice"    4 "$IO" control-init "$AGENT" "$CONTROL"
assert "init bad json" 2 "$IO" control-init "$AGENT" '{nope'
assert "init invalid"  6 "$IO" control-init "$AGENT" '{"schema":1}'

# --- control-read ---
assert "read" 0 "$IO" control-read "$AGENT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["desired"]=="paused"' "$TMP/out" 2>/dev/null \
  && ok || { cp "$TMP/out" "$TMP/read.json"; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["desired"]=="paused"' "$TMP/read.json" && ok || fail "read content"; }

# --- CAS: success path (operator start) ---
assert "cas start" 0 "$IO" control-cas "$AGENT" \
  --expect 'desired="paused"' --set 'desired="running"' \
  --event agent_start --actor operator
python3 - "$AGENT/control.json" <<'PY' && ok || fail "cas result"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["desired"]=="running" and d["seq"]==1, d
PY

# --- CAS: conflict must not write ---
assert "cas conflict" 4 "$IO" control-cas "$AGENT" \
  --expect 'desired="paused"' --set 'desired="stopped"'
python3 - "$AGENT/control.json" <<'PY' && ok || fail "conflict wrote"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["desired"]=="running" and d["seq"]==1, d
PY

# --- CAS: gate A shape (inc generation + nested sets) ---
assert "cas gate-a" 0 "$IO" control-cas "$AGENT" \
  --expect 'desired="running"' --expect 'lease.state="none"' \
  --inc generation \
  --set 'lease.state="acquiring"' --set 'lease.start_attempt_id="att-1"' \
  --set 'lease.socket="agent-test-agent.g1"' --event lease_acquiring
python3 - "$AGENT/control.json" <<'PY' && ok || fail "gate-a result"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["generation"]==1 and d["lease"]["state"]=="acquiring", d
PY

# --- CAS refuses to produce invalid doc ---
assert "cas invalid enum" 6 "$IO" control-cas "$AGENT" \
  --set 'lease.state="bogus"'

# --- state-read: no state yet -> null ---
[[ "$("$IO" state-read "$AGENT")" == "null" ]] && ok || fail "state null"

# --- state-read: старое поколение отфильтровано fencing'ом ---
cat > "$AGENT/state.0.json" <<'EOF'
{"schema":1,"generation":0,"attempt_id":"att-0","phase":"working",
"agent_claim":"running","session_id":"s","iteration_started_at":"x",
"last_progress_at":"x","next_wakeup_at":null,"iterations":1,"cost_usd":0}
EOF
[[ "$("$IO" state-read "$AGENT")" == "null" ]] && ok || fail "stale gen not fenced"

# --- state-read: текущее поколение читается ---
cat > "$AGENT/state.1.json" <<'EOF'
{"schema":1,"generation":1,"attempt_id":"att-1","phase":"sleeping",
"agent_claim":"running","session_id":"s","iteration_started_at":"x",
"last_progress_at":"x","next_wakeup_at":"y","iterations":2,"cost_usd":0.1}
EOF
"$IO" state-read "$AGENT" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); assert d["phase"]=="sleeping"' \
  && ok || fail "state current gen"

# --- state-read: мусор = молчащий агент, не падение ---
echo '{broken' > "$AGENT/state.1.json"
[[ "$("$IO" state-read "$AGENT")" == "null" ]] && ok || fail "broken state -> null"

# --- events: каждая CAS-запись оставила строку с seq ---
[[ "$(grep -c '"seq"' "$AGENT/events.jsonl")" -ge 3 ]] && ok || fail "events missing"
assert "event-append" 0 "$IO" event-append "$AGENT" test_event tester '{"k":1}'
grep -q test_event "$AGENT/events.jsonl" && ok || fail "event-append line"

# --- validate ---
assert "validate ok" 0 "$IO" validate "$AGENT"
rm "$AGENT/mission.md"
assert "validate missing mission" 6 "$IO" validate "$AGENT"
printf 'stub' > "$AGENT/mission.md"
echo '{broken' > "$AGENT/control.json"
assert "validate broken control" 6 "$IO" validate "$AGENT"

# --- имя каталога валидируется ---
mkdir -p "$TMP/agents/BAD_NAME"
assert "bad name" 2 "$IO" control-read "$TMP/agents/BAD_NAME"

# --- classify OVERRUN: свежий lease + протухший iteration_started_at ---
# Регресс: агент (LLM) не сбрасывает iteration_started_at между поколениями;
# свежее поколение не должно "рождаться просроченным" (мгновенный OVERRUN).
CAGENT="$TMP/agents/cls-agent"
mkdir -p "$CAGENT"; printf 'stub' > "$CAGENT/spec.yaml"; printf 'stub' > "$CAGENT/mission.md"
ISO_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ISO_1H=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u +%s)
write_cls() { # <granted_at>
  cat > "$CAGENT/control.json" <<EOF
{"schema":1,"seq":0,"desired":"running","generation":1,"session_id":null,
"started_at":"$ISO_1H","deadline_extension_h":0,"mission_base":null,
"lease":{"state":"active","start_attempt_id":"att-1","gen_base":null,
"socket":"s","unit":"u","main_pid":123,"pid_start":456,
"granted_at":"$1","renewed_at":"$1","ttl_s":300},
"acceptance":{"status":"pending","artifact":null,"verdict_by":null,
"checked_at":null,"note":null,"check_job":null,"check_runs":[]},
"attention":null,"hold":null,"handoff":null}
EOF
  cat > "$CAGENT/state.1.json" <<EOF
{"schema":1,"generation":1,"attempt_id":"att-1","phase":"working",
"status_line":"x","agent_claim":"running","claim_artifact":null,
"session_id":"s","iteration_started_at":"$ISO_1H","last_progress_at":"$ISO_NOW",
"next_wakeup_at":null,"iterations":1,"cost_usd":0}
EOF
}
FACTS="{\"unit_active\":true,\"heartbeat_age_s\":0,\"now\":$NOW_EPOCH}"
# свежий lease (granted_at=сейчас), итерация "час назад" -> НЕ OVERRUN
write_cls "$ISO_NOW"
CLS=$("$IO" classify "$CAGENT" --facts "$FACTS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["class"])')
[[ "$CLS" == "HEALTHY_WORKING" ]] && ok || fail "свежий lease + протухший iter -> $CLS (ждали HEALTHY_WORKING)"
# старый lease (granted_at=час назад) + старая итерация -> честный OVERRUN
write_cls "$ISO_1H"
CLS=$("$IO" classify "$CAGENT" --facts "$FACTS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["class"])')
[[ "$CLS" == "OVERRUN" ]] && ok || fail "старый lease + старая итерация -> $CLS (ждали OVERRUN)"

echo "---"
echo "agent-io: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
