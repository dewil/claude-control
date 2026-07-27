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
limits: { max_iterations: 99, max_hours: 8, max_iteration_minutes: ${MIM:-20} }
${2:-}
EOF
  echo "# mock mission" > "$TMP/$name.mission.md"
  local extra=()
  [[ -n "${3:-}" ]] && extra=(--reviewer-role "$3")
  "$RC" agent create "$name" --spec "$TMP/$name.spec.yaml" \
    --mission "$TMP/$name.mission.md" "${extra[@]}" >/dev/null
  echo healthy > "$CLAUDE_AGENTS_DIR/$name/mock.mode"
}

# reviewer-role снапшот для stage-7 сценариев (manifest + sha)
mk_reviewer_role() {
  local rr="$TMP/reviewer-role"
  mkdir -p "$rr"; echo "# mock reviewer rubric" > "$rr/prompt.md"
  local sha; sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$rr/prompt.md")
  cat > "$rr/manifest.yaml" <<EOF
schema: 1
role: mockrev
files:
  - { path: prompt.md, sha256: "$sha" }
EOF
  echo "$rr"
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
# max_iteration_minutes=1: OVERRUN считается от возраста lease ТЕКУЩЕГО
# поколения (classify клампит it_age к granted_age - протухший
# iteration_started_at сам по себе не даёт мгновенный карантин). Чтобы
# поколение реально "переработало", ждём >60с активного lease до overrun.
MIM=1 make_agent s3
start_and_settle s3
sleep 62  # granted_age > max_iteration_minutes(1)*60с
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

echo "=== S9d (C12/§10.1, event/drain): три drain-агента с событиями в spool - admission/RAM-бюджет разводит старты, не все три сразу ==="
RUNB="$REPO/bin/claude-agent-run"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool-s9d"
MOCKCL_S9D="$TMP/mock-claude-s9d"
cat > "$MOCKCL_S9D" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null   # съесть промпт
sleep 60         # держим drain-юнит активным на все окно admission-проверки
echo '{"type":"result","result":"processed","total_cost_usd":0.01}'
EOF
chmod +x "$MOCKCL_S9D"
export CLAUDE_BIN="$MOCKCL_S9D"
# drain-юнит не пишет промежуточных heartbeat пока блокирован внутри одного
# claude-вызова (мок спит 60с) - боевой HB_MAX=10 (задан вверху файла ради
# быстрых MODAL-кейсов S5) счел бы это зависанием и загасил юнит раньше
# времени. На окно этого сценария порог поднимается, снаружи не течет.
HB_MAX_SAVE_S9D="$CLAUDE_AGENT_HB_MAX"
export CLAUDE_AGENT_HB_MAX=120
for a in s9d1 s9d2 s9d3; do
  cat > "$TMP/$a.spec.yaml" <<EOF
schema: 1
name: $a
type: event
role: mock
goal: "drain admission scenario $a"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 90 }
source: { kind: spool, replay_window_h: 72 }
runtime: drain
EOF
  "$RC" agent create "$a" --spec "$TMP/$a.spec.yaml" >/dev/null
  "$RUNB" spool-put "$a" --text "s9d событие" >/dev/null
