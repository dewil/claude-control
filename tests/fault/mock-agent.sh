#!/usr/bin/env bash
# mock-agent: fake mission runtime for fault-injection tests.
# Runs inside the agent tmux (injected via CLAUDE_AGENT_RUNTIME_CMD), obeys
# the same env contract as real claude and reports through state.<gen>.json
# + fake relay heartbeats in session.debug.log.
#
# Behavior is driven by $CLAUDE_AGENT_DIR/mock.mode (re-read every loop):
#   healthy     sleeping, fresh next_wakeup, heartbeats     -> HEALTHY_SLEEPING
#   overrun     working since long ago, heartbeats          -> OVERRUN
#   oversleep   sleeping, next_wakeup in the past, hb       -> OVERSLEPT
#   mute        no state updates, no heartbeats             -> MODAL (после grace)
#   nohb        state updates fresh, but no heartbeats      -> MODAL
#   claim       one commit in worktree, agent_claim=done    -> CLAIMED
#   blocked     agent_claim=blocked                         -> CLAIMED(blocked)
set -u

DIR="$CLAUDE_AGENT_DIR"
GEN="$CLAUDE_AGENT_GENERATION"
ATT="$CLAUDE_AGENT_ATTEMPT"
IO="$(command -v claude-agent-io || echo "$MOCK_IO")"
STATE="$DIR/state.$GEN.json"
DEBUG="$DIR/session.debug.log"

iso() { date -u ${1:+-d "$1"} +%Y-%m-%dT%H:%M:%SZ; }
hb()  { echo "$(iso) [DEBUG] CCRClient: Heartbeat sent" >> "$DEBUG"; }

write_state() { # <phase> <claim> <artifact> <iter_started> <next_wakeup>
  python3 - "$GEN" "$ATT" "$@" <<'PY' | "$IO" durable-write "$STATE"
import json, sys
g, att, phase, claim, artifact, it, wake = sys.argv[1:8]
print(json.dumps({
  "schema": 1, "generation": int(g), "attempt_id": att, "phase": phase,
  "status_line": "mock %s" % phase, "agent_claim": claim,
  "claim_artifact": artifact or None, "session_id": "mock-session",
  "iteration_started_at": it, "last_progress_at": it,
  "next_wakeup_at": wake or None, "iterations": 1, "cost_usd": 0.0}))
PY
}

claimed=""
while true; do
  mode=$(cat "$DIR/mock.mode" 2>/dev/null || echo healthy)
  case "$mode" in
    healthy)
      write_state sleeping running "" "$(iso)" "$(iso '+60 seconds')"; hb ;;
    overrun)
      write_state working running "" "$(iso '-45 minutes')" ""; hb ;;
    oversleep)
      write_state sleeping running "" "$(iso '-10 minutes')" "$(iso '-5 minutes')"; hb ;;
    mute)
      : ;;  # молчим совсем
    nohb)
      write_state sleeping running "" "$(iso)" "$(iso '+60 seconds')" ;;
    claim)
      if [[ -z "$claimed" ]]; then
        ( cd "$DIR/work" \
          && echo "result $(date +%s)" > result.txt \
          && git add result.txt \
          && git -c user.email=m@m -c user.name=mock commit -qm "mock result" )
        claimed=$(git -C "$DIR/work" rev-parse HEAD)
      fi
      write_state sleeping done "$claimed" "$(iso)" "$(iso '+300 seconds')"; hb ;;
    blocked)
      write_state sleeping blocked "" "$(iso)" "$(iso '+300 seconds')"; hb ;;
  esac
  sleep 2
done
