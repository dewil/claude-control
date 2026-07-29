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

# --- fixtures V2.10 (T2/T3/T4: docs/design-2026-07-28-v2.10-task-actually-works.md) ---
mask_prompt_v210() { # <file> <key-hex> -> вычищает волатильные envelope_key/таймстемпы/native_id
  # (тот же прием, что mask_prompt в tests/test-agent-question.sh Q13, публичный
  # факт из НЕЕ ЖЕ: имя агента в промпте не рендерится - разные agent-dir
  # сравнимы байт-в-байт после этой маскировки без отдельной подмены имени).
  local f="$1" key="$2"
  sed -E \
    -e "s/${key}/<KEY>/g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' \
    -e 's/("native_id"[:=] ?"?)[0-9]+("?)/\1<N>\2/g' \
    "$f"
}
ask_direct_v210() { # <agent-dir> <stub-key> <question-text> -> stdout=qid (Q13-style: временный
  # stub-конверт в inflight, снимается сразу после ask - claude-agent-ask
  # требует envelope_key реально в inflight, V2.3 §2/аудит major 6)
  local dir="$1" key="$2" q="$3"
  local stubbed=0
  if [[ ! -f "$dir/inbox/inflight/$key.json" ]]; then
    mkdir -p "$dir/inbox/inflight"
    printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"text":"stub-for-ask"}}\n' \
      "$key" > "$dir/inbox/inflight/$key.json"
    stubbed=1
  fi
  CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" "$HERE/../bin/claude-agent-ask" --question "$q"
  local rc=$?
  [[ "$stubbed" == 1 ]] && rm -f "$dir/inbox/inflight/$key.json"
  return $rc
}
close_question_v210() { # <question-json-file> - закрывает открытый вопрос (без этого - см. ambiguity-
  # заметка перед U21/U22 - открытый вопрос заморозил бы pick_ready и мешал
  # бы прогнать сам кейс, не давая проверить именно гейт "каталог questions/")
  python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["status"] = "closed"; d["answer"] = "irrelevant"; d["answered_at"] = "2026-01-01T00:00:00Z"
json.dump(d, open(p, "w"))
' "$1"
}
perm_allow_has_v210() { # <agent-settings.json> <exact-value> -> True/False (без интерполяции в
  # python-eval-строку - значения из T4 несут "/", "*", "(", ")", небезопасно
  # склеивать в текст выражения)
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sys.argv[2] in d.get("permissions", {}).get("allow", []))
' "$1" "$2"
}

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
if [[ -n "${PROMPT_DUMP_FILE:-}" ]]; then cat > "$PROMPT_DUMP_FILE"; else cat > /dev/null; fi
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
# членство, не строгое равенство (контрольный аудит блокер 2): эшелон
# защиты доверенных каналов (questions/, reject_comments/, lessons.json,
# done.json) теперь ВСЕГДА примешивается в deny сгенерированного пояса -
# спековый deny остается в списке, но список больше не равен ему буквально.
[[ "$(jq_file "$SLJ1" '"WebFetch" in d["permissions"]["deny"]' 2>/dev/null)" == "True" ]] \
  && ok || fail "U1: permissions.deny из спеки (WebFetch) присутствует"
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

####################################################################
# V2.10 (T1-T4): docs/design-2026-07-28-v2.10-task-actually-works.md
# Написано с чистого листа по спеке (SDD, RED-фаза) - bin/claude-agent-run,
# bin/claude-agent-done, bin/claude-agent-ask, bin/claude-agent-reconciler,
# bin/_rc_projects.sh НЕ читаны. Публичный контракт - из самой спеки V2.10 и
# из уже установленного контракта соседних этапов (U1-U16 выше, tests/
# test-agent-question.sh Q13 - прием mask_prompt/golden, tests/
# test-agent-thread.sh T2 - факт, что текст payload.text текущего события
# рендерится в промпте буквально, что дает наблюдаемый маркер позиции
# "блока события" для T3-п.6 без знания внутренних заголовков секций).
#
# Ambiguity-заметки (реализация НЕ читана, решения приняты по тексту самой
# спеки). Ревизия 4: координатор четырежды правил контракт по итогам прошлых
# проходов (§1.1/§2.1/§2.2/§5 T4, затем §2.2/T3 дважды подряд) - ниже
# сведено, что закрыто. Открытых пунктов не осталось - каждое замечание
# этой суиты подтвердилось живой проверкой и было закрыто правкой контракта,
# а не тестом под текущее поведение.
# 1. ЗАКРЫТО координатором: §2.1/§2.2 несут ТОЧНЫЙ текст рамок тремя блоками
#    (worktree/direct/ask) - см. FRAME_*_TEXT_V210 ниже, пинятся как
#    голден-подстроки (grep -qF), не пересказ.
# 2. ЗАКРЫТО координатором, дважды (ревизия 3 -> ревизия 4). Гейт §2.2 прошел
#    через ДВА отвергнутых варианта, каждый проверкой, не рассуждением:
#    - "наличие каталога questions/" (ревизии 1/2) - замкнут сам на себя:
#      свежесозданный event-агент каталога не несет вовсе, заводится лениво
#      первым же вопросом; в проде маскировала гонка с question-reminders
#      реконсилера;
#    - "§2.0 И type == event" (ревизия 3, было мое замечание 2 первого
#      прохода - оказалось глубже, чем казалось обеим сторонам) - отвергнут
#      сам координатор: нечем проверить (mission-агенты до build_prompt не
#      доходят вовсе, идут через tmux/pty, не через CLAUDE_BIN - см. заметку
#      4 предыдущей ревизии, теперь снятую) и субтильно неверен (type в
#      спеке по умолчанию mission, событийный агент со spool-источником, но
#      без явного type, лишился бы рамки ни за что).
#    Итоговый гейт (ревизия 4): рамка вопроса присутствует у ЛЮБОГО агента,
#    прошедшего ОБЩИЙ гейт §2.0 (валидный `permissions`) - и только его,
#    независимо от workspace и каталога questions/. Отдельного признака
#    "событийный путь" не нужно: `build_prompt` вызывается ровно из одного
#    места (`run_event`). U21a/U21b проверяют решающую пару по каталогу
#    (событие БЕЗ каталога / С каталогом закрытого вопроса - тот же прием,
#    что и раньше, открытый вопрос заморозил бы pick_ready - дают
#    ОДИНАКОВЫЙ результат), U20 проверяет ту же независимость по workspace
#    (ws=none тоже получает рамку, промпт перестал быть байт-в-байт голденом).
# 3. ЗАКРЫТО координатором: T4 был помечен как "проверить нельзя, мок без
#    песочницы" - и это привело к ложному пину "пояс не путевой". Живой
#    прогон (со стороны координатора) показал обратное: голый Write реально
#    пишет ВНЕ cwd, и рантайм чинит это перепиской пояса в agent-settings.json
#    (Write -> Write(//<cwd>/**), ровно два слэша). U23/U24 проверяют это
#    структурно (по сгенерированному settings-файлу), без утверждений о
#    реальной песочнице claude.
# 4. ЗАКРЫТО координатором (ревизия 4): "type: mission -> нет упоминания" из
#    T3 снят вместе с отказом от гейта type==event - вопрос стал неприменим
#    (mission-агенты структурно не проходят через build_prompt/run_event, а
#    не "трудно проверить"), U21c удален без замены.
#
# Изоляция $CLAUDE_CONFIG_DIR на весь блок ниже: intake/step трогают
# $CLAUDE_CONFIG_DIR/projects/<slug> (ретеншн транскриптов, V2.1 §4/U9,
# НЕЗАВИСИМО от workspace) и trust preseed для workspace!=none (U8/U16) -
# без явного override оба ушли бы в боевой ~/.claude (на этой машине
# CLAUDE_CONFIG_DIR уже выставлен в окружении на реальный ~/.claude, см.
# аналогичный комментарий в tests/test-agent-task-lifecycle.sh:58-70).
export CLAUDE_CONFIG_DIR="$TMP/cfg-v210"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Голден-тексты рамки протокола - §2.1/§2.2 контракта дословно. Текст
# worktree переписан еще раз третьим кругом аудита (V2.10 §3d.1,
# 2026-07-29): у агента нет git вообще (обертка claude-agent-commit
# упразднена целиком - хуки/фильтры/fsmonitor глушить по одному оказалось
# гонкой, которую нельзя выиграть). Коммитит рантайм; агент только
# объявляет заявку - ОДИН раз, пока дерево еще чисто (у него нет способа
# закоммитить, поэтому call_done() позже на грязном дереве отобьет).
FRAME_WORKTREE_TEXT_V210='Протокол контура. У тебя нет git - эту команду можно позвать только ОДИН раз и СРАЗУ, пока рабочее дерево еще чистое: claude-agent-done --summary "<что собираешься сделать, одной фразой>". Дальше просто работай - рантайм закоммитит твои изменения сам, когда прогон завершится. Без этого вызова работу не увидит никто - карточка приемки строится только из твоей заявки.'
FRAME_DIRECT_TEXT_V210='Протокол контура. Когда работа готова к показу человеку - объяви об этом сам: claude-agent-done --summary "<что сделано, одной фразой>". Предъявляется список измененных файлов, контур считает его сам. Без этого вызова работу не увидит никто - карточка приемки строится только из твоей заявки.'
FRAME_ASK_TEXT_V210='Нужно решение человека - спроси, а не гадай и не отчитывайся "сделайте руками": claude-agent-ask --question "<вопрос>" (можно добавить --options "а|б|в" и --context "..."). Прогон на этом закончится, вопрос уйдет человеку карточкой, его ответ придет тебе следующим событием.'

