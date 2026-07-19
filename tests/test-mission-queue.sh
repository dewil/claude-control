#!/usr/bin/env bash
# Tests for bin/claude-agent-run: mission-очередь операторских комментариев
# (этап 9). Контракт: design-2026-07-19-stage9-mission-operator-io.md
# (очередь-как-spool, framing, кап+backpressure, delivered-ledger, stalled).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"

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

# --- fixture: mission-агент вручную (юнит-скоуп, без CLI) ---
AG="$CLAUDE_AGENTS_DIR/mis"
MI="$AG/mission-inbox"
mkdir -p "$AG"

# ------------------------------------------------------------ mission-put
assert "mission-put text"    0 "$RUN" mission-put mis --text "первое наставление"
[[ "$(cat "$TMP/out")" == "1" ]] && ok || fail "первый seq = 1"
[[ -f "$MI/msg-000001.json" ]] && ok || fail "msg-000001.json опубликован"
[[ "$(cat "$MI/.seq")" == "1" ]] && ok || fail ".seq = 1"
[[ "$(jq_file "$MI/msg-000001.json" 'd["text"]')" == "первое наставление" ]] \
  && ok || fail "text сохранен"
[[ "$(jq_file "$MI/msg-000001.json" 'd["seq"]')" == "1" ]] \
  && ok || fail "seq в теле"

assert "mission-put второй"  0 "$RUN" mission-put mis --text "второе" --from dwl
[[ "$(cat "$TMP/out")" == "2" ]] && ok || fail "второй seq = 2"
[[ "$(jq_file "$MI/msg-000002.json" 'd["from"]')" == "dwl" ]] \
  && ok || fail "--from сохранен"

# framing: \n -> литерал \n, C0 (включая tab) выпилены
assert "mission-put framing" 0 "$RUN" mission-put mis --text "$(printf 'a\nb\tc\x07d')"
[[ "$(jq_file "$MI/msg-000003.json" 'd["text"]')" == 'a\nb cd' ]] \
  && ok || fail "нормализация: literal \\n, tab->пробел, C0 удален: $(jq_file "$MI/msg-000003.json" 'd["text"]')"

# входной лимит длины
big=$(python3 -c 'print("x" * 5000)')
assert "mission-put too large" 6 "$RUN" mission-put mis --text "$big"

# идемпотентность --id: повтор дает тот же seq, дубля нет
assert "mission-put --id"    0 "$RUN" mission-put mis --text "четыре" --id tg:42
SEQ4="$(cat "$TMP/out")"
assert "mission-put --id повтор" 0 "$RUN" mission-put mis --text "четыре" --id tg:42
[[ "$(cat "$TMP/out")" == "$SEQ4" ]] && ok || fail "--id повтор: тот же seq"
[[ "$(ls "$MI"/msg-*.json | wc -l | tr -d ' ')" == "4" ]] \
  && ok || fail "--id повтор: дубль не создан"
assert "--id другой payload"  2 "$RUN" mission-put mis --text "другое" --id tg:42

# crash-протокол: .seq впереди файлов - дыра, не коллизия
echo 10 > "$MI/.seq"
assert "mission-put после дыры" 0 "$RUN" mission-put mis --text "после дыры"
[[ "$(cat "$TMP/out")" == "11" ]] && ok || fail "seq после дыры = 11"

# ошибки адресации
assert "плохое имя"           2 "$RUN" mission-put "BAD NAME" --text x
assert "нет агента"           3 "$RUN" mission-put ghost --text x

# ------------------------------------------------------------ mission-next
assert "mission-next"        0 "$RUN" mission-next mis
[[ "$(jq_file "$TMP/out" 'd["seq"]')" == "1" ]] \
  && ok || fail "next отдает старейший (seq 1)"

# FIFO numeric: msg-000002 < msg-000011
assert "mark ok seq1"        0 "$RUN" mission-mark mis 1 --ok
assert "next после mark"     0 "$RUN" mission-next mis
[[ "$(jq_file "$TMP/out" 'd["seq"]')" == "2" ]] \
  && ok || fail "next после доставки 1 -> seq 2"

# delivered-ledger: файл переехал
[[ -f "$MI/delivered/msg-000001.json" && ! -f "$MI/msg-000001.json" ]] \
  && ok || fail "доставленный переехал в delivered/"
