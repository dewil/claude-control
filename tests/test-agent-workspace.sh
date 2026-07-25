#!/usr/bin/env bash
# Tests for V2.1 workspace/permissions (событийные агенты с рабочим пространством).
# Контракт: docs/design-2026-07-25-v2.1-workspace-permissions.md §10 (кейсы U1-U10).
# Написано с чистого листа по спеке (SDD, RED-фаза) - реализация еще не читана
# (bin/* сознательно не открывался при написании этого файла).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/../bin/claude-rc"
RUN="$HERE/../bin/claude-agent-run"
REVIEW="$HERE/../bin/claude-agent-review"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt

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
cget() { # <agent-name> <py-expr over control dict d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$CLAUDE_AGENTS_DIR/$1/control.json" "$2"
}
trust_ok() { # <config-dir>/.claude.json <realpath> -> True/False
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
p=d.get("projects",{}).get(sys.argv[2],{})
print(bool(p.get("hasTrustDialogAccepted")))' "$1" "$2"
}
argv_has() { grep -qxF -- "$1" "$2"; }   # <expected-line> <dumpfile>
slugify() { python3 -c 'import re,sys; print(re.sub(r"[^a-zA-Z0-9]","-",sys.argv[1]))' "$1"; }

mk_event() { # <name> <extra-yaml-lines> -> печатает путь к agent-dir
  local name="$1" extra="$2"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "workspace unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
$extra
EOF
  echo "$ag"
}

# --- mock claude: дампит argv (если задан ARGV_DUMP_FILE), поведение по MOCK_MODE_FILE ---
MOCK="$TMP/mock-claude"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # съесть промпт
if [[ -n "${ARGV_DUMP_FILE:-}" ]]; then printf '%s\n' "$@" > "$ARGV_DUMP_FILE"; fi
mode=$(cat "${MOCK_MODE_FILE:-/dev/null}" 2>/dev/null || echo ok)
case "$mode" in
  ok)     echo '{"type":"result","result":"обработано","total_cost_usd":0.01}' ;;
  pwd)    echo "{\"type\":\"result\",\"result\":\"$PWD\",\"total_cost_usd\":0.01}" ;;
  touch)  touch "${MOCK_TOUCH_NAME:-created.txt}"
          echo '{"type":"result","result":"created","total_cost_usd":0.01}' ;;
  review) echo '{"type":"result","result":"{\"verdict\":\"accept\",\"findings\":[],\"summary\":\"ok\"}"}' ;;
  fail)   echo boom >&2; exit 1 ;;
esac
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK" MOCK_MODE_FILE="$TMP/mock-mode"
echo ok > "$MOCK_MODE_FILE"