done
"$RC" agent start s9d1 >/dev/null; "$RC" agent start s9d2 >/dev/null; "$RC" agent start s9d3 >/dev/null
pass  # stagger: только один drain-захват за проход
ACT=$(for a in s9d1 s9d2 s9d3; do cfield "$a" 'd["lease"]["state"]'; done | grep -c -v none)
[[ "$ACT" == "1" ]] && ok "s9d: stagger - один drain-захват за проход" || fail "s9d: $ACT захватов за проход"
sleep 2; pass; sleep 2; pass   # добираем второй (бюджет 250MB = 2x100MB); все еще "жуют" событие (мок спит 60с)
ACT=$(for a in s9d1 s9d2 s9d3; do cfield "$a" 'd["lease"]["state"]'; done | grep -c -v none)
[[ "$ACT" == "2" ]] && ok "s9d: RAM budget = 2 drain-агента" || fail "s9d: $ACT активных (ждали 2)"
QUEUED=$(for a in s9d1 s9d2 s9d3; do cfield "$a" 'd["hold"]'; done | grep -c admission_queue)
[[ "$QUEUED" -ge 1 ]] && ok "s9d: третий drain-агент в admission_queue" || fail "s9d: очередь пуста"
for a in s9d1 s9d2 s9d3; do "$RC" agent stop "$a" >/dev/null 2>&1; done
pass  # гасим досрочно (не ждём естественного завершения sleep 60 в моке)
unset CLAUDE_BIN
export CLAUDE_AGENT_HB_MAX="$HB_MAX_SAVE_S9D"

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
# v2.1 (S21a/b): создает файл в $PWD (=cwd прогона, Popen(cwd=...)) и,
# для worktree-сценария, коммитит его в текущую (агентскую) ветку
grep -q worktree-commit <<<"$prompt" && {
  touch task-output.txt
  git add -A >/dev/null 2>&1
  git commit -q -m "task commit" >/dev/null 2>&1 || true
}
grep -q direct-touch <<<"$prompt" && touch direct-output.txt
echo '{"type":"result","result":"обработано","total_cost_usd":0.001}'
EOF
chmod +x "$MOCKCL"
export CLAUDE_BIN="$MOCKCL"
RUNB="$REPO/bin/claude-agent-run"

make_event_agent() { # <name> [runs_per_day] [extra-spec-yaml]
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
${3:-}
EOF
  "$RC" agent create "$1" --spec "$TMP/$1.spec.yaml" >/dev/null
}
resume_fails_of() { # <name>: 0 если счетчик отсутствует (см. cget/cset)
  local v; v=$(grep '^resume_fails=' "$CLAUDE_RECONCILER_DIR/cache/$1.flags" \
    2>/dev/null | cut -d= -f2)
  echo "${v:-0}"
}
lease_state_of() { cfield "$1" 'd["lease"]["state"]'; }
changes_has() { # <changes-json> <relpath> <field: added|modified|deleted>
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in d.get(sys.argv[3], []) else 1)' "$1" "$2" "$3"
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

echo "=== S20a (v2 §4.2/§6): runtime=drain - юнит не стартует на пустом spool, событие -> старт-обработка-выход, resume_fails не растет ==="
make_event_agent e20a 100 'runtime: drain'
IB20A="$CLAUDE_AGENTS_DIR/e20a/inbox"
"$RC" agent start e20a >/dev/null
pass; pass; pass   # 3 прохода на пустом spool (контракт §6 S20a)
systemctl --user is-active agent-e20a.service >/dev/null 2>&1 \
  && fail "s20a: юнит стартовал на пустом spool" \
  || ok "s20a: юнит ни разу не стартовал (3 прохода, spool пуст)"
[[ "$(lease_state_of e20a)" == "none" ]] \
  && ok "s20a: lease.state=none" || fail "s20a: lease.state != none"
[[ -z "$(cfield e20a '(d["attention"] or {}).get("reason","")')" ]] \
  && ok "s20a: attention пуст (до события)" || fail "s20a: attention не пуст"
RF0=$(resume_fails_of e20a)
"$RUNB" spool-put e20a --text "drain событие" >/dev/null
pass
wait_for 20 "s20a: событие обработано (done)" \
  bash -c "[[ \$(ls '$IB20A/done' 2>/dev/null | wc -l) -eq 1 ]]"
wait_for 15 "s20a: юнит вышел, lease освобожден" \
  bash -c "! systemctl --user is-active agent-e20a.service >/dev/null 2>&1 \
    && [[ \$(\"$IO\" control-read \"$CLAUDE_AGENTS_DIR/e20a\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"lease\"][\"state\"])') == none ]]"
[[ -z "$(cfield e20a '(d["attention"] or {}).get("reason","")')" ]] \
  && ok "s20a: attention пуст после выхода" || fail "s20a: attention появился"
