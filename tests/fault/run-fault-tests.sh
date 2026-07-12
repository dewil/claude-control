#!/usr/bin/env bash
# Fault-injection suite for the agent layer (stage 1b acceptance criterion:
# "каждый сценарий сходится к desired или к needs-attention с алертом").
# Scenarios map to the crash matrix of the state-machine design (§7.1).
#
# LINUX ONLY (systemd --user, cgroups). Run on the llm VM:
#   tests/fault/run-fault-tests.sh
set -u

[[ "$(uname -s)" == "Linux" ]] || { echo "Linux only (systemd)"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RC="$REPO/bin/claude-rc"
RECON="$REPO/bin/claude-agent-reconciler"
IO="$REPO/bin/claude-agent-io"

TMP="$(mktemp -d)"
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_RECONCILER_DIR="$TMP/reconciler"
export CLAUDE_AGENT_RUNTIME_CMD="MOCK_IO=$IO $HERE/mock-agent.sh"
export CLAUDE_AGENT_STOP_GRACE=3
export CLAUDE_AGENT_START_GRACE=8
export CLAUDE_AGENT_SLEEP_GRACE=5
export CLAUDE_AGENT_HB_MAX=10
export CLAUDE_AGENTS_RAM_BUDGET_MB=250
unset CLAUDE_AGENTS_REQUIRE_MOUNT 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

cleanup() {
  for u in $(systemctl --user list-units 'agent-*' --all --plain --no-legend 2>/dev/null | awk '{print $1}'); do
    systemctl --user stop "$u" >/dev/null 2>&1 || true
  done
  systemctl --user reset-failed >/dev/null 2>&1 || true
  for s in /tmp/tmux-$(id -u)/agent-*; do
    [[ -e "$s" ]] && tmux -L "$(basename "$s")" kill-server 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass()  { "$RECON" --once; }
cfield() { # <name> <py-expr over d>
  "$IO" control-read "$CLAUDE_AGENTS_DIR/$1" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print($2)"
}
wait_for() { # <sec> <desc> <cmd...>: poll до успеха, гоняя проходы
  # reconciler'а (сходимость почти всегда требует нескольких проходов -
  # это сжатый аналог штатного 60s-цикла).
  local sec="$1" desc="$2"; shift 2
  local i=0
  while [[ $i -lt $sec ]]; do
    "$@" >/dev/null 2>&1 && { ok "$desc"; return 0; }
    [[ $((i % 2)) -eq 1 ]] && "$RECON" --once >/dev/null 2>&1
    sleep 1; i=$((i+1))
  done
  fail "$desc (timeout ${sec}s)"; return 1
}
mainpid_of() { systemctl --user show -p MainPID --value "agent-$1.service" 2>/dev/null; }
check_active() { [[ "$(cfield "$1" 'd["lease"]["state"]')" == "active" ]]; }
check_gen()    { [[ "$(cfield "$1" 'd["generation"]')" == "$2" ]]; }
check_att()    { [[ "$(cfield "$1" '(d["attention"] or {}).get("reason","")')" == "$2" ]]; }

make_agent() { # <name> [spec-extra]
  local name="$1"
  local proj="$TMP/proj-$name"
  git init -q "$proj"
  ( cd "$proj" && echo base > base.txt && git add . \
    && git -c user.email=t@t -c user.name=t commit -qm init )
  cat > "$TMP/$name.spec.yaml" <<EOF
schema: 1
name: $name
type: mission
role: mock
project: $proj
goal: "fault scenario $name"
autonomy: act
memory_max_mb: 100
limits: { max_iterations: 99, max_hours: 8, max_iteration_minutes: 20 }
${2:-}
EOF
  echo "# mock mission" > "$TMP/$name.mission.md"
  "$RC" agent create "$name" --spec "$TMP/$name.spec.yaml" \
    --mission "$TMP/$name.mission.md" >/dev/null
  echo healthy > "$CLAUDE_AGENTS_DIR/$name/mock.mode"
}

start_and_settle() { # <name>: start -> passes до lease=active
  "$RC" agent start "$1" >/dev/null
  pass; sleep 3; pass
  wait_for 10 "$1: lease active" check_active "$1"
}

echo "=== S1 (C1/C2): kill агента -> resume, gen++ ==="
make_agent s1
start_and_settle s1
G=$(cfield s1 'd["generation"]')
systemctl --user kill -s SIGKILL agent-s1.service 2>/dev/null
sleep 2; pass   # обнаружит ORPHANED -> дочистит lease
sleep 1; pass   # T1: новый захват
sleep 3
wait_for 10 "s1: re-acquired gen+1" check_gen s1 "$((G+1))"
wait_for 10 "s1: healthy again" check_active s1
"$RC" agent stop s1 >/dev/null; pass

echo "=== S2 (C3): tmux kill-server -> converge ==="
make_agent s2
start_and_settle s2
SOCK=$(cfield s2 'd["lease"]["socket"]')
tmux -L "$SOCK" kill-server 2>/dev/null
sleep 2; pass; sleep 1; pass; sleep 3
wait_for 10 "s2: re-acquired after tmux kill" check_active s2
"$RC" agent stop s2 >/dev/null; pass

echo "=== S3 (C11): SIGSTOP -> нет прогресса -> кварантин/рестарт ==="
make_agent s3
start_and_settle s3
echo overrun > "$CLAUDE_AGENTS_DIR/s3/mock.mode"
sleep 3
pass  # OVERRUN 1-й раз: попытка interrupt (send-keys), кэш-флаг
sleep 2
pass  # OVERRUN 2-й раз: гашение + overrun_quarantine
wait_for 8 "s3: overrun_quarantine" check_att s3 overrun_quarantine
[[ "$(cfield s3 'd["lease"]["state"]')" == "none" ]] \
  && ok "s3: lease released after quarantine" || fail "s3: lease not released"
pass  # attention блокирует resume
[[ "$(cfield s3 'd["lease"]["state"]')" == "none" ]] \
  && ok "s3: attention blocks resume" || fail "s3: resumed despite attention"
"$RC" agent resolve s3 --stop >/dev/null && ok "s3: resolve --stop" || fail "s3 resolve"

echo "=== S4 (T5): OVERSLEPT -> пинок -> рестарт ==="
make_agent s4
start_and_settle s4
echo oversleep > "$CLAUDE_AGENTS_DIR/s4/mock.mode"
sleep 3; pass   # пинок Enter + кэш
sleep 2; pass   # рецидив: гашение + новый захват в след. проходах
echo healthy > "$CLAUDE_AGENTS_DIR/s4/mock.mode"
sleep 1; pass; sleep 3; pass
wait_for 12 "s4: recovered after oversleep" check_active s4
"$RC" agent stop s4 >/dev/null; pass

echo "=== S5 (T6/§5.2): нет heartbeat при живом процессе -> MODAL -> рестарты -> attention ==="
make_agent s5
start_and_settle s5
echo nohb > "$CLAUDE_AGENTS_DIR/s5/mock.mode"
sleep 12   # heartbeat протухает (HB_MAX=10)
pass; sleep 2; pass; sleep 2; pass; sleep 2; pass
wait_for 30 "s5: modal_screen attention после рестартов" check_att s5 modal_screen
"$RC" agent resolve s5 --stop >/dev/null; pass

echo "=== S6 (T7/§8): claim done -> provenance -> needs-human -> accept ==="
make_agent s6
start_and_settle s6
echo claim > "$CLAUDE_AGENTS_DIR/s6/mock.mode"
sleep 4
pass  # CLAIMED: гашение + приемка (нет check -> needs-human)
wait_for 10 "s6: needs-human" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s6 | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
ART=$(cfield s6 'd["acceptance"]["artifact"]')
[[ -n "$ART" && "$ART" != "None" ]] && ok "s6: artifact recorded" || fail "s6: no artifact"
"$RC" agent accept s6 >/dev/null \
  && ok "s6: accepted" || fail "s6: accept failed"
[[ "$(cfield s6 'd["desired"]')" == "stopped" ]] \
  && ok "s6: terminal verdict stopped desired" || fail "s6: desired not stopped"
pass

echo "=== S7 (§8.2): deterministic check -> auto-accept ==="
make_agent s7 'acceptance: { check: "test -f result.txt", deterministic: true, timeout_s: 30 }'
start_and_settle s7
echo claim > "$CLAUDE_AGENTS_DIR/s7/mock.mode"
sleep 4
pass          # гашение + запуск check-воркера
sleep 4; pass # сбор результата: [0,0] -> accepted
wait_for 30 "s7: auto-accepted" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s7 | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == accepted ]]"
[[ "$(cfield s7 'd["desired"]')" == "stopped" ]] \
  && ok "s7: desired stopped той же записью" || fail "s7: desired"

