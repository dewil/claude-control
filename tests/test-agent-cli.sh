#!/usr/bin/env bash
# Tests for bin/claude-rc-agent: lifecycle of the operator CLI (§4.2).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/../bin/claude-rc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AGENTS_DIR="$TMP/agents"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
assert() { # <desc> <expected-exit> <cmd...>
  local desc="$1" want="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [[ "$got" == "$want" ]]; then ok; else
    fail "$desc: exit $got != $want ($(head -c150 "$TMP/err"))"; fi
}
cget() { # <name> <py-expr over control dict d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$CLAUDE_AGENTS_DIR/$1/control.json" "$2"
}

# --- fixture: tiny git project ---
PROJ="$TMP/proj"
git init -q "$PROJ"
( cd "$PROJ" && echo hi > f.txt && git add . \
  && git -c user.email=t@t -c user.name=t commit -qm init )

SPEC="$TMP/spec.yaml"
cat > "$SPEC" <<EOF
schema: 1
name: demo
type: mission
role: coder
project: $PROJ
goal: "test mission"
autonomy: act
memory_max_mb: 100
limits: { max_iterations: 5, max_hours: 1, max_iteration_minutes: 2 }
EOF
echo "# mission" > "$TMP/mission.md"

# --- create ---
assert "create"            0 "$RC" agent create demo --spec "$SPEC" --mission "$TMP/mission.md"
assert "create dup"        4 "$RC" agent create demo --spec "$SPEC" --mission "$TMP/mission.md"
assert "create bad name"   2 "$RC" agent create Bad_Name --spec "$SPEC" --mission "$TMP/mission.md"
[[ "$(cget demo 'd["desired"]')" == "paused" ]] && ok || fail "create desired"
[[ -n "$(cget demo 'd["mission_base"]')" ]] && ok || fail "mission_base set"
git -C "$PROJ" show-ref --verify -q refs/heads/agent/demo && ok || fail "branch created"
[[ -d "$CLAUDE_AGENTS_DIR/demo/work" ]] && ok || fail "worktree created"

# spec c type=event отклоняется (этап 4)
sed 's/type: mission/type: event/; s/name: demo/name: evt/' "$SPEC" > "$TMP/spec-evt.yaml"
assert "create event refused" 2 "$RC" agent create evt --spec "$TMP/spec-evt.yaml" --mission "$TMP/mission.md"

# --- desired transitions ---
assert "start"        0 "$RC" agent start demo
[[ "$(cget demo 'd["desired"]')" == "running" ]] && ok || fail "start desired"
assert "start twice"  4 "$RC" agent start demo
assert "pause"        0 "$RC" agent pause demo
assert "start again"  0 "$RC" agent start demo
assert "stop"         0 "$RC" agent stop demo
assert "stop idemp"   0 "$RC" agent stop demo
[[ "$(cget demo 'd["desired"]')" == "stopped" ]] && ok || fail "stop desired"

# --- attention: start блокируется, гашение нет ---
"$HERE/../bin/claude-agent-io" control-cas "$CLAUDE_AGENTS_DIR/demo" \
  --set 'attention={"reason":"resume_failed","since":"x","episode":"e1","count":4}' \
  --set 'desired="paused"' --event test_setup >/dev/null
assert "start blocked by attention" 4 "$RC" agent start demo
assert "stop allowed with attention" 0 "$RC" agent stop demo
"$HERE/../bin/claude-agent-io" control-cas "$CLAUDE_AGENTS_DIR/demo" \
  --set 'desired="running"' --event test_setup >/dev/null
assert "resolve no mode"  2 "$RC" agent resolve demo
assert "resolve resume"   0 "$RC" agent resolve demo --resume
[[ "$(cget demo 'd["attention"]')" == "None" ]] && ok || fail "attention cleared"

# mission_timeout требует --extend-hours
"$HERE/../bin/claude-agent-io" control-cas "$CLAUDE_AGENTS_DIR/demo" \
  --set 'attention={"reason":"mission_timeout","since":"x","episode":"e2","count":1}' \
  --event test_setup >/dev/null
assert "timeout resume w/o extend" 4 "$RC" agent resolve demo --resume
assert "timeout resume + extend"   0 "$RC" agent resolve demo --resume --extend-hours 2
[[ "$(cget demo 'd["deadline_extension_h"]')" == "2" ]] && ok || fail "extension recorded"

# --- acceptance: claim -> accept терминален, одной записью с desired ---
GEN=$(cget demo 'd["generation"]')
cat > "$CLAUDE_AGENTS_DIR/demo/state.$GEN.json" <<EOF
{"schema":1,"generation":$GEN,"attempt_id":"a","phase":"sleeping",
"agent_claim":"done","claim_artifact":"abc123","session_id":"s",
"iteration_started_at":"x","last_progress_at":"x","next_wakeup_at":"y",
"iterations":1,"cost_usd":0}
EOF
assert "accept" 0 "$RC" agent accept demo
[[ "$(cget demo 'd["acceptance"]["status"]')" == "accepted" ]] && ok || fail "accepted"
[[ "$(cget demo 'd["desired"]')" == "stopped" ]] && ok || fail "verdict+desired atomically"
assert "start after terminal" 4 "$RC" agent start demo
assert "accept twice"         4 "$RC" agent accept demo

# --- revise: только из needs-human ---
assert "revise from accepted" 4 "$RC" agent revise demo --note "redo"

# второй агент: needs-human -> revise
sed 's/name: demo/name: demo2/' "$SPEC" > "$TMP/spec2.yaml"
assert "create demo2" 0 "$RC" agent create demo2 --spec "$TMP/spec2.yaml" --mission "$TMP/mission.md"
"$HERE/../bin/claude-agent-io" control-cas "$CLAUDE_AGENTS_DIR/demo2" \
  --set 'acceptance.status="needs-human"' --event test_setup >/dev/null
assert "revise ok" 0 "$RC" agent revise demo2 --note "поправь тесты"
[[ "$(cget demo2 'd["acceptance"]["status"]')" == "revise" ]] && ok || fail "revise status"
[[ "$(cget demo2 'd["acceptance"]["note"]')" == "поправь тесты" ]] && ok || fail "revise note"

# reject требует --reason
"$HERE/../bin/claude-agent-io" control-cas "$CLAUDE_AGENTS_DIR/demo2" \
  --expect 'acceptance.status="revise"' --set 'acceptance.status="needs-human"' \
  --event test_setup >/dev/null
assert "reject w/o reason" 2 "$RC" agent reject demo2
assert "reject"            0 "$RC" agent reject demo2 --reason "не то"
[[ "$(cget demo2 'd["desired"]')" == "stopped" ]] && ok || fail "reject stops"

# --- status/list не падают ---
assert "status" 0 "$RC" agent status demo
assert "list"   0 "$RC" agent list
grep -q demo2 "$TMP/out" && ok || fail "list contains demo2"
assert "status missing" 3 "$RC" agent status nosuch

echo "---"
echo "agent-cli: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
