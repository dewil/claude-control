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
# per-agent permissions (модель доверия п.5): сид по autonomy-пресету
SLJ="$CLAUDE_AGENTS_DIR/demo/work/.claude/settings.local.json"
[[ -f "$SLJ" ]] && ok || fail "settings.local.json посеян"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["permissions"]["defaultMode"])' "$SLJ")" == "acceptEdits" ]] \
  && ok || fail "autonomy=act -> defaultMode=acceptEdits"
python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["permissions"]["allow"]; sys.exit(0 if any("bypass" in r.lower() for r in a) else 1)' "$SLJ" \
  && fail "bypassPermissions в allow!" || ok "без bypassPermissions"
python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["permissions"]["allow"]; sys.exit(0 if "Bash" in a else 1)' "$SLJ" \
  && ok "act: Bash разрешен целиком" || fail "act: нет полного Bash"
git -C "$CLAUDE_AGENTS_DIR/demo/work" status --porcelain | grep -q claude \
  && fail ".claude/ виден в git status (попадет в артефакт)" || ok ".claude/ исключен из git"
# recreate: create чистит stale-scratch реконсилера прежней инкарнации
export CLAUDE_RECONCILER_DIR="$TMP/reconciler"
mkdir -p "$CLAUDE_RECONCILER_DIR/cache"
echo "kick_g1=1" > "$CLAUDE_RECONCILER_DIR/cache/demo3.flags"
sed 's/name: demo/name: demo3/' "$SPEC" > "$TMP/spec-demo3.yaml"
assert "create demo3 (recreate)" 0 "$RC" agent create demo3 --spec "$TMP/spec-demo3.yaml" --mission "$TMP/mission.md"
[[ ! -f "$CLAUDE_RECONCILER_DIR/cache/demo3.flags" ]] \
  && ok "create снес stale-флаги реконсилера" || fail "stale kick_g1 пережил create"

# event-агент (этап 4): создается с inbox+spool, без worktree и mission
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
sed 's/type: mission/type: event/; s/name: demo/name: evt/' "$SPEC" > "$TMP/spec-evt.yaml"
assert "create event без source" 2 "$RC" agent create evt --spec "$TMP/spec-evt.yaml"
cat >> "$TMP/spec-evt.yaml" <<EOF
source: { kind: spool, replay_window_h: 72 }
EOF
# недоверенный вход: event строго suggest (модель доверия п.2)
assert "create event с autonomy=act отбит" 2 "$RC" agent create evt --spec "$TMP/spec-evt.yaml"
sed -i.bak 's/autonomy: act/autonomy: suggest/' "$TMP/spec-evt.yaml"
assert "create event" 0 "$RC" agent create evt --spec "$TMP/spec-evt.yaml"
[[ -d "$CLAUDE_AGENTS_DIR/evt/inbox/pending" ]] && ok || fail "event: inbox создан"
[[ -d "$TMP/spool/evt" ]] && ok || fail "event: spool создан"
[[ ! -d "$CLAUDE_AGENTS_DIR/evt/work" ]] && ok || fail "event: без worktree"
[[ "$(cget evt 'd["mission_base"]')" == "None" ]] && ok || fail "event: mission_base=null"
assert "attach event отказ" 4 "$RC" agent attach evt
assert "dlq event пуст" 0 "$RC" agent dlq evt
assert "inbox-restore event" 0 "$RC" agent inbox-restore evt
assert "status event" 0 "$RC" agent status evt

# acceptance.kind (этап 7): валидация create + reviewer-role
RR="$TMP/reviewer-role"; mkdir -p "$RR"; echo "# reviewer" > "$RR/prompt.md"
RR_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$RR/prompt.md")
cat > "$RR/manifest.yaml" <<EOF
schema: 1
role: acceptor
role_rev: 1
files:
  - { path: prompt.md, sha256: "$RR_SHA" }
EOF
mk_mission_spec() { # <name> <kind-block>
  cat > "$TMP/$1.spec.yaml" <<EOF
schema: 1
name: $1
type: mission
role: coder
project: $PROJ
goal: "role-review test"
autonomy: act
memory_max_mb: 100
limits: { max_iterations: 5, max_hours: 1, max_iteration_minutes: 2 }
$2
EOF
}
mk_mission_spec rv1 'acceptance: { kind: bogus }'
assert "kind невалидный отбит" 2 "$RC" agent create rv1 --spec "$TMP/rv1.spec.yaml" --mission "$TMP/mission.md"
mk_mission_spec rv2 'acceptance: { kind: role-review }'
assert "role-review без reviewer-role отбит" 2 "$RC" agent create rv2 --spec "$TMP/rv2.spec.yaml" --mission "$TMP/mission.md"
mk_mission_spec rv3 'acceptance: { kind: both, deterministic: true }'
assert "both без check отбит" 2 "$RC" agent create rv3 --spec "$TMP/rv3.spec.yaml" --mission "$TMP/mission.md" --reviewer-role "$RR"
mk_mission_spec rv4 'acceptance: { kind: role-review }'
assert "role-review + reviewer-role ok" 0 "$RC" agent create rv4 --spec "$TMP/rv4.spec.yaml" --mission "$TMP/mission.md" --reviewer-role "$RR"
[[ -f "$CLAUDE_AGENTS_DIR/rv4/reviewer-role/prompt.md" ]] && ok || fail "reviewer-role заморожен снапшотом"
# reviewer-role без manifest отбит (ревью-3: revoke обходится без manifest)
RRB="$TMP/rr-nomanifest"; mkdir -p "$RRB"; echo x > "$RRB/prompt.md"
mk_mission_spec rv5 'acceptance: { kind: role-review }'
assert "reviewer-role без manifest отбит" 2 "$RC" agent create rv5 --spec "$TMP/rv5.spec.yaml" --mission "$TMP/mission.md" --reviewer-role "$RRB"
# reviewer-role с неверным sha отбит
RRW="$TMP/rr-badsha"; mkdir -p "$RRW"; echo real > "$RRW/prompt.md"
cat > "$RRW/manifest.yaml" <<EOF
schema: 1
role: acceptor
files:
  - { path: prompt.md, sha256: "0000000000000000000000000000000000000000000000000000000000000000" }
EOF
mk_mission_spec rv6 'acceptance: { kind: role-review }'
assert "reviewer-role с неверным sha отбит" 2 "$RC" agent create rv6 --spec "$TMP/rv6.spec.yaml" --mission "$TMP/mission.md" --reviewer-role "$RRW"
# both без deterministic:true отбит (ревью-3: both требует det)
mk_mission_spec rv7 'acceptance: { kind: both, check: "true" }'
assert "both без deterministic отбит" 2 "$RC" agent create rv7 --spec "$TMP/rv7.spec.yaml" --mission "$TMP/mission.md" --reviewer-role "$RR"
# revoke-role снимает у агента (durable CAS-поле)
"$RC" agent revoke-role acceptor >/dev/null 2>&1 && ok || fail "revoke-role выполнен"
[[ "$(cget rv4 'd["acceptance"].get("reviewer_revoked")')" == "True" ]] && ok || fail "revoke-role выставил CAS-поле"

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