echo "=== S8 (C9): fail-closed mount hold ==="
make_agent s8
export CLAUDE_AGENTS_REQUIRE_MOUNT="/nonexistent-mount-$$"
"$RC" agent start s8 >/dev/null
pass
[[ "$(cfield s8 'd["hold"]')" == "luks_locked" ]] \
  && ok "s8: hold luks_locked" || fail "s8: no hold"
[[ "$(cfield s8 'd["lease"]["state"]')" == "none" ]] \
  && ok "s8: no start under hold" || fail "s8: started under hold!"
grep -q '"reason": "luks_locked"' "$CLAUDE_RECONCILER_DIR/alerts.jsonl" \
  && ok "s8: alert in ledger" || fail "s8: no alert"
N1=$(grep -c luks_locked "$CLAUDE_RECONCILER_DIR/alerts.jsonl")
pass  # повторный проход не спамит
N2=$(grep -c luks_locked "$CLAUDE_RECONCILER_DIR/alerts.jsonl")
[[ "$N1" == "$N2" ]] && ok "s8: alert deduped" || fail "s8: alert spam"
pass; pass; pass  # регресс ребут-теста 2026-07-11: hold не растит retry (§16.3/C9)
[[ "$(cfield s8 '(d["attention"] or {}).get("reason","-")')" == "-" ]] \
  && ok "s8: hold не растит retry (нет resume_failed)" || fail "s8: hold вырастил attention"