# =============================================================== U1
echo "=== U1: permissions -> agent-settings.json + settings-argv ==="
AG1=$(mk_event evtperm 'permissions:
  allow: ["Bash(git commit:*)"]
  deny: ["WebFetch"]
permission_mode: acceptEdits')
"$RUN" spool-put evtperm --text "u1" >/dev/null
"$RUN" intake "$AG1" >/dev/null
ARGV1="$TMP/argv1.txt"
ARGV_DUMP_FILE="$ARGV1" "$RUN" step "$AG1" >/dev/null 2>"$TMP/err1"
SLJ1="$AG1/agent-settings.json"
[[ -f "$SLJ1" ]] && ok || fail "U1: agent-settings.json создан"
[[ "$(jq_file "$SLJ1" 'd["permissions"]["allow"]' 2>/dev/null)" == "['Bash(git commit:*)']" ]] \
  && ok || fail "U1: permissions.allow из спеки"
[[ "$(jq_file "$SLJ1" 'd["permissions"]["deny"]' 2>/dev/null)" == "['WebFetch']" ]] \
  && ok || fail "U1: permissions.deny из спеки"
[[ -f "$ARGV1" ]] && ok || fail "U1: mock-claude был вызван (argv записан)"
argv_has "--settings" "$ARGV1" && ok || fail "U1: argv содержит --settings"
argv_has "$SLJ1" "$ARGV1" && ok || fail "U1: --settings указывает на agent-settings.json"
argv_has "--setting-sources" "$ARGV1" && ok || fail "U1: argv содержит --setting-sources"
argv_has "user" "$ARGV1" && ok || fail "U1: --setting-sources user"
argv_has "--permission-mode" "$ARGV1" && ok || fail "U1: argv содержит --permission-mode"
argv_has "acceptEdits" "$ARGV1" && ok || fail "U1: --permission-mode acceptEdits (из спеки)"
argv_has "--disallowedTools" "$ARGV1" && fail "U1: --disallowedTools не должен передаваться" || ok

# =============================================================== U2
echo "=== U2: без permissions -> старый blacklist argv байт-в-байт ==="
AG2=$(mk_event evtnoperm '')
"$RUN" spool-put evtnoperm --text "u2" >/dev/null
"$RUN" intake "$AG2" >/dev/null
ARGV2="$TMP/argv2.txt"
ARGV_DUMP_FILE="$ARGV2" "$RUN" step "$AG2" >/dev/null 2>"$TMP/err2"
[[ -f "$ARGV2" ]] && ok || fail "U2: mock-claude был вызван"
argv_has "--disallowedTools" "$ARGV2" && ok || fail "U2: старый blacklist-флаг присутствует"
argv_has "--settings" "$ARGV2" && fail "U2: --settings не должен появляться без permissions" || ok
argv_has "--setting-sources" "$ARGV2" && fail "U2: --setting-sources не должен появляться" || ok
argv_has "--permission-mode" "$ARGV2" && fail "U2: --permission-mode не должен появляться" || ok
[[ ! -e "$AG2/agent-settings.json" ]] && ok || fail "U2: agent-settings.json не создается без permissions"

# =============================================================== U3 (голден-регресс - ожидаемо GREEN)
echo "=== U3: argv ревьюера не изменился (голден) ==="
RD="$TMP/rvagent"; mkdir -p "$RD/.reviews" "$RD/work" "$RD/reviewer-role"
( cd "$RD/work" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > f && git add . && git commit -qm base && echo b > f && git commit -qam art )
GB3=$(git -C "$RD/work" rev-parse HEAD~1); ART3=$(git -C "$RD/work" rev-parse HEAD)
printf 'правило: суди по диффу\n' > "$RD/reviewer-role/prompt.md"
RD_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$RD/reviewer-role/prompt.md")
printf 'schema: 1\nrole: acceptor\nrole_rev: 1\nfiles:\n  - { path: prompt.md, sha256: "%s" }\n' \
  "$RD_SHA" > "$RD/reviewer-role/manifest.yaml"
ARGV3="$TMP/argv3.txt"
echo review > "$MOCK_MODE_FILE"
CLAUDE_BIN="$MOCK" ARGV_DUMP_FILE="$ARGV3" "$REVIEW" "$RD" j3 1 "$ART3" "$GB3" 30 >/dev/null 2>"$TMP/err3"
echo ok > "$MOCK_MODE_FILE"
EXPECT_DT="Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Agent,Read,Glob,Grep,NotebookRead,TodoWrite,WebImage"
[[ -f "$ARGV3" ]] && ok || fail "U3: reviewer вызвал mock-claude"
LN=$(grep -nxF -- "--disallowedTools" "$ARGV3" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "${LN:-}" ]]; then
  GOT3=$(sed -n "$((LN+1))p" "$ARGV3")
  [[ "$GOT3" == "$EXPECT_DT" ]] && ok || fail "U3: disallowedTools golden mismatch (got: $GOT3)"
else
  fail "U3: --disallowedTools отсутствует в argv ревьюера"
fi