RF1=$(resume_fails_of e20a)
[[ "$RF1" -le "$RF0" ]] \
  && ok "s20a: resume_fails не вырос ($RF0 -> $RF1)" \
  || fail "s20a: resume_fails вырос ($RF0 -> $RF1) - подозреваемая гонка с gate_b на быстром drain-выходе"
GEN_A=$(cfield e20a 'd["generation"]')
# pause, не stop: agent start требует desired=paused (stop - терминален,
# см. cmd_stop/cmd_start в bin/claude-rc-agent) - S20b переиспользует агента
"$RC" agent pause e20a >/dev/null 2>&1; pass

echo "=== S20b (v2 §4.2): второе событие тому же drain-агенту - цикл повторился, generation вырос ==="
"$RC" agent start e20a >/dev/null
pass
"$RUNB" spool-put e20a --text "drain событие 2" >/dev/null
pass
wait_for 20 "s20b: второе событие обработано (done)" \
  bash -c "[[ \$(ls '$IB20A/done' 2>/dev/null | wc -l) -eq 2 ]]"
wait_for 15 "s20b: юнит вышел повторно, lease освобожден" \
  bash -c "! systemctl --user is-active agent-e20a.service >/dev/null 2>&1 \
    && [[ \$(\"$IO\" control-read \"$CLAUDE_AGENTS_DIR/e20a\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"lease\"][\"state\"])') == none ]]"
GEN_B=$(cfield e20a 'd["generation"]')
[[ "$GEN_B" -gt "$GEN_A" ]] \
  && ok "s20b: generation вырос ($GEN_A -> $GEN_B)" \
  || fail "s20b: generation не вырос ($GEN_A -> $GEN_B)"
"$RC" agent stop e20a >/dev/null 2>&1; pass

echo "=== S20c (v2 §5 регресс): event-агент БЕЗ runtime (loop) стартует безусловно при пустом spool ==="
# runtime не задан -> дефолт loop; поведение должно быть байт-в-байт как в
# S16-S19 (там же и покрыто) - здесь явная точечная проверка контраста с S20a.
make_event_agent e20c
"$RC" agent start e20c >/dev/null
pass
wait_for 15 "s20c: loop-агент стартовал на пустом spool (регресс к S16)" check_active e20c
"$RC" agent stop e20c >/dev/null 2>&1; pass

echo "=== S20d (аудит: inflight-гейт + Gate-B fast-exit): kill mid-inflight -> восстановление БЕЗ нового события ==="
make_event_agent e20d 100 'runtime: drain'
IB20D="$CLAUDE_AGENTS_DIR/e20d/inbox"
"$RC" agent start e20d >/dev/null
"$RUNB" spool-put e20d --text "медленное событие" >/dev/null
pass
wait_for 15 "s20d: юнит поднялся (ready>0)" check_active e20d
wait_for 15 "s20d: конверт ушел в inflight (claim)" \
  bash -c "[[ \$(ls '$IB20D/inflight' 2>/dev/null | wc -l) -ge 1 ]]"
MP=$(mainpid_of e20d); [[ "$MP" -gt 0 ]] && kill -9 "$MP" 2>/dev/null
GEN_D0=$(cfield e20d 'd["generation"]')
# spool пуст - никакого нового события не кладем: следующий подъем юнита
# обязан произойти по факту inflight>0 (blocker 1, v2 §4.2), иначе конверт
# зависает бессрочно
wait_for 40 "s20d: юнит поднялся снова БЕЗ нового события, recovery дожал конверт до done" \
  bash -c "[[ \$(ls '$IB20D/done' 2>/dev/null | wc -l) -eq 1 ]]"
wait_for 15 "s20d: юнит вышел, lease освобожден" \
  bash -c "! systemctl --user is-active agent-e20d.service >/dev/null 2>&1 \
    && [[ \$(\"$IO\" control-read \"$CLAUDE_AGENTS_DIR/e20d\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"lease\"][\"state\"])') == none ]]"