unset CLAUDE_AGENTS_REQUIRE_MOUNT
pass; sleep 3
wait_for 15 "s8: starts after unlock" check_active s8
[[ "$(cfield s8 'd["hold"]')" == "None" ]] \
  && ok "s8: hold cleared" || fail "s8: hold stuck"
"$RC" agent stop s8 >/dev/null; pass

echo "=== S9 (C12/§10.1): admission + stagger ==="
make_agent s9a; make_agent s9b; make_agent s9c
"$RC" agent start s9a >/dev/null; "$RC" agent start s9b >/dev/null; "$RC" agent start s9c >/dev/null
pass  # stagger: только один захват за проход
ACT=$(for a in s9a s9b s9c; do cfield "$a" 'd["lease"]["state"]'; done | grep -c -v none)
[[ "$ACT" == "1" ]] && ok "s9: stagger - один захват за проход" || fail "s9: $ACT захватов за проход"
sleep 2; pass; sleep 2; pass   # добираем второй (бюджет 250MB = 2x100MB)
ACT=$(for a in s9a s9b s9c; do cfield "$a" 'd["lease"]["state"]'; done | grep -c -v none)
[[ "$ACT" == "2" ]] && ok "s9: RAM budget = 2 агента" || fail "s9: $ACT активных (ждали 2)"
QUEUED=$(for a in s9a s9b s9c; do cfield "$a" 'd["hold"]'; done | grep -c admission_queue)
[[ "$QUEUED" -ge 1 ]] && ok "s9: третий в admission_queue" || fail "s9: очередь пуста"
for a in s9a s9b s9c; do "$RC" agent stop "$a" >/dev/null; done; pass; pass