# =============================================================== U4
echo "=== U4: cwd по workspace (none -> run/, direct -> project) ==="
AG4N=$(mk_event evtcwdnone '')
"$RUN" spool-put evtcwdnone --text "u4n" >/dev/null
"$RUN" intake "$AG4N" >/dev/null
echo pwd > "$MOCK_MODE_FILE"
"$RUN" step "$AG4N" >/dev/null 2>"$TMP/err4n"
echo ok > "$MOCK_MODE_FILE"
K4N=$(ls "$AG4N/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
EXP_RUN=$(cd "$AG4N/run" 2>/dev/null && pwd -P)
GOT4N=$(jq_file "$AG4N/inbox/done/$K4N.json" 'd["meta"]["result"]' 2>/dev/null)
[[ -n "$K4N" && -n "$EXP_RUN" && "$GOT4N" == "$EXP_RUN" ]] \
  && ok || fail "U4: workspace:none cwd = agents/<name>/run (got [$GOT4N] want [$EXP_RUN])"

PROJ4D="$TMP/proj4d"; mkdir -p "$PROJ4D"
AG4D=$(mk_event evtcwddirect "workspace: direct
project: $PROJ4D")
"$RUN" spool-put evtcwddirect --text "u4d" >/dev/null
"$RUN" intake "$AG4D" >/dev/null
echo pwd > "$MOCK_MODE_FILE"
"$RUN" step "$AG4D" >/dev/null 2>"$TMP/err4d"
echo ok > "$MOCK_MODE_FILE"
K4D=$(ls "$AG4D/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
EXP_DIR=$(cd "$PROJ4D" && pwd -P)
GOT4D=$(jq_file "$AG4D/inbox/done/$K4D.json" 'd["meta"]["result"]' 2>/dev/null)
[[ -n "$K4D" && "$GOT4D" == "$EXP_DIR" ]] \
  && ok || fail "U4: workspace:direct cwd = spec.project (got [$GOT4D] want [$EXP_DIR])"

# =============================================================== U5
echo "=== U5: create event+worktree ==="
PROJ5="$TMP/proj5"; git init -q "$PROJ5"
( cd "$PROJ5" && echo hi > f.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec5.yaml" <<EOF
schema: 1
name: wtree1
type: event
role: none
project: $PROJ5
goal: "worktree event test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
assert "U5 create event+worktree" 0 "$RC" agent create wtree1 --spec "$TMP/spec5.yaml"
[[ -d "$CLAUDE_AGENTS_DIR/wtree1/work" ]] && ok || fail "U5: work/ каталог создан"
INC5=$(cget wtree1 'd.get("incarnation","")' 2>/dev/null)
BR5="task/wtree1-${INC5:0:8}"
git -C "$PROJ5" show-ref --verify -q "refs/heads/$BR5" \
  && ok || fail "U5: ветка $BR5 не найдена (task/<name>-<inc8>)"
[[ "$(git -C "$CLAUDE_AGENTS_DIR/wtree1/work" rev-parse HEAD 2>/dev/null)" \
   == "$(git -C "$PROJ5" rev-parse HEAD)" ]] \
  && ok || fail "U5: worktree HEAD != project HEAD"
git -C "$CLAUDE_AGENTS_DIR/wtree1/work" status --short >/dev/null 2>&1 \
  && ok || fail "U5: worktree не функционален (gitdir не починен?)"
# негативный кейс: существующая одноименная ветка -> fail-closed (§2, тестовый
# шов CLAUDE_AGENT_TEST_INCARNATION подменяет случайную incarnation)
cat > "$TMP/spec5b.yaml" <<EOF
schema: 1
name: wtreecol
type: event
role: none
project: $PROJ5
goal: "worktree collision test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
git -C "$PROJ5" branch task/wtreecol-deadbeef HEAD
assert "U5 коллизия ветки -> fail-closed" 2 \
  env CLAUDE_AGENT_TEST_INCARNATION=deadbeef01 "$RC" agent create wtreecol --spec "$TMP/spec5b.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/wtreecol" ]] && ok || fail "U5 коллизия: полуагент не остался (staging откатился)"
[[ "$(git -C "$PROJ5" rev-parse task/wtreecol-deadbeef 2>/dev/null)" == "$(git -C "$PROJ5" rev-parse HEAD)" ]] \
  && ok || fail "U5 коллизия: существующая ветка не тронута"

# =============================================================== U6
echo "=== U6: валидация create (workspace/project) ==="
mkdir -p "$TMP/notgit"
cat > "$TMP/spec6a.yaml" <<EOF
schema: 1
name: wtreebad
type: event
role: none
project: $TMP/notgit
goal: g
autonomy: suggest
source: { kind: spool }
workspace: worktree
EOF
assert "U6 workspace:worktree на не-git отбит" 2 "$RC" agent create wtreebad --spec "$TMP/spec6a.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/wtreebad" ]] && ok || fail "U6: полуагент wtreebad не остался"

