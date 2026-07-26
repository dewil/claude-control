#!/usr/bin/env bash
# Tests for V2.2 thread-memory (событийные агенты, тред задачи agents/<name>/thread.jsonl).
# Контракт: docs/design-2026-07-26-v2.2-thread-memory.md §7 (кейсы T1-T10).
# Написано с чистого листа по спеке (SDD, RED-фаза) - реализация еще не читана
# (bin/* сознательно не открывался при написании этого файла).
#
# Порядок в файле: T1-T8 по спеке; T10 (голден) написан ПЕРЕД T9, потому что
# T9 сравнивается с эталоном, снятым в T10 (см. комментарий у T10) - тот же
# прием переупорядочивания, что в test-agent-drain.sh (T5 перед T1).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../bin/claude-agent-run"
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
jline() { # <one json line> <py-expr over dict d>
  python3 -c 'import json,sys
d=json.loads(sys.argv[1])
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
reset_next() { # <pending-json-path> - снять backoff, чтобы step взял конверт снова
  python3 - "$1" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["meta"]["next_attempt_at"] = None
json.dump(d, open(p, "w"))
PY
}
linecount() { [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }
bytecount() { [[ -f "$1" ]] && wc -c < "$1" | tr -d ' ' || echo 0; }
mask_prompt() { # <file> <key-hex> <native_id> - вычищаем волатильные поля конверта
  local f="$1" key="$2" nid="$3"
  sed -E \
    -e "s/${key}/<KEY>/g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' \
    -e "s/(\"native_id\"[:=] ?\"?)${nid}(\"?)/\\1<N>\\2/g" \
    "$f"
}

mk_event() { # <name> -> печатает путь к agent-dir
  local name="$1"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "thread memory unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
  echo "$ag"
}

# --- mock claude: дампит STDIN (промпт) в PROMPT_DUMP_FILE, если задан ---
MOCK="$TMP/mock-claude"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${PROMPT_DUMP_FILE:-}" ]]; then cat > "$PROMPT_DUMP_FILE"; else cat > /dev/null; fi
mode=$(cat "${MOCK_MODE_FILE:-/dev/null}" 2>/dev/null || echo ok)
case "$mode" in
  ok)   printf '{"type":"result","result":"%s","total_cost_usd":0.01}\n' "${MOCK_RESULT_TEXT:-processed}" ;;
  fail) echo boom >&2; exit 1 ;;
esac
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK" MOCK_MODE_FILE="$TMP/mock-mode"
echo ok > "$MOCK_MODE_FILE"

# =============================================================== T1
echo "=== T1: прогон пишет event+result с правильными key/seq/kind ==="
AGT1=$(mk_event evtt1)
"$RUN" spool-put evtt1 --text "t1-event-payload" >/dev/null
"$RUN" intake "$AGT1" >/dev/null
KT1=$(ls "$AGT1/inbox/pending" | sed 's/.json//')
MOCK_RESULT_TEXT="t1-result-text" "$RUN" step "$AGT1" >/dev/null 2>"$TMP/errt1"
THJ1="$AGT1/thread.jsonl"
[[ -f "$THJ1" ]] && ok || fail "T1: thread.jsonl создан"
LC1=$(linecount "$THJ1")
[[ "$LC1" == "2" ]] && ok || fail "T1: ровно 2 записи (event+result), получили '${LC1}'"
L1A=$(sed -n '1p' "$THJ1" 2>/dev/null); L1B=$(sed -n '2p' "$THJ1" 2>/dev/null)
[[ "$(jline "$L1A" 'd.get("key")' 2>/dev/null)" == "$KT1" ]] && ok || fail "T1: key записи 1 = key конверта"
[[ "$(jline "$L1A" 'd.get("kind")' 2>/dev/null)" == "event" ]] && ok || fail "T1: kind записи 1 = event"
[[ "$(jline "$L1A" 'd.get("seq")' 2>/dev/null)" == "0" ]] && ok || fail "T1: seq записи 1 = 0"
[[ "$(jline "$L1A" '"t1-event-payload" in d.get("text","")' 2>/dev/null)" == "True" ]] \
  && ok || fail "T1: текст события в записи 1"
[[ "$(jline "$L1B" 'd.get("key")' 2>/dev/null)" == "$KT1" ]] && ok || fail "T1: key записи 2 = key конверта"
[[ "$(jline "$L1B" 'd.get("kind")' 2>/dev/null)" == "result" ]] && ok || fail "T1: kind записи 2 = result"
[[ "$(jline "$L1B" 'd.get("seq")' 2>/dev/null)" == "1" ]] && ok || fail "T1: seq записи 2 = 1"
[[ "$(jline "$L1B" '"t1-result-text" in d.get("text","")' 2>/dev/null)" == "True" ]] \
  && ok || fail "T1: текст результата в записи 2"

# =============================================================== T2
echo "=== T2: второй прогон видит в промпте текст первого ==="
AGT2=$(mk_event evtt2)
"$RUN" spool-put evtt2 --text "t2-first-unique-marker" >/dev/null
"$RUN" intake "$AGT2" >/dev/null
MOCK_RESULT_TEXT="t2-first-result-marker" "$RUN" step "$AGT2" >/dev/null 2>"$TMP/errt2a"
"$RUN" spool-put evtt2 --text "t2-second-event" >/dev/null
"$RUN" intake "$AGT2" >/dev/null
PROMPT2="$TMP/prompt2.txt"
PROMPT_DUMP_FILE="$PROMPT2" "$RUN" step "$AGT2" >/dev/null 2>"$TMP/errt2b"
[[ -s "$PROMPT2" ]] && ok || fail "T2: mock вызван, промпт сдампен"
grep -qF "t2-first-unique-marker" "$PROMPT2" && ok || fail "T2: промпт содержит текст первого события"
grep -qF "t2-first-result-marker" "$PROMPT2" && ok || fail "T2: промпт содержит результат первого прогона"
grep -qF "t2-second-event" "$PROMPT2" && ok || fail "T2: текущее (второе) событие тоже в промпте"

# =============================================================== T3
echo "=== T3: reader-дедуп по (key,kind,seq) - берется последняя запись ==="
# Черный ящик не дает воспроизвести настоящий крэш "между записью треда и
# переходом pending->done" (переход атомарен под .inbox.lock снаружи не
# остановить) - ближайший достижимый вариант, санкционированный брифом:
# дописываем в thread.jsonl вторую запись с ТЕМ ЖЕ (key,kind,seq) вручную и
# проверяем, что построение промпта берет последнюю (last-wins), а не первую.
AGT3=$(mk_event evtt3)
"$RUN" spool-put evtt3 --text "t3-event" >/dev/null
"$RUN" intake "$AGT3" >/dev/null
KT3=$(ls "$AGT3/inbox/pending" | sed 's/.json//')
MOCK_RESULT_TEXT="t3-original-result" "$RUN" step "$AGT3" >/dev/null 2>"$TMP/errt3a"
THJ3="$AGT3/thread.jsonl"
[[ -f "$THJ3" ]] && ok || fail "T3: thread.jsonl создан после первого прогона"
printf '{"key": "%s", "seq": 1, "at": "2026-07-26T09:00:00Z", "kind": "result", "text": "t3-newer-result-should-win"}\n' \
  "$KT3" >> "$THJ3"
"$RUN" spool-put evtt3 --text "t3-second-event" >/dev/null
"$RUN" intake "$AGT3" >/dev/null
PROMPT3="$TMP/prompt3.txt"
PROMPT_DUMP_FILE="$PROMPT3" "$RUN" step "$AGT3" >/dev/null 2>"$TMP/errt3b"
grep -qF "t3-newer-result-should-win" "$PROMPT3" \
  && ok || fail "T3: в промпте взята ПОСЛЕДНЯЯ запись дубля (key,kind,seq)"
grep -qF "t3-original-result" "$PROMPT3" \
  && fail "T3: вытесненная (первая) запись не должна попасть в промпт" || ok

# =============================================================== T4
echo "=== T4: битая хвостовая строка пропускается, промпт строится ==="
AGT4=$(mk_event evtt4)
"$RUN" spool-put evtt4 --text "t4-good-event" >/dev/null
"$RUN" intake "$AGT4" >/dev/null
MOCK_RESULT_TEXT="t4-good-result" "$RUN" step "$AGT4" >/dev/null 2>"$TMP/errt4a"
THJ4="$AGT4/thread.jsonl"
[[ -f "$THJ4" ]] && ok || fail "T4: thread.jsonl создан после первого прогона"
printf '{"key": "garbage-incomplete-lin' >> "$THJ4"   # без завершающего \n и без закрывающей }
"$RUN" spool-put evtt4 --text "t4-second-event" >/dev/null
"$RUN" intake "$AGT4" >/dev/null
PROMPT4="$TMP/prompt4.txt"
PROMPT_DUMP_FILE="$PROMPT4" "$RUN" step "$AGT4" >/dev/null 2>"$TMP/errt4b"
rc4=$?
[[ "$rc4" == 0 ]] && ok || fail "T4: step не падает на битой хвостовой строке (rc=$rc4)"
[[ -s "$PROMPT4" ]] && ok || fail "T4: промпт все равно построен"
grep -qF "t4-good-event" "$PROMPT4" && ok || fail "T4: валидная запись до битой строки осталась в промпте"
grep -qF "t4-good-result" "$PROMPT4" && ok || fail "T4: валидный результат до битой строки остался в промпте"

# =============================================================== T5
echo "=== T5: кап хвоста THREAD_TAIL_MAX_BYTES=512 - маркер усечения ==="
AGT5=$(mk_event evtt5)
for i in $(seq 1 20); do
  "$RUN" spool-put evtt5 --text "t5-event-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" >/dev/null
  "$RUN" intake "$AGT5" >/dev/null
  THREAD_TAIL_MAX_BYTES=512 MOCK_RESULT_TEXT="t5-result-$i" "$RUN" step "$AGT5" >/dev/null 2>"$TMP/errt5_$i"
done
"$RUN" spool-put evtt5 --text "t5-final-event" >/dev/null
"$RUN" intake "$AGT5" >/dev/null
PROMPT5="$TMP/prompt5.txt"
THREAD_TAIL_MAX_BYTES=512 PROMPT_DUMP_FILE="$PROMPT5" "$RUN" step "$AGT5" >/dev/null 2>"$TMP/errt5b"
[[ -s "$PROMPT5" ]] && ok || fail "T5: промпт сдампен"
grep -qF "тред усечен" "$PROMPT5" && ok || fail "T5: маркер усечения '[тред усечен: ...]' присутствует"
grep -qF "t5-event-1-" "$PROMPT5" \
  && fail "T5: самая старая запись не должна поместиться в урезанный (512 байт) хвост" || ok
grep -qF "t5-final-event" "$PROMPT5" && ok || fail "T5: текущее событие в промпте"
SZ5=$(bytecount "$PROMPT5")
[[ "$SZ5" -lt 6000 ]] && ok || fail "T5: промпт не раздут капом (размер $SZ5 байт при 20 непустых записях без капа было бы больше)"

# =============================================================== T6
echo "=== T6: fail не пишет в тред; deadletter пишет одну note ==="
AGT6=$(mk_event evtt6)
"$RUN" spool-put evtt6 --text "t6-doomed" >/dev/null
"$RUN" intake "$AGT6" >/dev/null
KT6=$(ls "$AGT6/inbox/pending" | sed 's/.json//')
echo fail > "$MOCK_MODE_FILE"
"$RUN" step "$AGT6" >/dev/null 2>"$TMP/errt6_1"
[[ ! -f "$AGT6/thread.jsonl" ]] && ok || fail "T6: неуспешный прогон не создал/не дописал тред (попытка 1)"
reset_next "$AGT6/inbox/pending/$KT6.json"
"$RUN" step "$AGT6" >/dev/null 2>"$TMP/errt6_2"
reset_next "$AGT6/inbox/pending/$KT6.json"
"$RUN" step "$AGT6" >/dev/null 2>"$TMP/errt6_3"
echo ok > "$MOCK_MODE_FILE"
[[ -f "$AGT6/inbox/deadletter/$KT6.json" ]] && ok || fail "T6: конверт ушел в deadletter после 3 неуспешных попыток"
THJ6="$AGT6/thread.jsonl"
[[ -f "$THJ6" ]] && ok || fail "T6: после deadletter в тред записана note"
LC6=$(linecount "$THJ6")
[[ "$LC6" == "1" ]] && ok || fail "T6: ровно одна запись (note) в треде (получили '${LC6}')"
L6=$(sed -n '1p' "$THJ6" 2>/dev/null)
[[ "$(jline "$L6" 'd.get("kind")' 2>/dev/null)" == "note" ]] && ok || fail "T6: kind записи = note"
[[ "$(jline "$L6" 'd.get("key")' 2>/dev/null)" == "$KT6" ]] && ok || fail "T6: key note = key отброшенного конверта"

# =============================================================== T7
echo "=== T7: компакция THREAD_MAX_BYTES=2048 - архив + note о переносе ==="
AGT7=$(mk_event evtt7)
for i in $(seq 1 20); do
  "$RUN" spool-put evtt7 --text "t7-event-$i-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy" >/dev/null
  "$RUN" intake "$AGT7" >/dev/null
  THREAD_MAX_BYTES=2048 MOCK_RESULT_TEXT="t7-result-$i" "$RUN" step "$AGT7" >/dev/null 2>"$TMP/errt7_$i"
done
ARCH7="$AGT7/thread-archive.jsonl"
[[ -f "$ARCH7" ]] && ok || fail "T7: thread-archive.jsonl появился после превышения THREAD_MAX_BYTES"
SZ7=$(bytecount "$AGT7/thread.jsonl")
[[ -n "$SZ7" && "$SZ7" -lt 3000 ]] \
  && ok || fail "T7: активный thread.jsonl сжат компакцией (размер '$SZ7' байт при капе 2048)"
FIRST7=$(head -n1 "$AGT7/thread.jsonl" 2>/dev/null)
[[ "$(jline "$FIRST7" 'd.get("kind")' 2>/dev/null)" == "note" ]] \
  && ok || fail "T7: первая строка активного файла - note о переносе"
grep -qF "перенесено в архив" <<<"$FIRST7" && ok || fail "T7: текст note упоминает перенос в архив"

# =============================================================== T8
echo "=== T8: payload.kind==answer -> запись kind=answer, пометка 'доверенный' ==="
AGT8=$(mk_event evtt8)
"$RUN" spool-put evtt8 --json '{"kind":"answer","text":"t8-answer-unique-text"}' >/dev/null
"$RUN" intake "$AGT8" >/dev/null
"$RUN" step "$AGT8" >/dev/null 2>"$TMP/errt8a"
THJ8="$AGT8/thread.jsonl"
[[ -f "$THJ8" ]] && ok || fail "T8: thread.jsonl создан для answer-конверта"
LC8=$(linecount "$THJ8")
[[ "$LC8" == "2" ]] \
  && ok || fail "T8: ровно 2 записи (answer+result, без отдельной event) - получили '${LC8}'"
L8=$(sed -n '1p' "$THJ8" 2>/dev/null)
[[ "$(jline "$L8" 'd.get("kind")' 2>/dev/null)" == "answer" ]] && ok || fail "T8: первая запись kind=answer"
[[ "$(jline "$L8" 'd.get("seq")' 2>/dev/null)" == "0" ]] && ok || fail "T8: seq=0 для answer-записи"
grep -qF "t8-answer-unique-text" <<<"$L8" && ok || fail "T8: текст ответа сохранен в записи"
"$RUN" spool-put evtt8 --text "t8-second-event" >/dev/null
"$RUN" intake "$AGT8" >/dev/null
PROMPT8="$TMP/prompt8.txt"
PROMPT_DUMP_FILE="$PROMPT8" "$RUN" step "$AGT8" >/dev/null 2>"$TMP/errt8b"
grep -qF "t8-answer-unique-text" "$PROMPT8" && ok || fail "T8: текст ответа виден в промпте следующего прогона"
grep -qF "[ответ dwl - доверенный]" "$PROMPT8" \
  && ok || fail "T8: пометка '[ответ dwl - доверенный]' присутствует в промпте"

# =============================================================== T10 (голден, снят раньше T9 - см. заголовок файла)
echo "=== T10 (регресс): голден промпта агента без треда, снят прямо в тесте ==="
AGTG=$(mk_event evtthreadgolden)
"$RUN" spool-put evtthreadgolden --text "thread-golden-shared-text" >/dev/null
"$RUN" intake "$AGTG" >/dev/null
KG=$(ls "$AGTG/inbox/pending" | sed 's/.json//')
[[ ! -f "$AGTG/thread.jsonl" ]] && ok || fail "T10: перед первым прогоном thread.jsonl отсутствует"
PROMPTG="$TMP/prompt_golden.txt"
MOCK_RESULT_TEXT="golden-result-text" PROMPT_DUMP_FILE="$PROMPTG" "$RUN" step "$AGTG" >/dev/null 2>"$TMP/errtg"
[[ -s "$PROMPTG" ]] && ok || fail "T10: промпт голден-прогона сдампен"
GOLDEN_MASKED=$(mask_prompt "$PROMPTG" "$KG" "1")

# =============================================================== T9
echo "=== T9: THREAD_ENABLED=0 - тред не читается/не пишется, промпт = голден ==="
"$RUN" spool-put evtthreadgolden --text "thread-golden-shared-text" >/dev/null
"$RUN" intake "$AGTG" >/dev/null
K9=$(ls "$AGTG/inbox/pending" | sed 's/.json//')
LC_BEFORE=$(linecount "$AGTG/thread.jsonl")
PROMPT9="$TMP/prompt_t9.txt"
THREAD_ENABLED=0 MOCK_RESULT_TEXT="golden-result-text" PROMPT_DUMP_FILE="$PROMPT9" \
  "$RUN" step "$AGTG" >/dev/null 2>"$TMP/errt9"
[[ -s "$PROMPT9" ]] && ok || fail "T9: THREAD_ENABLED=0 не роняет прогон, mock вызван"
LC_AFTER=$(linecount "$AGTG/thread.jsonl")
[[ "$LC_AFTER" == "$LC_BEFORE" ]] \
  && ok || fail "T9: THREAD_ENABLED=0 не дописывает тред (было '$LC_BEFORE', стало '$LC_AFTER')"
T9_MASKED=$(mask_prompt "$PROMPT9" "$K9" "2")
[[ "$GOLDEN_MASKED" == "$T9_MASKED" ]] \
  && ok || fail "T9: промпт с THREAD_ENABLED=0 не совпадает с голденом T10 (после маскировки key/native_id/ts)"

echo
echo "test-agent-thread: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