echo "=== S10 (C21): crash посреди гашения -> recovery ==="
make_agent s10
start_and_settle s10
# имитируем crash reconciler'а после шага 1 гашения: stopping + живой юнит
"$IO" control-cas "$CLAUDE_AGENTS_DIR/s10" --expect 'lease.state="active"' \
  --set 'lease.state="stopping"' --event test_crash_stopping >/dev/null
"$RC" agent stop s10 >/dev/null
pass  # STOPPING_RECOVERY: должен довести гашение
wait_for 10 "s10: stopping recovered to none" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s10 | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"lease\"][\"state\"])')\" == none ]]"
systemctl --user is-active agent-s10.service >/dev/null 2>&1 \
  && fail "s10: unit still alive" || ok "s10: unit gone"

echo "=== S11 (§8.4): revise -> gen++ -> рестарт ==="
make_agent s11
start_and_settle s11
echo claim > "$CLAUDE_AGENTS_DIR/s11/mock.mode"
sleep 4; pass
wait_for 10 "s11: needs-human" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s11 | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
G=$(cfield s11 'd["generation"]')
echo healthy > "$CLAUDE_AGENTS_DIR/s11/mock.mode"
"$RC" agent revise s11 --note "доделай" >/dev/null && ok "s11: revise" || fail "s11: revise"
pass  # R1: pending + gen++
[[ "$(cfield s11 'd["acceptance"]["status"]')" == "pending" ]] \
  && ok "s11: acceptance pending" || fail "s11: acceptance"
[[ "$(cfield s11 'd["generation"]')" == "$((G+1))" ]] \
  && ok "s11: generation++" || fail "s11: gen"
sleep 1; pass; sleep 3
wait_for 12 "s11: рестартовал с новым поколением" check_active s11
"$RC" agent stop s11 >/dev/null; pass

echo "=== S12 (C6/R2): crash до гейта B -> довершение ==="
make_agent s12
start_and_settle s12
# имитация: возвращаем lease в acquiring при живом юните и state
ATT_ID=$(cfield s12 'd["lease"]["start_attempt_id"]')
"$IO" control-cas "$CLAUDE_AGENTS_DIR/s12" --expect 'lease.state="active"' \
  --set 'lease.state="acquiring"' --set 'lease.main_pid=null' \
  --event test_crash_gate_b >/dev/null
pass  # ACQUIRING_READY -> R2: гейт B довершен
wait_for 8 "s12: gate B recovered" check_active s12
[[ "$(cfield s12 'd["lease"]["main_pid"]')" != "None" ]] \
  && ok "s12: main_pid re-recorded" || fail "s12: main_pid null"
"$RC" agent stop s12 >/dev/null; pass

echo "=== S13 (§9): handoff-адопция ==="
# фикстура: "origin-сессия" = sleep-процесс + фейковый транскрипт в namespace
SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
ORIGIN_CWD="$TMP/origin-proj"
mkdir -p "$ORIGIN_CWD"
SLUG_O=$(echo "$ORIGIN_CWD" | sed 's|[^a-zA-Z0-9]|-|g')
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CFG/projects/$SLUG_O"
echo '{"type":"fake","line":1}' > "$CFG/projects/$SLUG_O/$SID.jsonl"
sleep 300 & OPID=$!
OSTART=$(awk '{print $22}' "/proc/$OPID/stat")
make_agent s13
sed "s/^name: s13\$/name: s13h/" "$TMP/s13.spec.yaml" > "$TMP/s13h.spec.yaml"
"$REPO/bin/claude-rc" agent create s13h --spec "$TMP/s13h.spec.yaml" \
  --mission "$TMP/s13.mission.md" \
  --handoff-session "$SID" --handoff-pid "$OPID" \
  --handoff-pid-start "$OSTART" --handoff-cwd "$ORIGIN_CWD" \
  --handoff-expires-min 10 >/dev/null \
  && ok "s13: handoff-create" || fail "s13: handoff-create"