cat > "$TMP/spec6b.yaml" <<EOF
schema: 1
name: directbad
type: event
role: none
project: $TMP/does-not-exist-dir
goal: g
autonomy: suggest
source: { kind: spool }
workspace: direct
EOF
assert "U6 workspace:direct на несуществующую папку отбит" 2 "$RC" agent create directbad --spec "$TMP/spec6b.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/directbad" ]] && ok || fail "U6: полуагент directbad не остался"

cat > "$TMP/spec6c.yaml" <<EOF
schema: 1
name: garbagews
type: event
role: none
project: $PROJ5
goal: g
autonomy: suggest
source: { kind: spool }
workspace: bogus
EOF
assert "U6 workspace мусор отбит" 2 "$RC" agent create garbagews --spec "$TMP/spec6c.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/garbagews" ]] && ok || fail "U6: полуагент garbagews не остался"

# =============================================================== U7
echo "=== U7: direct снапшот-манифест (changes/<key>.json) ==="
PROJ7="$TMP/proj7"; mkdir -p "$PROJ7"
AG7=$(mk_event evtdirect7 "workspace: direct
project: $PROJ7")
"$RUN" spool-put evtdirect7 --text "u7-touch" >/dev/null
"$RUN" spool-put evtdirect7 --text "u7-noop" >/dev/null
"$RUN" intake "$AG7" >/dev/null
K7A=$(ls "$AG7/inbox/pending" 2>/dev/null | sort | head -1 | sed 's/.json//')
echo touch > "$MOCK_MODE_FILE"
MOCK_TOUCH_NAME="created.txt" "$RUN" step "$AG7" >/dev/null 2>"$TMP/err7a"
echo ok > "$MOCK_MODE_FILE"
CH7A="$AG7/changes/$K7A.json"
[[ -n "$K7A" && -f "$CH7A" ]] && ok || fail "U7: changes/<key>.json создан после первого прогона"
[[ "$(jq_file "$CH7A" '"created.txt" in d["added"]' 2>/dev/null)" == "True" ]] \
  && ok || fail "U7: created.txt в added"
K7B=$(ls "$AG7/inbox/pending" 2>/dev/null | sort | head -1 | sed 's/.json//')
"$RUN" step "$AG7" >/dev/null 2>"$TMP/err7b"
CH7B="$AG7/changes/$K7B.json"
[[ -n "$K7B" && -f "$CH7B" ]] && ok || fail "U7: changes/<key>.json создан после второго прогона"
[[ "$(jq_file "$CH7B" 'd["added"]==[] and d["modified"]==[] and d["deleted"]==[]' 2>/dev/null)" == "True" ]] \
  && ok || fail "U7: второй прогон без изменений -> пустой дифф"

# =============================================================== U8
echo "=== U8: trust preseed в \$CLAUDE_CONFIG_DIR/.claude.json ==="
PROJ8="$TMP/proj8"; mkdir -p "$PROJ8"
export CLAUDE_CONFIG_DIR="$TMP/cfg8"
AG8=$(mk_event evtdirect8 "workspace: direct
project: $PROJ8")
"$RUN" spool-put evtdirect8 --text "u8" >/dev/null
"$RUN" intake "$AG8" >/dev/null
"$RUN" step "$AG8" >/dev/null 2>"$TMP/err8"
REAL8=$(cd "$PROJ8" && pwd -P)
CJ8="$CLAUDE_CONFIG_DIR/.claude.json"
[[ -f "$CJ8" ]] && ok || fail "U8: .claude.json создан/дополнен"
[[ "$(trust_ok "$CJ8" "$REAL8" 2>/dev/null)" == "True" ]] \
  && ok || fail "U8: hasTrustDialogAccepted=true для realpath(cwd)"
unset CLAUDE_CONFIG_DIR

# =============================================================== U9
echo "=== U9: ретеншн транскриптов - none чистит, direct не трогает ==="
export CLAUDE_CONFIG_DIR="$TMP/cfg9"
AG9N=$(mk_event evtretnone '')
# realpath (аудит minor 7/U16): $AGENTS_DIR может лежать за симлинком - slug
# считается от РЕЗОЛВНУТОГО cwd, run/ еще не создан - readlink -f не требует
# существования цели (semantика как os.path.realpath)
SLUG9N=$(slugify "$(readlink -f "$AG9N/run")")
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG9N"
touch -t 202001010000 "$CLAUDE_CONFIG_DIR/projects/$SLUG9N/old.jsonl"
touch "$CLAUDE_CONFIG_DIR/projects/$SLUG9N/fresh.jsonl"
"$RUN" intake "$AG9N" >/dev/null
[[ ! -f "$CLAUDE_CONFIG_DIR/projects/$SLUG9N/old.jsonl" ]] \
  && ok || fail "U9 none: старый транскрипт вычищен (slug фактического cwd)"
[[ -f "$CLAUDE_CONFIG_DIR/projects/$SLUG9N/fresh.jsonl" ]] \
  && ok || fail "U9 none: свежий транскрипт остался"

PROJ9D="$TMP/proj9d"; mkdir -p "$PROJ9D"
AG9D=$(mk_event evtretdirect "workspace: direct
project: $PROJ9D")
REAL9D=$(cd "$PROJ9D" && pwd -P)
SLUG9D=$(slugify "$REAL9D")
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG9D"
touch -t 202001010000 "$CLAUDE_CONFIG_DIR/projects/$SLUG9D/old.jsonl"
touch "$CLAUDE_CONFIG_DIR/projects/$SLUG9D/fresh.jsonl"
"$RUN" intake "$AG9D" >/dev/null
[[ -f "$CLAUDE_CONFIG_DIR/projects/$SLUG9D/old.jsonl" ]] \
  && ok || fail "U9 direct: чистка транскриптов запрещена - старый должен остаться"
[[ -f "$CLAUDE_CONFIG_DIR/projects/$SLUG9D/fresh.jsonl" ]] \
  && ok || fail "U9 direct: свежий тоже на месте"
unset CLAUDE_CONFIG_DIR

# =============================================================== U10
echo "=== U10: autonomy:act допускается только с permissions ==="
PROJ10="$TMP/proj10"; git init -q "$PROJ10"
( cd "$PROJ10" && echo hi > f.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec10a.yaml" <<EOF
schema: 1
name: evtact1
type: event
role: none
project: $PROJ10
goal: g
autonomy: act
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
permissions:
  allow: ["Bash(git commit:*)"]
EOF
assert "U10 event+permissions+act проходит" 0 "$RC" agent create evtact1 --spec "$TMP/spec10a.yaml"

cat > "$TMP/spec10b.yaml" <<EOF
schema: 1
name: evtact2
type: event
role: none
goal: g
autonomy: act
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
assert "U10 event без permissions + act отбит" 2 "$RC" agent create evtact2 --spec "$TMP/spec10b.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/evtact2" ]] && ok || fail "U10: полуагент evtact2 не остался"

# =============================================================== U11 (аудит V2.1, blocker 1)
echo "=== U11: permission_mode вне белого списка ==="
cat > "$TMP/spec11.yaml" <<EOF
schema: 1
name: evtbypass
type: event
role: none
goal: g
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
permission_mode: bypassPermissions
EOF
assert "U11 permission_mode=bypassPermissions -> create exit 2" 2 "$RC" agent create evtbypass --spec "$TMP/spec11.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/evtbypass" ]] && ok || fail "U11: полуагент evtbypass не остался"