GEN_D1=$(cfield e20d 'd["generation"]')
[[ "$GEN_D1" -gt "$GEN_D0" ]] \
  && ok "s20d: generation вырос после восстановления ($GEN_D0 -> $GEN_D1)" \
  || fail "s20d: generation не вырос ($GEN_D0 -> $GEN_D1)"
[[ -z "$(ls "$IB20D/pending" "$IB20D/inflight" 2>/dev/null | grep json)" ]] \
  && ok "s20d: очередь пуста после recovery, дублей нет" || fail "s20d: остатки в очереди"
[[ -z "$(cfield e20d '(d["attention"] or {}).get("reason","")')" ]] \
  && ok "s20d: attention пуст" || fail "s20d: attention появился"
# явная проверка fast-exit (major 2): Gate B без MainPID при inactive/success
# юнита - штатный drain-выход, не провал захвата
RF_D=$(resume_fails_of e20d)
[[ "$RF_D" -eq 0 ]] \
  && ok "s20d: resume_fails == 0 после всех циклов (fast-exit не растит счетчик)" \
  || fail "s20d: resume_fails вырос ($RF_D) - Gate B fast-exit не сработал"
[[ "$(cfield e20d '(d["attention"] or {}).get("reason","")')" != "resume_failed" ]] \
  && ok "s20d: attention.reason != resume_failed" || fail "s20d: attention=resume_failed"
"$RC" agent stop e20d >/dev/null 2>&1; pass

echo "=== S21a (v2.1 §2/§4/§7): workspace=worktree - прогон коммитит в свою ветку, main не тронут ==="
PROJ21A="$TMP/proj21a"
git init -q -b main "$PROJ21A"
( cd "$PROJ21A" && git config user.email t@t && git config user.name t \
  && echo base > base.txt && git add . && git commit -qm init )
BASE21A=$(git -C "$PROJ21A" rev-parse main)
make_event_agent e21a 100 "project: $PROJ21A
workspace: worktree
runtime: drain"
IB21A="$CLAUDE_AGENTS_DIR/e21a/inbox"
[[ -d "$CLAUDE_AGENTS_DIR/e21a/work" ]] \
  && ok "s21a: worktree создан при create" || fail "s21a: worktree/ отсутствует"
INC21A=$(cfield e21a 'd["incarnation"]')
BR21A="task/e21a-${INC21A:0:8}"
git -C "$PROJ21A" show-ref --verify -q "refs/heads/$BR21A" \
  && ok "s21a: ветка $BR21A создана (task/<name>-<inc8>)" || fail "s21a: ветка не найдена"
"$RC" agent start e21a >/dev/null
"$RUNB" spool-put e21a --text "worktree-commit задача" >/dev/null
pass
wait_for 20 "s21a: событие обработано (done)" \
  bash -c "[[ \$(ls '$IB21A/done' 2>/dev/null | wc -l) -eq 1 ]]"
wait_for 15 "s21a: юнит вышел, lease освобожден" \
  bash -c "! systemctl --user is-active agent-e21a.service >/dev/null 2>&1 \
    && [[ \$(\"$IO\" control-read \"$CLAUDE_AGENTS_DIR/e21a\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"lease\"][\"state\"])') == none ]]"
CUR21A=$(git -C "$PROJ21A" rev-parse "$BR21A")
[[ "$CUR21A" != "$BASE21A" ]] \
  && ok "s21a: ветка $BR21A получила новый коммит" || fail "s21a: ветка не продвинулась"
git -C "$PROJ21A" cat-file -e "$CUR21A:task-output.txt" 2>/dev/null \
  && ok "s21a: task-output.txt закоммичен в агентскую ветку" || fail "s21a: файла нет в коммите"
[[ "$(git -C "$PROJ21A" rev-parse main)" == "$BASE21A" ]] \
  && ok "s21a: main не тронут" || fail "s21a: main изменился!"
[[ -z "$(cfield e21a '(d["attention"] or {}).get("reason","")')" ]] \
  && ok "s21a: attention пуст" || fail "s21a: attention появился"
"$RC" agent stop e21a >/dev/null 2>&1; pass