echo healthy > "$CLAUDE_AGENTS_DIR/s13h/mock.mode"
pass
[[ "$(cfield s13h 'd["handoff"]["phase"]')" == "prepared" ]] \
  && ok "s13: prepared ждет живой origin" || fail "s13: prepared ($(cfield s13h 'd["handoff"]["phase"]'))"
[[ "$(cfield s13h 'd["desired"]')" == "paused" ]] \
  && ok "s13: desired=paused при живом origin" || fail "s13: desired"
kill "$OPID" 2>/dev/null; wait "$OPID" 2>/dev/null
pass  # триада ок -> adopting -> move -> adopted + desired=running
wait_for 10 "s13: adopted + running" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s13h | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"handoff\"][\"phase\"], d[\"desired\"])')\" == \"adopted running\" ]]"
SLUG_W=$(echo "$CLAUDE_AGENTS_DIR/s13h/work" | sed 's|[^a-zA-Z0-9]|-|g')
[[ -f "$CFG/projects/$SLUG_W/$SID.jsonl" ]] \
  && ok "s13: транскрипт в namespace агента" || fail "s13: транскрипт не переехал"
[[ ! -f "$CFG/projects/$SLUG_O/$SID.jsonl" ]] \
  && ok "s13: origin-файла больше нет (--continue не найдет)" || fail "s13: origin остался"
wait_for 15 "s13: агент стартовал после адопции" check_active s13h
"$REPO/bin/claude-rc" agent stop s13h >/dev/null; pass
rm -rf "$CFG/projects/$SLUG_O" "$CFG/projects/$SLUG_W"

echo "=== S14 (C26): crash посреди адопции -> recovery ==="
SID2=$(python3 -c 'import uuid; print(uuid.uuid4())')
mkdir -p "$CFG/projects/$SLUG_O"
echo '{"type":"fake","line":2}' > "$CFG/projects/$SLUG_O/$SID2.jsonl"
D2=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CFG/projects/$SLUG_O/$SID2.jsonl")
sed "s/^name: s13\$/name: s14h/" "$TMP/s13.spec.yaml" > "$TMP/s14h.spec.yaml"
"$REPO/bin/claude-rc" agent create s14h --spec "$TMP/s14h.spec.yaml" \
  --mission "$TMP/s13.mission.md" \
  --handoff-session "$SID2" --handoff-pid 1 --handoff-pid-start 999999999 \
  --handoff-cwd "$ORIGIN_CWD" >/dev/null 2>&1 || true
# имитация crash ПОСЛЕ входа в adopting, ДО move
"$IO" control-cas "$CLAUDE_AGENTS_DIR/s14h" --expect 'handoff.phase="prepared"' \
  --set 'handoff.phase="adopting"' --set "handoff.transcript_digest=\"$D2\"" \
  --event test_crash_adopting >/dev/null
echo healthy > "$CLAUDE_AGENTS_DIR/s14h/mock.mode"
pass  # recovery: origin есть/dest нет -> move -> adopted
wait_for 10 "s14: adopting recovery -> adopted" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s14h | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"handoff\"][\"phase\"])')\" == adopted ]]"
"$REPO/bin/claude-rc" agent stop s14h >/dev/null; pass; pass

echo "=== S15 (§9.4): чужой dest -> adoption_failed, ничего не удалено ==="
SID3=$(python3 -c 'import uuid; print(uuid.uuid4())')
echo '{"type":"fake","line":3}' > "$CFG/projects/$SLUG_O/$SID3.jsonl"
sed "s/^name: s13\$/name: s15h/" "$TMP/s13.spec.yaml" > "$TMP/s15h.spec.yaml"
"$REPO/bin/claude-rc" agent create s15h --spec "$TMP/s15h.spec.yaml" \
  --mission "$TMP/s13.mission.md" \
  --handoff-session "$SID3" --handoff-pid 1 --handoff-pid-start 999999999 \
  --handoff-cwd "$ORIGIN_CWD" >/dev/null 2>&1 || true