AG11=$(mk_event evtbypass2 'permissions:
  allow: ["Bash(git commit:*)"]
permission_mode: acceptEdits')
"$RUN" spool-put evtbypass2 --text "u11" >/dev/null
"$RUN" intake "$AG11" >/dev/null
sed -i 's/acceptEdits/bypassPermissions/' "$AG11/spec.yaml"   # спека отредактирована ПОСЛЕ create
ARGV11="$TMP/argv11.txt"
ARGV_DUMP_FILE="$ARGV11" "$RUN" step "$AG11" >/dev/null 2>"$TMP/err11"
argv_has "--permission-mode" "$ARGV11" && ok || fail "U11: argv содержит --permission-mode"
argv_has "default" "$ARGV11" && ok || fail "U11: runner форсит default (не bypassPermissions)"
argv_has "bypassPermissions" "$ARGV11" && fail "U11: bypassPermissions НЕ должен попасть в argv" || ok

# =============================================================== U12 (аудит V2.1, major 2)
echo "=== U12: структура permissions ==="
cat > "$TMP/spec12a.yaml" <<EOF
schema: 1
name: evtbadperm1
type: event
role: none
goal: g
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
permissions: []
EOF
assert "U12 permissions:[] -> create exit 2" 2 "$RC" agent create evtbadperm1 --spec "$TMP/spec12a.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/evtbadperm1" ]] && ok || fail "U12: полуагент evtbadperm1 не остался"