echo "=== S21b (v2.1 §6): workspace=direct - файл на месте, changes-дифф зафиксирован ==="
PROJ21B="$TMP/proj21b"
mkdir -p "$PROJ21B"
echo one > "$PROJ21B/one.txt"
echo two > "$PROJ21B/two.txt"
make_event_agent e21b 100 "project: $PROJ21B
workspace: direct
runtime: drain"
IB21B="$CLAUDE_AGENTS_DIR/e21b/inbox"
"$RC" agent start e21b >/dev/null
"$RUNB" spool-put e21b --text "direct-touch задача" >/dev/null
pass
wait_for 20 "s21b: событие обработано (done)" \
  bash -c "[[ \$(ls '$IB21B/done' 2>/dev/null | wc -l) -eq 1 ]]"
wait_for 15 "s21b: юнит вышел, lease освобожден" \
  bash -c "! systemctl --user is-active agent-e21b.service >/dev/null 2>&1 \
    && [[ \$(\"$IO\" control-read \"$CLAUDE_AGENTS_DIR/e21b\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"lease\"][\"state\"])') == none ]]"
[[ -f "$PROJ21B/direct-output.txt" ]] \
  && ok "s21b: файл создан прямо в живой папке проекта" || fail "s21b: файла нет в проекте"
DONEKEY21B=$(ls "$IB21B/done" | sed 's/.json//' | head -1)
CH21B="$CLAUDE_AGENTS_DIR/e21b/changes/$DONEKEY21B.json"
[[ -f "$CH21B" ]] \
  && ok "s21b: changes/<key>.json создан" || fail "s21b: changes-файл не создан"
changes_has "$CH21B" direct-output.txt added \
  && ok "s21b: direct-output.txt зафиксирован в changes.added" \
  || fail "s21b: файла нет в changes.added"
[[ -z "$(cfield e21b '(d["attention"] or {}).get("reason","")')" ]] \
  && ok "s21b: attention пуст" || fail "s21b: attention появился"
"$RC" agent stop e21b >/dev/null 2>&1; pass

echo "=== S30 (security): claim_artifact с \$() НЕ исполняется classify-eval ==="
# adversarial блокер 2: агентский claim_artifact течёт в eval реконсилера
# ДО git-провенанса. json.dumps в двойных кавычках исполнил бы $()/``;
# shlex.quote (одинарные) - нет. Проверяем на реальном пути classify->eval.
rm -f /tmp/reconciler-pwned
make_agent s30
start_and_settle s30
GEN=$(cfield s30 'd["generation"]')
# заглушить рантайм, чтобы hb mock-агента не перезаписал инъекцию
systemctl --user kill -s SIGKILL agent-s30.service 2>/dev/null; sleep 1
python3 - "$CLAUDE_AGENTS_DIR/s30" "$GEN" <<'PY'
import json, os, sys
adir, gen = sys.argv[1], sys.argv[2]
p = os.path.join(adir, "state.%s.json" % gen)
d = json.load(open(p))
d["agent_claim"] = "done"
d["claim_artifact"] = "$(touch /tmp/reconciler-pwned)"
d["phase"] = "sleeping"
json.dump(d, open(p, "w"))
PY
pass; pass  # classify каждого прохода читает claim_artifact -> eval
[[ ! -e /tmp/reconciler-pwned ]] \
  && ok "s30: \$() в claim_artifact не исполнился" \
  || { fail "s30: claim_artifact исполнился шеллом реконсилера!"; rm -f /tmp/reconciler-pwned; }
"$RC" agent stop s30 >/dev/null 2>&1; pass