# =============================================================== U17 (V2.10 T2)
echo "=== U17: штатный шаблон examples/task-template.yaml.example доезжает поясом до раннера (не legacy-blacklist) ==="
CLAUDE_RC_PROJECTS_FILE_U17="$TMP/projects-u17.yaml"
PROJ_U17="$TMP/proj-u17"; mkdir -p "$PROJ_U17"
git -C "$PROJ_U17" init -q
( cd "$PROJ_U17" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
printf 'demoprojtpl: %s\n' "$PROJ_U17" > "$CLAUDE_RC_PROJECTS_FILE_U17"
OUT_U17=$(CLAUDE_RC_PROJECTS_FILE="$CLAUDE_RC_PROJECTS_FILE_U17" \
  CLAUDE_RC_TASK_TEMPLATE="$HERE/../examples/task-template.yaml.example" \
  "$RC" agent new-task --name evtu17tpl --project demoprojtpl --text "u17 template smoke" \
  2>"$TMP/u17.err"); RC_U17=$?
[[ "$RC_U17" == 0 ]] && ok || fail "U17: new-task со штатным шаблоном проходит (got $RC_U17: $(cat "$TMP/u17.err"))"
AG_U17="$CLAUDE_AGENTS_DIR/evtu17tpl"
[[ -f "$AG_U17/spec.yaml" ]] && ok || fail "U17: агент реально создан из штатного шаблона"
"$RUN" intake "$AG_U17" >/dev/null
ARGV_U17="$TMP/argv-u17.txt"
ARGV_DUMP_FILE="$ARGV_U17" "$RUN" step "$AG_U17" >/dev/null 2>"$TMP/u17-step.err"
[[ -f "$ARGV_U17" ]] && ok || fail "U17: mock-claude вызван"
argv_has "--settings" "$ARGV_U17" && ok || fail "U17: --settings присутствует (пояс доехал)"
argv_has "--disallowedTools" "$ARGV_U17" \
  && fail "U17: legacy-blacklist НЕ должен использоваться штатным шаблоном" || ok
SLJ_U17="$AG_U17/agent-settings.json"
[[ -f "$SLJ_U17" ]] && ok || fail "U17: agent-settings.json создан"
# Write/Edit пинятся в ПУТЕВОЙ форме (§1.1/T4): рантайм переписывает голые
# Write/Edit в Write(//<cwd>/**) при генерации agent-settings.json, поэтому
# байт-в-байт "Write"/"Edit" в этом файле больше НЕ бывает - обнаружено
# после того, как приземлившийся T4 поймал прежнюю (дословную из T1)
# версию этой проверки как ложно-красную.
CWD_U17=$(cd "$AG_U17/work" && pwd -P)
for perm in "Write(//$CWD_U17/**)" "Edit(//$CWD_U17/**)" "Bash(claude-agent-done:*)" "Bash(claude-agent-ask:*)"; do
  [[ "$(perm_allow_has_v210 "$SLJ_U17" "$perm")" == "True" ]] \
    && ok || fail "U17: permissions.allow содержит $perm"
done
[[ "$(jq_file "$SLJ_U17" 'len(d["permissions"]["deny"]) > 0' 2>/dev/null)" == "True" ]] \
  && ok || fail "U17: permissions.deny непуст (примешан эшелон доверенных каналов, хотя спека несет deny:[])"

# =============================================================== U18 (V2.10 T3, ws=worktree)
echo "=== U18: ws=worktree + валидный пояс - рамка зовет claude-agent-done, с последствием невызова, ВЫШЕ блока события ==="
PROJ_U18="$TMP/proj-u18"; mkdir -p "$PROJ_U18"
git -C "$PROJ_U18" init -q
( cd "$PROJ_U18" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec-u18.yaml" <<EOF
schema: 1
name: evtu18done
type: event
role: none
project: $PROJ_U18
goal: "u18 protocol frame worktree"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
# §3d.1: у агента нет git вообще (обертка claude-agent-commit упразднена) -
# рамка worktree зовет ОДНУ команду, claude-agent-done, - только она и
# обязана быть объявлена поясом, иначе рамки нет вовсе (см. U25).
permissions:
  allow: ["Write", "Edit", "Bash(claude-agent-done:*)"]
EOF
assert "U18 create" 0 "$RC" agent create evtu18done --spec "$TMP/spec-u18.yaml"
AG_U18="$CLAUDE_AGENTS_DIR/evtu18done"
"$RUN" spool-put evtu18done --text "u18-event-marker" >/dev/null
"$RUN" intake "$AG_U18" >/dev/null
PROMPT_U18="$TMP/prompt-u18.txt"
PROMPT_DUMP_FILE="$PROMPT_U18" "$RUN" step "$AG_U18" >/dev/null 2>"$TMP/u18-step.err"
[[ -s "$PROMPT_U18" ]] && ok || fail "U18: промпт сдампен"
grep -qF "$FRAME_WORKTREE_TEXT_V210" "$PROMPT_U18" \
  && ok || fail "U18: рамка протокола worktree - точный текст §2.1 (голден)"
IDX_FRAME_U18=$(python3 -c "print(open('$PROMPT_U18').read().find('claude-agent-done --summary'))")
IDX_EVENT_U18=$(python3 -c "print(open('$PROMPT_U18').read().find('u18-event-marker'))")
[[ "$IDX_FRAME_U18" != "-1" && "$IDX_EVENT_U18" != "-1" && "$IDX_FRAME_U18" -lt "$IDX_EVENT_U18" ]] \
  && ok || fail "U18: рамка протокола идет ВЫШЕ блока события (frame@$IDX_FRAME_U18 event@$IDX_EVENT_U18)"

# =============================================================== U19 (V2.10 T3, ws=direct)
echo "=== U19: ws=direct + валидный пояс - та же команда claude-agent-done, БЕЗ требования коммита ==="
PROJ_U19="$TMP/proj-u19"; mkdir -p "$PROJ_U19"
AG_U19=$(mk_event evtu19done 'workspace: direct
project: '"$PROJ_U19"'
permissions:
  allow: ["Write", "Edit", "Bash(claude-agent-done:*)"]')
"$RUN" spool-put evtu19done --text "u19-event" >/dev/null
"$RUN" intake "$AG_U19" >/dev/null
PROMPT_U19="$TMP/prompt-u19.txt"
PROMPT_DUMP_FILE="$PROMPT_U19" "$RUN" step "$AG_U19" >/dev/null 2>"$TMP/u19-step.err"
[[ -s "$PROMPT_U19" ]] && ok || fail "U19: промпт сдампен"
grep -qF "$FRAME_DIRECT_TEXT_V210" "$PROMPT_U19" \
  && ok || fail "U19: рамка протокола direct - точный текст §2.1 (голден)"
grep -qF "Зови ПОСЛЕ коммита" "$PROMPT_U19" \
  && fail "U19: workspace:direct НЕ требует коммита - формулировка worktree не должна утечь сюда" || ok

# =============================================================== U20 (V2.10 T3, ревизия 4: §2.2 не завязан на workspace)
# Старая версия этого кейса пиновала "валидный permissions при ws=none БЕЗ
# questions/ не меняет промпт байт-в-байт" - это было верно, пока рамка
# вопроса требовала каталог (ревизия 2) или type:event (ревизия 3, тоже
# отвергнута). Текущий контракт (§2.2/T3): рамка вопроса присутствует у
# ЛЮБОГО агента, прошедшего общий гейт §2.0, НЕЗАВИСИМО от workspace и
# каталога - значит для ws=none с валидным permissions рамка теперь ОБЯЗАНА
# появиться, и старый голден-инвариант стал ложным. Кейс переписан на
# обратное утверждение: без permissions рамки нет (gate §2.0), с permissions
# рамка есть и промпт отличается от baseline (иначе рамка не появилась вовсе).
# Правка ревизии 5 (§2.0 п.2, сужение по P10): валидного permissions
# недостаточно самого по себе - пояс обязан ОБЪЯВЛЯТЬ команду
# (Bash(claude-agent-ask... или голый Bash). "permissions с одним Read" из
# предыдущих ревизий этого кейса под новым правилом больше не триггерит
# рамку - allow ниже дописан объявлением claude-agent-ask, чтобы кейс
# по-прежнему проверял то, что заявлен: "workspace не влияет", а не
# случайно упал на другом, более узком условии.
echo "=== U20: ws=none без questions/ - валидный permissions С объявлением claude-agent-ask ДОБАВЛЯЕТ рамку вопроса (не байт-в-байт: §2.2 не завязан на workspace) ==="
AG_U20BASE=$(mk_event evtu20base '')
"$RUN" spool-put evtu20base --text "u20-shared-marker" >/dev/null
"$RUN" intake "$AG_U20BASE" >/dev/null
PROMPT_U20BASE="$TMP/prompt-u20base.txt"
MOCK_RESULT_TEXT="u20-golden-result" PROMPT_DUMP_FILE="$PROMPT_U20BASE" "$RUN" step "$AG_U20BASE" >/dev/null 2>"$TMP/u20base.err"
[[ -s "$PROMPT_U20BASE" ]] && ok || fail "U20: baseline-промпт (без permissions) сдампен"
KU20BASE=$(ls "$AG_U20BASE/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
GOLDEN_U20=$(mask_prompt_v210 "$PROMPT_U20BASE" "$KU20BASE")
grep -qF "$FRAME_ASK_TEXT_V210" "$PROMPT_U20BASE" \
  && fail "U20: baseline БЕЗ permissions не должен нести рамку вопроса (gate §2.0 не пройден)" || ok

AG_U20PERM=$(mk_event evtu20perm 'permissions:
  allow: ["Read", "Bash(claude-agent-ask:*)"]')
"$RUN" spool-put evtu20perm --text "u20-shared-marker" >/dev/null
"$RUN" intake "$AG_U20PERM" >/dev/null
PROMPT_U20PERM="$TMP/prompt-u20perm.txt"
MOCK_RESULT_TEXT="u20-golden-result" PROMPT_DUMP_FILE="$PROMPT_U20PERM" "$RUN" step "$AG_U20PERM" >/dev/null 2>"$TMP/u20perm.err"
[[ -s "$PROMPT_U20PERM" ]] && ok || fail "U20: промпт с валидным permissions (ws=none, без questions/) сдампен"
KU20PERM=$(ls "$AG_U20PERM/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
MASKED_U20PERM=$(mask_prompt_v210 "$PROMPT_U20PERM" "$KU20PERM")
grep -qF "$FRAME_ASK_TEXT_V210" "$PROMPT_U20PERM" \
  && ok || fail "U20: валидный permissions при ws=none без questions/ добавляет рамку вопроса (§2.2 не завязан на workspace)"
[[ "$MASKED_U20PERM" != "$GOLDEN_U20" ]] \
  && ok || fail "U20: промпт с рамкой обязан отличаться от baseline (иначе рамка не появилась вовсе)"

# =============================================================== U21 (V2.10 T3, ревизия 4: §2.2 = только общий гейт §2.0, ни type, ни каталог роли не играют)
# Полная история отвергнутых гейтов (для честности - оба были рассмотрены и
# отвергнуты координатором проверкой, не рассуждением):
# - каталог questions/ (ревизия 1/2): замкнут сам на себя - свежесозданный
#   event-агент каталога не несет вовсе, заводится лениво первым вопросом;
# - type == event (ревизия 3): нечем проверить (mission-агенты до
#   build_prompt не доходят, идут через tmux/pty, не через CLAUDE_BIN) и
#   субтильно неверен (type по умолчанию mission, agent со spool-источником
#   без явного type лишился бы рамки ни за что).
# Итог (ревизия 4): рамка вопроса присутствует у ЛЮБОГО агента, прошедшего
# общий гейт §2.0 (валидный permissions) - и только его. Отдельного признака
# "событийный путь" не нужно: build_prompt вызывается ровно из одного места
# (run_event), само попадание туда и есть событийный путь. U21a/U21b
# проверяют РЕШАЮЩУЮ пару по каталогу (обязаны дать ОДИНАКОВЫЙ результат),
# U20 выше проверяет то же по workspace (ws=none тоже получает рамку).
# Ревизия 5: allow дописан объявлением claude-agent-ask - без него (просто
# "Read") пояс не объявляет команду, и по новому §2.0 п.2 рамки не будет
# вовсе (см. U26), что смешало бы этот кейс с другим условием.
echo "=== U21a: type=event БЕЗ каталога questions/ - рамка ask есть (решающий кейс: старый гейт по каталогу отвергнут) ==="
AG_U21A=$(mk_event evtu21a 'permissions:
  allow: ["Read", "Bash(claude-agent-ask:*)"]')
"$RUN" spool-put evtu21a --text "u21a-event" >/dev/null
"$RUN" intake "$AG_U21A" >/dev/null
[[ ! -d "$AG_U21A/questions" ]] && ok || fail "U21a: fixture - questions/ реально отсутствует у свежего event-агента"
PROMPT_U21A="$TMP/prompt-u21a.txt"
PROMPT_DUMP_FILE="$PROMPT_U21A" "$RUN" step "$AG_U21A" >/dev/null 2>"$TMP/u21a.err"
[[ -s "$PROMPT_U21A" ]] && ok || fail "U21a: промпт сдампен"
grep -qF "$FRAME_ASK_TEXT_V210" "$PROMPT_U21A" \
  && ok || fail "U21a: рамка ask - точный текст §2.2 (голден) присутствует БЕЗ каталога questions/"

echo "=== U21b: type=event С каталогом questions/ (закрытый вопрос) - рамка ask ТА ЖЕ, каталог не влияет ==="
AG_U21B=$(mk_event evtu21b 'permissions:
  allow: ["Read", "Bash(claude-agent-ask:*)"]')
"$RUN" spool-put evtu21b --text "u21b-event" >/dev/null
"$RUN" intake "$AG_U21B" >/dev/null
QID_U21B=$(ask_direct_v210 "$AG_U21B" "u21b-stub-key" "u21b stub question")
close_question_v210 "$AG_U21B/questions/$QID_U21B.json"
[[ -d "$AG_U21B/questions" ]] && ok || fail "U21b: fixture - questions/ реально существует у второго агента"
PROMPT_U21B="$TMP/prompt-u21b.txt"
PROMPT_DUMP_FILE="$PROMPT_U21B" "$RUN" step "$AG_U21B" >/dev/null 2>"$TMP/u21b.err"
[[ -s "$PROMPT_U21B" ]] && ok || fail "U21b: промпт сдампен"
grep -qF "$FRAME_ASK_TEXT_V210" "$PROMPT_U21B" \
  && ok || fail "U21b: рамка ask - точный текст §2.2 (голден) присутствует С каталогом questions/ (тот же результат, что U21a)"

# U21c (type=mission untestable-gap) удален по ревизии 4: гейт §2.2 больше
# не зависит от type вовсе (только общий гейт §2.0), поэтому отдельного
# mission-кейса не требуется - структурная причина ("build_prompt вызывается
# ровно из run_event") делает вопрос неприменимым, а не непроверенным.

# =============================================================== U22 (V2.10 T3, гейт §2.0)
echo "=== U22: БЕЗ блока permissions - ws=worktree И questions/ вместе НЕ включают рамку (живые агенты контура) ==="
PROJ_U22="$TMP/proj-u22"; mkdir -p "$PROJ_U22"
git -C "$PROJ_U22" init -q
( cd "$PROJ_U22" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec-u22.yaml" <<EOF
schema: 1
name: evtu22noperm
type: event
role: none
project: $PROJ_U22
goal: "u22 gate 2.0 no permissions"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
assert "U22 create (без permissions)" 0 "$RC" agent create evtu22noperm --spec "$TMP/spec-u22.yaml"
AG_U22="$CLAUDE_AGENTS_DIR/evtu22noperm"
"$RUN" spool-put evtu22noperm --text "u22-event" >/dev/null
"$RUN" intake "$AG_U22" >/dev/null
QID_U22=$(ask_direct_v210 "$AG_U22" "u22-stub-key" "u22 stub question")
close_question_v210 "$AG_U22/questions/$QID_U22.json"
[[ -d "$AG_U22/questions" ]] && ok || fail "U22: fixture - questions/ реально существует"
PROMPT_U22="$TMP/prompt-u22.txt"
PROMPT_DUMP_FILE="$PROMPT_U22" "$RUN" step "$AG_U22" >/dev/null 2>"$TMP/u22-step.err"
[[ -s "$PROMPT_U22" ]] && ok || fail "U22: промпт сдампен"
[[ ! -f "$AG_U22/agent-settings.json" ]] \
  && ok || fail "U22: fixture - агент реально без пояса (agent-settings.json не создан, legacy-blacklist)"
grep -qF "claude-agent-done" "$PROMPT_U22" \
  && fail "U22: без permissions рамка НЕ должна упоминать claude-agent-done, даже при ws=worktree" || ok
grep -qF "claude-agent-ask" "$PROMPT_U22" \
  && fail "U22: без permissions рамка НЕ должна упоминать claude-agent-ask, даже при questions/" || ok

unset CLAUDE_CONFIG_DIR

# =============================================================== U23 (V2.10 T4/§1.1, переписан после ревизии 2)
echo "=== U23: голый Write/Edit переписывается в путевой Write(//<cwd>/**) - ДВА слэша, cwd реальный, path-scoped запись не трогается (workspace: worktree) ==="
PROJ_U23="$TMP/proj-u23"; mkdir -p "$PROJ_U23"
git -C "$PROJ_U23" init -q
( cd "$PROJ_U23" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
PRESCOPED_U23="Write(//$TMP/pre-scoped-u23/**)"
cat > "$TMP/spec-u23.yaml" <<EOF
schema: 1
name: evtu23wr
type: event
role: none
project: $PROJ_U23
goal: "u23 write isolation rewrite"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
permissions:
  allow: ["Read","Write","Edit","$PRESCOPED_U23","Bash(claude-agent-done:*)"]
  deny: []
  ask: []
EOF
export CLAUDE_CONFIG_DIR="$TMP/cfg-v210b"; mkdir -p "$CLAUDE_CONFIG_DIR"
assert "U23 create" 0 "$RC" agent create evtu23wr --spec "$TMP/spec-u23.yaml"
AG_U23="$CLAUDE_AGENTS_DIR/evtu23wr"
"$RUN" spool-put evtu23wr --text "u23-event" >/dev/null
"$RUN" intake "$AG_U23" >/dev/null
"$RUN" step "$AG_U23" >/dev/null 2>"$TMP/u23-step.err"
SLJ_U23="$AG_U23/agent-settings.json"
[[ -f "$SLJ_U23" ]] && ok || fail "U23: agent-settings.json создан"
CWD_U23=$(cd "$AG_U23/work" && pwd -P)
EXP_WRITE_U23="Write(//$CWD_U23/**)"
EXP_EDIT_U23="Edit(//$CWD_U23/**)"
SINGLE_SLASH_WRITE_U23="Write(/$CWD_U23/**)"
[[ "$(perm_allow_has_v210 "$SLJ_U23" "$EXP_WRITE_U23")" == "True" ]] \
  && ok || fail "U23: голый Write переписан в путевой $EXP_WRITE_U23 (ровно два слэша)"
[[ "$(perm_allow_has_v210 "$SLJ_U23" "$EXP_EDIT_U23")" == "True" ]] \
  && ok || fail "U23: голый Edit переписан в путевой $EXP_EDIT_U23 (ровно два слэша)"
[[ "$(perm_allow_has_v210 "$SLJ_U23" "Write")" == "False" ]] \
  && ok || fail "U23: голая запись Write НЕ должна остаться в allow"
[[ "$(perm_allow_has_v210 "$SLJ_U23" "Edit")" == "False" ]] \
  && ok || fail "U23: голая запись Edit НЕ должна остаться в allow"
[[ "$(perm_allow_has_v210 "$SLJ_U23" "$SINGLE_SLASH_WRITE_U23")" == "False" ]] \
  && ok || fail "U23: однослэшевая форма НЕ должна встретиться вместо двухслэшевой (не матчится как абсолютный путь, §1.1)"
[[ "$(perm_allow_has_v210 "$SLJ_U23" "$PRESCOPED_U23")" == "True" ]] \
  && ok || fail "U23: уже путевая запись из спеки остается нетронутой рантаймом"

# =============================================================== U24 (V2.10 T4/§1.1, workspace: none)
echo "=== U24: то же путевое переписывание Write/Edit действует при workspace: none (cwd = agents/<name>/run) ==="
AG_U24=$(mk_event evtu24none 'permissions:
  allow: ["Write"]
  deny: []
  ask: []')
"$RUN" spool-put evtu24none --text "u24-event" >/dev/null
"$RUN" intake "$AG_U24" >/dev/null
"$RUN" step "$AG_U24" >/dev/null 2>"$TMP/u24-step.err"
SLJ_U24="$AG_U24/agent-settings.json"
[[ -f "$SLJ_U24" ]] && ok || fail "U24: agent-settings.json создан (workspace:none)"
CWD_U24=$(cd "$AG_U24/run" && pwd -P)
EXP_WRITE_U24="Write(//$CWD_U24/**)"
[[ "$(perm_allow_has_v210 "$SLJ_U24" "$EXP_WRITE_U24")" == "True" ]] \
  && ok || fail "U24: голый Write переписан в путевой $EXP_WRITE_U24 даже при workspace:none"
[[ "$(perm_allow_has_v210 "$SLJ_U24" "Write")" == "False" ]] \
  && ok || fail "U24: голая запись Write не должна остаться (workspace:none)"

####################################################################
# V2.10 (ревизия 5, последнее сужение §2.0): рамка про КОНКРЕТНУЮ команду
# контура появляется только если пояс эту команду реально ОБЪЯВЛЯЕТ -
# запись в permissions.allow либо в точности "Bash", либо начинается с
# "Bash(claude-agent-done" / "Bash(claude-agent-ask" для соответствующей
# рамки. Повод: существующий голден V2.4 P10 (tests/test-agent-permit.sh,
# пояс ["Bash(git commit:*)"]) покраснел на прежней (более широкой) версии
# правила "валидный permissions -> обе рамки" - он не дает ни одной команды
# контура, но получал рамку вопроса ни за что. P10 НЕ трогается в этой
# суите (координатор ведет его отдельно как регресс-пин прицельности) -
# кейсы ниже добавлены именно затем, чтобы прицельность была видна и здесь,
# не только в P10.
export CLAUDE_CONFIG_DIR="$TMP/cfg-v210c"; mkdir -p "$CLAUDE_CONFIG_DIR"

# =============================================================== U25 (V2.10 T3, ревизия 5)
echo "=== U25: валидный permissions, workspace:worktree, НЕТ claude-agent-done И НЕТ голого Bash - рамки готовности НЕТ, промпт байт-в-байт с baseline ==="
PROJ_U25="$TMP/proj-u25"; mkdir -p "$PROJ_U25"
git -C "$PROJ_U25" init -q
( cd "$PROJ_U25" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec-u25base.yaml" <<EOF
schema: 1
name: evtu25base
type: event
role: none
project: $PROJ_U25
goal: "u25 shared goal"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
assert "U25 create baseline (без permissions)" 0 "$RC" agent create evtu25base --spec "$TMP/spec-u25base.yaml"
AG_U25BASE="$CLAUDE_AGENTS_DIR/evtu25base"
"$RUN" spool-put evtu25base --text "u25-shared-marker" >/dev/null
"$RUN" intake "$AG_U25BASE" >/dev/null
PROMPT_U25BASE="$TMP/prompt-u25base.txt"
MOCK_RESULT_TEXT="u25-golden-result" PROMPT_DUMP_FILE="$PROMPT_U25BASE" "$RUN" step "$AG_U25BASE" >/dev/null 2>"$TMP/u25base.err"
[[ -s "$PROMPT_U25BASE" ]] && ok || fail "U25: baseline промпт (без permissions) сдампен"
KU25BASE=$(ls "$AG_U25BASE/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
GOLDEN_U25=$(mask_prompt_v210 "$PROMPT_U25BASE" "$KU25BASE")

cat > "$TMP/spec-u25perm.yaml" <<EOF
schema: 1
name: evtu25perm
type: event
role: none
project: $PROJ_U25
goal: "u25 shared goal"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
permissions:
  allow: ["Read", "Write", "Bash(git commit:*)"]
EOF
assert "U25 create (permissions есть, done/bare-Bash не объявлены)" 0 "$RC" agent create evtu25perm --spec "$TMP/spec-u25perm.yaml"
AG_U25PERM="$CLAUDE_AGENTS_DIR/evtu25perm"
"$RUN" spool-put evtu25perm --text "u25-shared-marker" >/dev/null
"$RUN" intake "$AG_U25PERM" >/dev/null
PROMPT_U25PERM="$TMP/prompt-u25perm.txt"
MOCK_RESULT_TEXT="u25-golden-result" PROMPT_DUMP_FILE="$PROMPT_U25PERM" "$RUN" step "$AG_U25PERM" >/dev/null 2>"$TMP/u25perm.err"
[[ -s "$PROMPT_U25PERM" ]] && ok || fail "U25: промпт (permissions без claude-agent-done/bare Bash) сдампен"
grep -qF "claude-agent-done" "$PROMPT_U25PERM" \
  && fail "U25: рамка готовности НЕ должна появиться - пояс не объявляет ни Bash(claude-agent-done..., ни голый Bash" || ok
KU25PERM=$(ls "$AG_U25PERM/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
MASKED_U25PERM=$(mask_prompt_v210 "$PROMPT_U25PERM" "$KU25PERM")
[[ "$MASKED_U25PERM" == "$GOLDEN_U25" ]] \
  && ok || fail "U25: промпт байт-в-байт с baseline - permissions есть, но команда не объявлена, для рамки готовности это как ее отсутствие"

# =============================================================== U26 (V2.10 T3, ревизия 5)
echo "=== U26: валидный permissions, НЕТ claude-agent-ask И НЕТ голого Bash - рамки вопроса НЕТ, промпт байт-в-байт с baseline (та же проверка, для ask) ==="
AG_U26BASE=$(mk_event evtu26base '')
"$RUN" spool-put evtu26base --text "u26-shared-marker" >/dev/null
"$RUN" intake "$AG_U26BASE" >/dev/null
PROMPT_U26BASE="$TMP/prompt-u26base.txt"
MOCK_RESULT_TEXT="u26-golden-result" PROMPT_DUMP_FILE="$PROMPT_U26BASE" "$RUN" step "$AG_U26BASE" >/dev/null 2>"$TMP/u26base.err"
[[ -s "$PROMPT_U26BASE" ]] && ok || fail "U26: baseline промпт (без permissions) сдампен"
KU26BASE=$(ls "$AG_U26BASE/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
GOLDEN_U26=$(mask_prompt_v210 "$PROMPT_U26BASE" "$KU26BASE")

AG_U26PERM=$(mk_event evtu26perm 'permissions:
  allow: ["Read", "Write", "Bash(git commit:*)"]')
"$RUN" spool-put evtu26perm --text "u26-shared-marker" >/dev/null
"$RUN" intake "$AG_U26PERM" >/dev/null
PROMPT_U26PERM="$TMP/prompt-u26perm.txt"
MOCK_RESULT_TEXT="u26-golden-result" PROMPT_DUMP_FILE="$PROMPT_U26PERM" "$RUN" step "$AG_U26PERM" >/dev/null 2>"$TMP/u26perm.err"
[[ -s "$PROMPT_U26PERM" ]] && ok || fail "U26: промпт (permissions без claude-agent-ask/bare Bash) сдампен"
grep -qF "claude-agent-ask" "$PROMPT_U26PERM" \
  && fail "U26: рамка вопроса НЕ должна появиться - пояс не объявляет ни Bash(claude-agent-ask..., ни голый Bash" || ok
KU26PERM=$(ls "$AG_U26PERM/inbox/done" 2>/dev/null | sed 's/.json//' | head -1)
MASKED_U26PERM=$(mask_prompt_v210 "$PROMPT_U26PERM" "$KU26PERM")
[[ "$MASKED_U26PERM" == "$GOLDEN_U26" ]] \
  && ok || fail "U26: промпт байт-в-байт с baseline - permissions есть, но команда не объявлена, для рамки вопроса это как ее отсутствие"

# =============================================================== U27 (V2.10 T3, ревизия 5: рамки независимы;
# обновлено §3d.1 - у агента нет git вообще, рамка worktree теперь зовет
# ОДНУ команду контура (claude-agent-done). U27a проверяет, что ее одной
# достаточно - рамка готовности есть, а рамка вопроса (claude-agent-ask не
# объявлен) по-прежнему отсутствует - независимость рамок).
echo "=== U27a: пояс объявляет ТОЛЬКО claude-agent-done (ws=worktree) - рамка готовности ЕСТЬ (§3d.1: одной команды достаточно), рамка вопроса отсутствует ==="
PROJ_U27="$TMP/proj-u27"; mkdir -p "$PROJ_U27"
git -C "$PROJ_U27" init -q
( cd "$PROJ_U27" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec-u27a.yaml" <<EOF
schema: 1
name: evtu27a
type: event
role: none
project: $PROJ_U27
goal: "u27a only done"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
permissions:
  allow: ["Read", "Bash(claude-agent-done:*)"]
EOF
assert "U27a create (только claude-agent-done)" 0 "$RC" agent create evtu27a --spec "$TMP/spec-u27a.yaml"
AG_U27A="$CLAUDE_AGENTS_DIR/evtu27a"
"$RUN" spool-put evtu27a --text "u27a-event" >/dev/null
"$RUN" intake "$AG_U27A" >/dev/null
PROMPT_U27A="$TMP/prompt-u27a.txt"
PROMPT_DUMP_FILE="$PROMPT_U27A" "$RUN" step "$AG_U27A" >/dev/null 2>"$TMP/u27a.err"
[[ -s "$PROMPT_U27A" ]] && ok || fail "U27a: промпт сдампен"
grep -qF "$FRAME_WORKTREE_TEXT_V210" "$PROMPT_U27A" \
  && ok || fail "U27a: рамка готовности ЕСТЬ - claude-agent-done один достаточен для worktree (§3d.1)"
grep -qF "claude-agent-ask" "$PROMPT_U27A" \
  && fail "U27a: рамка вопроса НЕ должна появиться - claude-agent-ask не объявлен (реализация не должна путать объявление одной команды с другой)" || ok

echo "=== U27b: пояс объявляет ТОЛЬКО claude-agent-ask - рамка вопроса есть, рамка готовности ОТСУТСТВУЕТ ==="
cat > "$TMP/spec-u27b.yaml" <<EOF
schema: 1
name: evtu27b
type: event
role: none
project: $PROJ_U27
goal: "u27b only ask"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
permissions:
  allow: ["Read", "Bash(claude-agent-ask:*)"]
EOF
assert "U27b create (только claude-agent-ask)" 0 "$RC" agent create evtu27b --spec "$TMP/spec-u27b.yaml"
AG_U27B="$CLAUDE_AGENTS_DIR/evtu27b"
"$RUN" spool-put evtu27b --text "u27b-event" >/dev/null
"$RUN" intake "$AG_U27B" >/dev/null
PROMPT_U27B="$TMP/prompt-u27b.txt"
PROMPT_DUMP_FILE="$PROMPT_U27B" "$RUN" step "$AG_U27B" >/dev/null 2>"$TMP/u27b.err"
[[ -s "$PROMPT_U27B" ]] && ok || fail "U27b: промпт сдампен"
grep -qF "$FRAME_ASK_TEXT_V210" "$PROMPT_U27B" \
  && ok || fail "U27b: рамка вопроса есть (claude-agent-ask объявлен)"
grep -qF "claude-agent-done" "$PROMPT_U27B" \
  && fail "U27b: рамка готовности НЕ должна появиться - claude-agent-done не объявлен (реализация не должна путать объявление одной команды с другой)" || ok

# =============================================================== U28 (V2.10 T3, ревизия 5)
echo "=== U28: голый Bash в allow - обе рамки есть (готовности и вопроса) ==="
PROJ_U28="$TMP/proj-u28"; mkdir -p "$PROJ_U28"
git -C "$PROJ_U28" init -q
( cd "$PROJ_U28" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec-u28.yaml" <<EOF
schema: 1
name: evtu28
type: event
role: none
project: $PROJ_U28
goal: "u28 bare bash"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
permissions:
  allow: ["Read", "Bash"]
EOF
assert "U28 create (голый Bash)" 0 "$RC" agent create evtu28 --spec "$TMP/spec-u28.yaml"
AG_U28="$CLAUDE_AGENTS_DIR/evtu28"
"$RUN" spool-put evtu28 --text "u28-event" >/dev/null
"$RUN" intake "$AG_U28" >/dev/null
PROMPT_U28="$TMP/prompt-u28.txt"
PROMPT_DUMP_FILE="$PROMPT_U28" "$RUN" step "$AG_U28" >/dev/null 2>"$TMP/u28.err"
[[ -s "$PROMPT_U28" ]] && ok || fail "U28: промпт сдампен"
grep -qF "$FRAME_WORKTREE_TEXT_V210" "$PROMPT_U28" \
  && ok || fail "U28: рамка готовности есть (голый Bash покрывает claude-agent-done)"
grep -qF "$FRAME_ASK_TEXT_V210" "$PROMPT_U28" \
  && ok || fail "U28: рамка вопроса есть (голый Bash покрывает claude-agent-ask)"

# =============================================================== U29 (V2.10 T3+T4, ревизия 5: взаимодействие с §1.1)
echo "=== U29: путевое переписывание Write/Edit (§1.1) не влияет на сверку объявления команд контура - обе рамки есть, Write/Edit все равно переписаны в settings.json ==="
PROJ_U29="$TMP/proj-u29"; mkdir -p "$PROJ_U29"
git -C "$PROJ_U29" init -q
( cd "$PROJ_U29" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec-u29.yaml" <<EOF
schema: 1
name: evtu29
type: event
role: none
project: $PROJ_U29
goal: "u29 rewrite vs declaration"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
# §3d.1: рамка worktree требует ОДНУ команду - claude-agent-done (см. U27a).
permissions:
  allow: ["Write", "Edit", "Bash(claude-agent-done:*)", "Bash(claude-agent-ask:*)"]
EOF
assert "U29 create" 0 "$RC" agent create evtu29 --spec "$TMP/spec-u29.yaml"
AG_U29="$CLAUDE_AGENTS_DIR/evtu29"
"$RUN" spool-put evtu29 --text "u29-event" >/dev/null
"$RUN" intake "$AG_U29" >/dev/null
PROMPT_U29="$TMP/prompt-u29.txt"
PROMPT_DUMP_FILE="$PROMPT_U29" "$RUN" step "$AG_U29" >/dev/null 2>"$TMP/u29.err"
[[ -s "$PROMPT_U29" ]] && ok || fail "U29: промпт сдампен"
grep -qF "$FRAME_WORKTREE_TEXT_V210" "$PROMPT_U29" \
  && ok || fail "U29: рамка готовности есть, несмотря на присутствие Write/Edit (путевое переписывание) в том же поясе"
grep -qF "$FRAME_ASK_TEXT_V210" "$PROMPT_U29" \
  && ok || fail "U29: рамка вопроса есть, несмотря на присутствие Write/Edit (путевое переписывание) в том же поясе"
SLJ_U29="$AG_U29/agent-settings.json"
[[ -f "$SLJ_U29" ]] && ok || fail "U29: agent-settings.json создан"
CWD_U29=$(cd "$AG_U29/work" && pwd -P)
[[ "$(perm_allow_has_v210 "$SLJ_U29" "Write(//$CWD_U29/**)")" == "True" ]] \
  && ok || fail "U29: Write все равно переписан в путевую форму - сверка объявления команд не мешает §1.1"
[[ "$(perm_allow_has_v210 "$SLJ_U29" "Edit(//$CWD_U29/**)")" == "True" ]] \
  && ok || fail "U29: Edit все равно переписан в путевую форму - сверка объявления команд не мешает §1.1"
[[ "$(perm_allow_has_v210 "$SLJ_U29" "Bash(claude-agent-done:*)")" == "True" ]] \
  && ok || fail "U29: Bash(claude-agent-done:*) остается нетронутым (не подвергается путевому переписыванию)"
[[ "$(perm_allow_has_v210 "$SLJ_U29" "Bash(claude-agent-ask:*)")" == "True" ]] \
  && ok || fail "U29: Bash(claude-agent-ask:*) остается нетронутым (не подвергается путевому переписыванию)"

# =============================================================== U30 (V2.10 T3, §2.0 п.2, аудит серьезная 7)
# Граница имени команды: голого сравнения по префиксу строки недостаточно -
# "Bash(claude-agent-done-disabled:*)" начинается с "Bash(claude-agent-done",
# но объявляет ДРУГУЮ, несуществующую команду. Сверка обязана отличать это
# от настоящего объявления claude-agent-done - и в ТОЧНОЙ форме без ":*"
# тоже (§2.0 п.2 перечисляет "Bash(<команда>)" как валидную форму наравне с
# "Bash(<команда>:*)").
echo "=== U30a: Bash(claude-agent-done-disabled:*) НЕ считается объявлением claude-agent-done - рамки готовности НЕТ (граница имени, аудит серьезная 7) ==="
PROJ_U30="$TMP/proj-u30"; mkdir -p "$PROJ_U30"
git -C "$PROJ_U30" init -q
( cd "$PROJ_U30" && echo hi > f.txt && git add f.txt && git -c user.email=t@t -c user.name=t commit -qm init )
cat > "$TMP/spec-u30a.yaml" <<EOF
schema: 1
name: evtu30a
type: event
role: none
project: $PROJ_U30
goal: "u30a disabled-suffix false match"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
# §3d.1: рамка worktree требует ОДНУ команду - claude-agent-done. Здесь
# объявлена ТОЛЬКО claude-agent-done-disabled - отсутствие рамки готовности
# обязано объясняться границей имени (аудит V2.10 r2, минорная 11), а не
# чем-то еще.
permissions:
  allow: ["Read", "Bash(claude-agent-done-disabled:*)"]
EOF
assert "U30a create" 0 "$RC" agent create evtu30a --spec "$TMP/spec-u30a.yaml"
AG_U30A="$CLAUDE_AGENTS_DIR/evtu30a"
"$RUN" spool-put evtu30a --text "u30a-event" >/dev/null
"$RUN" intake "$AG_U30A" >/dev/null
PROMPT_U30A="$TMP/prompt-u30a.txt"
PROMPT_DUMP_FILE="$PROMPT_U30A" "$RUN" step "$AG_U30A" >/dev/null 2>"$TMP/u30a.err"
[[ -s "$PROMPT_U30A" ]] && ok || fail "U30a: промпт сдампен"
grep -qF "claude-agent-done --summary" "$PROMPT_U30A" \
  && fail "U30a: рамка готовности НЕ должна появиться - claude-agent-done-disabled это другая команда, не claude-agent-done" || ok

# §3c (аудит V2.10 r2, серьезная 9): точная форма без ':*' разрешает в
# Claude Code только ГОЛЫЙ вызов без единого аргумента - обертке нужен
# обязательный --summary/--message, такой вызов CLI гарантированно отобьет.
# Признавать такую запись "объявлением" значило бы звать агента к заведомо
# отказывающей команде - поэтому теперь она НЕ считается объявлением.
echo "=== U30b: Bash(claude-agent-done) - ТОЧНАЯ форма без :* НЕ покрывает обязательный --summary/--message - рамки готовности НЕТ (аудит V2.10 r2, серьезная 9) ==="
cat > "$TMP/spec-u30b.yaml" <<EOF
schema: 1
name: evtu30b
type: event
role: none
project: $PROJ_U30
goal: "u30b exact form without star"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
permissions:
  allow: ["Read", "Bash(claude-agent-done)"]
EOF
assert "U30b create" 0 "$RC" agent create evtu30b --spec "$TMP/spec-u30b.yaml"
AG_U30B="$CLAUDE_AGENTS_DIR/evtu30b"
"$RUN" spool-put evtu30b --text "u30b-event" >/dev/null
"$RUN" intake "$AG_U30B" >/dev/null
PROMPT_U30B="$TMP/prompt-u30b.txt"
PROMPT_DUMP_FILE="$PROMPT_U30B" "$RUN" step "$AG_U30B" >/dev/null 2>"$TMP/u30b.err"
[[ -s "$PROMPT_U30B" ]] && ok || fail "U30b: промпт сдампен"
grep -qF "$FRAME_WORKTREE_TEXT_V210" "$PROMPT_U30B" \
  && fail "U30b: рамка готовности НЕ должна появиться - точная форма Bash(claude-agent-done) без :* разрешает только вызов БЕЗ аргументов (аудит серьезная 9)" || ok

echo "=== U30c: Bash(claude-agent-done:*) - реальная wildcard-форма - рамка готовности ЕСТЬ (регресс-пин: фикс серьезной 9 не сузил валидную форму) ==="
cat > "$TMP/spec-u30c.yaml" <<EOF
schema: 1
name: evtu30c
type: event
role: none
project: $PROJ_U30
goal: "u30c wildcard form"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
permissions:
  allow: ["Read", "Bash(claude-agent-done:*)"]
EOF
assert "U30c create" 0 "$RC" agent create evtu30c --spec "$TMP/spec-u30c.yaml"
AG_U30C="$CLAUDE_AGENTS_DIR/evtu30c"
"$RUN" spool-put evtu30c --text "u30c-event" >/dev/null
"$RUN" intake "$AG_U30C" >/dev/null
PROMPT_U30C="$TMP/prompt-u30c.txt"
PROMPT_DUMP_FILE="$PROMPT_U30C" "$RUN" step "$AG_U30C" >/dev/null 2>"$TMP/u30c.err"
[[ -s "$PROMPT_U30C" ]] && ok || fail "U30c: промпт сдампен"
grep -qF "$FRAME_WORKTREE_TEXT_V210" "$PROMPT_U30C" \
  && ok || fail "U30c: рамка готовности есть (форма :* покрывает вызов с аргументами)"

unset CLAUDE_CONFIG_DIR

echo
echo "test-agent-workspace: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
