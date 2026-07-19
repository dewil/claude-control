#!/usr/bin/env bash
# Tests for reconciler mission_drain (этап 9): доставка операторского
# комментария в живую сессию по SM §13.1 (fail-closed). Контракт:
# design-2026-07-19-stage9 (pane -t, verify-протокол, recovery, backpressure).
# tmux подменяется фейком в PATH; вход - тест-шов `--drain-once <dir> <gen>`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RECON="$HERE/../bin/claude-agent-reconciler"
RUN="$HERE/../bin/claude-agent-run"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_RECONCILER_DIR="$TMP/rc"
mkdir -p "$TMP/rc"

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

# --- fake tmux: лог вызовов + имитация pane ---
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$TMUX_LOG"
cmd=""
for a in "$@"; do
  case "$a" in list-panes|capture-pane|send-keys) cmd="$a"; break;; esac
done
case "$cmd" in
  list-panes)   cat "$FAKE_PANES" ;;
  capture-pane) cat "$FAKE_PANE" ;;
  send-keys)
    # имитация эха ввода: send-keys -l TEXT дописывает текст в input-строку
    if [[ "${TMUX_SWALLOW:-}" != "1" ]]; then
      prev=""
      for a in "$@"; do
        if [[ "$prev" == "-l" ]]; then
          python3 - "$FAKE_PANE" "$a" <<'PY'
import sys
p, t = sys.argv[1], sys.argv[2]
lines = open(p).read().splitlines()
if lines:
    lines[-1] += t
else:
    lines = [t]
open(p, "w").write("\n".join(lines) + "\n")
PY
        fi
        prev="$a"
      done
    fi ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"
export TMUX_LOG="$TMP/tmux.log" FAKE_PANES="$TMP/panes" FAKE_PANE="$TMP/pane"

idle_pane() { printf '/rc active\n❯ \n' > "$FAKE_PANE"; }
reset_log() { : > "$TMUX_LOG"; }

# --- fixture: mission-агент + очередь ---
AG="$CLAUDE_AGENTS_DIR/mis"; MI="$AG/mission-inbox"
mkdir -p "$AG"
printf '%%0 claude\n' > "$FAKE_PANES"

# ------------------------------------------------- S1: happy path (SM §13.1)
"$RUN" mission-put mis --text "привет агент" >/dev/null
idle_pane; reset_log
assert "drain happy"        0 "$RECON" --drain-once "$AG" 1
[[ -f "$MI/delivered/msg-000001.json" && ! -f "$MI/msg-000001.json" ]] \
  && ok || fail "S1: сообщение доставлено (переехало в delivered)"
grep -q -- '-L agent-mis.g1 send-keys -t %0 -l \[оператор #1\]: привет агент' "$TMUX_LOG" \
  && ok || fail "S1: send-keys с -t %0 и маркером"
grep -q -- 'send-keys -t %0 Enter' "$TMUX_LOG" \
  && ok || fail "S1: Enter дослан после verify"
[[ "$(jq_file "$MI/.drain.json" 'd["last_result"]')" == "ok" ]] \
  && ok || fail "S1: last_result ok"

# ------------------------------------------------- S2: черновик оператора
"$RUN" mission-put mis --text "второе" >/dev/null
printf '/rc active\n❯ черновик оператора\n' > "$FAKE_PANE"; reset_log
assert "drain при черновике" 0 "$RECON" --drain-once "$AG" 1
[[ -f "$MI/msg-000002.json" ]] && ok || fail "S2: файл остался в очереди"
grep -q -- '-l' "$TMUX_LOG" && fail "S2: send-keys -l не должен звучать" || ok

# ------------------------------------------------- S3: busy (нет промпта)
printf 'думаю...\nвывод инструмента\n' > "$FAKE_PANE"; reset_log
assert "drain при busy"      0 "$RECON" --drain-once "$AG" 1
[[ -f "$MI/msg-000002.json" ]] && ok || fail "S3: файл остался"
grep -q -- '-l' "$TMUX_LOG" && fail "S3: не шлем в busy pane" || ok

# ------------------------------------------------- S4: verify-fail x2
idle_pane; reset_log
TMUX_SWALLOW=1 "$RECON" --drain-once "$AG" 1 >/dev/null 2>&1
[[ -f "$MI/msg-000002.json" ]] && ok || fail "S4: verify-fail - файл остался"
[[ "$(jq_file "$MI/.drain.json" 'd["fail_streak"]')" == "1" ]] \
  && ok || fail "S4: fail_streak 1"
grep -q -- 'send-keys -t %0 Enter' "$TMUX_LOG" \
  && fail "S4: Enter не шлется без verify" || ok
idle_pane
TMUX_SWALLOW=1 "$RECON" --drain-once "$AG" 1 >/dev/null 2>&1
[[ "$(jq_file "$MI/.drain.json" 'd["fail_streak"]')" == "2" ]] \
  && ok || fail "S4: fail_streak 2"

# ------------------------------------------------- S5: recovery (маркер уже в input)
printf '/rc active\n❯ [оператор #2]: второе\n' > "$FAKE_PANE"; reset_log
assert "drain recovery"      0 "$RECON" --drain-once "$AG" 1
[[ -f "$MI/delivered/msg-000002.json" ]] && ok || fail "S5: recovery доставил"
grep -q -- 'send-keys -t %0 Enter' "$TMUX_LOG" && ok || fail "S5: Enter дослан"
grep -q -- '-l' "$TMUX_LOG" && fail "S5: повторный -l не нужен" || ok
[[ "$(jq_file "$MI/.drain.json" 'd["fail_streak"]')" == "0" ]] \
  && ok || fail "S5: streak сброшен"

# ------------------------------------------------- S6: split - выбор claude-pane
AG2="$CLAUDE_AGENTS_DIR/mis2"; MI2="$AG2/mission-inbox"; mkdir -p "$AG2"
"$RUN" mission-put mis2 --text "в сплит" >/dev/null
printf '%%0 bash\n%%1 claude\n' > "$FAKE_PANES"
idle_pane; reset_log
assert "drain split->claude"  0 "$RECON" --drain-once "$AG2" 3
grep -q -- '-L agent-mis2.g3 send-keys -t %1 -l' "$TMUX_LOG" \
  && ok || fail "S6: выбран claude-pane %1"
[[ -f "$MI2/delivered/msg-000001.json" ]] && ok || fail "S6: доставлено"

# ------------------------------------------------- S7: неоднозначность - fail-closed
"$RUN" mission-put mis2 --text "двусмысленно" >/dev/null
printf '%%0 claude\n%%1 node\n%%2 bash\n' > "$FAKE_PANES"
idle_pane; reset_log
assert "drain ambiguous"      0 "$RECON" --drain-once "$AG2" 3
[[ -f "$MI2/msg-000002.json" ]] && ok || fail "S7: не отправлено (файл на месте)"
grep -q -- 'send-keys' "$TMUX_LOG" && fail "S7: send-keys не звучит" || ok

# ------------------------------------------------- S8: одиночный pane любой команды
printf '%%3 zsh\n' > "$FAKE_PANES"
idle_pane; reset_log
assert "drain single pane"    0 "$RECON" --drain-once "$AG2" 3
grep -q -- 'send-keys -t %3 -l' "$TMUX_LOG" \
  && ok || fail "S8: единственный pane используется как есть"

# ------------------------------------------------- S9: пустая очередь - тишина
reset_log
assert "drain пустая очередь" 0 "$RECON" --drain-once "$AG" 1
grep -q -- 'send-keys' "$TMUX_LOG" && fail "S9: тишина" || ok

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL == 0 ]]