# =========================================================================
# Этап 7: ролевой приёмщик (design 2026-07-12-stage7). Мокается ТОЛЬКО
# вывод приёмщика (CLAUDE_AGENT_REVIEW_CMD -> mock-review.sh); FSM/fencing/
# phase/retry/revoke - настоящие.
# =========================================================================
# НАСТОЯЩИЙ claude-agent-review, мокается только claude (CLAUDE_BIN) -
# проверяются реальные git diff, mission gate, role verification, пустой
# cwd, строгий парсер, no-clobber (ревью-4 п.9)
unset CLAUDE_AGENT_REVIEW_CMD 2>/dev/null || true
export CLAUDE_BIN="$HERE/mock-review-claude.sh"
REVROLE=$(mk_reviewer_role)
rm -f /tmp/agent-review-pwned   # $()-зонд из summary мока (см. S21 и финал)
acc_status() { cfield "$1" 'd["acceptance"]["status"]'; }
drive_claim() { # <name>: погнать mock-агента в claim done с артефактом
  echo claim > "$CLAUDE_AGENTS_DIR/$1/mock.mode"; sleep 4; pass; sleep 3; pass
}

echo "=== S20 (§8.6): role-review + auto_accept -> accepted ==="
export MOCK_REVIEW_VERDICT=accept
make_agent s20 'acceptance: { kind: role-review, auto_accept: true }' "$REVROLE"
start_and_settle s20
drive_claim s20
wait_for 20 "s20: reviewer accept -> accepted" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s20 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == accepted ]]"
[[ "$(cfield s20 'd["desired"]')" == "stopped" ]] \
  && ok "s20: terminal stopped" || fail "s20: desired"
[[ "$(cfield s20 'd["acceptance"]["verdict_by"]')" == "reviewer" ]] \
  && ok "s20: verdict_by=reviewer" || fail "s20: verdict_by"

echo "=== S21 (§8.6): role-review без auto_accept -> needs-human (рекомендация) ==="
make_agent s21 'acceptance: { kind: role-review }' "$REVROLE"
start_and_settle s21
drive_claim s21
wait_for 20 "s21: accept без auto -> needs-human" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s21 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
[[ "$(cfield s21 'd["desired"]')" != "stopped" ]] \
  && ok "s21: не терминален (человек решает)" || fail "s21: desired stopped!"
# note из summary приемщика: читаемая кириллица (не \uXXXX-эскейпы)...
N21=$(cfield s21 'd["acceptance"]["note"]')
case "$N21" in
  *кириллица*) ok "s21: note с читаемой кириллицей" ;;
  *) fail "s21: note нечитаема: ${N21:0:80}" ;;
esac
# ...и $() из LLM-текста НЕ исполняется шеллом реконсилера
[[ ! -e /tmp/agent-review-pwned ]] \
  && ok "s21: \$()-зонд из summary не исполнился" \
  || { fail "s21: summary исполнился шеллом!"; rm -f /tmp/agent-review-pwned; }
"$RC" agent stop s21 >/dev/null; pass

echo "=== S22 (§8.6): reviewer reject -> needs-human, не авто-reject ==="
export MOCK_REVIEW_VERDICT=reject
make_agent s22 'acceptance: { kind: role-review, auto_accept: true }' "$REVROLE"
start_and_settle s22
drive_claim s22
wait_for 20 "s22: reject -> needs-human (не rejected терминал)" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s22 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
"$RC" agent stop s22 >/dev/null; pass

echo "=== S23 (§8.8): both - чек зелёный -> review -> accepted (phase-FSM) ==="
export MOCK_REVIEW_VERDICT=accept
make_agent s23 'acceptance: { kind: both, check: "test -f base.txt", deterministic: true, auto_accept: true }' "$REVROLE"
start_and_settle s23
echo claim > "$CLAUDE_AGENTS_DIR/s23/mock.mode"; sleep 4; pass; sleep 3
# промежуточные фазы наблюдаемы: переходы требуют ОТДЕЛЬНОГО прохода
# reconciler'а, а между двумя poll'ами wait_for - максимум один проход
wait_for 15 "s23: phase=check_running (стартовый CAS чека)" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s23 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"].get(\"phase\") or \"\")')\" == check_running ]]"
wait_for 20 "s23: phase=review_running (чек-гейт зелёный)" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s23 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"].get(\"phase\") or \"\")')\" == review_running ]]"
wait_for 25 "s23: both -> accepted через phase-FSM" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s23 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == accepted ]]"
[[ -z "$(cfield s23 '(d["acceptance"].get("phase") or "")')" ]] \
  && ok "s23: phase сброшена терминальным CAS" || fail "s23: phase не сброшена"