cat > "$TMP/spec12b.yaml" <<EOF
schema: 1
name: evtbadperm2
type: event
role: none
goal: g
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
permissions:
  allow: 1
EOF
assert "U12 permissions.allow не список -> create exit 2" 2 "$RC" agent create evtbadperm2 --spec "$TMP/spec12b.yaml"
[[ ! -e "$CLAUDE_AGENTS_DIR/evtbadperm2" ]] && ok || fail "U12: полуагент evtbadperm2 не остался"

AG12=$(mk_event evtbadperm3 'permissions:
  allow: ["Bash(git commit:*)"]')
"$RUN" spool-put evtbadperm3 --text "u12" >/dev/null
"$RUN" intake "$AG12" >/dev/null
python3 - "$AG12/spec.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('permissions:\n  allow: ["Bash(git commit:*)"]\n', 'permissions: []\n')
open(p, "w").write(s)
PY
ARGV12="$TMP/argv12.txt"
assert "U12 runner не падает на битой структуре permissions" 0 \
  env ARGV_DUMP_FILE="$ARGV12" "$RUN" step "$AG12"
argv_has "--disallowedTools" "$ARGV12" && ok || fail "U12: runner ушел на старый blacklist-argv"
argv_has "--settings" "$ARGV12" && fail "U12: --settings не должен появляться (структура невалидна)" || ok

# =============================================================== U13 (аудит V2.1, major 3)
echo "=== U13: FIFO/symlink исключены из манифеста; snapshot_exclude режет каталог ==="
PROJ13="$TMP/proj13"; mkdir -p "$PROJ13/excludeddir"
echo "keep out" > "$PROJ13/excludeddir/pre-existing.txt"
mkfifo "$PROJ13/afifo" 2>/dev/null || true
ln -s /nonexistent-target "$PROJ13/alink"
AG13=$(mk_event evtdirect13 "workspace: direct
project: $PROJ13
snapshot_exclude: [\"excludeddir/**\"]")
"$RUN" spool-put evtdirect13 --text "u13" >/dev/null
"$RUN" intake "$AG13" >/dev/null
K13=$(ls "$AG13/inbox/pending" 2>/dev/null | sort | head -1 | sed 's/.json//')
echo touch > "$MOCK_MODE_FILE"
MOCK_TOUCH_NAME="excludeddir/newfile.txt" timeout 20 "$RUN" step "$AG13" >/dev/null 2>"$TMP/err13"
RC13=$?
echo ok > "$MOCK_MODE_FILE"
[[ "$RC13" == 0 ]] && ok || fail "U13: step не завис и не упал на FIFO (rc=$RC13)"
CH13="$AG13/changes/$K13.json"
[[ -f "$CH13" ]] && ok || fail "U13: changes/<key>.json создан"
[[ "$(jq_file "$CH13" '"afifo" not in d.get("added",[])+d.get("modified",[])' 2>/dev/null)" == "True" ]] \
  && ok || fail "U13: FIFO не входит в манифест/дифф"
[[ "$(jq_file "$CH13" '"alink" not in d.get("added",[])+d.get("modified",[])' 2>/dev/null)" == "True" ]] \
  && ok || fail "U13: symlink не входит в манифест/дифф"
[[ "$(jq_file "$CH13" '"excludeddir/newfile.txt" not in d.get("added",[])' 2>/dev/null)" == "True" ]] \
  && ok || fail "U13: excludeddir/** режет каталог (новый файл внутри не всплыл в diff)"

# =============================================================== U14 (аудит V2.1, major 4)
echo "=== U14: недоступный файл - помечен ошибкой, не 'мигает' в диффе ==="
PROJ14="$TMP/proj14"; mkdir -p "$PROJ14"
echo "secret" > "$PROJ14/noaccess.txt"
chmod 000 "$PROJ14/noaccess.txt"
AG14=$(mk_event evtdirect14 "workspace: direct
project: $PROJ14")
"$RUN" spool-put evtdirect14 --text "u14" >/dev/null
"$RUN" intake "$AG14" >/dev/null
K14=$(ls "$AG14/inbox/pending" 2>/dev/null | sort | head -1 | sed 's/.json//')
echo ok > "$MOCK_MODE_FILE"
"$RUN" step "$AG14" >/dev/null 2>"$TMP/err14"
CH14="$AG14/changes/$K14.json"
[[ -f "$CH14" ]] && ok || fail "U14: changes/<key>.json создан"
[[ "$(jq_file "$CH14" '"noaccess.txt" not in d.get("added",[]) and "noaccess.txt" not in d.get("deleted",[])' 2>/dev/null)" == "True" ]] \
  && ok || fail "U14: недоступный файл не мигает как added/deleted (метка ошибки в манифесте стабильна)"
chmod 644 "$PROJ14/noaccess.txt"

# =============================================================== U15 (аудит V2.1, major 5/minor 6)
echo "=== U15: параллельный preseed без потери правок; битый .claude.json чинится ==="
CFG15="$TMP/cfg15"; mkdir -p "$CFG15"
for i in $(seq 1 8); do
  python3 "$HERE/../bin/_agent_trust_preseed.py" "$CFG15/.claude.json" "/tmp/proj-$i" &
done
wait
python3 -c '
import json
d = json.load(open("'"$CFG15"'/.claude.json"))
print(all(d.get("projects", {}).get("/tmp/proj-%d" % i, {}).get("hasTrustDialogAccepted")
          for i in range(1, 9)))' > "$TMP/u15check.txt"
[[ "$(cat "$TMP/u15check.txt")" == "True" ]] \
  && ok || fail "U15: все 8 ключей проекта на месте после параллельных preseed"

CFG15B="$TMP/cfg15b"; mkdir -p "$CFG15B"
echo "{not valid json" > "$CFG15B/.claude.json"
python3 "$HERE/../bin/_agent_trust_preseed.py" "$CFG15B/.claude.json" "/tmp/projX"
[[ "$(trust_ok "$CFG15B/.claude.json" "/tmp/projX" 2>/dev/null)" == "True" ]] \
  && ok || fail "U15: битый .claude.json переписан минимальным валидным с trust"

# =============================================================== U16 (аудит V2.1, minor 7)
echo "=== U16: ретеншн по realpath(cwd) при симлинкованном AGENTS_DIR ==="
REAL_BASE="$TMP/real-agents-base"; mkdir -p "$REAL_BASE"
LINK_AGENTS="$TMP/agents-symlink"; ln -s "$REAL_BASE" "$LINK_AGENTS"
export CLAUDE_AGENTS_DIR="$LINK_AGENTS"
export CLAUDE_CONFIG_DIR="$TMP/cfg16"
AG16=$(mk_event evtsymlink '')
SLUG16=$(slugify "$(readlink -f "$AG16/run")")
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$SLUG16"
touch -t 202001010000 "$CLAUDE_CONFIG_DIR/projects/$SLUG16/old.jsonl"
"$RUN" intake "$AG16" >/dev/null
[[ ! -f "$CLAUDE_CONFIG_DIR/projects/$SLUG16/old.jsonl" ]] \
  && ok || fail "U16: ретеншн сработал по realpath (не по симлинк-пути AGENTS_DIR)"
unset CLAUDE_CONFIG_DIR
export CLAUDE_AGENTS_DIR="$TMP/agents"

echo
echo "test-agent-workspace: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