[[ "$(jq_file "$MI/.drain.json" 'd["last_result"]')" == "ok" ]] \
  && ok || fail "drain.json: last_result ok"
[[ "$(jq_file "$MI/.drain.json" 'd["fail_streak"]')" == "0" ]] \
  && ok || fail "drain.json: fail_streak 0"

# mark --fail: streak растет, файл остается
assert "mark fail seq2"      0 "$RUN" mission-mark mis 2 --fail
[[ -f "$MI/msg-000002.json" ]] && ok || fail "fail: файл остался в очереди"
[[ "$(jq_file "$MI/.drain.json" 'd["fail_streak"]')" == "1" ]] \
  && ok || fail "fail_streak 1"
assert "mark fail снова"     0 "$RUN" mission-mark mis 2 --fail
[[ "$(jq_file "$MI/.drain.json" 'd["fail_streak"]')" == "2" ]] \
  && ok || fail "fail_streak 2"
assert "mark ok сбрасывает"  0 "$RUN" mission-mark mis 2 --ok
[[ "$(jq_file "$MI/.drain.json" 'd["fail_streak"]')" == "0" ]] \
  && ok || fail "ok сбрасывает streak"

# идемпотентность mark --ok (crash после replace до drain-записи)
assert "mark ok повтор"      0 "$RUN" mission-mark mis 2 --ok

# ------------------------------------------------------------ кап + backpressure
( export CLAUDE_AGENT_MISSION_MAX_MSGS=4
  # в очереди: 3,4,11; четвертый лезет в кап, пятый - отказ
  "$RUN" mission-put mis --text "под кап" >/dev/null 2>&1 || exit 1
  "$RUN" mission-put mis --text "сверх капа" >/dev/null 2>&1 && exit 1
  exit 0 )
[[ $? == 0 ]] && ok || fail "кап: 4-й прошел, 5-й отбит"
( export CLAUDE_AGENT_MISSION_MAX_MSGS=4
  "$RUN" mission-put mis --text "сверх капа" >/dev/null 2>"$TMP/err"
  [[ $? == 6 ]] )
[[ $? == 0 ]] && ok || fail "кап: отказ = exit 6 (backpressure)"

# ------------------------------------------------------------ delivered prune
( export CLAUDE_AGENT_MISSION_DELIVERED_KEEP=2
  "$RUN" mission-mark mis 3 --ok >/dev/null 2>&1
  n=$(ls "$MI/delivered"/msg-*.json | wc -l | tr -d ' ')
  [[ "$n" == "2" ]] )
[[ $? == 0 ]] && ok || fail "delivered prune до KEEP=2"

# ------------------------------------------------------------ mission-status
assert "mission-status"      0 "$RUN" mission-status mis
[[ "$(jq_file "$TMP/out" 'd["depth"]')" == "3" ]] \
  && ok || fail "status: depth 3 (4,11,кап-мессадж)"
[[ "$(jq_file "$TMP/out" 'd["stalled"]')" == "False" ]] \
  && ok || fail "status: свежая очередь не stalled"

# stalled: старейший старше порога и последняя попытка неуспешна
touch -t 202601010000 "$MI/msg-000004.json"
assert "mark fail для stalled" 0 "$RUN" mission-mark mis 4 --fail
assert "mission-status stalled" 0 "$RUN" mission-status mis
[[ "$(jq_file "$TMP/out" 'd["stalled"]')" == "True" ]] \
  && ok || fail "status: старая очередь + fail = stalled"
[[ "$(jq_file "$TMP/out" 'd["fail_streak"]')" == "1" ]] \
  && ok || fail "status: fail_streak прокинут"

# пустая очередь: next молчит, status depth 0
AG2="$CLAUDE_AGENTS_DIR/mis2"; mkdir -p "$AG2"
assert "next пустой"          0 "$RUN" mission-next mis2
[[ ! -s "$TMP/out" ]] && ok || fail "next на пустой очереди молчит"
assert "status пустой"        0 "$RUN" mission-status mis2
[[ "$(jq_file "$TMP/out" 'd["depth"]')" == "0" ]] && ok || fail "status: depth 0"

# безопасность: symlink вместо mission-inbox - отказ
AG3="$CLAUDE_AGENTS_DIR/mis3"; mkdir -p "$AG3" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$AG3/mission-inbox"
assert "symlink отбит"        7 "$RUN" mission-put mis3 --text x

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL == 0 ]]
