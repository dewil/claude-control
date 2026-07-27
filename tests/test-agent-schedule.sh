#!/usr/bin/env bash
# Tests for V2.8: расписание как источник событий (`claude-agent-run
# schedule-tick <agent_dir>`), durable-состояние `agents/<name>/schedule.json`.
# Контракт: docs/design-2026-07-27-v2.8-schedule-source.md §6 (кейсы S1-S22).
#
# Написано с чистого листа по спеке (SDD, RED-фаза): реализация V2.8 НЕ
# читана - bin/claude-rc-agent, bin/claude-agent-run, bin/claude-agent-reconciler
# ни разу не открывались через Read. Публичный контракт взят из самой спеки и
# из design-2026-07-12-stage4-event-spool.md (коды возврата spool-put:
# 2 - валидация/id-payload mismatch, 3 - нет агента, 5 - lock busy,
# 6 - кап, 7 - файловая небезопасность симлинка), плюс стиль и приемы -
# из tests/test-agent-run.sh (spool-put/intake, симлинк-атака на spool ->
# exit 7, кап через CLAUDE_AGENT_EVENT_MAX_BYTES -> exit 6),
# tests/test-agent-cli.sh (минимальная валидная спека type:event workspace:none
# без git-проекта, конвенция exit 2 для всех отказов валидации спеки при
# create), tests/test-agent-task-lifecycle.sh (B35/B36 - образец сквозного
# прохода реального `claude-agent-reconciler --once` с изолированными
# CLAUDE_AGENTS_DIR/CLAUDE_RECONCILER_DIR).
#
# Формат CLAUDE_AGENT_NOW - unix-секунды (docstring _schedule_now() в
# bin/claude-agent-run - единственное, что было целенаправленно проверено
# точечным grep по этой одной строке контракта env-переменной, ПОСЛЕ того как
# черным ящиком было обнаружено, что ISO8601 тайм-инъекция молча игнорируется
# и подставляется реальное время хоста; тела функций не читались).
#
# Методология без утечки в реализацию (важно для falsifiability, не только
# для чистоты SDD): спека НЕ фиксирует формат сериализации `last_slot` и
# формат `--id`/payload, который schedule-tick реально кладет в spool.
# Поэтому там, где нужно "подставить" durable-состояние (симуляция простоя/
# краха), тесты НЕ авторят schedule.json руками с придуманным форматом -
# вместо этого состояние получается ТОЛЬКО через реальные вызовы schedule-tick
# (baseline-тик, затем снимок/восстановление файла schedule.json теми же
# байтами, что записала сама реализация). Так тест остается верен контракту
# (что должно происходить), а не догадке о внутреннем формате.
set -u
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/../bin/claude-rc"
RUN="$HERE/../bin/claude-agent-run"
RECON="$HERE/../bin/claude-agent-reconciler"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export TZ=UTC
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
    fail "$desc: exit $got != $want ($(head -c200 "$TMP/err"))"; fi
}
jq_file() { # <file> <py-expr over dict/list d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
yaml_get() { # <file> <py-expr over dict d (yaml.safe_load)>
  python3 -c 'import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2" 2>/dev/null
}
sched_get() { jq_file "$1/schedule.json" "$2"; } # <agent-dir> <py-expr over d>
ctrl_get()  { jq_file "$1/control.json" "$2"; }   # <agent-dir> <py-expr over d>
spool_count() { ls "$CLAUDE_AGENT_SPOOL_BASE/$1"/*.json 2>/dev/null | grep -c '\.json$'; } # <name>
last_spool_file() { ls "$CLAUDE_AGENT_SPOOL_BASE/$1"/*.json 2>/dev/null | sort | tail -1; } # <name>

tick() { # <agent-dir> <now-unix-seconds> -> запускает schedule-tick c CLAUDE_AGENT_NOW=<now-unix-seconds>;
  # exit code - через $? сразу после вызова; stdout/stderr - в $TMP/tick.out/.err
  CLAUDE_AGENT_NOW="$2" "$RUN" schedule-tick "$1" >"$TMP/tick.out" 2>"$TMP/tick.err"
}

# --- общий проект (workspace:none не создает worktree - плоский каталог без
#     git достаточен, прецедент tests/test-agent-task-lifecycle.sh
#     mk_created_none_agent: PROJ_B26/27/28 = голый mkdir) ---
PROJ_SHARED="$TMP/proj-shared"; mkdir -p "$PROJ_SHARED"

write_event_spec() { # <name> <schedule-yaml-блок-или-пусто> -> печатает путь к spec.yaml
  # (минимальный валидный type:event/workspace:none - прецедент
  # tests/test-agent-cli.sh spec-evt.yaml)
  local name="$1" sched="${2:-}"
  local f="$TMP/spec-$name.yaml"
  cat > "$f" <<EOF
schema: 1
name: $name
type: event
role: none
project: $PROJ_SHARED
goal: "schedule test $name"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: none
EOF
  if [[ -n "$sched" ]]; then printf '%s\n' "$sched" >> "$f"; fi
  echo "$f"
}

# --- проект и mission.md для S7 (type:mission требует git-репозиторий - прецедент tests/test-agent-cli.sh) ---
PROJ_MISSION="$TMP/proj-mission"
git init -q --initial-branch=main "$PROJ_MISSION"
( cd "$PROJ_MISSION" && echo hi > f.txt && git add . \
  && git -c user.email=t@t -c user.name=t commit -qm init )
MISSION_MD="$TMP/mission.md"; echo "# mission" > "$MISSION_MD"

write_mission_spec() { # <name> <schedule-yaml-блок> -> печатает путь к spec.yaml (type:mission)
  local name="$1" sched="${2:-}"
  local f="$TMP/spec-$name.yaml"
  cat > "$f" <<EOF
schema: 1
name: $name
type: mission
role: coder
project: $PROJ_MISSION
goal: "schedule mission test $name"
autonomy: act
limits: { max_iterations: 5, max_hours: 1, max_iteration_minutes: 2 }
EOF
  if [[ -n "$sched" ]]; then printf '%s\n' "$sched" >> "$f"; fi
  echo "$f"
}

mk_ticking_agent() { # <name> <schedule-yaml-блок> -> печатает agent-dir; create + start (desired=running)
  local name="$1" sched="$2"
  local spec; spec=$(write_event_spec "$name" "$sched")
  "$RC" agent create "$name" --spec "$spec" >/dev/null 2>"$TMP/create-$name.err"
  local rc=$?
  [[ "$rc" == 0 ]] && ok || fail "fixture: create $name ($(cat "$TMP/create-$name.err"))"
  "$RC" agent start "$name" >/dev/null 2>"$TMP/start-$name.err"
  local rc2=$?
  [[ "$rc2" == 0 ]] && ok || fail "fixture: start $name ($(cat "$TMP/start-$name.err"))"
  echo "$CLAUDE_AGENTS_DIR/$name"
}

# =============================================================== S1
echo "=== S1: every в трех формах (m/h/d) принимается при create ==="
SPEC1M=$(write_event_spec "s1-every-m" 'schedule:
  every: 5m
  text: "s1m"')
assert "S1: every 5m принято" 0 "$RC" agent create s1-every-m --spec "$SPEC1M"
[[ "$(yaml_get "$SPEC1M" 'd["schedule"]["every"]')" == "5m" ]] && ok || fail "S1: every=5m сохранен в спеке"

SPEC1H=$(write_event_spec "s1-every-h" 'schedule:
  every: 2h
  text: "s1h"')
assert "S1: every 2h принято" 0 "$RC" agent create s1-every-h --spec "$SPEC1H"

SPEC1D=$(write_event_spec "s1-every-d" 'schedule:
  every: 1d
  text: "s1d"')
assert "S1: every 1d принято" 0 "$RC" agent create s1-every-d --spec "$SPEC1D"

# =============================================================== S2
echo "=== S2: at принимается ==="
SPEC2=$(write_event_spec "s2-at" 'schedule:
  at: "09:00"
  text: "s2"')
assert "S2: at принято" 0 "$RC" agent create s2-at --spec "$SPEC2"
[[ "$(yaml_get "$SPEC2" 'd["schedule"]["at"]')" == "09:00" ]] && ok || fail "S2: at=09:00 сохранен в спеке"

# =============================================================== S3
echo "=== S3: every и at вместе - отказ при create ==="
SPEC3=$(write_event_spec "s3-both" 'schedule:
  every: 1h
  at: "09:00"
  text: "s3"')
assert "S3: every+at вместе -> отказ" 2 "$RC" agent create s3-both --spec "$SPEC3"
[[ ! -e "$CLAUDE_AGENTS_DIR/s3-both" ]] && ok || fail "S3: агент не создан"

# =============================================================== S4
echo "=== S4: schedule без text/json - отказ ==="
SPEC4=$(write_event_spec "s4-notext" 'schedule:
  every: 1h')
assert "S4: schedule без text/json -> отказ" 2 "$RC" agent create s4-notext --spec "$SPEC4"
[[ ! -e "$CLAUDE_AGENTS_DIR/s4-notext" ]] && ok || fail "S4: агент не создан"

# =============================================================== S5
echo "=== S5: every: 30s (меньше минуты, неверный суффикс) - отказ ==="
SPEC5=$(write_event_spec "s5-tooshort" 'schedule:
  every: 30s
  text: "s5"')
assert "S5: every 30s -> отказ" 2 "$RC" agent create s5-tooshort --spec "$SPEC5"
[[ ! -e "$CLAUDE_AGENTS_DIR/s5-tooshort" ]] && ok || fail "S5: агент не создан"

# =============================================================== S6
echo "=== S6: незнакомый ключ внутри schedule - отказ (молча проигнорированная опечатка недопустима) ==="
SPEC6=$(write_event_spec "s6-badkey" 'schedule:
  every: 1h
  text: "s6"
  wat: 1')
assert "S6: неизвестный ключ schedule.wat -> отказ" 2 "$RC" agent create s6-badkey --spec "$SPEC6"
[[ ! -e "$CLAUDE_AGENTS_DIR/s6-badkey" ]] && ok || fail "S6: агент не создан"

# =============================================================== S7
echo "=== S7: schedule при type: mission - отказ (schedule допустим только для type:event/source.kind:spool) ==="
SPEC7=$(write_mission_spec "s7-mission" 'schedule:
  every: 1h
  text: "s7"')
assert "S7: schedule на type:mission -> отказ" 2 "$RC" agent create s7-mission --spec "$SPEC7" --mission "$MISSION_MD"
[[ ! -e "$CLAUDE_AGENTS_DIR/s7-mission" ]] && ok || fail "S7: агент не создан"

# =============================================================== S8
echo "=== S8: сетка every глобальная - тот же слот для двух НЕЗАВИСИМЫХ агентов в одном часовом окне; иной слот в следующем часе ==="
# Падает, если слот считается не как floor(unix/N)*N от глобальной эпохи, а
# как локальный счетчик (напр. "N-й тик с момента create" или "N-й тик с
# момента появления schedule") - тогда два независимо созданных агента,
# тикнутые в разное время внутри одного и того же часа, получили бы РАЗНЫЙ
# last_slot вместо одинакового.
AGS8A=$(mk_ticking_agent "s8-a" 'schedule:
  every: 1h
  text: "s8a"')
tick "$AGS8A" "1773130320"; RCS8A1=$?
[[ "$RCS8A1" == 0 ]] && ok || fail "S8: первый тик агента A (got $RCS8A1: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s8-a)" == "0" ]] && ok || fail "S8: первый тик A не порождает событие"
LS8A1=$(sched_get "$AGS8A" 'd.get("last_slot")')

AGS8B=$(mk_ticking_agent "s8-b" 'schedule:
  every: 1h
  text: "s8b"')
tick "$AGS8B" "1773132420"; RCS8B1=$?
[[ "$RCS8B1" == 0 ]] && ok || fail "S8: первый тик агента B (got $RCS8B1: $(cat "$TMP/tick.err"))"
LS8B1=$(sched_get "$AGS8B" 'd.get("last_slot")')
[[ "$LS8A1" == "$LS8B1" ]] && ok \
  || fail "S8: тот же часовой слот для двух независимых агентов (got A=$LS8A1 B=$LS8B1)"

tick "$AGS8A" "1773133500"; RCS8A2=$?
[[ "$RCS8A2" == 0 ]] && ok || fail "S8: второй тик A (следующий час) (got $RCS8A2: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s8-a)" == "1" ]] && ok || fail "S8: смена часа -> ровно одно событие"
LS8A2=$(sched_get "$AGS8A" 'd.get("last_slot")')
[[ "$LS8A2" != "$LS8A1" ]] && ok || fail "S8: last_slot изменился при смене часа"

# =============================================================== S9
echo "=== S9: at дает ПОСЛЕДНЕЕ НАСТУПИВШЕЕ HH:MM - до него в этот день слот вчерашний, после - сегодняшний ==="
# Падает на первой редакции контракта ("слот = сегодняшние HH:MM всегда, без
# отката на вчера"): та версия давала бы слот day2 09:00 уже на тике day2
# 00:30 (HH:MM в тот день еще не наступило) - событие ушло бы почти в
# полночь вместо 09:00. Доказано мутацией: docs/dev/ на скретч-копии со
# снятым откатом "candidate -= timedelta(days=1)" - see финальный ответ.
AGS9=$(mk_ticking_agent "s9-at" 'schedule:
  at: "09:00"
  text: "s9"')
tick "$AGS9" "1773133500"; RCS9A=$?
[[ "$RCS9A" == 0 ]] && ok || fail "S9: первый тик (day1, после 09:00) (got $RCS9A: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9-at)" == "0" ]] && ok || fail "S9: первый тик не порождает событие"
LS9_1=$(sched_get "$AGS9" 'd.get("last_slot")')

tick "$AGS9" "1773135600"; RCS9B=$?
[[ "$RCS9B" == 0 ]] && ok || fail "S9: второй тик тот же день (got $RCS9B: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9-at)" == "0" ]] && ok || fail "S9: в пределах того же дня - без нового события"
LS9_2=$(sched_get "$AGS9" 'd.get("last_slot")')
[[ "$LS9_2" == "$LS9_1" ]] && ok || fail "S9: слот стабилен в течение дня"

tick "$AGS9" "1773189000"; RCS9BOUND=$?  # day2 00:30 - после полуночи, но ДО 09:00
[[ "$RCS9BOUND" == 0 ]] && ok || fail "S9: тик day2 00:30, до 09:00 (got $RCS9BOUND: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9-at)" == "0" ]] && ok \
  || fail "S9: до наступления HH:MM в новый день - слот еще вчерашний, событие НЕ порождается (не срабатывает в полночь)"
LS9_BOUND=$(sched_get "$AGS9" 'd.get("last_slot")')
[[ "$LS9_BOUND" == "$LS9_1" ]] && ok || fail "S9: last_slot не сдвинулся до наступления 09:00"

tick "$AGS9" "1773219900"; RCS9C=$?
[[ "$RCS9C" == 0 ]] && ok || fail "S9: тик на следующий день после 09:00 (got $RCS9C: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9-at)" == "1" ]] && ok || fail "S9: новый день, после 09:00 -> ровно одно новое событие"
LS9_3=$(sched_get "$AGS9" 'd.get("last_slot")')
[[ "$LS9_3" != "$LS9_1" ]] && ok || fail "S9: слот изменился на следующий день"

# =============================================================== S9a
echo "=== S9a: at:09:00 за сутки дает РОВНО ОДНО событие, и оно приходит в 09:00, а не в 00:00 ==="
AGS9A=$(mk_ticking_agent "s9a-daily" 'schedule:
  at: "09:00"
  text: "s9a"')
tick "$AGS9A" "1773133500"; RCS9A1=$?  # day1 09:05 - фиксация
[[ "$RCS9A1" == 0 ]] && ok || fail "S9a: фиксация (got $RCS9A1: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9a-daily)" == "0" ]] && ok || fail "S9a: фиксация без события"
tick "$AGS9A" "1773189000"; RCS9A2=$?  # day2 00:30
[[ "$RCS9A2" == 0 ]] && ok || fail "S9a: day2 00:30 (got $RCS9A2: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9a-daily)" == "0" ]] && ok || fail "S9a: в 00:30 события еще нет (не в полночь)"
tick "$AGS9A" "1773219540"; RCS9A3=$?  # day2 08:59 - за минуту до 09:00
[[ "$RCS9A3" == 0 ]] && ok || fail "S9a: day2 08:59 (got $RCS9A3: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9a-daily)" == "0" ]] && ok || fail "S9a: за минуту до 09:00 события еще нет"
tick "$AGS9A" "1773219900"; RCS9A4=$?  # day2 09:05 - после 09:00
[[ "$RCS9A4" == 0 ]] && ok || fail "S9a: day2 09:05 (got $RCS9A4: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9a-daily)" == "1" ]] && ok || fail "S9a: ровно одно событие за сутки, пришло в 09:00"
tick "$AGS9A" "1773252000"; RCS9A5=$?  # day2 18:00 - позже тем же днем
[[ "$RCS9A5" == 0 ]] && ok || fail "S9a: day2 18:00 (got $RCS9A5: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s9a-daily)" == "1" ]] && ok || fail "S9a: до конца дня новых событий не появилось (по-прежнему одно)"

# =============================================================== S9b
echo "=== S9b: неразбираемый CLAUDE_AGENT_NOW - отказ, а не тихий откат на системное время ==="
AGS9B=$(mk_ticking_agent "s9b-badnow" 'schedule:
  every: 1h
  text: "s9b"')
CLAUDE_AGENT_NOW="not-a-number" "$RUN" schedule-tick "$AGS9B" \
  >"$TMP/tick.out" 2>"$TMP/tick.err"; RCS9B1=$?
[[ "$RCS9B1" != 0 ]] && ok || fail "S9b: CLAUDE_AGENT_NOW=not-a-number -> отказ (got $RCS9B1)"
[[ -s "$TMP/tick.err" ]] && ok || fail "S9b: сообщение об ошибке непусто"
[[ ! -f "$AGS9B/schedule.json" ]] && ok || fail "S9b: schedule.json не создан на отказавшем тике"
CLAUDE_AGENT_NOW="2026-07-27T09:00:00Z" "$RUN" schedule-tick "$AGS9B" \
  >"$TMP/tick.out" 2>"$TMP/tick.err"; RCS9B2=$?
[[ "$RCS9B2" != 0 ]] && ok || fail "S9b: CLAUDE_AGENT_NOW=ISO8601 -> отказ, не молчаливый откат на системное время (got $RCS9B2)"

# =============================================================== S10
echo "=== S10: payload детерминирован по слоту - повторная попытка того же слота НЕ дает die(2) ==="
# Падает, если payload зависит от чего-то нестабильного между попытками
# (реальное время вызова, pid, счетчик попыток и т.п.): тогда spool-put
# отобьет повтор как die(2) (тот же --id, другой payload), и tick3 (retry)
# завершится ненулевым кодом вместо идемпотентного успеха.
AGS10=$(mk_ticking_agent "s10-det" 'schedule:
  every: 1m
  text: "s10"')
tick "$AGS10" "1775037600"; RCS10_1=$?
[[ "$RCS10_1" == 0 ]] && ok || fail "S10: baseline-тик (got $RCS10_1)"
cp "$AGS10/schedule.json" "$TMP/s10-snapshot.json"
tick "$AGS10" "1775037660"; RCS10_2=$?
[[ "$RCS10_2" == 0 ]] && ok || fail "S10: тик, продвигающий слот, событие 1 (got $RCS10_2: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s10-det)" == "1" ]] && ok || fail "S10: fixture - ровно одно событие после продвижения"
cp "$TMP/s10-snapshot.json" "$AGS10/schedule.json"  # откат last_slot назад - симуляция "второй попытки" того же слота
tick "$AGS10" "1775037660"; RCS10_3=$?
[[ "$RCS10_3" == 0 ]] && ok || fail "S10: повторная попытка того же слота НЕ die(2) (got $RCS10_3: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s10-det)" == "1" ]] && ok || fail "S10: повторная попытка не создала второе событие"

# =============================================================== S11
echo "=== S11: повтор в том же слоте - идемпотентный no-op (проверка НЕ полагается на дедуп spool-put) ==="
# Падает, если schedule-tick не проверяет last_slot==текущий_слот ДО вызова
# spool-put, а всегда пытается публиковать: тогда второй тик того же слота
# реально дернет spool-put, который под тиной cap-байтов упадет die(6), и
# tick2 вернет ненулевой код вместо тихого no-op.
AGS11=$(mk_ticking_agent "s11-noop" 'schedule:
  every: 1m
  text: "s11"')
tick "$AGS11" "1775044800"; RCS11_1=$?
[[ "$RCS11_1" == 0 ]] && ok || fail "S11: baseline-тик (got $RCS11_1)"
tick "$AGS11" "1775044860"; RCS11_2=$?
[[ "$RCS11_2" == 0 ]] && ok || fail "S11: тик, продвигающий слот (got $RCS11_2: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s11-noop)" == "1" ]] && ok || fail "S11: fixture - одно событие после продвижения"
CLAUDE_AGENT_EVENT_MAX_BYTES=1 CLAUDE_AGENT_NOW="1775044860" "$RUN" schedule-tick "$AGS11" \
  >"$TMP/tick.out" 2>"$TMP/tick.err"; RCS11_3=$?
[[ "$RCS11_3" == 0 ]] && ok \
  || fail "S11: повтор в том же слоте - настоящий no-op, spool-put не вызывается (got $RCS11_3: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s11-noop)" == "1" ]] && ok || fail "S11: второго события нет"

# =============================================================== S12
echo "=== S12: первый тик после появления schedule события не порождает, только фиксирует слот ==="
AGS12=$(mk_ticking_agent "s12-first" 'schedule:
  every: 1m
  text: "s12"')
tick "$AGS12" "1775124000"; RCS12=$?
[[ "$RCS12" == 0 ]] && ok || fail "S12: первый тик exit 0 (got $RCS12: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s12-first)" == "0" ]] && ok || fail "S12: событие не создано"
[[ -f "$AGS12/schedule.json" ]] && ok || fail "S12: schedule.json создан"
[[ -n "$(sched_get "$AGS12" 'd.get("last_slot")')" ]] && ok || fail "S12: last_slot зафиксирован"
[[ "$(sched_get "$AGS12" 'd.get("last_fired_at")')" == "None" ]] && ok || fail "S12: last_fired_at пуст (событие не было)"

# =============================================================== S13 / S14 / S15
echo "=== S13: простой в шесть слотов дает ОДНО событие, а не шесть ==="
# Падает, если реализация досылает по одному событию на каждый пропущенный
# слот (баг "полный backfill"): тогда после простоя в 6 слотов в spool
# появилось бы 6 новых событий вместо одного.
AGS13=$(mk_ticking_agent "s13-catchup" 'schedule:
  every: 1m
  json: {"kind": "daily-check"}')
tick "$AGS13" "1775210400"; RCS13_1=$?
[[ "$RCS13_1" == 0 ]] && ok || fail "S13: baseline-тик (got $RCS13_1)"
[[ "$(spool_count s13-catchup)" == "0" ]] && ok || fail "S13: baseline - без события"
LS13_0=$(sched_get "$AGS13" 'd.get("last_slot")')

tick "$AGS13" "1775210760"; RCS13_2=$?  # простой в 6 слотов (every: 1m)
[[ "$RCS13_2" == 0 ]] && ok || fail "S13: тик после простоя (got $RCS13_2: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s13-catchup)" == "1" ]] && ok || fail "S13: ровно одно событие после простоя в 6 слотов (не 6)"
LS13_1=$(sched_get "$AGS13" 'd.get("last_slot")')
[[ "$LS13_1" != "$LS13_0" ]] && ok || fail "S13: last_slot продвинулся к ТЕКУЩЕМУ слоту"

echo "=== S14: число пропущенных слотов попало в skipped_since (schedule.json) и в payload события ==="
# §4 (контракт исправлен): skipped_since - число слотов МЕЖДУ last_slot и
# текущим, не включая ни тот, ни другой; простой в 6 слотов (every:1m) дает
# ordinal-last_ordinal=6, skipped=6-1=5.
SKIPPED_SCHED13=$(sched_get "$AGS13" 'd.get("skipped_since")')
[[ "$SKIPPED_SCHED13" == "5" ]] && ok \
  || fail "S14: skipped_since в schedule.json == 5 (got $SKIPPED_SCHED13)"
EV13=$(last_spool_file s13-catchup)
[[ -n "$EV13" ]] && ok || fail "S14: fixture - событие после простоя реально в spool"
SKIPPED_PAYLOAD13=$(jq_file "$EV13" 'd.get("skipped_since")')
[[ "$SKIPPED_PAYLOAD13" == "$SKIPPED_SCHED13" ]] && ok \
  || fail "S14: skipped_since в payload события совпадает со значением в schedule.json (payload=$SKIPPED_PAYLOAD13, schedule.json=$SKIPPED_SCHED13)"

echo "=== S14b: форма text - skipped_since НЕ подмешивается, payload остается ровно заданной строкой ==="
# Падает, если schedule-tick кладет text-форму как {"text":..., "skipped_since":...}
# вместо ровно заданной строки (S13/S14 используют json-форму и это не ловят).
EV13B=$(last_spool_file s9-at)  # s9-at (S9) - text-форма, к этому месту уже дало одно событие
[[ -n "$EV13B" ]] && ok || fail "S14b: fixture - событие text-формы есть в spool"
[[ "$(jq_file "$EV13B" 'd.get("text")')" == "s9" ]] && ok \
  || fail "S14b: text-payload равен ровно заданной строке из спеки"
[[ "$(jq_file "$EV13B" '"skipped_since" not in d')" == "True" ]] && ok \
  || fail "S14b: skipped_since отсутствует в payload text-формы"

echo "=== S15: после наверстывания сетка продолжается штатно (следующий обычный слот снова дает ровно одно событие) ==="
tick "$AGS13" "1775210820"; RCS13_3=$?
[[ "$RCS13_3" == 0 ]] && ok || fail "S15: штатный тик после наверстывания (got $RCS13_3: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s13-catchup)" == "2" ]] && ok || fail "S15: еще одно (второе всего) событие на обычном шаге"
LS13_2=$(sched_get "$AGS13" 'd.get("last_slot")')
[[ "$LS13_2" != "$LS13_1" ]] && ok || fail "S15: last_slot продвинулся дальше"
[[ "$(sched_get "$AGS13" 'd.get("skipped_since")')" == "0" ]] && ok \
  || fail "S15: skipped_since=0 на обычном (не наверстывающем) шаге"

# =============================================================== S16
echo "=== S16: крах между spool-put и записью last_slot - следующий тик доигрывает, второго события нет ==="
# Падает, если после успешного дедуп-ответа spool-put ("уже доставлено")
# реализация не дописывает last_slot (например, пишет last_slot только в
# ветке "публикация была свежей", забывая ветку "уже существует"): тогда
# после восстановления last_slot останется навсегда устаревшим, и агент
# будет бесконечно "довыполнять" один и тот же слот на каждом следующем тике.
AGS16=$(mk_ticking_agent "s16-crash" 'schedule:
  every: 1m
  text: "s16"')
tick "$AGS16" "1775300400"; RCS16_1=$?
[[ "$RCS16_1" == 0 ]] && ok || fail "S16: baseline-тик (got $RCS16_1)"
LS16_0=$(sched_get "$AGS16" 'd.get("last_slot")')
cp "$AGS16/schedule.json" "$TMP/s16-pre-advance.json"   # состояние ДО шага, который сейчас продвинет слот
tick "$AGS16" "1775300460"; RCS16_2=$?
[[ "$RCS16_2" == 0 ]] && ok || fail "S16: тик, продвигающий слот и публикующий событие (got $RCS16_2: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s16-crash)" == "1" ]] && ok || fail "S16: fixture - событие реально опубликовано"
LS16_ADVANCED=$(sched_get "$AGS16" 'd.get("last_slot")')
# Независимая проверка (НЕ сравнение состояния с самим собой): этот тик
# ДЕЙСТВИТЕЛЬНО продвинул last_slot вперед от baseline. Без этой проверки
# падает именно защита от бага "успешный spool-put не персистится в
# last_slot" - следующие сравнения (LS16_ADVANCED) молча сверяли бы уже
# сломанное значение само с собой и оставались бы зелеными при любом
# поведении (см. финальный ответ).
[[ "$LS16_ADVANCED" != "$LS16_0" ]] && ok || fail "S16: last_slot реально продвинулся этим тиком (не совпадает с baseline)"
cp "$TMP/s16-pre-advance.json" "$AGS16/schedule.json"   # откат ТОЛЬКО last_slot - симуляция "spool-put прошел, запись last_slot не успела"
tick "$AGS16" "1775300460"; RCS16_3=$?         # тот же слот - "доигрывание" после гипотетического краха
[[ "$RCS16_3" == 0 ]] && ok || fail "S16: тик-доигрывание завершается успешно (got $RCS16_3: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s16-crash)" == "1" ]] && ok || fail "S16: второго события НЕ появилось (дедуп по --id)"
[[ "$(sched_get "$AGS16" 'd.get("last_slot")')" == "$LS16_ADVANCED" ]] && ok \
  || fail "S16: last_slot корректно доигран до текущего слота после восстановления"

# =============================================================== S17
echo "=== S17: desired: stopped - расписание не наполняет очередь ==="
AGS17=$(mk_ticking_agent "s17-stopped" 'schedule:
  every: 1m
  text: "s17"')
tick "$AGS17" "1775394000"; RCS17_1=$?
[[ "$RCS17_1" == 0 ]] && ok || fail "S17: baseline-тик (got $RCS17_1)"
"$RC" agent stop s17-stopped >/dev/null 2>"$TMP/s17-stop.err"; RCS17STOP=$?
[[ "$RCS17STOP" == 0 ]] && ok || fail "S17: fixture - agent stop (got $RCS17STOP: $(cat "$TMP/s17-stop.err"))"
[[ "$(ctrl_get "$AGS17" 'd.get("desired")')" == "stopped" ]] && ok || fail "S17: fixture - desired=stopped"
tick "$AGS17" "1775394060"; RCS17_2=$?
[[ "$RCS17_2" == 0 ]] && ok || fail "S17: тик на остановленном агенте - без ошибки (got $RCS17_2: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s17-stopped)" == "0" ]] && ok || fail "S17: события нет, пока агент stopped"
"$RC" agent start s17-stopped >/dev/null 2>"$TMP/s17-start.err"
tick "$AGS17" "1775394300"; RCS17_3=$?
[[ "$RCS17_3" == 0 ]] && ok || fail "S17: тик после возобновления (got $RCS17_3: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s17-stopped)" -le "1" ]] && ok \
  || fail "S17: после возобновления - не более одного события (не флуд по накопленным слотам, got $(spool_count s17-stopped))"

# =============================================================== S18
echo "=== S18: backpressure spool-put (кап, die 6) - шаг отказал, last_slot НЕ сдвинулся, следующий тик повторяет тот же слот ==="
AGS18=$(mk_ticking_agent "s18-backpressure" 'schedule:
  every: 1m
  text: "s18"')
tick "$AGS18" "1775484000"; RCS18_1=$?
[[ "$RCS18_1" == 0 ]] && ok || fail "S18: baseline-тик (got $RCS18_1)"
[[ "$(ctrl_get "$AGS18" 'd.get("attention")')" == "None" ]] && ok || fail "S18: fixture - attention пуст изначально"
LS18_0=$(sched_get "$AGS18" 'd.get("last_slot")')
CLAUDE_AGENT_EVENT_MAX_BYTES=1 CLAUDE_AGENT_NOW="1775484060" "$RUN" schedule-tick "$AGS18" \
  >"$TMP/tick.out" 2>"$TMP/tick.err"; RCS18_2=$?
[[ "$RCS18_2" != 0 ]] && ok || fail "S18: тик с капом spool-put отказывает (exit != 0, got $RCS18_2)"
[[ "$(spool_count s18-backpressure)" == "0" ]] && ok || fail "S18: события не появилось при backpressure"
[[ "$(sched_get "$AGS18" 'd.get("last_slot")')" == "$LS18_0" ]] && ok || fail "S18: last_slot НЕ сдвинулся после отказа"
tick "$AGS18" "1775484060"; RCS18_3=$?  # тот же слот, кап снят - retry
[[ "$RCS18_3" == 0 ]] && ok || fail "S18: следующий тик (тот же слот, кап снят) доигрывает (got $RCS18_3: $(cat "$TMP/tick.err"))"
[[ "$(spool_count s18-backpressure)" == "1" ]] && ok || fail "S18: событие опубликовано после retry"
[[ "$(sched_get "$AGS18" 'd.get("last_slot")')" != "$LS18_0" ]] && ok || fail "S18: last_slot продвинулся после успешного retry"

# =============================================================== S19
echo "=== S19: иной ненулевой код spool-put (файловая небезопасность, die 7) - отказ шага с attention ==="
AGS19=$(mk_ticking_agent "s19-otherfail" 'schedule:
  every: 1m
  text: "s19"')
tick "$AGS19" "1775574000"; RCS19_1=$?
[[ "$RCS19_1" == 0 ]] && ok || fail "S19: baseline-тик (got $RCS19_1)"
[[ "$(ctrl_get "$AGS19" 'd.get("attention")')" == "None" ]] && ok || fail "S19: fixture - attention пуст изначально"
LS19_0=$(sched_get "$AGS19" 'd.get("last_slot")')
rm -rf "$CLAUDE_AGENT_SPOOL_BASE/s19-otherfail"
mkdir -p "$TMP/elsewhere-s19"
ln -s "$TMP/elsewhere-s19" "$CLAUDE_AGENT_SPOOL_BASE/s19-otherfail"  # симлинк вместо spool -> spool-put die(7)
tick "$AGS19" "1775574060"; RCS19_2=$?
[[ "$RCS19_2" != 0 ]] && ok || fail "S19: тик отказывает на небезопасном spool (exit != 0, got $RCS19_2)"
[[ "$(ctrl_get "$AGS19" 'd.get("attention") is not None')" == "True" ]] && ok \
  || fail "S19: attention выставлен на агенте"
[[ "$(sched_get "$AGS19" 'd.get("last_slot")')" == "$LS19_0" ]] && ok || fail "S19: last_slot не сдвинулся при отказе"

# =============================================================== S20
echo "=== S20: битый/нечитаемый schedule.json - attention по этому агенту, другой агент не задет ==="
AGS20=$(mk_ticking_agent "s20-broken" 'schedule:
  every: 1m
  text: "s20"')
printf 'not valid json {{{' > "$AGS20/schedule.json"
tick "$AGS20" "1775664000"; RCS20_1=$?
[[ "$RCS20_1" != 0 ]] && ok || fail "S20: тик на битом schedule.json отказывает (exit != 0, got $RCS20_1)"
[[ -s "$TMP/tick.err" ]] && ok || fail "S20: сообщение об ошибке непусто"
[[ "$(ctrl_get "$AGS20" 'd.get("attention") is not None')" == "True" ]] && ok \
  || fail "S20: attention выставлен на битом агенте"

AGS20OK=$(mk_ticking_agent "s20-ok" 'schedule:
  every: 1m
  text: "s20ok"')
tick "$AGS20OK" "1775664000"; RCS20_2=$?
[[ "$RCS20_2" == 0 ]] && ok || fail "S20: соседний агент тикает штатно, несмотря на битого (got $RCS20_2: $(cat "$TMP/tick.err"))"

# =============================================================== S21
echo "=== S21: агент без блока schedule - шаг no-op, schedule.json не создается ==="
AGS21=$(mk_ticking_agent "s21-none" "")
tick "$AGS21" "1775754000"; RCS21=$?
[[ "$RCS21" == 0 ]] && ok || fail "S21: тик без schedule - exit 0 (got $RCS21: $(cat "$TMP/tick.err"))"
[[ ! -f "$AGS21/schedule.json" ]] && ok || fail "S21: schedule.json не создан"
[[ "$(spool_count s21-none)" == "0" ]] && ok || fail "S21: событий нет"

# =============================================================== S22
echo "=== S22: сквозное - через РЕАЛЬНЫЙ проход claude-agent-reconciler --once, агент получает событие в spool, intake его подхватывает ==="
BASE_S22="$TMP/agents-s22"; mkdir -p "$BASE_S22"
RCDIR_S22="$TMP/reconciler-s22"; mkdir -p "$RCDIR_S22"
PROJ_S22="$TMP/proj-s22"; mkdir -p "$PROJ_S22"
SPEC_S22="$TMP/spec-s22-e2e.yaml"
cat > "$SPEC_S22" <<EOF
schema: 1
name: s22-e2e
type: event
role: none
project: $PROJ_S22
goal: "schedule S22 e2e"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: none
schedule:
  every: 1m
  text: "s22"
EOF
CLAUDE_AGENTS_DIR="$BASE_S22" "$RC" agent create s22-e2e --spec "$SPEC_S22" >/dev/null 2>"$TMP/s22-create.err"
RCS22C=$?
[[ "$RCS22C" == 0 ]] && ok || fail "S22: fixture - create (got $RCS22C: $(cat "$TMP/s22-create.err"))"
CLAUDE_AGENTS_DIR="$BASE_S22" "$RC" agent start s22-e2e >/dev/null 2>"$TMP/s22-start.err"
RCS22S=$?
[[ "$RCS22S" == 0 ]] && ok || fail "S22: fixture - start (got $RCS22S: $(cat "$TMP/s22-start.err"))"
AGS22="$BASE_S22/s22-e2e"
# baseline-тик (прямой вызов - только чтобы зафиксировать точку отсчета слота,
# см. S12: первый тик не порождает событие; сам предмет S22 - следующий проход,
# сделанный РЕАЛЬНЫМ реконсилером, не имитацией)
CLAUDE_AGENTS_DIR="$BASE_S22" tick "$AGS22" "1775844000"; RCS22T1=$?
[[ "$RCS22T1" == 0 ]] && ok || fail "S22: fixture - baseline-тик (got $RCS22T1)"
CLAUDE_AGENTS_DIR="$BASE_S22" CLAUDE_RECONCILER_DIR="$RCDIR_S22" CLAUDE_AGENT_SPOOL_BASE="$CLAUDE_AGENT_SPOOL_BASE" \
  CLAUDE_AGENT_NOW="1775844060" "$RECON" --once >/dev/null 2>"$TMP/s22-recon.err"; RCS22R=$?
[[ "$RCS22R" == 0 ]] && ok || fail "S22: реальный проход реконсилера завершается штатно (got $RCS22R: $(cat "$TMP/s22-recon.err"))"
[[ "$(spool_count s22-e2e)" == "1" ]] && ok || fail "S22: событие появилось в spool за реальный проход"
# НЕ ls по inbox/pending: реальный --once проход не только делает intake,
# но и в том же проходе может успеть поднять executor (lease active),
# который сам же гоняет конверт pending->inflight (и дальше retry/
# deadletter) - гонка с любой проверкой конкретного inbox-каталога
# (обнаружено эмпирически: конверт то в inflight, то кратковременно виден
# в обоих сразу при retry). Предмет S22 - что intake вообще подхватил
# событие из spool курсором, а курсор дальше исполнителем не двигается
# и потому стабилен как индикатор.
S22_CURSOR=$("$RUN" inbox-status "$AGS22" 2>/dev/null | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["cursor"])' 2>/dev/null)
[[ "$S22_CURSOR" == "1" ]] && ok || fail "S22: intake (в том же проходе реконсилера) подхватил событие (cursor got $S22_CURSOR)"

echo
echo "test-agent-schedule: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