SLUG_W15=$(echo "$CLAUDE_AGENTS_DIR/s15h/work" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$CFG/projects/$SLUG_W15"
echo '{"foreign":"file"}' > "$CFG/projects/$SLUG_W15/$SID3.jsonl"  # чужой dest
pass; pass
wait_for 8 "s15: adoption_failed на чужом dest" check_att s15h adoption_failed
grep -q foreign "$CFG/projects/$SLUG_W15/$SID3.jsonl" \
  && ok "s15: чужой файл не тронут" || fail "s15: чужой файл поврежден"
[[ -f "$CFG/projects/$SLUG_O/$SID3.jsonl" ]] \
  && ok "s15: origin цел" || fail "s15: origin пропал"
"$REPO/bin/claude-rc" agent resolve s15h --stop >/dev/null 2>&1 || true
rm -rf "$CFG/projects/$SLUG_O" "$CFG/projects/$SLUG_W15"

# =========================================================================
# Этап 4: event-агенты (design delta 2026-07-12). Рантайм - НАСТОЯЩИЙ
# claude-agent-run loop; мокается только claude (CLAUDE_BIN).
# =========================================================================
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_CYCLE_S=1
export CLAUDE_AGENT_RETRY_DELAYS="1,2,3"
export CLAUDE_AGENT_PROBE_CMD="$(command -v true)"
ALERTLOG="$TMP/alerts-hook.log"
cat > "$TMP/alert-hook.sh" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2 \$3" >> "$ALERTLOG"
EOF
chmod +x "$TMP/alert-hook.sh"
export CLAUDE_AGENT_ALERT_CMD="$TMP/alert-hook.sh"
MOCKCL="$TMP/mock-claude"
cat > "$MOCKCL" <<'EOF'
#!/usr/bin/env bash
prompt=$(cat)
grep -q poison <<<"$prompt" && { echo "poison boom" >&2; exit 1; }
grep -q медленное <<<"$prompt" && sleep 6
echo '{"type":"result","result":"обработано","total_cost_usd":0.001}'
EOF
chmod +x "$MOCKCL"
export CLAUDE_BIN="$MOCKCL"
RUNB="$REPO/bin/claude-agent-run"

make_event_agent() { # <name> [runs_per_day]
  cat > "$TMP/$1.spec.yaml" <<EOF
schema: 1
name: $1
type: event
role: mock
goal: "event fault scenario $1"
autonomy: suggest
memory_max_mb: 60
limits: { runs_per_day: ${2:-100}, run_timeout_s: 15 }
source: { kind: spool, replay_window_h: 72 }
EOF
  "$RC" agent create "$1" --spec "$TMP/$1.spec.yaml" >/dev/null
}

echo "=== S16 (Д1-Д3): event-агент - intake, прогоны, kill -9 без потери ==="
make_event_agent e16
IB16="$CLAUDE_AGENTS_DIR/e16/inbox"
"$RUNB" spool-put e16 --text "быстрое событие" >/dev/null
"$RUNB" spool-put e16 --text "медленное событие" >/dev/null
"$RC" agent start e16 >/dev/null
pass
wait_for 15 "s16: lease active" check_active e16
wait_for 25 "s16: первое событие done" \
  bash -c "[[ \$(ls '$IB16/done' | wc -l) -ge 1 ]]"
# kill -9 посреди медленного прогона (второй конверт inflight)
MP=$(mainpid_of e16); [[ "$MP" -gt 0 ]] && kill -9 "$MP" 2>/dev/null
wait_for 40 "s16: kill -9 -> resume, оба события done (потери нет)" \
  bash -c "[[ \$(ls '$IB16/done' | wc -l) -eq 2 ]]"
[[ "$(cfield e16 'd["generation"]')" -ge 2 ]] \
  && ok "s16: generation вырос" || fail "s16: generation не вырос"
[[ -z "$(ls "$IB16/pending" "$IB16/inflight" 2>/dev/null | grep json)" ]] \
  && ok "s16: очередь пуста, дублей нет" || fail "s16: остатки в очереди"
[[ "$(grep -c key "$IB16/dedup.jsonl")" -eq 2 ]] \
  && ok "s16: дедуп-леджер = 2 ключа" || fail "s16: дедуп-леджер неверен"
"$RC" agent stop e16 >/dev/null 2>&1; pass

echo "=== S17 (Д5): бюджет-кап -> executor выходит, hold + алерт, intake живет ==="
make_event_agent e17 1
IB17="$CLAUDE_AGENTS_DIR/e17/inbox"
"$RUNB" spool-put e17 --text "первое в кап" >/dev/null
"$RUNB" spool-put e17 --text "второе за капом" >/dev/null
"$RC" agent start e17 >/dev/null
pass
wait_for 25 "s17: одно событие done (кап=1)" \
  bash -c "[[ \$(ls '$IB17/done' | wc -l) -eq 1 ]]"
wait_for 30 "s17: hold budget_exhausted" \
  bash -c "[[ \$($RC agent status e17 | grep -c budget_exhausted) -ge 1 ]]"
grep -q "e17 budget_exhausted" "$ALERTLOG" \
  && ok "s17: алерт пуш ушел" || fail "s17: алерта нет"
"$RUNB" spool-put e17 --text "третье при hold" >/dev/null
pass; pass
[[ "$(ls "$IB17/pending" | wc -l)" -ge 2 ]] \
  && ok "s17: intake живет при hold (§10.2)" || fail "s17: intake встал"
systemctl --user is-active agent-e17.service >/dev/null 2>&1 \
  && fail "s17: рантайм не должен бежать" || ok "s17: рантайм стоит"
"$RC" agent stop e17 >/dev/null 2>&1; pass

echo "=== S18 (§10.3/§16.1): wedge -> attention, захват РАЗРЕШЕН, drain лечит ==="
export CLAUDE_AGENT_INBOX_MAX_EVENTS=1
make_event_agent e18
IB18="$CLAUDE_AGENTS_DIR/e18/inbox"
"$RUNB" spool-put e18 --text "раз" >/dev/null
"$RUNB" spool-put e18 --text "два" >/dev/null
pass; pass   # intake при desired=paused (§11.1)
wait_for 10 "s18: attention inbox_wedged" check_att e18 inbox_wedged
"$RC" agent start e18 >/dev/null
wait_for 40 "s18: drain при wedged - оба события done" \
  bash -c "[[ \$(ls '$IB18/done' | wc -l) -eq 2 ]]"
wait_for 10 "s18: wedge самоснялся" \
  bash -c "[[ -z \$(\"$IO\" control-read \"$CLAUDE_AGENTS_DIR/e18\" | python3 -c 'import json,sys; print((json.load(sys.stdin).get(\"attention\") or {}).get(\"reason\",\"\"))') ]]"
unset CLAUDE_AGENT_INBOX_MAX_EVENTS
"$RC" agent stop e18 >/dev/null 2>&1; pass

echo "=== S19 (§11.2): ядовитое событие -> DLQ, очередь живет, алерт ==="
make_event_agent e19
IB19="$CLAUDE_AGENTS_DIR/e19/inbox"
"$RUNB" spool-put e19 --text "poison событие" >/dev/null
"$RUNB" spool-put e19 --text "здоровое событие" >/dev/null
"$RC" agent start e19 >/dev/null
pass
wait_for 40 "s19: poison -> deadletter (3 попытки)" \
  bash -c "[[ \$(ls '$IB19/deadletter' | wc -l) -eq 1 ]]"
wait_for 20 "s19: здоровое событие done (очередь жива)" \
  bash -c "[[ \$(ls '$IB19/done' | wc -l) -eq 1 ]]"
grep -q "e19 event_deadletter" "$ALERTLOG" \
  && ok "s19: алерт deadletter ушел" || fail "s19: алерта нет"
DLK=$(ls "$IB19/deadletter" | sed 's/.json//')
"$RC" agent dlq e19 --requeue "$DLK" >/dev/null \
  && ok "s19: requeue ok" || fail "s19: requeue сломан"
"$RC" agent stop e19 >/dev/null 2>&1; pass

echo "==="
echo "fault suite: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