echo "=== S24 (§8.8): both - чек красный -> needs-human, приёмщик НЕ запущен ==="
make_agent s24 'acceptance: { kind: both, check: "test -f NOPE", deterministic: true, auto_accept: true }' "$REVROLE"
start_and_settle s24
drive_claim s24
sleep 4; pass
wait_for 25 "s24: красный чек -> needs-human" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s24 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
[[ ! -d "$CLAUDE_AGENTS_DIR/s24/.reviews" || -z "$(ls -A "$CLAUDE_AGENTS_DIR/s24/.reviews" 2>/dev/null)" ]] \
  && ok "s24: приёмщик не запускался при красном чеке" || fail "s24: reviewer запущен зря"
"$RC" agent stop s24 >/dev/null; pass

echo "=== S25 (§8.7): reviewer прогон падает -> retry -> attempts>=3 needs-human ==="
export MOCK_REVIEW_MODE=fail MOCK_REVIEW_VERDICT=accept
make_agent s25 'acceptance: { kind: role-review, auto_accept: true }' "$REVROLE"
start_and_settle s25
drive_claim s25
pass; pass; pass; pass; pass  # проходы растят attempts до 3
wait_for 25 "s25: reviewer_failed -> needs-human" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s25 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
"$IO" control-read "$CLAUDE_AGENTS_DIR/s25" | grep -q "reviewer_failed после 3" \
  && ok "s25: note reviewer_failed (attempts=3)" || fail "s25: note без reviewer_failed/attempts"
# retry держит ТОТ ЖЕ job (review_started ровно один - слот не задваивается,
# новый job не заводится), attempts растут через review_retry
EV25="$CLAUDE_AGENTS_DIR/s25/events.jsonl"
[[ "$(grep -c review_started "$EV25")" -eq 1 ]] \
  && ok "s25: один review_started (retry того же job)" || fail "s25: review_started != 1"
[[ "$(grep -c review_retry "$EV25")" -eq 2 ]] \
  && ok "s25: два review_retry (attempts 2,3)" || fail "s25: review_retry != 2"
unset MOCK_REVIEW_MODE
"$RC" agent stop s25 >/dev/null; pass

echo "=== S26 (§8.8): отозванная роль -> review НЕ стартует, needs-human ==="
export MOCK_REVIEW_VERDICT=accept
make_agent s26 'acceptance: { kind: role-review, auto_accept: true }' "$REVROLE"
start_and_settle s26
# revoke ДО claim: гейт детерминированно проверяем "review не стартует"
# (revoke во время бегущего review покрыт expect'ом терминального CAS)
"$RC" agent revoke-role mockrev >/dev/null 2>&1
drive_claim s26
wait_for 20 "s26: revoke -> needs-human (не accepted)" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s26 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
[[ ! -d "$CLAUDE_AGENTS_DIR/s26/.reviews" || -z "$(ls -A "$CLAUDE_AGENTS_DIR/s26/.reviews" 2>/dev/null)" ]] \
  && ok "s26: review-result не появился" || fail "s26: review отработал при отозванной роли"
grep -q review_started "$CLAUDE_AGENTS_DIR/s26/events.jsonl" \
  && fail "s26: review_started при отозванной роли" || ok "s26: review не стартовал (нет review_started)"
"$IO" control-read "$CLAUDE_AGENTS_DIR/s26" | grep -q "reviewer role revoked" \
  && ok "s26: note revoked" || fail "s26: note без revoked"
"$RC" agent stop s26 >/dev/null 2>&1; pass

echo "=== S27 (§8.7): парсер badjson -> uncertain -> needs-human (реальный воркер) ==="
export MOCK_REVIEW_MODE=badjson
make_agent s27 'acceptance: { kind: role-review, auto_accept: true }' "$REVROLE"
start_and_settle s27
drive_claim s27
wait_for 20 "s27: невалидный JSON вывода -> needs-human" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s27 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == needs-human ]]"
unset MOCK_REVIEW_MODE
"$RC" agent stop s27 >/dev/null 2>&1; pass

echo "=== S28 (§8.7): artifact сменился при живом review_job -> stale -> re-review ==="
# симуляция: review_job стартовал (прогоны падают - result нет), затем
# сохранённый artifact подменяется (job "из-под другого claim"). stale-guard
# обязан сбросить job ДО retry и завести НОВЫЙ, а не перезапустить старый
export MOCK_REVIEW_MODE=fail MOCK_REVIEW_VERDICT=accept
make_agent s28 'acceptance: { kind: role-review, auto_accept: true }' "$REVROLE"
start_and_settle s28
drive_claim s28
wait_for 15 "s28: review_job создан" \
  bash -c "[[ -n \"\$($IO control-read $CLAUDE_AGENTS_DIR/s28 | python3 -c 'import json,sys;print((json.load(sys.stdin)[\"acceptance\"].get(\"review_job\") or {}).get(\"job_id\") or \"\")')\" ]]"
"$IO" control-cas "$CLAUDE_AGENTS_DIR/s28" \
  --set 'acceptance.review_job.artifact="0000000000000000000000000000000000000000"' \
  --event test_artifact_switch --actor test >/dev/null
unset MOCK_REVIEW_MODE   # новый job отработает штатно (accept)
wait_for 30 "s28: stale -> новый review -> accepted" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s28 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == accepted ]]"
grep -q review_stale "$CLAUDE_AGENTS_DIR/s28/events.jsonl" \
  && ok "s28: review_stale зафиксирован" || fail "s28: нет review_stale"
[[ "$(grep -c review_started "$CLAUDE_AGENTS_DIR/s28/events.jsonl")" -eq 2 ]] \
  && ok "s28: второй review стартовал заново (не retry старого)" || fail "s28: review_started != 2"
A28=$(cfield s28 'd["acceptance"]["artifact"]')
[[ -n "$A28" && "$A28" != "0000000000000000000000000000000000000000" ]] \
  && ok "s28: принят реальный artifact" || fail "s28: принят подменный artifact"

echo "=== S29 (§8.7): stale generation в review_job -> stale -> re-review ==="
export MOCK_REVIEW_MODE=fail MOCK_REVIEW_VERDICT=accept
make_agent s29 'acceptance: { kind: role-review, auto_accept: true }' "$REVROLE"
start_and_settle s29
drive_claim s29
wait_for 15 "s29: review_job создан" \
  bash -c "[[ -n \"\$($IO control-read $CLAUDE_AGENTS_DIR/s29 | python3 -c 'import json,sys;print((json.load(sys.stdin)[\"acceptance\"].get(\"review_job\") or {}).get(\"job_id\") or \"\")')\" ]]"
"$IO" control-cas "$CLAUDE_AGENTS_DIR/s29" \
  --set 'acceptance.review_job.generation=999' \
  --event test_stale_generation --actor test >/dev/null
unset MOCK_REVIEW_MODE
wait_for 30 "s29: stale generation -> новый review -> accepted" \
  bash -c "[[ \"\$($IO control-read $CLAUDE_AGENTS_DIR/s29 | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"acceptance\"][\"status\"])')\" == accepted ]]"
grep -q review_stale "$CLAUDE_AGENTS_DIR/s29/events.jsonl" \
  && ok "s29: review_stale зафиксирован" || fail "s29: нет review_stale"

unset MOCK_REVIEW_VERDICT CLAUDE_BIN
# no-clobber воркера проверяется детерминированно в test-agent-review.sh
# (уровень воркера, без гонки FSM - ревью-5 п.4)
# $()-зонд из summary мока не исполнился НИ в одном acceptor-сценарии
[[ ! -e /tmp/agent-review-pwned ]] \
  && ok "acceptor: \$()-зонд из summary нигде не исполнился" \
  || { fail "acceptor: summary исполнился шеллом (см. S20-S29)"; rm -f /tmp/agent-review-pwned; }

echo "==="
echo "fault suite: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
