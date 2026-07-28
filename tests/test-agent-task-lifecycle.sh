#!/usr/bin/env bash
# Tests for V2.7a: рождение задачи (`claude-rc agent new-task`) и заявка о
# готовности (bin/claude-agent-done).
# Контракт: docs/design-2026-07-26-v2.7a-task-birth-and-done.md §6 (кейсы N1-N15).
#
# Написано с чистого листа по спеке (SDD, RED-фаза): реализация V2.7a НЕ
# читана - bin/claude-rc-agent, bin/claude-agent-run, bin/claude-agent-reconciler,
# bin/claude-agent-tgbot, bin/claude-agent-done ни разу не открывались через
# Read. Публичный контракт прочитан из самой спеки V2.7a, из
# design-2026-07-25-v2.1-workspace-permissions.md (worktree/direct/none,
# снапшот-манифест) и design-2026-07-26-v2.4-permission-gate.md
# (envelope_in_inflight); стиль и вспомогательные функции - из
# tests/test-agent-question.sh, tests/test-agent-tg-cards.sh,
# tests/test-agent-reminders.sh и tests/test-agent-workspace.sh (тесты, не
# реализация - используются только их публично наблюдаемые CLI-вызовы:
# `claude-rc agent create <name> --spec <file>` создает workorktree в
# agents/<name>/work, ветка task/<name>-<inc8>, HEAD worktree == HEAD project
# на момент create).
#
# Обновление после ревью координатора (спека дополнена §3/§4/§6, ambiguity-
# заметки предыдущей версии закрыты явными правками контракта):
# - CLI-точка входа для карточки "готово" зафиксирована явно: подкоманда
#   `claude-agent-run done-notify <agent-dir>` (реконсилер зовет ее на тике
#   для каждого агента, как question-reminders в V2.6) - вместо
#   черноящичного предположения про глобальный `claude-agent-reconciler
#   --once` из предыдущей версии. Изоляция фикстур (отдельный base-каталог
#   на кейс) сохранена по требованию координатора, хотя теперь и не
#   обязательна технически (done-notify берет явный agent-dir, не подметает
#   CLAUDE_AGENTS_DIR целиком).
# - Схема аргументов alert-вызова зафиксирована (§4): `<agent> "задача
#   готова" <человекочитаемая сводка> <json-detail>`, detail = {kind:"done",
#   agent, project, summary, commit_sha, branch, changes, empty}. N12-N14
#   теперь проверяют позиции и содержимое detail, не только факт вызова.
# - workspace:direct (§3): claude-agent-done сам не считает changes (снимок
#   "до" живет только в памяти раннера) - ставит changes:null; раннер в
#   ok-ветке дописывает changes/empty в уже существующий done.json под
#   done.lock. N9 проверяет ОБА среза: сразу после вызова claude-agent-done
#   (changes:null - не дефект) и после возврата "$RUN" step (changes уже
#   дописан).
# - Код возврата отказа claude-agent-done зафиксирован явно как exit 2
#   (§3) - N7/N10/N11 проверяют его без оговорки "предположительно".
# - N15 (по разбору координатора): существующая тревога планировщика по
#   самодельной фикстуре без валидного control.json (`control_invalid` и
#   родня) - отдельный, не относящийся к этому этапу путь. Проверяется
#   отсутствие ИМЕННО пуша с detail.kind=="done", а не отсутствие любых
#   алертов вообще.
set -u
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/../bin/claude-rc"
RUN="$HERE/../bin/claude-agent-run"
DONE="$HERE/../bin/claude-agent-done"
COMMIT="$HERE/../bin/claude-agent-commit"
RECON="$HERE/../bin/claude-agent-reconciler"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# HOME переопределен: bin/claude-agent-run без CLAUDE_AGENT_LESSONS_JOURNAL_DIR
# резолвит ~/.claude-control/lessons от реального $HOME.
export HOME="$TMP/home"
mkdir -p "$HOME"
# CLAUDE_CONFIG_DIR - ОТДЕЛЬНО от HOME (по образцу test-agent-run.sh/
# test-agent-workspace.sh): у claude-agent-run фолбэк ~/.claude только БЕЗ
# явного CLAUDE_CONFIG_DIR, а он в среде этой машины уже выставлен на боевой
# ~/.claude - HOME-фолбэк его не перебивает. Проверено черным ящиком: без
# этой строки preseed_trust (infra_probe/transcripts_cleanup туда же) для
# workspace:direct реально дописывал боевой ~/.claude/.claude.json записями
# projects[<фикстура>] на каждом прогоне ("$RUN" step, N9/N22) - боевой файл
# уже нес ~1000 таких мусорных tmp-путей от прошлых прогонов этого же теста.
export CLAUDE_CONFIG_DIR="$TMP/cfg"
mkdir -p "$CLAUDE_CONFIG_DIR"
# _integrate_merge_worktree (bin/claude-agent-run) реально мержит фикстуры
# (`git merge --no-edit`) без явных GIT_AUTHOR_*/GIT_COMMITTER_* - при
# non-ff-мерже это commit, которому нужна identity; с боевым $HOME она
# бралась молча из ~/.gitconfig, изолированному нужна своя.
git config --global user.name "test" >/dev/null
git config --global user.email "test@test.invalid" >/dev/null

export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_AGENT_SPOOL_BASE="$TMP/spool"
export CLAUDE_AGENT_PROBE_CMD=/usr/bin/true
export CLAUDE_AGENT_GENERATION=1 CLAUDE_AGENT_ATTEMPT=test-attempt
# claude-agent-reconciler (и, судя по всему, разделяемое с ним состояние)
# держит блокировку/кэш "single instance" по умолчанию в реальном (не
# тестовом) месте - обнаружено черным ящиком ("another reconciler is
# running" на раннем прогоне этой суиты на этой машине, где может крутиться
# боевой инстанс). CLAUDE_RECONCILER_DIR - тот же тестовый шов, что и в
# tests/test-mission-drain.sh - уводит его в одноразовый каталог; держим на
# всякий случай и для done-notify (§4: это подкоманда, которую боевой
# reconciler зовет на своем тике, состояние может быть общим).
export CLAUDE_RECONCILER_DIR="$TMP/reconciler"
mkdir -p "$CLAUDE_RECONCILER_DIR"

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
jq_str() { # <json-текст> <py-expr over d, распарсенного из этого текста>
  python3 -c 'import json,sys
d=json.loads(sys.argv[1])
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}
yaml_get() { # <file> <py-expr over dict d (yaml.safe_load)>
  python3 -c 'import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2" 2>/dev/null
}
yaml_goal_eq() { # <specfile> <expected-text> -> True/False (сравнение байт-в-байт)
  python3 -c 'import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
sys.stdout.write(str(d.get("goal") == sys.argv[2]))' "$1" "$2" 2>/dev/null
}
yaml_has_key() { # <specfile> <keyname> -> True/False
  python3 -c 'import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
print(sys.argv[2] in d)' "$1" "$2" 2>/dev/null
}

mk_inflight() { # <agent-dir> <key> - синтетический конверт в inbox/inflight
  # (тот же прием, что ask_direct в test-agent-question.sh/test-agent-tg-cards.sh):
  # claude-agent-done обязан требовать реальный envelope_key в inflight
  # (V2.7a §3, общая функция envelope_in_inflight, V2.4 major 6).
  local dir="$1" key="$2"
  mkdir -p "$dir/inbox/inflight"
  printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"text":"stub-for-done"}}\n' \
    "$key" > "$dir/inbox/inflight/$key.json"
}
call_done() { # <agent-dir> <event-key> [опции claude-agent-done...]
  local dir="$1" key="$2"; shift 2
  CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" "$DONE" "$@"
}
mk_worktree_agent() { # <name> <project-path> -> печатает agent-dir; создает через
  # реальный "$RC agent create" (публичный контракт V2.1 §2) - никаких
  # догадок о внутреннем хранении incarnation/base, все берется от git.
  local name="$1" proj="$2"
  local specfile="$TMP/spec-$name.yaml"
  cat > "$specfile" <<EOF
schema: 1
name: $name
type: event
role: none
project: $proj
goal: "worktree fixture for $name"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
  "$RC" agent create "$name" --spec "$specfile" >/dev/null 2>"$TMP/create-$name.err"
  local rc=$?
  [[ "$rc" == 0 ]] && ok || fail "fixture: create $name (workspace:worktree) ($(cat "$TMP/create-$name.err"))"
  echo "$CLAUDE_AGENTS_DIR/$name"
}
mk_none_agent() { # <name> [extra-yaml] -> печатает agent-dir (spec.yaml от руки, без create)
  local name="$1" extra="${2:-}"
  local ag="$CLAUDE_AGENTS_DIR/$name"
  mkdir -p "$ag" "$CLAUDE_AGENT_SPOOL_BASE/$name"
  chmod 0700 "$CLAUDE_AGENT_SPOOL_BASE/$name"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
goal: "task-lifecycle unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
$extra
EOF
  echo "$ag"
}
mk_isolated_agent() { # <base-dir> <name> -> печатает agent-dir; spec.yaml (workspace:none) под base_dir/name
  # (для N12-N14/N15c: реконсилер --once проходит ГЛОБАЛЬНО по CLAUDE_AGENTS_DIR
  # - каждому такому кейсу нужен свой пустой base_dir с ровно одним агентом,
  # иначе done.json других N-кейсов дают лишние вызовы alert-команды)
  local base="$1" name="$2"
  local ag="$base/$name"
  mkdir -p "$ag"
  cat > "$ag/spec.yaml" <<EOF
schema: 1
name: $name
type: event
role: none
project: $PROJ_NONE
goal: "reconciler done-push unit test"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
  echo "$ag"
}
write_done_json() { # <agent-dir> <key> <summary> -> done.json requested/workspace:none/pushed_at:null
  local dir="$1" key="$2" summary="$3"
  python3 -c '
import json, sys
d = {"state": "requested", "requested_at": "2026-01-01T00:00:00Z", "envelope_key": sys.argv[2],
     "workspace": "none", "summary": sys.argv[3],
     "branch": None, "base": None, "commit_sha": None, "empty": None, "changes": None,
     "pushed_at": None, "accepted_at": None, "integrated_at": None, "cleaned_at": None, "archived_at": None}
json.dump(d, open(sys.argv[1] + "/done.json", "w"), ensure_ascii=False)
' "$dir" "$key" "$summary"
}
write_done_json_direct() { # <agent-dir> <key> <summary> [changes-json|null] ->
  # done.json requested/workspace:direct/pushed_at:null (N17/N22: фикстуры
  # workspace:direct с явным changes, в отличие от write_done_json/none).
  local dir="$1" key="$2" summary="$3" changes="${4:-null}"
  python3 -c '
import json, sys
d = {"state": "requested", "requested_at": "2026-01-01T00:00:00Z", "envelope_key": sys.argv[2],
     "workspace": "direct", "summary": sys.argv[3],
     "branch": None, "base": None, "commit_sha": None, "empty": None,
     "changes": json.loads(sys.argv[4]),
     "pushed_at": None, "accepted_at": None, "integrated_at": None, "cleaned_at": None, "archived_at": None}
json.dump(d, open(sys.argv[1] + "/done.json", "w"), ensure_ascii=False)
' "$dir" "$key" "$summary" "$changes"
}
mk_done_envelope() { # <agent-dir> <key> - синтетический конверт в inbox/done
  # (аудит V2.7a, major 6): done-notify обязан проверять, что envelope_key
  # реально соответствует завершившемуся прогону - конверту в inbox/done/
  # этого агента, иначе руками написанный done.json обходил бы весь
  # фенсинг claude-agent-done.
  local dir="$1" key="$2"
  mkdir -p "$dir/inbox/done"
  printf '{"schema":1,"key":"%s","source_ns":"test","native_id":"0","received_at":"2026-01-01T00:00:00Z","meta":{"attempts":0,"recoveries":0,"quarantined":false,"next_attempt_at":null,"history":[]},"payload":{"text":"stub-for-done"}}\n' \
    "$key" > "$dir/inbox/done/$key.json"
}
mk_alert_ok() { # <log-file> <script-path> - мок alert-команды: логирует argv (все args одной строкой), exit 0
  local log="$1" script="$2"
  cat > "$script" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$log"
printf '===\n' >> "$log"
EOF
  chmod +x "$script"
}
mk_alert_fail() { # <log-file> <script-path> - как mk_alert_ok, но exit 1
  local log="$1" script="$2"
  cat > "$script" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$log"
printf '===\n' >> "$log"
exit 1
EOF
  chmod +x "$script"
}
alert_block_count() { [[ -f "$1" ]] && grep -c '^===$' "$1" || echo 0; } # <log> -> число вызовов
alert_block_field() { # <log> <block-idx 1-based> <arg-idx 0-based> -> значение позиционного аргумента
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, bidx, aidx = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
blocks, cur = [], []
try:
    for line in open(path):
        line = line.rstrip("\n")
        if line == "===":
            blocks.append(cur); cur = []
        else:
            cur.append(line)
except FileNotFoundError:
    pass
b = blocks[bidx-1] if bidx-1 < len(blocks) else []
print(b[aidx] if aidx < len(b) else "")
PY
}
alert_detail() { alert_block_field "$1" "$2" 3; } # <log> <block-idx> -> 4-й аргумент (json-detail) как есть
alert_log_has_done_kind() { # <log> -> True/False - есть ли среди вызовов detail.kind=="done"
  python3 - "$1" <<'PY'
import sys, json
path = sys.argv[1]
blocks, cur = [], []
try:
    for line in open(path):
        line = line.rstrip("\n")
        if line == "===":
            blocks.append(cur); cur = []
        else:
            cur.append(line)
except FileNotFoundError:
    pass
found = False
for b in blocks:
    if len(b) >= 4:
        try:
            d = json.loads(b[3])
            if isinstance(d, dict) and d.get("kind") == "done":
                found = True
        except Exception:
            pass
print(found)
PY
}

# --- реестр проектов и шаблон спеки (V2.7a §2) ---
export CLAUDE_RC_PROJECTS_FILE="$TMP/projects.yaml"
export CLAUDE_RC_TASK_TEMPLATE="$TMP/task-template.yaml"
PROJ_NONE="$TMP/proj-none"; mkdir -p "$PROJ_NONE"
cat > "$CLAUDE_RC_PROJECTS_FILE" <<EOF
demoproj: $PROJ_NONE
EOF
# goal подставляется УЖЕ экранированным как валидный YAML-скаляр - поэтому в
# самом шаблоне плейсхолдер {{goal}} стоит БЕЗ ручных кавычек вокруг себя
# (иначе кавычка в тексте задачи ломала бы шаблон - см. §2/N4).
cat > "$CLAUDE_RC_TASK_TEMPLATE" <<'EOF'
schema: 1
name: {{name}}
type: event
role: none
project: {{project}}
goal: {{goal}}
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF

# --- mock claude: режимы ok (штатный успех) и done_direct (создает файл в
#     cwd=spec.project, затем сам вызывает claude-agent-done унаследованными
#     CLAUDE_AGENT_DIR/CLAUDE_AGENT_EVENT_KEY - тот же прием, что MOCK_ASK_BIN
#     в test-agent-question.sh) ---
MOCK="$TMP/mock-claude"
export MOCK_DONE_BIN="$DONE"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
mode=$(cat "${MOCK_MODE_FILE:-/dev/null}" 2>/dev/null || echo ok)
case "$mode" in
  ok) echo '{"type":"result","result":"processed","total_cost_usd":0.01}' ;;
  done_direct)
    echo "n9 direct change" > "${MOCK_DIRECT_FILE:-direct-created.txt}"
    "$MOCK_DONE_BIN" --summary "N9 summary" >"${TMP_DONE_OUT:-/dev/null}" 2>"${TMP_DONE_ERR:-/dev/null}"
    # снимок done.json СРАЗУ после вызова claude-agent-done, ДО того как раннер
    # (после возврата этого мока) допишет changes/empty под done.lock (§3) -
    # нужен тесту N9, чтобы отличить "changes:null мид-run - это не дефект"
    # от "changes так и не дописан после прогона".
    if [[ -n "${MOCK_DONE_SNAPSHOT:-}" && -f "$CLAUDE_AGENT_DIR/done.json" ]]; then
      cp "$CLAUDE_AGENT_DIR/done.json" "$MOCK_DONE_SNAPSHOT"
    fi
    echo '{"type":"result","result":"done-called","total_cost_usd":0.01}' ;;
  done_early_worktree_commit)
    # V2.10 T9 (§3a, аудит блокер 4): агент зовет claude-agent-done СРАЗУ
    # (worktree еще чист, empty:true), затем делает работу и коммитит ЕЕ -
    # но второй раз claude-agent-done не зовет. cwd этого мока для
    # workspace:worktree = <agent_dir>/work (V2.1 контракт).
    "$MOCK_DONE_BIN" --summary "early done" >"${TMP_DONE_OUT:-/dev/null}" 2>"${TMP_DONE_ERR:-/dev/null}"
    if [[ -n "${MOCK_DONE_SNAPSHOT:-}" && -f "$CLAUDE_AGENT_DIR/done.json" ]]; then
      cp "$CLAUDE_AGENT_DIR/done.json" "$MOCK_DONE_SNAPSHOT"
    fi
    echo "${MOCK_LATE_MARKER:-late-work}" > "${MOCK_LATE_FILE:-late-file.txt}"
    git add "${MOCK_LATE_FILE:-late-file.txt}"
    git -c user.email=t@t -c user.name=t commit -qm "late work after premature done"
    echo '{"type":"result","result":"done-early-committed","total_cost_usd":0.01}' ;;
  done_early_worktree_dirty)
    # T9, вторая ветка: после преждевременного claude-agent-done worktree
    # остается ГРЯЗНЫМ (незакоммиченное) - заявка обязана инвалидироваться,
    # а не предъявляться человеку как готовая.
    "$MOCK_DONE_BIN" --summary "early done dirty" >"${TMP_DONE_OUT:-/dev/null}" 2>"${TMP_DONE_ERR:-/dev/null}"
    echo "${MOCK_DIRTY_MARKER:-dirty-leftover}" > "${MOCK_DIRTY_FILE:-dirty-file.txt}"
    echo '{"type":"result","result":"done-early-dirty","total_cost_usd":0.01}' ;;
esac
EOF
chmod +x "$MOCK"
export CLAUDE_BIN="$MOCK" MOCK_MODE_FILE="$TMP/mock-mode"
echo ok > "$MOCK_MODE_FILE"

# =============================================================== N1
echo "=== N1: new-task на чистом месте -> агент создан, спека валидна, одно событие в spool, desired:running ==="
OUT1=$("$RC" agent new-task --name task-tg1001 --project demoproj --text "N1 text" 2>"$TMP/n1.err"); RC1=$?
[[ "$RC1" == 0 ]] && ok || fail "N1: exit 0 (got $RC1: $(cat "$TMP/n1.err"))"
[[ "$OUT1" == "task-tg1001 created started" ]] && ok || fail "N1: строка вывода '<name> created started' (got: $OUT1)"
AG1="$CLAUDE_AGENTS_DIR/task-tg1001"
[[ -f "$AG1/spec.yaml" ]] && ok || fail "N1: агент создан (spec.yaml на месте)"
[[ "$(yaml_get "$AG1/spec.yaml" 'd.get("name")')" == "task-tg1001" ]] && ok || fail "N1: спека валидна (name)"
[[ "$(yaml_goal_eq "$AG1/spec.yaml" "N1 text")" == "True" ]] && ok || fail "N1: goal сохранен"
[[ "$(yaml_get "$AG1/spec.yaml" 'd.get("project")')" == "$PROJ_NONE" ]] && ok || fail "N1: project резолвлен из projects.yaml"
N1_SPOOL_COUNT=$(ls "$CLAUDE_AGENT_SPOOL_BASE/task-tg1001"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$N1_SPOOL_COUNT" == "1" ]] && ok || fail "N1: ровно одно событие в spool (got $N1_SPOOL_COUNT)"
[[ -f "$AG1/control.json" ]] && ok || fail "N1: control.json создан"
[[ "$(jq_file "$AG1/control.json" 'd["desired"]')" == "running" ]] && ok || fail "N1: desired=running"

# =============================================================== N2
echo "=== N2: повтор той же команды (redelivery) -> второй агент не создан, второго события нет, exit 0, 'existing running' ==="
OUT2=$("$RC" agent new-task --name task-tg1001 --project demoproj --text "N1 text" 2>"$TMP/n2.err"); RC2=$?
[[ "$RC2" == 0 ]] && ok || fail "N2: exit 0 (got $RC2: $(cat "$TMP/n2.err"))"
[[ "$OUT2" == "task-tg1001 existing running" ]] && ok || fail "N2: строка вывода '<name> existing running' (got: $OUT2)"
N2_SPOOL_COUNT=$(ls "$CLAUDE_AGENT_SPOOL_BASE/task-tg1001"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$N2_SPOOL_COUNT" == "1" ]] && ok || fail "N2: второго события в spool не появилось (got $N2_SPOOL_COUNT)"
[[ "$(yaml_goal_eq "$AG1/spec.yaml" "N1 text")" == "True" ]] && ok || fail "N2: спека не перезаписана (create реально был no-op)"
[[ "$(jq_file "$AG1/control.json" 'd["desired"]')" == "running" ]] && ok || fail "N2: desired остается running"

# =============================================================== N3
echo "=== N3: имя из update_id укладывается в NAME_RE (граница 10 цифр); несуществующий проект -> отказ, без мусора ==="
OUT3A=$("$RC" agent new-task --name task-tg9999999999 --project demoproj --text "N3 boundary name" 2>"$TMP/n3a.err"); RC3A=$?
[[ "$RC3A" == 0 ]] && ok || fail "N3a: имя task-tg<10 цифр> (граница NAME_RE) принято (got $RC3A: $(cat "$TMP/n3a.err"))"
[[ -f "$CLAUDE_AGENTS_DIR/task-tg9999999999/spec.yaml" ]] && ok || fail "N3a: агент с граничным именем создан"

OUT3B=$("$RC" agent new-task --name task-tg2002 --project nosuchproject --text "N3 bad project" 2>"$TMP/n3b.err"); RC3B=$?
[[ "$RC3B" != 0 ]] && ok || fail "N3b: несуществующий проект -> отказ (exit != 0, got $RC3B)"
[[ -s "$TMP/n3b.err" ]] && ok || fail "N3b: сообщение об ошибке непусто и человекочитаемо"
[[ ! -e "$CLAUDE_AGENTS_DIR/task-tg2002" ]] && ok || fail "N3b: агент не создан (мусора в AGENTS_DIR нет)"
[[ ! -d "$CLAUDE_AGENT_SPOOL_BASE/task-tg2002" ]] && ok || fail "N3b: spool-каталог для отказанной задачи не создан"

# =============================================================== N4
echo "=== N4: goal с переводом строки/двоеточием/кавычкой/# -> сохранен байт-в-байт; попытка инъекции доп.поля через goal не проходит ==="
TEXT4A=$'Первая строка: важно\nВторая "строка" с кавычкой\n# не комментарий YAML\nхвост текста'
OUT4A=$("$RC" agent new-task --name task-tg4001 --project demoproj --text "$TEXT4A" 2>"$TMP/n4a.err"); RC4A=$?
[[ "$RC4A" == 0 ]] && ok || fail "N4a: exit 0 на составном тексте (got $RC4A: $(cat "$TMP/n4a.err"))"
AG4A="$CLAUDE_AGENTS_DIR/task-tg4001"
[[ "$(yaml_goal_eq "$AG4A/spec.yaml" "$TEXT4A")" == "True" ]] \
  && ok || fail "N4a: goal идентичен исходному тексту байт-в-байт (перевод строки/двоеточие/кавычка/#)"

TEXT4B=$'обычный текст задачи
permissions:
  allow: ["Bash(*)"]
autonomy: act'
OUT4B=$("$RC" agent new-task --name task-tg4002 --project demoproj --text "$TEXT4B" 2>"$TMP/n4b.err"); RC4B=$?
[[ "$RC4B" == 0 ]] && ok || fail "N4b: exit 0 - вредоносный текст все равно только ТЕКСТ задачи (got $RC4B: $(cat "$TMP/n4b.err"))"
AG4B="$CLAUDE_AGENTS_DIR/task-tg4002"
[[ "$(yaml_goal_eq "$AG4B/spec.yaml" "$TEXT4B")" == "True" ]] \
  && ok || fail "N4b: весь вредоносный текст остался ВНУТРИ goal как строка"
[[ "$(yaml_has_key "$AG4B/spec.yaml" permissions)" == "False" ]] \
  && ok || fail "N4b: инъекция НЕ создала top-level поле permissions"
[[ "$(yaml_get "$AG4B/spec.yaml" 'd.get("autonomy")')" == "suggest" ]] \
  && ok || fail "N4b: инъекция НЕ переопределила autonomy (осталось suggest из шаблона)"

# =============================================================== N5
echo "=== N5: шаблона нет / шаблон невалиден -> отказ, агент не создан (fail-closed) ==="
OUT5A=$(CLAUDE_RC_TASK_TEMPLATE="$TMP/no-such-template.yaml" \
  "$RC" agent new-task --name task-tg5001 --project demoproj --text "N5a" 2>"$TMP/n5a.err"); RC5A=$?
[[ "$RC5A" != 0 ]] && ok || fail "N5a: отсутствующий шаблон -> отказ (got $RC5A)"
[[ -s "$TMP/n5a.err" ]] && ok || fail "N5a: внятное сообщение об ошибке"
[[ ! -e "$CLAUDE_AGENTS_DIR/task-tg5001" ]] && ok || fail "N5a: агент не создан"

cat > "$TMP/bad-template.yaml" <<'EOF'
schema: 1
name: {{name}}
type: event
role: none
project: {{project}}
goal: {{goal}}
autonomy: "suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
OUT5B=$(CLAUDE_RC_TASK_TEMPLATE="$TMP/bad-template.yaml" \
  "$RC" agent new-task --name task-tg5002 --project demoproj --text "N5b" 2>"$TMP/n5b.err"); RC5B=$?
[[ "$RC5B" != 0 ]] && ok || fail "N5b: невалидный (битый YAML) шаблон -> отказ (got $RC5B)"
[[ -s "$TMP/n5b.err" ]] && ok || fail "N5b: внятное сообщение об ошибке"
[[ ! -e "$CLAUDE_AGENTS_DIR/task-tg5002" ]] && ok || fail "N5b: агент не создан"

# --- фикстура: git-проект для worktree-кейсов (N6-N8, N10) ---
PROJ_GIT="$TMP/proj-git"; git init -q "$PROJ_GIT"
( cd "$PROJ_GIT" && echo hi > f.txt && git add . \
  && git -c user.email=t@t -c user.name=t commit -qm init )

# =============================================================== N6
echo "=== N6: claude-agent-done в worktree с чистым деревом (1 коммит поверх base) -> requested, commit_sha=HEAD потомок base, empty:false ==="
AG6=$(mk_worktree_agent wt6 "$PROJ_GIT")
BASE6=$(git -C "$AG6/work" rev-parse HEAD)
( cd "$AG6/work" && echo "n6 change" > n6.txt && git add n6.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "n6 commit" )
COMMIT6=$(git -C "$AG6/work" rev-parse HEAD)
mk_inflight "$AG6" "n6-key"
call_done "$AG6" "n6-key" --summary "N6 summary" >"$TMP/n6.out" 2>"$TMP/n6.err"; RC6=$?
[[ "$RC6" == 0 ]] && ok || fail "N6: exit 0 (got $RC6: $(cat "$TMP/n6.err"))"
DJ6="$AG6/done.json"
[[ -f "$DJ6" ]] && ok || fail "N6: done.json создан"
[[ "$(jq_file "$DJ6" 'd.get("state")')" == "requested" ]] && ok || fail "N6: state=requested"
[[ "$(jq_file "$DJ6" 'd.get("workspace")')" == "worktree" ]] && ok || fail "N6: workspace=worktree"
[[ "$(jq_file "$DJ6" 'd.get("summary")')" == "N6 summary" ]] && ok || fail "N6: summary сохранен"
[[ "$(jq_file "$DJ6" 'd.get("envelope_key")')" == "n6-key" ]] && ok || fail "N6: envelope_key = ключ конверта"
[[ "$(jq_file "$DJ6" 'd.get("commit_sha")')" == "$COMMIT6" ]] && ok || fail "N6: commit_sha = HEAD ветки задачи"
[[ "$(jq_file "$DJ6" 'd.get("base")')" == "$BASE6" ]] && ok || fail "N6: base = исходный HEAD проекта на момент create"
git -C "$AG6/work" merge-base --is-ancestor "$BASE6" "$COMMIT6" \
  && ok || fail "N6: HEAD - потомок base (merge-base --is-ancestor)"
[[ "$(jq_file "$DJ6" 'd.get("branch","")')" == task/wt6-* ]] && ok || fail "N6: branch = task/wt6-<inc8>"
[[ "$(jq_file "$DJ6" 'd.get("empty")')" == "False" ]] && ok || fail "N6: empty=false (есть коммит поверх base)"
[[ "$(jq_file "$DJ6" 'bool(d.get("requested_at"))')" == "True" ]] && ok || fail "N6: requested_at заполнен"
[[ "$(jq_file "$DJ6" 'd.get("pushed_at")')" == "None" ]] && ok || fail "N6: pushed_at=null (карточку еще не пушили)"
[[ "$(jq_file "$DJ6" 'd.get("accepted_at")')" == "None" ]] && ok || fail "N6: accepted_at=null (поля V2.7b присутствуют, но пусты)"
[[ "$(jq_file "$DJ6" 'd.get("integrated_at")')" == "None" ]] && ok || fail "N6: integrated_at=null"
[[ "$(jq_file "$DJ6" 'd.get("cleaned_at")')" == "None" ]] && ok || fail "N6: cleaned_at=null"
[[ "$(jq_file "$DJ6" 'd.get("archived_at")')" == "None" ]] && ok || fail "N6: archived_at=null"

# =============================================================== N6b
echo "=== N6b: фенсинг умеет провалиться - HEAD не потомок зафиксированной базы -> exit 2 ==="
# Смысл кейса: проверка "HEAD - потомок base" обязана быть falsifiable.
# Если base выводить из самого HEAD (например merge-base HEAD и HEAD
# проекта), она истинна по определению и не отловит ничего - именно так и
# было в первой реализации. Здесь база в control.json подменяется на
# коммит из НЕСВЯЗАННОЙ истории, и заявка обязана быть отбита.
AG6B=$(mk_worktree_agent wt6b "$PROJ_GIT")
( cd "$AG6B/work" && echo "n6b" > n6b.txt && git add n6b.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "n6b commit" )
ORPHAN=$(cd "$AG6B/work" && git -c user.email=t@t -c user.name=t \
  commit-tree -m orphan "$(git hash-object -t tree /dev/null)")
python3 - "$AG6B/control.json" "$ORPHAN" <<'PY'
import json, sys
p, sha = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["mission_base"] = sha
json.dump(d, open(p, "w"), ensure_ascii=False)
PY
mk_inflight "$AG6B" "n6b-key"
call_done "$AG6B" "n6b-key" --summary "N6b" >"$TMP/n6b.out" 2>"$TMP/n6b.err"; RC6B=$?
[[ "$RC6B" == 2 ]] && ok || fail "N6b: exit 2 на чужой базе (got $RC6B: $(cat "$TMP/n6b.err"))"
[[ ! -f "$AG6B/done.json" ]] && ok || fail "N6b: done.json не создан"

# =============================================================== N7
echo "=== N7: грязное дерево -> exit 2, done.json не создан ==="
AG7=$(mk_worktree_agent wt7 "$PROJ_GIT")
( cd "$AG7/work" && echo "dirty, not committed" >> f.txt )
mk_inflight "$AG7" "n7-key"
call_done "$AG7" "n7-key" --summary "N7 summary" >"$TMP/n7.out" 2>"$TMP/n7.err"; RC7=$?
[[ "$RC7" == 2 ]] && ok || fail "N7: exit 2 на грязном дереве (got $RC7: $(cat "$TMP/n7.err"))"
[[ -s "$TMP/n7.err" ]] && ok || fail "N7: сообщение про 'закоммить' непусто"
[[ ! -f "$AG7/done.json" ]] && ok || fail "N7: done.json не создан"

# =============================================================== N8
echo "=== N8: ни одного коммита поверх base -> requested, empty:true (не отказ) ==="
AG8=$(mk_worktree_agent wt8 "$PROJ_GIT")
BASE8=$(git -C "$AG8/work" rev-parse HEAD)
mk_inflight "$AG8" "n8-key"
call_done "$AG8" "n8-key" --summary "N8 summary" >"$TMP/n8.out" 2>"$TMP/n8.err"; RC8=$?
[[ "$RC8" == 0 ]] && ok || fail "N8: exit 0 - отсутствие коммитов НЕ отказ (got $RC8: $(cat "$TMP/n8.err"))"
DJ8="$AG8/done.json"
[[ -f "$DJ8" ]] && ok || fail "N8: done.json создан"
[[ "$(jq_file "$DJ8" 'd.get("state")')" == "requested" ]] && ok || fail "N8: state=requested"
[[ "$(jq_file "$DJ8" 'd.get("commit_sha")')" == "$BASE8" ]] && ok || fail "N8: commit_sha == base (ни одного коммита)"
[[ "$(jq_file "$DJ8" 'd.get("empty")')" == "True" ]] && ok || fail "N8: empty=true"

# =============================================================== N9
echo "=== N9: workspace:direct -> changes:null сразу после claude-agent-done (не дефект, §3), после возврата 'step' раннер дописал реальные пути ==="
PROJ9="$TMP/proj9"; mkdir -p "$PROJ9"
AG9=$(mk_none_agent evtd9 "workspace: direct
project: $PROJ9")
"$RUN" spool-put evtd9 --text "n9-event" >/dev/null
"$RUN" intake "$AG9" >/dev/null
echo done_direct > "$MOCK_MODE_FILE"
MOCK_DIRECT_FILE="direct-created.txt" TMP_DONE_OUT="$TMP/n9-done.out" TMP_DONE_ERR="$TMP/n9-done.err" \
  MOCK_DONE_SNAPSHOT="$TMP/n9-done-midrun.json" \
  "$RUN" step "$AG9" >/dev/null 2>"$TMP/n9-step.err"
echo ok > "$MOCK_MODE_FILE"
[[ -f "$PROJ9/direct-created.txt" ]] && ok || fail "N9: fixture - мок реально создал файл в spec.project"
[[ ! -d "$PROJ9/.git" ]] && ok || fail "N9: git не задействован (проект не git-репозиторий)"
MIDRUN9="$TMP/n9-done-midrun.json"
[[ -f "$MIDRUN9" ]] && ok || fail "N9: fixture - снимок done.json мид-run снят (claude-agent-done отработал внутри прогона)"
[[ "$(jq_file "$MIDRUN9" 'd.get("state")')" == "requested" ]] && ok || fail "N9: мид-run state=requested"
[[ "$(jq_file "$MIDRUN9" 'd.get("changes")')" == "None" ]] \
  && ok || fail "N9: мид-run changes=null (claude-agent-done сам не считает диф - §3, это не дефект)"
DJ9="$AG9/done.json"
[[ -f "$DJ9" ]] && ok || fail "N9: done.json на месте после возврата 'step'"
[[ "$(jq_file "$DJ9" 'd.get("state")')" == "requested" ]] && ok || fail "N9: state=requested"
[[ "$(jq_file "$DJ9" 'd.get("workspace")')" == "direct" ]] && ok || fail "N9: workspace=direct"
[[ "$(jq_file "$DJ9" '"direct-created.txt" in (d.get("changes") or [])')" == "True" ]] \
  && ok || fail "N9: раннер дописал changes с реально созданным путем (direct-created.txt) после ok-исхода"
[[ "$(jq_file "$DJ9" 'd.get("empty")')" == "False" ]] && ok || fail "N9: empty=false (файл добавлен)"

# =============================================================== N10
echo "=== N10: повторный claude-agent-done при requested -> ok, requested_at не переписан; при accepted -> exit 2, файл не изменен ==="
AG10=$(mk_worktree_agent wt10 "$PROJ_GIT")
( cd "$AG10/work" && echo "n10 change" > n10.txt && git add n10.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "n10 commit" )
COMMIT10=$(git -C "$AG10/work" rev-parse HEAD)
mk_inflight "$AG10" "n10-key"
call_done "$AG10" "n10-key" --summary "first" >/dev/null 2>"$TMP/n10a.err"
DJ10="$AG10/done.json"
[[ -f "$DJ10" ]] && ok || fail "N10: fixture - первый вызов создал done.json ($(cat "$TMP/n10a.err"))"
REQAT10_1=$(jq_file "$DJ10" 'd.get("requested_at")')
call_done "$AG10" "n10-key" --summary "second" >/dev/null 2>"$TMP/n10b.err"; RC10B=$?
[[ "$RC10B" == 0 ]] && ok || fail "N10: повтор при requested тем же commit_sha -> ok (got $RC10B: $(cat "$TMP/n10b.err"))"
[[ "$(jq_file "$DJ10" 'd.get("requested_at")')" == "$REQAT10_1" ]] && ok || fail "N10: requested_at не переписан"
[[ "$(jq_file "$DJ10" 'd.get("commit_sha")')" == "$COMMIT10" ]] && ok || fail "N10: commit_sha не изменился"
[[ "$(jq_file "$DJ10" 'd.get("summary")')" == "second" ]] && ok || fail "N10: summary обновлен вторым вызовом"

python3 -c '
import json, sys
p = sys.argv[1] + "/done.json"
d = json.load(open(p))
d["state"] = "accepted"
d["accepted_at"] = "2026-01-02T00:00:00Z"
json.dump(d, open(p, "w"))
' "$AG10"
SUMMARY10_BEFORE=$(jq_file "$DJ10" 'd.get("summary")')
call_done "$AG10" "n10-key" --summary "third" >/dev/null 2>"$TMP/n10c.err"; RC10C=$?
[[ "$RC10C" == 2 ]] && ok || fail "N10: вызов на уже accepted -> exit 2 (got $RC10C: $(cat "$TMP/n10c.err"))"
[[ "$(jq_file "$DJ10" 'd.get("state")')" == "accepted" ]] && ok || fail "N10: state остается accepted"
[[ "$(jq_file "$DJ10" 'd.get("summary")')" == "$SUMMARY10_BEFORE" ]] && ok || fail "N10: файл не изменен отклоненным вызовом (summary не 'third')"

# =============================================================== N10d
echo "=== N10d (§4, blocker): повторный claude-agent-done с продвинувшимся commit_sha сбрасывает pushed_at в null (документ пересобран целиком) ==="
AG10D=$(mk_worktree_agent wt10d "$PROJ_GIT")
( cd "$AG10D/work" && echo "n10d change 1" > n10d.txt && git add n10d.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "n10d commit 1" )
COMMIT10D_1=$(git -C "$AG10D/work" rev-parse HEAD)
mk_inflight "$AG10D" "n10d-key"
call_done "$AG10D" "n10d-key" --summary "first" >/dev/null 2>"$TMP/n10d-a.err"
DJ10D="$AG10D/done.json"
[[ "$(jq_file "$DJ10D" 'd.get("commit_sha")')" == "$COMMIT10D_1" ]] \
  && ok || fail "N10d: fixture - первый commit_sha записан"
# карточка "готово" уже ушла (pushed_at проставлен) - имитируем этот факт
# напрямую в файле, как это сделал бы done-notify после доставки.
python3 -c '
import json, sys
p = sys.argv[1] + "/done.json"
d = json.load(open(p))
d["pushed_at"] = "2026-01-01T12:00:00Z"
json.dump(d, open(p, "w"), ensure_ascii=False)
' "$AG10D"
( cd "$AG10D/work" && echo "n10d change 2" > n10d2.txt && git add n10d2.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "n10d commit 2" )
COMMIT10D_2=$(git -C "$AG10D/work" rev-parse HEAD)
call_done "$AG10D" "n10d-key" --summary "second (after new commit)" >/dev/null 2>"$TMP/n10d-b.err"; RC10D=$?
[[ "$RC10D" == 0 ]] && ok || fail "N10d: повторный вызов с продвинувшимся commit_sha -> ok (got $RC10D: $(cat "$TMP/n10d-b.err"))"
[[ "$(jq_file "$DJ10D" 'd.get("commit_sha")')" == "$COMMIT10D_2" ]] \
  && ok || fail "N10d: commit_sha обновлен на новый HEAD"
[[ "$(jq_file "$DJ10D" 'd.get("pushed_at")')" == "None" ]] \
  && ok || fail "N10d: pushed_at сброшен в null - новая заявка обязана снова отправить карточку"
[[ "$(jq_file "$DJ10D" 'd.get("state")')" == "requested" ]] \
  && ok || fail "N10d: state остается requested"
[[ "$(jq_file "$DJ10D" 'd.get("summary")')" == "second (after new commit)" ]] \
  && ok || fail "N10d: summary обновлен новой заявкой"

# =============================================================== N11
echo "=== N11: envelope_key вне inflight -> отказ, done.json не создан (регресс V2.4 major 6) ==="
AG11=$(mk_none_agent evtd11)
call_done "$AG11" "nonexistent-key-not-in-inflight" --summary "N11" >"$TMP/n11.out" 2>"$TMP/n11.err"; RC11=$?
[[ "$RC11" == 2 ]] && ok || fail "N11: exit 2 (got $RC11: $(cat "$TMP/n11.err"))"
[[ -s "$TMP/n11.err" ]] && ok || fail "N11: сообщение об ошибке непусто"
[[ ! -f "$AG11/done.json" ]] && ok || fail "N11: done.json не создан"

# =============================================================== N12
echo "=== N12: done-notify при requested и пустом pushed_at -> ровно один вызов alert-команды (позиции/detail зафиксированы §4), pushed_at проставлен; повтор -> без пуша ==="
BASE12="$TMP/recon-agents-n12"; mkdir -p "$BASE12"
AG12=$(mk_isolated_agent "$BASE12" evtd12)
write_done_json "$AG12" "n12-key" "N12 summary text"
mk_done_envelope "$AG12" "n12-key"  # аудит V2.7a major 6: envelope_key обязан быть реальным
ALERT_LOG12="$TMP/n12-alert.log"
mk_alert_ok "$ALERT_LOG12" "$TMP/alert-ok-n12.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n12.sh" "$RUN" done-notify "$AG12" >/dev/null 2>"$TMP/n12a.err"; RC12A=$?
[[ "$RC12A" == 0 ]] && ok || fail "N12: exit 0 (got $RC12A: $(cat "$TMP/n12a.err"))"
[[ "$(alert_block_count "$ALERT_LOG12")" == "1" ]] && ok || fail "N12: ровно один вызов alert-команды"
[[ "$(alert_block_field "$ALERT_LOG12" 1 0)" == "evtd12" ]] && ok || fail "N12: 1-й аргумент - короткое имя агента"
[[ "$(alert_block_field "$ALERT_LOG12" 1 1)" == "задача готова" ]] \
  && ok || fail "N12: 2-й аргумент - постоянная строка 'задача готова' (got: $(alert_block_field "$ALERT_LOG12" 1 1))"
SUMMARY_ARG12=$(alert_block_field "$ALERT_LOG12" 1 2)
[[ "$SUMMARY_ARG12" == *"N12 summary text"* ]] \
  && ok || fail "N12: 3-й аргумент - человекочитаемая сводка, содержит summary (got: $SUMMARY_ARG12)"
DETAIL12=$(alert_detail "$ALERT_LOG12" 1)
[[ "$(jq_str "$DETAIL12" 'd.get("kind")')" == "done" ]] && ok || fail "N12: detail.kind=done"
[[ "$(jq_str "$DETAIL12" 'd.get("agent")')" == "evtd12" ]] && ok || fail "N12: detail.agent = короткое имя агента"
[[ "$(jq_str "$DETAIL12" 'd.get("project")')" == "$PROJ_NONE" ]] && ok || fail "N12: detail.project = spec.project"
[[ "$(jq_str "$DETAIL12" 'd.get("summary")')" == "N12 summary text" ]] && ok || fail "N12: detail.summary = summary из done.json"
[[ "$(jq_file "$AG12/done.json" 'bool(d.get("pushed_at"))')" == "True" ]] && ok || fail "N12: pushed_at проставлен"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n12.sh" "$RUN" done-notify "$AG12" >/dev/null 2>"$TMP/n12b.err"
[[ "$(alert_block_count "$ALERT_LOG12")" == "1" ]] && ok || fail "N12: повторный проход не пушит второй раз (пуш уже доставлен)"

# =============================================================== N13
echo "=== N13: недоставка (alert-команда вернула ненулевой код) -> pushed_at пуст, следующий проход доставляет ==="
BASE13="$TMP/recon-agents-n13"; mkdir -p "$BASE13"
AG13=$(mk_isolated_agent "$BASE13" evtd13)
write_done_json "$AG13" "n13-key" "N13 summary"
mk_done_envelope "$AG13" "n13-key"  # аудит V2.7a major 6: envelope_key обязан быть реальным
ALERT_LOG13F="$TMP/n13-fail.log"
mk_alert_fail "$ALERT_LOG13F" "$TMP/alert-fail-n13.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-fail-n13.sh" "$RUN" done-notify "$AG13" >/dev/null 2>"$TMP/n13a.err"
[[ "$(alert_block_count "$ALERT_LOG13F")" == "1" ]] && ok || fail "N13: alert-команда реально вызвана несмотря на неуспех"
[[ "$(jq_file "$AG13/done.json" 'd.get("pushed_at")')" == "None" ]] && ok || fail "N13: pushed_at остается пуст после недоставки"
ALERT_LOG13OK="$TMP/n13-ok.log"
mk_alert_ok "$ALERT_LOG13OK" "$TMP/alert-ok-n13.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n13.sh" "$RUN" done-notify "$AG13" >/dev/null 2>"$TMP/n13b.err"
[[ "$(alert_block_count "$ALERT_LOG13OK")" == "1" ]] && ok || fail "N13: следующий проход (рабочая alert-команда) доставляет"
[[ "$(jq_file "$AG13/done.json" 'bool(d.get("pushed_at"))')" == "True" ]] && ok || fail "N13: pushed_at проставлен после успешной доставки"

# =============================================================== N14
echo "=== N14: секрет в summary -> замаскирован (redact) в 3-м аргументе и в detail.summary, не уезжает в alert-вызов ==="
BASE14="$TMP/recon-agents-n14"; mkdir -p "$BASE14"
AG14=$(mk_isolated_agent "$BASE14" evtd14)
SECRET14='PASSWORD=hunter2 curl -H "Authorization: Bearer abc.def.ghi" https://x'
write_done_json "$AG14" "n14-key" "$SECRET14"
mk_done_envelope "$AG14" "n14-key"  # аудит V2.7a major 6: envelope_key обязан быть реальным
ALERT_LOG14="$TMP/n14-alert.log"
mk_alert_ok "$ALERT_LOG14" "$TMP/alert-ok-n14.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n14.sh" "$RUN" done-notify "$AG14" >/dev/null 2>"$TMP/n14.err"
[[ "$(alert_block_count "$ALERT_LOG14")" == "1" ]] && ok || fail "N14: fixture - карточка реально пушится ($(cat "$TMP/n14.err"))"
ALERT_CONTENT14=$(cat "$ALERT_LOG14" 2>/dev/null)
[[ "$ALERT_CONTENT14" != *"hunter2"* ]] && ok || fail "N14: секрет 'hunter2' не должен быть в вызове alert-команды (ни в одном аргументе)"
[[ "$ALERT_CONTENT14" != *"abc.def.ghi"* ]] && ok || fail "N14: секрет 'abc.def.ghi' не должен быть в вызове alert-команды (ни в одном аргументе)"

# =============================================================== N16
echo "=== N16 (blocker, стык бот -> CLI): /new проходит РЕАЛЬНЫЙ разбор команды бота (parse_command+authorized+handle), не CLI напрямую ==="
# Импортирует bin/claude-agent-tgbot КАК МОДУЛЬ (importlib, тот же файл, что
# запускается в проде) и зовет parse_command/authorized/handle - ровно ту
# стыковку, которую боевой mode_poll() делает построчно: `elif authorized(upd,
# wl): cmd, arg = parse_command(mtext); ... handle(cmd, arg, update_id=...,
# from_id=...)`. Никакой реализации /new здесь не дублируется - только вызов
# настоящих функций бота.
N16_HELPER="$TMP/n16-helper.py"
cat > "$N16_HELPER" <<'PY'
import importlib.machinery, importlib.util, json, sys


def load_tgbot(path):
    # spec_from_file_location без явного loader'а не находит его для файла
    # без .py-суффикса (bin/claude-agent-tgbot) - loader задаем явно.
    loader = importlib.machinery.SourceFileLoader("tgbot_under_test", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main():
    tgbot_path, mode = sys.argv[1], sys.argv[2]
    tgbot = load_tgbot(tgbot_path)
    wl = {555}
    if mode == "dispatch":
        update_id, from_id, text = int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
        update = {"message": {"chat": {"type": "private"},
                              "from": {"id": from_id}, "text": text}}
        if not tgbot.authorized(update, wl):
            print(json.dumps({"authorized": False}))
            return
        cmd, arg = tgbot.parse_command(text)
        if not cmd:
            print(json.dumps({"authorized": True, "cmd": None}))
            return
        out_text, _pre = tgbot.handle(cmd, arg, update_id=update_id,
                                      from_id=from_id)
        print(json.dumps({"authorized": True, "cmd": cmd, "text": out_text},
                         ensure_ascii=False))
    else:
        raise SystemExit("unknown mode %r" % mode)


main()
PY
n16_dispatch() { python3 "$N16_HELPER" "$HERE/../bin/claude-agent-tgbot" dispatch "$1" "$2" "$3"; }

DISPATCH16A=$(n16_dispatch 16001 555 "/new demoproj N16 text")
[[ "$(jq_str "$DISPATCH16A" 'd.get("cmd")')" == "/new" ]] \
  && ok || fail "N16: команда распознана как /new (got: $DISPATCH16A)"
[[ "$(jq_str "$DISPATCH16A" 'd.get("text")')" == "task-tg16001 created started" ]] \
  && ok || fail "N16: дошло до реального new-task с именем из update_id (got: $DISPATCH16A)"
AG16="$CLAUDE_AGENTS_DIR/task-tg16001"
[[ -f "$AG16/spec.yaml" ]] && ok || fail "N16: агент реально создан через диспетч бота"
N16_SPOOL_COUNT=$(ls "$CLAUDE_AGENT_SPOOL_BASE/task-tg16001"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$N16_SPOOL_COUNT" == "1" ]] && ok || fail "N16: ровно одно событие в spool"

DISPATCH16B=$(n16_dispatch 16001 555 "/new demoproj N16 text")
[[ "$(jq_str "$DISPATCH16B" 'd.get("text")')" == "task-tg16001 existing running" ]] \
  && ok || fail "N16: redelivery того же update_id - вторая задача не создается (got: $DISPATCH16B)"
N16_SPOOL_COUNT2=$(ls "$CLAUDE_AGENT_SPOOL_BASE/task-tg16001"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$N16_SPOOL_COUNT2" == "1" ]] && ok || fail "N16: второе событие в spool не появилось"

DISPATCH16C=$(n16_dispatch 16002 999 "/new demoproj should-not-create")
[[ "$(jq_str "$DISPATCH16C" 'd.get("authorized")')" == "False" ]] \
  && ok || fail "N16: неавторизованный from.id -> цепочка не вызвана (got: $DISPATCH16C)"
[[ ! -e "$CLAUDE_AGENTS_DIR/task-tg16002" ]] \
  && ok || fail "N16: агент неавторизованного апдейта не создан"

# =============================================================== N17
echo "=== N17 (blocker, гонка карточки): workspace:direct с changes==null -> done-notify дает skip; после дозаписи changes -> ровно один пуш ==="
BASE17="$TMP/recon-agents-n17"; mkdir -p "$BASE17"
AG17=$(mk_isolated_agent "$BASE17" evtd17)
write_done_json_direct "$AG17" "n17-key" "N17 summary" null
mk_done_envelope "$AG17" "n17-key"
ALERT_LOG17="$TMP/n17-alert.log"
mk_alert_ok "$ALERT_LOG17" "$TMP/alert-ok-n17.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n17.sh" "$RUN" done-notify "$AG17" >/dev/null 2>"$TMP/n17a.err"
[[ "$(alert_block_count "$ALERT_LOG17")" == "0" ]] \
  && ok || fail "N17: changes:null у workspace:direct -> skip, без пуша"
[[ "$(jq_file "$AG17/done.json" 'd.get("pushed_at")')" == "None" ]] \
  && ok || fail "N17: pushed_at остается пуст (skip, не fail)"
python3 -c '
import json, sys
p = sys.argv[1] + "/done.json"
d = json.load(open(p))
d["changes"] = ["a.txt", "b.txt"]
d["empty"] = False
json.dump(d, open(p, "w"), ensure_ascii=False)
' "$AG17"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n17.sh" "$RUN" done-notify "$AG17" >/dev/null 2>"$TMP/n17b.err"
[[ "$(alert_block_count "$ALERT_LOG17")" == "1" ]] \
  && ok || fail "N17: после дозаписи changes -> ровно один пуш"
[[ "$(jq_file "$AG17/done.json" 'bool(d.get("pushed_at"))')" == "True" ]] \
  && ok || fail "N17: pushed_at проставлен"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n17.sh" "$RUN" done-notify "$AG17" >/dev/null 2>"$TMP/n17c.err"
[[ "$(alert_block_count "$ALERT_LOG17")" == "1" ]] \
  && ok || fail "N17: повторный проход не пушит второй раз"

# =============================================================== N18
echo "=== N18 (major 1): существующий агент с тем же именем, но другим project/workspace/type -> отказ, событие в его spool НЕ положено ==="
printf '%s\n' "demoprojgit: $PROJ_GIT" >> "$CLAUDE_RC_PROJECTS_FILE"

# N18a: другой project
PROJ18_OTHER="$TMP/proj18-other"; mkdir -p "$PROJ18_OTHER"
SPEC18A="$TMP/spec18a.yaml"
cat > "$SPEC18A" <<EOF
schema: 1
name: task-tg18001
type: event
role: none
project: $PROJ18_OTHER
goal: "n18a - существующий агент, другой project"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
"$RC" agent create task-tg18001 --spec "$SPEC18A" >/dev/null 2>"$TMP/n18a-create.err"
OUT18A=$("$RC" agent new-task --name task-tg18001 --project demoproj --text "N18a attempt" 2>"$TMP/n18a.err"); RC18A=$?
[[ "$RC18A" != 0 ]] && ok || fail "N18a: отказ на конфликте project (got $RC18A)"
# маркер СПЕЦИФИЧЕН для сверки identity (не любой отказ вообще) - отличает
# реальный фикс от случайного нуля другого рода (напр. если бы кто-то
# ослабил проверку до "просто non-zero")
[[ "$(cat "$TMP/n18a.err")" == *"не та же задача"* ]] \
  && ok || fail "N18a: сообщение отказа - именно про несовпадение type/project/workspace (got: $(cat "$TMP/n18a.err"))"
N18A_SPOOL_COUNT=$(ls "$CLAUDE_AGENT_SPOOL_BASE/task-tg18001"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$N18A_SPOOL_COUNT" == "0" ]] && ok || fail "N18a: событие в spool НЕ положено (got $N18A_SPOOL_COUNT)"

# N18b: тот же project, но другой workspace (worktree вместо none из шаблона)
SPEC18B="$TMP/spec18b.yaml"
cat > "$SPEC18B" <<EOF
schema: 1
name: task-tg18002
type: event
role: none
project: $PROJ_GIT
goal: "n18b - существующий агент, workspace worktree"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
"$RC" agent create task-tg18002 --spec "$SPEC18B" >/dev/null 2>"$TMP/n18b-create.err"
OUT18B=$("$RC" agent new-task --name task-tg18002 --project demoprojgit --text "N18b attempt" 2>"$TMP/n18b.err"); RC18B=$?
[[ "$RC18B" != 0 ]] && ok || fail "N18b: отказ на конфликте workspace (got $RC18B)"
[[ "$(cat "$TMP/n18b.err")" == *"не та же задача"* ]] \
  && ok || fail "N18b: сообщение отказа - именно про несовпадение type/project/workspace (got: $(cat "$TMP/n18b.err"))"
N18B_SPOOL_COUNT=$(ls "$CLAUDE_AGENT_SPOOL_BASE/task-tg18002"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$N18B_SPOOL_COUNT" == "0" ]] && ok || fail "N18b: событие в spool НЕ положено (got $N18B_SPOOL_COUNT)"

# N18c: тот же project, но другой type (mission вместо event из шаблона)
MISSION18C="$TMP/mission18c.md"; echo "n18c mission fixture" > "$MISSION18C"
SPEC18C="$TMP/spec18c.yaml"
cat > "$SPEC18C" <<EOF
schema: 1
name: task-tg18003
type: mission
role: none
project: $PROJ_GIT
goal: "n18c - существующий агент, type mission"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
EOF
"$RC" agent create task-tg18003 --spec "$SPEC18C" --mission "$MISSION18C" >/dev/null 2>"$TMP/n18c-create.err"
OUT18C=$("$RC" agent new-task --name task-tg18003 --project demoprojgit --text "N18c attempt" 2>"$TMP/n18c.err"); RC18C=$?
[[ "$RC18C" != 0 ]] && ok || fail "N18c: отказ на конфликте type (got $RC18C)"
# маркер обязателен и здесь: без него mission-агент без spool-каталога
# отбивался бы позже (spool-put) СЛУЧАЙНО по совсем другой причине - тест
# должен ловить именно сверку identity, а не побочный эффект структуры
# mission-агентов
[[ "$(cat "$TMP/n18c.err")" == *"не та же задача"* ]] \
  && ok || fail "N18c: сообщение отказа - именно про несовпадение type/project/workspace, не побочный эффект (got: $(cat "$TMP/n18c.err"))"
N18C_SPOOL_COUNT=$(ls "$CLAUDE_AGENT_SPOOL_BASE/task-tg18003"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$N18C_SPOOL_COUNT" == "0" ]] && ok || fail "N18c: событие в spool НЕ положено (got $N18C_SPOOL_COUNT)"

# =============================================================== N19
echo "=== N19 (major 2): два параллельных new-task на одно имя -> ровно один агент, без вложенного .new-*/лишней ветки/лишнего worktree ==="
TEMPLATE19="$TMP/task-template-worktree.yaml"
cat > "$TEMPLATE19" <<'EOF'
schema: 1
name: {{name}}
type: event
role: none
project: {{project}}
goal: {{goal}}
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: worktree
EOF
# одинаковый --text у обоих гонщиков (аудит V2.7a, major 2: реальная гонка
# - две доставки ОДНОГО апдейта, текст всегда идентичен; разный текст на
# одном --id упал бы в producer-идемпотентности spool-put, что не имеет
# отношения к проверяемой здесь гонке cmd_create/mv)
( CLAUDE_RC_TASK_TEMPLATE="$TEMPLATE19" "$RC" agent new-task \
    --name task-tg19001 --project demoprojgit --text "N19 race" \
    >"$TMP/n19a.out" 2>"$TMP/n19a.err" ) &
PID19A=$!
( CLAUDE_RC_TASK_TEMPLATE="$TEMPLATE19" "$RC" agent new-task \
    --name task-tg19001 --project demoprojgit --text "N19 race" \
    >"$TMP/n19b.out" 2>"$TMP/n19b.err" ) &
PID19B=$!
wait "$PID19A"; RC19A=$?
wait "$PID19B"; RC19B=$?
[[ "$RC19A" == 0 && "$RC19B" == 0 ]] \
  && ok || fail "N19: оба параллельных вызова вернули 0 (got A=$RC19A B=$RC19B; $(cat "$TMP/n19a.err") / $(cat "$TMP/n19b.err"))"
AG19="$CLAUDE_AGENTS_DIR/task-tg19001"
[[ -f "$AG19/spec.yaml" ]] && ok || fail "N19: агент создан"
NEST19=$(find "$AG19" -maxdepth 1 -name '.new-*' 2>/dev/null | wc -l)
[[ "$NEST19" == "0" ]] && ok || fail "N19: без вложенного .new-* внутри опубликованного каталога"
STRAY19=$(find "$CLAUDE_AGENTS_DIR" -maxdepth 1 -name '.new-task-tg19001.*' 2>/dev/null | wc -l)
[[ "$STRAY19" == "0" ]] && ok || fail "N19: без осиротевшего staging-каталога в реестре"
BR19_COUNT=$(git -C "$PROJ_GIT" branch --list 'task/task-tg19001-*' | wc -l)
[[ "$BR19_COUNT" == "1" ]] && ok || fail "N19: ровно одна ветка task/task-tg19001-* (got $BR19_COUNT)"
WT19_COUNT=$(git -C "$PROJ_GIT" worktree list | grep -c "task-tg19001" || true)
[[ "$WT19_COUNT" == "1" ]] && ok || fail "N19: ровно один worktree для задачи (got $WT19_COUNT)"

# =============================================================== N20
echo "=== N20 (major 3): битая/подмененная spec.yaml -> claude-agent-done отказывает (fail-closed); неизвестный workspace -> отказ ==="
AG20A=$(mk_worktree_agent wt20a "$PROJ_GIT")
mk_inflight "$AG20A" "n20a-key"
printf '%s\n' "not: [valid: yaml" >> "$AG20A/spec.yaml"
call_done "$AG20A" "n20a-key" --summary "N20a" >"$TMP/n20a.out" 2>"$TMP/n20a.err"; RC20A=$?
[[ "$RC20A" == 2 ]] && ok || fail "N20a: битый spec.yaml -> exit 2 (got $RC20A: $(cat "$TMP/n20a.err"))"
[[ ! -f "$AG20A/done.json" ]] && ok || fail "N20a: done.json не создан на битой спеке"

AG20B=$(mk_worktree_agent wt20b "$PROJ_GIT")
mk_inflight "$AG20B" "n20b-key"
python3 -c '
import sys
p = sys.argv[1]
s = open(p).read().replace("workspace: worktree", "workspace: bogus")
open(p, "w").write(s)
' "$AG20B/spec.yaml"
call_done "$AG20B" "n20b-key" --summary "N20b" >"$TMP/n20b.out" 2>"$TMP/n20b.err"; RC20B=$?
[[ "$RC20B" == 2 ]] && ok || fail "N20b: незнакомое workspace 'bogus' -> exit 2 (got $RC20B: $(cat "$TMP/n20b.err"))"
[[ ! -f "$AG20B/done.json" ]] && ok || fail "N20b: done.json не создан на неизвестном workspace"

# =============================================================== N21
echo "=== N21 (major 4): mission_base не 40-hex ('HEAD') -> отказ; detached HEAD / чужая ветка -> отказ ==="
AG21A=$(mk_worktree_agent wt21a "$PROJ_GIT")
( cd "$AG21A/work" && echo "n21a" > n21a.txt && git add n21a.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "n21a commit" )
python3 - "$AG21A/control.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["mission_base"] = "HEAD"
json.dump(d, open(p, "w"), ensure_ascii=False)
PY
mk_inflight "$AG21A" "n21a-key"
call_done "$AG21A" "n21a-key" --summary "N21a" >"$TMP/n21a.out" 2>"$TMP/n21a.err"; RC21A=$?
[[ "$RC21A" == 2 ]] && ok || fail "N21a: mission_base='HEAD' -> exit 2 (got $RC21A: $(cat "$TMP/n21a.err"))"
[[ ! -f "$AG21A/done.json" ]] && ok || fail "N21a: done.json не создан"

AG21B=$(mk_worktree_agent wt21b "$PROJ_GIT")
( cd "$AG21B/work" && git checkout -q --detach HEAD )
mk_inflight "$AG21B" "n21b-key"
call_done "$AG21B" "n21b-key" --summary "N21b" >"$TMP/n21b.out" 2>"$TMP/n21b.err"; RC21B=$?
[[ "$RC21B" == 2 ]] && ok || fail "N21b: detached HEAD -> exit 2 (got $RC21B: $(cat "$TMP/n21b.err"))"
[[ ! -f "$AG21B/done.json" ]] && ok || fail "N21b: done.json не создан"

AG21C=$(mk_worktree_agent wt21c "$PROJ_GIT")
( cd "$AG21C/work" && git checkout -q -b some-other-branch )
mk_inflight "$AG21C" "n21c-key"
call_done "$AG21C" "n21c-key" --summary "N21c" >"$TMP/n21c.out" 2>"$TMP/n21c.err"; RC21C=$?
[[ "$RC21C" == 2 ]] && ok || fail "N21c: чужая ветка (не task/<name>-*) -> exit 2 (got $RC21C: $(cat "$TMP/n21c.err"))"
[[ ! -f "$AG21C/done.json" ]] && ok || fail "N21c: done.json не создан"

# =============================================================== N22
echo "=== N22 (major 5): дозапись changes только владельцем - чужой envelope_key -> заявка не тронута ==="
PROJ22="$TMP/proj22"; mkdir -p "$PROJ22"
AG22=$(mk_none_agent evtd22 "workspace: direct
project: $PROJ22")
write_done_json_direct "$AG22" "n22-foreign-key" "N22 stale claim" null
"$RUN" spool-put evtd22 --text "n22-event" >/dev/null
"$RUN" intake "$AG22" >/dev/null
echo ok > "$MOCK_MODE_FILE"
"$RUN" step "$AG22" >/dev/null 2>"$TMP/n22-step.err"
[[ "$(jq_file "$AG22/done.json" 'd.get("changes")')" == "None" ]] \
  && ok || fail "N22: done.json чужого envelope_key не тронут (changes все еще null)"
[[ "$(jq_file "$AG22/done.json" 'd.get("envelope_key")')" == "n22-foreign-key" ]] \
  && ok || fail "N22: envelope_key done.json не переписан текущим прогоном"

# =============================================================== N23
echo "=== N23 (major 6): envelope_key в done.json не соответствует конверту в inbox/done/ -> карточка не шлется ==="
BASE23="$TMP/recon-agents-n23"; mkdir -p "$BASE23"
AG23=$(mk_isolated_agent "$BASE23" evtd23)
write_done_json "$AG23" "n23-key-not-real" "N23 summary"
# намеренно НЕ создаем mk_done_envelope - конверта с этим ключом в inbox/done/ нет
ALERT_LOG23="$TMP/n23-alert.log"
mk_alert_ok "$ALERT_LOG23" "$TMP/alert-ok-n23.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n23.sh" "$RUN" done-notify "$AG23" >/dev/null 2>"$TMP/n23.err"
[[ "$(alert_block_count "$ALERT_LOG23")" == "0" ]] \
  && ok || fail "N23: без реального конверта в inbox/done - карточка не отправлена"
[[ "$(jq_file "$AG23/done.json" 'd.get("pushed_at")')" == "None" ]] \
  && ok || fail "N23: pushed_at не проставлен"

# =============================================================== N24
echo "=== N24 (major 7/8): секрет в пути changes замаскирован; 20000 путей -> кап 100 + общее число в detail, доставка проходит ==="
BASE24="$TMP/recon-agents-n24"; mkdir -p "$BASE24"
AG24=$(mk_isolated_agent "$BASE24" evtd24)
python3 -c '
import json, sys
paths = ["secret/token=abcdefghijklmnopqrstuvwx1234.txt"] \
    + ["file_%05d.txt" % i for i in range(19999)]
d = {"state": "requested", "requested_at": "2026-01-01T00:00:00Z", "envelope_key": sys.argv[2],
     "workspace": "direct", "summary": "N24 summary",
     "branch": None, "base": None, "commit_sha": None, "empty": False,
     "changes": paths,
     "pushed_at": None, "accepted_at": None, "integrated_at": None, "cleaned_at": None, "archived_at": None}
json.dump(d, open(sys.argv[1] + "/done.json", "w"), ensure_ascii=False)
' "$AG24" "n24-key"
mk_done_envelope "$AG24" "n24-key"
ALERT_LOG24="$TMP/n24-alert.log"
mk_alert_ok "$ALERT_LOG24" "$TMP/alert-ok-n24.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n24.sh" "$RUN" done-notify "$AG24" >/dev/null 2>"$TMP/n24.err"; RC24=$?
[[ "$RC24" == 0 ]] && ok || fail "N24: done-notify не падает на 20000 путях (got $RC24: $(cat "$TMP/n24.err"))"
[[ "$(alert_block_count "$ALERT_LOG24")" == "1" ]] && ok || fail "N24: доставка проходит (ровно один вызов)"
DETAIL24=$(alert_detail "$ALERT_LOG24" 1)
[[ "$(jq_str "$DETAIL24" 'len(d.get("changes") or [])')" == "100" ]] \
  && ok || fail "N24: в json-detail не более 100 путей (got $(jq_str "$DETAIL24" 'len(d.get("changes") or [])'))"
[[ "$(jq_str "$DETAIL24" 'd.get("changes_total")')" == "20000" ]] \
  && ok || fail "N24: detail несет общее число путей (got $(jq_str "$DETAIL24" 'd.get("changes_total")'))"
ALERT_CONTENT24=$(cat "$ALERT_LOG24" 2>/dev/null)
[[ "$ALERT_CONTENT24" != *"abcdefghijklmnopqrstuvwx1234"* ]] \
  && ok || fail "N24: секрет в пути changes замаскирован (не должен уйти в alert-вызов)"

# =============================================================== N25
echo "=== N25 (minor): текст задачи содержит {{project}} - подстановка одношаговая, goal сохранен дословно, спека не ломается ==="
TEXT25='почини {{project}} и заодно {{name}} и {{goal}} в тексте'
OUT25=$("$RC" agent new-task --name task-tg25001 --project demoproj --text "$TEXT25" 2>"$TMP/n25.err"); RC25=$?
[[ "$RC25" == 0 ]] && ok || fail "N25: exit 0 - текст с плейсхолдерами не ломает спеку (got $RC25: $(cat "$TMP/n25.err"))"
AG25="$CLAUDE_AGENTS_DIR/task-tg25001"
[[ "$(yaml_goal_eq "$AG25/spec.yaml" "$TEXT25")" == "True" ]] \
  && ok || fail "N25: goal идентичен исходному тексту байт-в-байт, включая {{project}}/{{name}}/{{goal}}"
[[ "$(yaml_get "$AG25/spec.yaml" 'd.get("project")')" == "$PROJ_NONE" ]] \
  && ok || fail "N25: project резолвлен нормально, не подменен содержимым goal"
[[ "$(yaml_get "$AG25/spec.yaml" 'd.get("name")')" == "task-tg25001" ]] \
  && ok || fail "N25: name не подменен содержимым goal"

# =============================================================== N15 (регресс §5)
echo "=== N15: ручной create/spool-событие работают как раньше; агент без done.json не порождает пуш с kind:done (посторонние тревоги планировщика - не в счет) ==="
BASE15="$TMP/recon-agents-n15"; mkdir -p "$BASE15"
SPOOL15="$TMP/spool-n15"; mkdir -p "$SPOOL15"
LEGACY_SPEC="$TMP/legacy1.spec.yaml"
cat > "$LEGACY_SPEC" <<EOF
schema: 1
name: legacy1
type: event
role: none
goal: "N15 regression - manual create unaffected by new-task"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
EOF
assert "N15: ручной create event-агента (как до этапа)" 0 \
  env CLAUDE_AGENTS_DIR="$BASE15" CLAUDE_AGENT_SPOOL_BASE="$SPOOL15" \
  "$RC" agent create legacy1 --spec "$LEGACY_SPEC"
AG15="$BASE15/legacy1"
[[ "$(jq_file "$AG15/control.json" 'd["desired"]')" == "paused" ]] && ok || fail "N15: create дает desired=paused (регресс)"
CLAUDE_AGENTS_DIR="$BASE15" CLAUDE_AGENT_SPOOL_BASE="$SPOOL15" "$RC" agent start legacy1 >/dev/null 2>&1
CLAUDE_AGENTS_DIR="$BASE15" CLAUDE_AGENT_SPOOL_BASE="$SPOOL15" "$RUN" spool-put legacy1 --text "n15-regular-event" >/dev/null
CLAUDE_AGENTS_DIR="$BASE15" CLAUDE_AGENT_SPOOL_BASE="$SPOOL15" "$RUN" intake "$AG15" >/dev/null
K15=$(ls "$AG15/inbox/pending" 2>/dev/null | sed 's/\.json//')
CLAUDE_AGENTS_DIR="$BASE15" CLAUDE_AGENT_SPOOL_BASE="$SPOOL15" "$RUN" step "$AG15" >/dev/null 2>"$TMP/n15.err"
[[ -n "$K15" && -f "$AG15/inbox/done/$K15.json" ]] \
  && ok || fail "N15: событие ('/task'-эквивалент) обработано как раньше ($(cat "$TMP/n15.err"))"
[[ ! -f "$AG15/done.json" ]] && ok || fail "N15: агент без заявки о готовности - done.json отсутствует"
ALERT_LOG15="$TMP/n15-alert.log"
mk_alert_ok "$ALERT_LOG15" "$TMP/alert-ok-n15.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n15.sh" "$RUN" done-notify "$AG15" >/dev/null 2>"$TMP/n15b.err"
[[ "$(alert_log_has_done_kind "$ALERT_LOG15")" == "False" ]] \
  && ok || fail "N15: агент без done.json не порождает пуш с kind:done (посторонние тревоги планировщика типа control_invalid к этапу не относятся)"

####################################################################
# V2.7b: приемка, интеграция, уборка, архив (кейсы B1-B38).
# Контракт: docs/design-2026-07-26-v2.7b-acceptance-integration.md §9-10.
# Написано с чистого листа по спеке (SDD, RED-фаза): bin/_rc_projects.sh,
# ветки done-advance/done-verdict в bin/claude-agent-run, ветка kind=="done"
# и обработка "d:"-callback в bin/claude-agent-tgbot, bin/claude-rc,
# bin/claude-control-project-watchdog ни разу не читаны через Read за это
# дополнение - только сама спека V2.7b и уже установленный (в N16/T14 выше,
# в tests/test-agent-tg-cards.sh) публичный контракт
# route_callback(data) -> (kind, id, arg) и authorized_cb(update, wl) -> bool.
#
# Ambiguity-заметки (полный список вопросов - в отчете задачи):
# - route_callback для "d:<agent>:<sha8>:a|r" - форма возврата спекой не
#   зафиксирована буквально (дан только формат callback-data). Черным ящиком
#   (тот же прием, что и в T14/N16 выше - реальный вызов, без чтения текста
#   функции) установлено: ("d:...:a") -> ("accept_done", "<agent>", "<sha8>").
#   "r"-ветка (reject) этим приемом не проверялась - B6 единственный кейс,
#   которому свим-требование §9.1 предписывает идти через route_callback.
# - только B6 (swim-требование §9.1) обязан идти через authorized_cb+
#   route_callback; B7-B11 (гейт identity, no-op, устаревание, комментарий)
#   бьют по claude-agent-run done-verdict напрямую - спека называет его
#   единственным владельцем записи вердикта, и swim-список явно требует
#   реальный route_callback только для кнопки приемки.
# - "done-verdict" не имеет заявленного --by в usage-строке §3.3 - verdict_by
#   не проверяется на конкретное значение, только на непустоту после успеха.
# - archive/tombstones - "под одним корнем" с agents/ (§6.2); корень принят
#   как dirname(CLAUDE_AGENTS_DIR) (т.е. $TMP/archive, $TMP/tombstones).
# - "бот нигде не пишет done.json" (B10) проверено как ПОЛНОЕ отсутствие
#   строки "done.json" в bin/claude-agent-tgbot - прочитано буквально
#   ("нигде"), а не как поиск конкретно open(...,"w").
# - B35 (бульхед) проверен как два независимых последовательных вызова
#   `done-advance` (агент A битый, агент B здоровый) в одном процессе, а не
#   через полный `claude-agent-reconciler --once` - глобальный проход по
#   ВСЕМ агентам общего CLAUDE_AGENTS_DIR рискует зацепить агентов N-серии
#   выше по файлу; спека называет владельцем именно однoagентную
#   `done-advance <agent_dir>`, реконсилер лишь "зовет ее безусловно на
#   каждом проходе" - сам глобальный цикл вне контракта, проверяемого тут.
####################################################################

# --- fixtures V2.7b ---
RC_PROJECTS_HELPER="$HERE/../bin/_rc_projects.sh"
rc_project_path() { ( . "$RC_PROJECTS_HELPER" 2>/dev/null; project_path "$1" 2>/dev/null ); } # <name> -> path (или пусто)
rc_project_integrate() { ( . "$RC_PROJECTS_HELPER" 2>/dev/null; project_integrate "$1" 2>/dev/null ); } # <name> -> integrate (или пусто)
# V2.10 T5 fixture: project_lessons_path из bin/_rc_projects.sh (V2.9 §6) - единственный резолвер пути зеркала уроков.
rc_project_lessons_path() { ( . "$RC_PROJECTS_HELPER" 2>/dev/null; project_lessons_path "$1" 2>/dev/null ); } # <name> -> path (или пусто)

register_flat_project() { # <name> <path> -> дописывает форму A (плоский скаляр) в projects.yaml
  printf '%s: %s\n' "$1" "$2" >> "$CLAUDE_RC_PROJECTS_FILE"
}
register_obj_project() { # <name> <path> [integrate] -> дописывает форму B (объект) в projects.yaml
  local name="$1" path="$2" integ="${3:-}"
  { printf '%s:\n  path: %s\n' "$name" "$path"
    [[ -n "$integ" ]] && printf '  integrate: %s\n' "$integ"
  } >> "$CLAUDE_RC_PROJECTS_FILE"
}
register_obj_project_lessons() { # <name> <path> <integrate> <lessons-rel> -> форма B с lessons (V2.10 T5, аналог lessons.sh)
  local name="$1" path="$2" integ="$3" lessons="$4"
  { printf '%s:\n  path: %s\n' "$name" "$path"
    [[ -n "$integ" ]] && printf '  integrate: %s\n' "$integ"
    [[ -n "$lessons" ]] && printf '  lessons: %s\n' "$lessons"
  } >> "$CLAUDE_RC_PROJECTS_FILE"
}
rewrite_project_integrate() { # <name> <new-integrate> -> точечно правит .integrate существующей объектной записи (без дублей ключей)
  python3 -c '
import yaml, sys
p, name, integ = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(p)) or {}
d[name]["integrate"] = integ
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
' "$CLAUDE_RC_PROJECTS_FILE" "$1" "$2"
}
rewrite_project_path() { # <name> <new-path> -> точечно правит .path существующей объектной записи (V2.10 T10, дрейф реестра)
  python3 -c '
import yaml, sys
p, name, newpath = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(p)) or {}
d[name]["path"] = newpath
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
' "$CLAUDE_RC_PROJECTS_FILE" "$1" "$2"
}
remove_project() { # <name> -> убирает запись целиком из реестра (V2.10 T10, "имя пропало из реестра")
  python3 -c '
import yaml, sys
p, name = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(p)) or {}
d.pop(name, None)
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
' "$CLAUDE_RC_PROJECTS_FILE" "$1"
}
call_commit() { # <agent-dir> <event-key> [опции claude-agent-commit...] - тот же прием, что call_done;
  # в отличие от call_done, claude-agent-commit фенсит по РЕАЛЬНОМУ cwd
  # прогона (§1.2) - поэтому вызывается ИЗ <agent-dir>/work, если тест не
  # проверяет именно нарушение этой границы (тогда используется "$COMMIT"
  # напрямую с нужным cwd, см. B74).
  local dir="$1" key="$2"; shift 2
  ( cd "$dir/work" && CLAUDE_AGENT_DIR="$dir" CLAUDE_AGENT_EVENT_KEY="$key" "$COMMIT" "$@" )
}

mk_git_project() { # <dir> -> git-репозиторий с веткой main и одним коммитом (f.txt)
  local dir="$1"
  git init -q --initial-branch=main "$dir"
  ( cd "$dir" && echo base > f.txt && git add f.txt \
    && git -c user.email=t@t -c user.name=t commit -qm init )
}

set_done_field() { # <agent-dir> <py-статемент, мутирующий d in-place> - патч done.json целиком (обходит done-lock - для фикстур белого ящика по фазам, не для проверки самого лока)
  local dir="$1" stmt="$2"
  python3 -c '
import json, sys
p = sys.argv[1] + "/done.json"
d = json.load(open(p))
exec(sys.argv[2])
json.dump(d, open(p, "w"), ensure_ascii=False)
' "$dir" "$stmt"
}

mk_requested_worktree() { # <name> <project> <event-key> <summary> -> печатает agent-dir; mk_worktree_agent + 1 коммит + call_done (requested, реальный фенсинг)
  local name="$1" proj="$2" key="$3" summary="$4"
  local dir
  dir=$(mk_worktree_agent "$name" "$proj")
  ( cd "$dir/work" && echo "$name change" > "$name.txt" && git add "$name.txt" \
    && git -c user.email=t@t -c user.name=t commit -qm "$name commit" )
  mk_inflight "$dir" "$key"
  call_done "$dir" "$key" --summary "$summary" >/dev/null 2>"$TMP/$name-done.err"
  echo "$dir"
}
accept_agent() { # <agent-dir> -> патчит requested->accepted + поля V2.7b (обходит done-verdict - фикстура для изолированной проверки фаз integrate/cleanup/archive)
  local dir="$1"
  set_done_field "$dir" '
d["state"] = "accepted"
d["verdict_at"] = "2026-02-01T00:00:00Z"
d["verdict_by"] = "tg:1001"
d["verdict_comment"] = None
d.setdefault("integrate_mode", None)
d.setdefault("integrate_ref", None)
d.setdefault("phase_attempts", 0)
d.setdefault("phase_error", None)
'
}
mk_created_none_agent() { # <name> <project> [workspace: none|direct] -> печатает agent-dir; реальный "$RC agent create" (control.json настоящий, desired=paused)
  local name="$1" proj="$2" ws="${3:-none}"
  local specfile="$TMP/spec-created-$name.yaml"
  cat > "$specfile" <<EOF
schema: 1
name: $name
type: event
role: none
project: $proj
goal: "created-none fixture for $name"
autonomy: suggest
memory_max_mb: 100
limits: { runs_per_day: 100, run_timeout_s: 20 }
source: { kind: spool, replay_window_h: 72 }
workspace: $ws
EOF
  "$RC" agent create "$name" --spec "$specfile" >/dev/null 2>"$TMP/create-created-$name.err"
  local rc=$?
  [[ "$rc" == 0 ]] && ok || fail "fixture: create $name (workspace:$ws, реальный create) ($(cat "$TMP/create-created-$name.err"))"
  echo "$CLAUDE_AGENTS_DIR/$name"
}
mk_gh_mock() { # <bindir> <log> [existing-pr-url] -> создает $bindir/gh (реальный внешний бинарь-подмена, git не мокается)
  local bindir="$1" log="$2" existing="${3:-}"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
printf '%s\n' "\$@" >> "$log"
printf '===\n' >> "$log"
case "\$1 \$2" in
  "pr create") echo "https://github.com/x/y/pull/1" ;;
  "pr list")
    if [[ -n "$existing" ]]; then echo '[{"url":"$existing"}]'; else echo '[]'; fi
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bindir/gh"
}

# --- B6: сквозной разбор callback-кнопки реальным ботом (authorized_cb+route_callback) ---
B6_HELPER="$TMP/b6-helper.py"
cat > "$B6_HELPER" <<'PY'
import importlib.machinery, importlib.util, json, sys


def load_tgbot(path):
    loader = importlib.machinery.SourceFileLoader("tgbot_under_test_b", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main():
    tgbot_path = sys.argv[1]
    from_id, data = int(sys.argv[2]), sys.argv[3]
    tgbot = load_tgbot(tgbot_path)
    wl = {1001}
    update = {"callback_query": {"id": "1", "from": {"id": from_id},
              "message": {"chat": {"id": from_id, "type": "private"}, "message_id": 1},
              "data": data}}
    if not tgbot.authorized_cb(update, wl):
        print(json.dumps({"authorized": False}))
        return
    result = tgbot.route_callback(data)
    print(json.dumps({"authorized": True, "route": list(result)}, ensure_ascii=False))


main()
PY
b6_dispatch() { python3 "$B6_HELPER" "$HERE/../bin/claude-agent-tgbot" "$1" "$2"; } # <from-id> <callback-data>

# =============================================================== B1
echo "=== B1: projects.yaml форма A (плоская) резолвится как раньше ==="
[[ "$(rc_project_path demoproj)" == "$PROJ_NONE" ]] && ok || fail "B1: project_path резолвит форму A (got: $(rc_project_path demoproj))"
OUTB1=$("$RC" agent new-task --name task-tgb001 --project demoproj --text "B1 regression" 2>"$TMP/b1.err"); RCB1=$?
[[ "$RCB1" == 0 ]] && ok || fail "B1: agent new-task с формой A все еще работает (got $RCB1: $(cat "$TMP/b1.err"))"
[[ "$(yaml_get "$CLAUDE_AGENTS_DIR/task-tgb001/spec.yaml" 'd.get("project")')" == "$PROJ_NONE" ]] \
  && ok || fail "B1: project в spec.yaml == путь, не мусор"

# =============================================================== B2
echo "=== B2: форма B (объект) отдает path; new-task с project-объектом не превращает project в сериализованную мапу ==="
PROJ_B2="$TMP/proj-b2"; mkdir -p "$PROJ_B2"
register_obj_project projb2 "$PROJ_B2" pr
[[ "$(rc_project_path projb2)" == "$PROJ_B2" ]] && ok || fail "B2: project_path резолвит форму B (got: $(rc_project_path projb2))"
OUTB2=$("$RC" agent new-task --name task-tgb002 --project projb2 --text "B2 obj-form" 2>"$TMP/b2.err"); RCB2=$?
[[ "$RCB2" == 0 ]] && ok || fail "B2: new-task с project-объектом проходит (got $RCB2: $(cat "$TMP/b2.err"))"
PB2=$(yaml_get "$CLAUDE_AGENTS_DIR/task-tgb002/spec.yaml" 'd.get("project")')
[[ "$PB2" == "$PROJ_B2" ]] && ok || fail "B2: project в spec.yaml - чистый путь, не сериализованная мапа (got: $PB2)"

# =============================================================== B3
echo "=== B3: объектная форма без integrate -> дефолт none (по факту фазы integrate: skipped, ветка цела) ==="
PROJ_B3="$TMP/proj-b3"; mkdir -p "$PROJ_B3"
mk_git_project "$PROJ_B3"
register_obj_project projb3 "$PROJ_B3"
[[ "$(rc_project_path projb3)" == "$PROJ_B3" ]] && ok || fail "B3: fixture - project_path резолвит projb3"
AGB3=$(mk_requested_worktree wtb3 "$PROJ_B3" b3-key "B3 summary")
BRANCH_B3=$(jq_file "$AGB3/done.json" 'd.get("branch")')
COMMITB3=$(jq_file "$AGB3/done.json" 'd.get("commit_sha")')
accept_agent "$AGB3"
"$RUN" done-advance "$AGB3" >/dev/null 2>"$TMP/b3.err"; RCB3=$?
[[ "$RCB3" == 0 ]] && ok || fail "B3: done-advance проходит на project без integrate (got $RCB3: $(cat "$TMP/b3.err"))"
[[ "$(jq_file "$AGB3/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B3: state=integrated (дефолт none сработал)"
[[ "$(jq_file "$AGB3/done.json" 'd.get("integrate_mode")')" == "skipped" ]] && ok || fail "B3: integrate_mode=skipped"
[[ "$(git -C "$PROJ_B3" rev-parse "refs/heads/$BRANCH_B3")" == "$COMMITB3" ]] && ok || fail "B3: ветка задачи цела с исходным коммитом"

# =============================================================== B4
echo "=== B4: незнакомое integrate -> отказ фазы integrate + attention, состояние не двигается ==="
PROJ_B4="$TMP/proj-b4"; mkdir -p "$PROJ_B4"
mk_git_project "$PROJ_B4"
register_obj_project projb4 "$PROJ_B4" bogus
AGB4=$(mk_requested_worktree wtb4 "$PROJ_B4" b4-key "B4 summary")
accept_agent "$AGB4"
"$RUN" done-advance "$AGB4" >/dev/null 2>"$TMP/b4.err"; RCB4=$?
[[ "$RCB4" == 3 ]] && ok || fail "B4: незнакомое integrate -> exit 3 (got $RCB4: $(cat "$TMP/b4.err"))"
[[ "$(jq_file "$AGB4/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B4: state остается accepted"
[[ -s "$TMP/b4.err" ]] && ok || fail "B4: внятное сообщение об ошибке"
[[ "$(jq_file "$AGB4/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B4: attention выставлен"

# =============================================================== B5
echo "=== B5 (структурный): yq-выражение резолва project вне _rc_projects.sh не встречается ==="
CNT_B5=$(grep -rho '\[strenv(name)\]' "$HERE/../bin" --exclude=_rc_projects.sh 2>/dev/null | wc -l | tr -d ' ')
[[ "$CNT_B5" == "0" ]] && ok || fail "B5: yq-выражение резолва вне bin/_rc_projects.sh не встречается ни разу (got $CNT_B5; внутри самого хелпера их закономерно два - путь и режим)"

# =============================================================== B6 (swim §9.1, обязателен реальный route_callback)
# (аудит "тестовый барьер" дефект 12): callback-data ОБЯЗАНА идти от РЕАЛЬНОЙ
# генерации кнопки (question_card/_done_card), а не собираться руками
# "d:agent:sha8:a" - иначе поломка в самой генерации (формат, порядок полей)
# осталась бы незамеченной. Применение тапа - через РЕАЛЬНЫЙ
# _handle_done_callback (api() застаблен, сеть не нужна), а не done-verdict
# напрямую - иначе поломка маршрутизации внутри бота (какая ветка вызывает
# --accept/--reject, что передается как agent_dir/sha8) прошла бы мимо теста.
echo "=== B6: тап 'принять' идет через РЕАЛЬНУЮ генерацию кнопки (_done_card) и реальный _handle_done_callback бота ==="
PROJ_B6="$TMP/proj-b6"; mkdir -p "$PROJ_B6"
mk_git_project "$PROJ_B6"
AGB6=$(mk_requested_worktree wtb6 "$PROJ_B6" b6-key "B6 summary")
COMMITB6=$(jq_file "$AGB6/done.json" 'd.get("commit_sha")')
BRANCH_B6=$(jq_file "$AGB6/done.json" 'd.get("branch")')
SHA8_B6="${COMMITB6:0:8}"
DATA_B6=$(python3 - "$HERE/../bin/claude-agent-tgbot" wtb6 projb6 "B6 summary" \
  "$COMMITB6" "$BRANCH_B6" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent, project, summary, commit_sha, branch = sys.argv[1:7]
loader = SourceFileLoader("tgbot_b6card", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
detail = {"kind": "done", "agent": agent, "project": project, "summary": summary,
          "commit_sha": commit_sha, "branch": branch, "changes": None,
          "empty": None}
text, reply_markup = mod.question_card(detail)
print(reply_markup["inline_keyboard"][0][0]["callback_data"])
PY
)
DISPATCH_B6=$(b6_dispatch 1001 "$DATA_B6")
[[ "$(jq_str "$DISPATCH_B6" 'd.get("authorized")')" == "True" ]] && ok || fail "B6: авторизованный from_id проходит (got: $DISPATCH_B6)"
KIND_B6=$(jq_str "$DISPATCH_B6" 'd["route"][0]')
[[ "$KIND_B6" == "accept_done" ]] && ok || fail "B6: route_callback распознал кнопку из _done_card (got: $DISPATCH_B6, data=$DATA_B6)"
AGENT_B6=$(jq_str "$DISPATCH_B6" 'd["route"][1]')
SHA_B6=$(jq_str "$DISPATCH_B6" 'd["route"][2]')
[[ "$AGENT_B6" == "wtb6" ]] && ok || fail "B6: route_callback вернул имя агента (got: $DISPATCH_B6)"
[[ "$SHA_B6" == "$SHA8_B6" ]] && ok || fail "B6: route_callback вернул sha8 (got: $DISPATCH_B6)"
CALLS_B6=$(python3 - "$HERE/../bin/claude-agent-tgbot" "$AGENT_B6" "$SHA_B6" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent, sha8 = sys.argv[1:4]
loader = SourceFileLoader("tgbot_b6handle", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
calls = []
def fake_api(token, proxy, method, http_timeout=30, **kw):
    calls.append((method, kw.get("text")))
    return {}
mod.api = fake_api
mod._handle_done_callback("TOK", None, 1001, 1, "accept_done", agent, sha8, 1001)
print(json.dumps(calls, ensure_ascii=False))
PY
)
APPLIED_B6=$(python3 -c '
import json, sys
calls = json.loads(sys.argv[1])
print(any(t and "принят" in t for _, t in calls))
' "$CALLS_B6")
[[ "$APPLIED_B6" == "True" ]] && ok || fail "B6: реальный _handle_done_callback применил вердикт (calls=$CALLS_B6)"
[[ "$(jq_file "$AGB6/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B6: state=accepted"
[[ "$(jq_file "$AGB6/done.json" 'bool(d.get("verdict_at"))')" == "True" ]] && ok || fail "B6: verdict_at проставлен"
[[ "$(jq_file "$AGB6/done.json" 'bool(d.get("verdict_by"))')" == "True" ]] && ok || fail "B6: verdict_by проставлен"

# =============================================================== B7
echo "=== B7: тап с чужого chat_id игнорируется, вердикт не применяется ==="
PROJ_B7="$TMP/proj-b7"; mkdir -p "$PROJ_B7"
mk_git_project "$PROJ_B7"
AGB7=$(mk_requested_worktree wtb7 "$PROJ_B7" b7-key "B7 summary")
COMMITB7=$(jq_file "$AGB7/done.json" 'd.get("commit_sha")')
SHA8_B7="${COMMITB7:0:8}"
DISPATCH_B7=$(b6_dispatch 9999 "d:wtb7:${SHA8_B7}:a")
[[ "$(jq_str "$DISPATCH_B7" 'd.get("authorized")')" == "False" ]] && ok || fail "B7: неавторизованный from_id -> authorized=False (got: $DISPATCH_B7)"
[[ "$(jq_file "$AGB7/done.json" 'd.get("state")')" == "requested" ]] && ok || fail "B7: state остается requested (чужой тап не применен)"
[[ "$(jq_file "$AGB7/done.json" 'd.get("verdict_at")')" == "None" ]] && ok || fail "B7: verdict_at не проставлен"

# =============================================================== B8
echo "=== B8: повторный тап 'принять' - no-op, verdict_at не переписывается ==="
PROJ_B8="$TMP/proj-b8"; mkdir -p "$PROJ_B8"
mk_git_project "$PROJ_B8"
AGB8=$(mk_requested_worktree wtb8 "$PROJ_B8" b8-key "B8 summary")
COMMITB8=$(jq_file "$AGB8/done.json" 'd.get("commit_sha")')
SHA8_B8="${COMMITB8:0:8}"
"$RUN" done-verdict "$AGB8" --accept --expect-sha "$SHA8_B8" >/dev/null 2>"$TMP/b8a.err"; RCB8A=$?
[[ "$RCB8A" == 0 ]] && ok || fail "B8: fixture - первый accept проходит (got $RCB8A: $(cat "$TMP/b8a.err"))"
VERDICT_AT_B8=$(jq_file "$AGB8/done.json" 'd.get("verdict_at")')
"$RUN" done-verdict "$AGB8" --accept --expect-sha "$SHA8_B8" >/dev/null 2>"$TMP/b8b.err"; RCB8B=$?
[[ "$RCB8B" == 0 ]] && ok || fail "B8: повторный accept - no-op, не ошибка (got $RCB8B: $(cat "$TMP/b8b.err"))"
[[ "$(jq_file "$AGB8/done.json" 'd.get("verdict_at")')" == "$VERDICT_AT_B8" ]] && ok || fail "B8: verdict_at не переписан повтором"

# =============================================================== B9
echo "=== B9: карточка с устаревшим sha8 (агент передекларировал новым коммитом) - вердикт не применен ==="
PROJ_B9="$TMP/proj-b9"; mkdir -p "$PROJ_B9"
mk_git_project "$PROJ_B9"
AGB9=$(mk_requested_worktree wtb9 "$PROJ_B9" b9-key "B9 summary v1")
COMMITB9A=$(jq_file "$AGB9/done.json" 'd.get("commit_sha")')
SHA8_B9A="${COMMITB9A:0:8}"
( cd "$AGB9/work" && echo "b9 v2" > b9v2.txt && git add b9v2.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b9 v2 commit" )
call_done "$AGB9" "b9-key" --summary "B9 summary v2" >/dev/null 2>"$TMP/b9-redeclare.err"
COMMITB9B=$(jq_file "$AGB9/done.json" 'd.get("commit_sha")')
[[ "$COMMITB9B" != "$COMMITB9A" ]] && ok || fail "B9: fixture - передекларация реально сдвинула commit_sha"
"$RUN" done-verdict "$AGB9" --accept --expect-sha "$SHA8_B9A" >/dev/null 2>"$TMP/b9.err"; RCB9=$?
[[ "$RCB9" != 0 ]] && ok || fail "B9: устаревший sha8 -> отказ (got $RCB9)"
[[ "$(jq_file "$AGB9/done.json" 'd.get("state")')" == "requested" ]] && ok || fail "B9: state остается requested (вердикт не применен)"
[[ "$(jq_file "$AGB9/done.json" 'd.get("verdict_at")')" == "None" ]] && ok || fail "B9: verdict_at не проставлен"

# =============================================================== B10
# (аудит "тестовый барьер" дефект 13): однострочный grep ловится
# тривиальным обходом - `open(\n    p + "/done.json")` разносит вызов и
# путь на разные строки и остается незамеченным. AST-разбор рассматривает
# КАЖДЫЙ вызов open/os.remove/os.unlink/durable_write/durable_json целиком
# (ast.get_source_segment покрывает весь узел, сколько бы строк он ни занял)
# и ищет "done.json" в исходном тексте именно ЭТОГО вызова, а не соседней
# строки - многострочный обход больше не проходит незамеченным.
echo "=== B10 (структурный, AST): бот не открывает done.json ни на чтение, ни на запись ==="
CNT_B10=$(python3 - "$HERE/../bin/claude-agent-tgbot" 2>"$TMP/b10-hits.err" <<'PY'
import ast, sys
path = sys.argv[1]
src = open(path).read()
tree = ast.parse(src, filename=path)
targets = {"open", "remove", "unlink", "durable_write", "durable_json"}
hits = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    func = node.func
    name = func.id if isinstance(func, ast.Name) else getattr(func, "attr", None)
    if name not in targets:
        continue
    seg = ast.get_source_segment(src, node) or ""
    if "done.json" in seg:
        hits.append((node.lineno, seg.replace("\n", " ")[:100]))
print(len(hits))
for ln, seg in hits:
    print("%d: %s" % (ln, seg), file=sys.stderr)
PY
)
CNT_B10="${CNT_B10:-0}"
[[ "$CNT_B10" == "0" ]] && ok || fail "B10: bin/claude-agent-tgbot обращается к done.json файлово, а не только упоминает его (got $CNT_B10: $(cat "$TMP/b10-hits.err"))"

# =============================================================== B11
# (аудит "тестовый барьер" дефект 12): reply-маршрут проверяется РЕАЛЬНЫМИ
# sent_map_register/sent_map_lookup/reply_target/_handle_done_reply бота, а
# не прямым done-verdict --comment - иначе поломка в определении "это reply
# на карточку готовности" (reply_target) прошла бы мимо теста.
echo "=== B11: комментарий к отказу идет через РЕАЛЬНЫЙ reply-маршрут бота (sent_map + reply_target + _handle_done_reply) ==="
PROJ_B11="$TMP/proj-b11"; mkdir -p "$PROJ_B11"
mk_git_project "$PROJ_B11"
AGB11=$(mk_requested_worktree wtb11 "$PROJ_B11" b11-key "B11 summary")
COMMITB11=$(jq_file "$AGB11/done.json" 'd.get("commit_sha")')
SHA8_B11="${COMMITB11:0:8}"
SENT_B11="$TMP/sent-b11.json"
python3 -c 'import json; json.dump({}, open("'"$SENT_B11"'", "w"))'
OUT_B11=$(CLAUDE_AGENT_TG_SENT_MAP="$SENT_B11" python3 - "$HERE/../bin/claude-agent-tgbot" wtb11 "$SHA8_B11" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent, sha8 = sys.argv[1:4]
loader = SourceFileLoader("tgbot_b11reply", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.sent_map_register(1101, [11], agent, None, kind="done", qid=sha8)
entry = mod.sent_map_lookup(1101, 11)
rt_kind, rt_qid = mod.reply_target(entry)
out = mod._handle_done_reply(entry.get("agent"), rt_qid, "нужно поправить X", 1001)
print(json.dumps({"kind": rt_kind, "qid": rt_qid, "out": out}, ensure_ascii=False))
PY
); RCB11=$?
[[ "$RCB11" == 0 ]] && ok || fail "B11: реальный reply-маршрут отрабатывает без исключения (got $RCB11: $OUT_B11)"
KIND_B11=$(jq_str "$OUT_B11" 'd.get("kind")')
[[ "$KIND_B11" == "done" ]] && ok || fail "B11: reply_target распознал запись sent_map как kind=done (got: $OUT_B11)"
QID_B11=$(jq_str "$OUT_B11" 'd.get("qid")')
[[ "$QID_B11" == "$SHA8_B11" ]] && ok || fail "B11: reply_target вернул sha8 из sent_map (got: $OUT_B11)"
[[ "$(jq_file "$AGB11/done.json" 'd.get("state")')" == "rejected" ]] && ok || fail "B11: state=rejected"
[[ "$(jq_file "$AGB11/done.json" 'd.get("verdict_comment")')" == "нужно поправить X" ]] && ok || fail "B11: verdict_comment сохранен байт-в-байт"

# =============================================================== B12
echo "=== B12: merge-перемотка (fast-forward) - целевая ветка сдвинута ровно на commit_sha ==="
PROJ_B12="$TMP/proj-b12"; mkdir -p "$PROJ_B12"
mk_git_project "$PROJ_B12"
register_obj_project projb12 "$PROJ_B12" merge
AGB12=$(mk_requested_worktree wtb12 "$PROJ_B12" b12-key "B12 summary")
COMMITB12=$(jq_file "$AGB12/done.json" 'd.get("commit_sha")')
accept_agent "$AGB12"
"$RUN" done-advance "$AGB12" >/dev/null 2>"$TMP/b12.err"; RCB12=$?
[[ "$RCB12" == 0 ]] && ok || fail "B12: done-advance (merge, fast-forward) проходит (got $RCB12: $(cat "$TMP/b12.err"))"
[[ "$(jq_file "$AGB12/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B12: state=integrated"
[[ "$(jq_file "$AGB12/done.json" 'd.get("integrate_mode")')" == "merge" ]] && ok || fail "B12: integrate_mode=merge"
[[ "$(jq_file "$AGB12/done.json" 'd.get("integrate_ref")')" == "$COMMITB12" ]] && ok || fail "B12: integrate_ref = получившийся sha целевой ветки"
[[ "$(git -C "$PROJ_B12" rev-parse refs/heads/main)" == "$COMMITB12" ]] && ok || fail "B12: целевая ветка main сдвинута на commit_sha"
[[ "$(git -C "$PROJ_B12" worktree list | wc -l | tr -d ' ')" == "2" ]] && ok || fail "B12: без лишнего временного worktree (FF не требует мержа)"
# (аудит блокер 5, дефект тестового барьера 5): не только ref, но и
# рабочее дерево dwl (project_path САМ и есть checkout ветки main) обязано
# быть синхронно с новым HEAD - иначе update-ref под чекаутом развел бы
# ссылку и индекс/файлы, git status показал бы обратные изменения.
[[ -z "$(git -C "$PROJ_B12" status --porcelain)" ]] && ok || fail "B12: git status в project_path чист после FF (индекс/файлы синхронны с новым HEAD)"
[[ -f "$PROJ_B12/wtb12.txt" ]] && ok || fail "B12: файл задачи реально появился в рабочем дереве dwl (не только ref сдвинут)"

# =============================================================== B13
echo "=== B13: целевая ветка ушла вперед без конфликта - реальный мерж во временном worktree, дерево dwl не тронуто, temp снят ==="
PROJ_B13="$TMP/proj-b13"; mkdir -p "$PROJ_B13"
mk_git_project "$PROJ_B13"
register_obj_project projb13 "$PROJ_B13" merge
AGB13=$(mk_requested_worktree wtb13 "$PROJ_B13" b13-key "B13 summary")
COMMITB13=$(jq_file "$AGB13/done.json" 'd.get("commit_sha")')
( cd "$PROJ_B13" && echo "unrelated advance" > other.txt && git add other.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "advance main" )
MAIN_ADVANCED_B13=$(git -C "$PROJ_B13" rev-parse refs/heads/main)
F_TXT_BEFORE_B13=$(cat "$PROJ_B13/f.txt")
accept_agent "$AGB13"
"$RUN" done-advance "$AGB13" >/dev/null 2>"$TMP/b13.err"; RCB13=$?
[[ "$RCB13" == 0 ]] && ok || fail "B13: done-advance (реальный мерж без конфликта) проходит (got $RCB13: $(cat "$TMP/b13.err"))"
[[ "$(jq_file "$AGB13/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B13: state=integrated"
[[ "$(jq_file "$AGB13/done.json" 'd.get("integrate_mode")')" == "merge" ]] && ok || fail "B13: integrate_mode=merge"
NEWTIP_B13=$(git -C "$PROJ_B13" rev-parse refs/heads/main)
git -C "$PROJ_B13" merge-base --is-ancestor "$MAIN_ADVANCED_B13" "$NEWTIP_B13" \
  && ok || fail "B13: посторонний коммит main - предок нового tip (реальный мерж, не перезапись)"
git -C "$PROJ_B13" merge-base --is-ancestor "$COMMITB13" "$NEWTIP_B13" \
  && ok || fail "B13: коммит задачи - предок нового tip"
[[ "$(jq_file "$AGB13/done.json" 'd.get("integrate_ref")')" == "$NEWTIP_B13" ]] && ok || fail "B13: integrate_ref = новый tip main"
[[ "$(cat "$PROJ_B13/f.txt")" == "$F_TXT_BEFORE_B13" ]] && ok || fail "B13: файл в рабочем дереве dwl байт-в-байт не тронут"
[[ "$(git -C "$PROJ_B13" worktree list | wc -l | tr -d ' ')" == "2" ]] && ok || fail "B13: временный worktree снят (осталось ровно 2: проект + агент)"
# (аудит блокер 5, дефект тестового барьера 5): рабочее дерево dwl обязано
# быть синхронно с новым HEAD после мержа, а не просто содержать НЕИЗМЕНЕННЫЙ
# f.txt (это условие выполнялось бы и под старым багом - файл, который
# мерж не трогает, не показал бы порчу; сама порча видна в git status и в
# отсутствии добавленного мержем файла задачи).
[[ -z "$(git -C "$PROJ_B13" status --porcelain)" ]] && ok || fail "B13: git status в project_path чист после мержа (индекс/файлы синхронны с новым HEAD)"
[[ -f "$PROJ_B13/wtb13.txt" ]] && ok || fail "B13: файл задачи реально появился в рабочем дереве dwl"

# =============================================================== B14 (swim §9.3, must-fail)
echo "=== B14: ветка задачи сдвинулась ПОСЛЕ заявки - отказ, мержа нет ==="
PROJ_B14="$TMP/proj-b14"; mkdir -p "$PROJ_B14"
mk_git_project "$PROJ_B14"
register_obj_project projb14 "$PROJ_B14" merge
BASE_B14=$(git -C "$PROJ_B14" rev-parse HEAD)
AGB14=$(mk_requested_worktree wtb14 "$PROJ_B14" b14-key "B14 summary")
COMMITB14=$(jq_file "$AGB14/done.json" 'd.get("commit_sha")')
BRANCH_B14=$(jq_file "$AGB14/done.json" 'd.get("branch")')
accept_agent "$AGB14"
( cd "$AGB14/work" && echo "b14 drift" > b14drift.txt && git add b14drift.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b14 drift after request" )
DRIFTED_B14=$(git -C "$AGB14/work" rev-parse HEAD)
[[ "$DRIFTED_B14" != "$COMMITB14" ]] && ok || fail "B14: fixture - ветка задачи реально уехала после заявки"
"$RUN" done-advance "$AGB14" >/dev/null 2>"$TMP/b14.err"; RCB14=$?
[[ "$RCB14" == 3 ]] && ok || fail "B14: отказ фазы (уехавшая ветка) - exit 3 (got $RCB14: $(cat "$TMP/b14.err"))"
[[ "$(jq_file "$AGB14/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B14: state остается accepted (мержа не было)"
[[ "$(git -C "$PROJ_B14" rev-parse refs/heads/main)" == "$BASE_B14" ]] && ok || fail "B14: целевая ветка НЕ сдвинута (мержа нет)"
[[ "$(git -C "$PROJ_B14" rev-parse "refs/heads/$BRANCH_B14")" == "$DRIFTED_B14" ]] && ok || fail "B14: fixture - ветка задачи на месте с уехавшим коммитом"

# =============================================================== B15 (swim §9.3, must-fail)
echo "=== B15: нет mission_base_branch (агент старого образца) - отказ с внятным текстом, не догадка ==="
PROJ_B15="$TMP/proj-b15"; mkdir -p "$PROJ_B15"
mk_git_project "$PROJ_B15"
register_obj_project projb15 "$PROJ_B15" merge
AGB15=$(mk_requested_worktree wtb15 "$PROJ_B15" b15-key "B15 summary")
python3 -c '
import json, sys
p = sys.argv[1] + "/control.json"
d = json.load(open(p))
d.pop("mission_base_branch", None)
json.dump(d, open(p, "w"), ensure_ascii=False)
' "$AGB15"
accept_agent "$AGB15"
"$RUN" done-advance "$AGB15" >/dev/null 2>"$TMP/b15.err"; RCB15=$?
[[ "$RCB15" == 3 ]] && ok || fail "B15: нет mission_base_branch -> exit 3 (got $RCB15: $(cat "$TMP/b15.err"))"
[[ -s "$TMP/b15.err" ]] && ok || fail "B15: внятное сообщение об ошибке (не догадка)"
[[ "$(jq_file "$AGB15/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B15: state остается accepted"

# =============================================================== B16
echo "=== B16: целевая ветка вычекаучена в другом дереве и оно грязное - отказ, ничего не тронуто ==="
PROJ_B16="$TMP/proj-b16"; mkdir -p "$PROJ_B16"
mk_git_project "$PROJ_B16"
register_obj_project projb16 "$PROJ_B16" merge
BASE_B16=$(git -C "$PROJ_B16" rev-parse HEAD)
AGB16=$(mk_requested_worktree wtb16 "$PROJ_B16" b16-key "B16 summary")
# main захвачен как mission_base_branch, пока PROJ_B16 был на main (create
# уже случился внутри mk_requested_worktree выше) - теперь можно увести
# первичный чекаут на служебную ветку, чтобы освободить main для ВТОРОГО
# (secondary) worktree: git не разрешает один и тот же branch checked out
# сразу в двух деревьях.
git -C "$PROJ_B16" checkout -q -b scratch-b16
SECONDARY_B16="$TMP/proj-b16-secondary"
git -C "$PROJ_B16" worktree add -q "$SECONDARY_B16" main
echo "uncommitted drift" >> "$SECONDARY_B16/f.txt"
accept_agent "$AGB16"
"$RUN" done-advance "$AGB16" >/dev/null 2>"$TMP/b16.err"; RCB16=$?
[[ "$RCB16" == 3 ]] && ok || fail "B16: грязное дерево в другом чекауте main -> exit 3 (got $RCB16: $(cat "$TMP/b16.err"))"
[[ "$(jq_file "$AGB16/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B16: state остается accepted (мержа нет)"
[[ "$(git -C "$PROJ_B16" rev-parse refs/heads/main)" == "$BASE_B16" ]] && ok || fail "B16: main не сдвинута"
[[ "$(cat "$SECONDARY_B16/f.txt")" == *"uncommitted drift"* ]] && ok || fail "B16: чужая незакоммиченная правка не тронута"
git -C "$PROJ_B16" worktree remove --force "$SECONDARY_B16" 2>/dev/null || true

# =============================================================== B17
echo "=== B17: конфликт при мерже - abort, временный worktree снят, attention, state остается accepted ==="
PROJ_B17="$TMP/proj-b17"; mkdir -p "$PROJ_B17"
mk_git_project "$PROJ_B17"
register_obj_project projb17 "$PROJ_B17" merge
AGB17=$(mk_worktree_agent wtb17 "$PROJ_B17")
( cd "$AGB17/work" && echo "task version" > f.txt && git add f.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b17 task edits f.txt" )
mk_inflight "$AGB17" "b17-key"
call_done "$AGB17" "b17-key" --summary "B17 summary" >/dev/null 2>"$TMP/b17-done.err"
( cd "$PROJ_B17" && echo "main version" > f.txt && git add f.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b17 main edits f.txt" )
MAIN_TIP_B17=$(git -C "$PROJ_B17" rev-parse refs/heads/main)
accept_agent "$AGB17"
"$RUN" done-advance "$AGB17" >/dev/null 2>"$TMP/b17.err"; RCB17=$?
[[ "$RCB17" == 3 ]] && ok || fail "B17: конфликт -> exit 3 (got $RCB17: $(cat "$TMP/b17.err"))"
[[ "$(jq_file "$AGB17/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B17: state остается accepted (dwl разруливает)"
[[ "$(git -C "$PROJ_B17" rev-parse refs/heads/main)" == "$MAIN_TIP_B17" ]] && ok || fail "B17: main не сдвинута (merge --abort)"
[[ "$(git -C "$PROJ_B17" worktree list | wc -l | tr -d ' ')" == "2" ]] && ok || fail "B17: временный worktree снят"
[[ "$(jq_file "$AGB17/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B17: attention выставлен"

# =============================================================== B18
echo "=== B18: empty:true - сразу integrated/skipped, integrate_ref:null, main не тронута ==="
PROJ_B18="$TMP/proj-b18"; mkdir -p "$PROJ_B18"
mk_git_project "$PROJ_B18"
register_obj_project projb18 "$PROJ_B18" merge
BASE_B18=$(git -C "$PROJ_B18" rev-parse HEAD)
AGB18=$(mk_worktree_agent wtb18 "$PROJ_B18")
mk_inflight "$AGB18" "b18-key"
call_done "$AGB18" "b18-key" --summary "B18 summary" >/dev/null 2>"$TMP/b18-done.err"
[[ "$(jq_file "$AGB18/done.json" 'd.get("empty")')" == "True" ]] && ok || fail "B18: fixture - empty=true (ни одного коммита)"
accept_agent "$AGB18"
"$RUN" done-advance "$AGB18" >/dev/null 2>"$TMP/b18.err"; RCB18=$?
[[ "$RCB18" == 0 ]] && ok || fail "B18: empty:true -> exit 0 (got $RCB18: $(cat "$TMP/b18.err"))"
[[ "$(jq_file "$AGB18/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B18: state=integrated"
[[ "$(jq_file "$AGB18/done.json" 'd.get("integrate_mode")')" == "skipped" ]] && ok || fail "B18: integrate_mode=skipped"
[[ "$(jq_file "$AGB18/done.json" 'd.get("integrate_ref")')" == "None" ]] && ok || fail "B18: integrate_ref=null"
[[ "$(git -C "$PROJ_B18" rev-parse refs/heads/main)" == "$BASE_B18" ]] && ok || fail "B18: main не тронута"

# =============================================================== B19
echo "=== B19: integrate:none (форма A) - skipped, ветка задачи цела, main не тронута ==="
PROJ_B19="$TMP/proj-b19"; mkdir -p "$PROJ_B19"
mk_git_project "$PROJ_B19"
register_flat_project projb19flat "$PROJ_B19"
BASE_B19=$(git -C "$PROJ_B19" rev-parse HEAD)
AGB19=$(mk_requested_worktree wtb19 "$PROJ_B19" b19-key "B19 summary")
COMMITB19=$(jq_file "$AGB19/done.json" 'd.get("commit_sha")')
BRANCH_B19=$(jq_file "$AGB19/done.json" 'd.get("branch")')
accept_agent "$AGB19"
"$RUN" done-advance "$AGB19" >/dev/null 2>"$TMP/b19.err"; RCB19=$?
[[ "$RCB19" == 0 ]] && ok || fail "B19: integrate:none (форма A, дефолт) -> exit 0 (got $RCB19: $(cat "$TMP/b19.err"))"
[[ "$(jq_file "$AGB19/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B19: state=integrated"
[[ "$(jq_file "$AGB19/done.json" 'd.get("integrate_mode")')" == "skipped" ]] && ok || fail "B19: integrate_mode=skipped"
[[ "$(git -C "$PROJ_B19" rev-parse refs/heads/main)" == "$BASE_B19" ]] && ok || fail "B19: main не тронута"
[[ "$(git -C "$PROJ_B19" rev-parse "refs/heads/$BRANCH_B19")" == "$COMMITB19" ]] && ok || fail "B19: ветка задачи цела с исходным коммитом"

# =============================================================== B20
echo "=== B20: integrate:pr - push в origin + gh pr create, integrate_ref = url ==="
PROJ_B20="$TMP/proj-b20"; mkdir -p "$PROJ_B20"
mk_git_project "$PROJ_B20"
git init -q --bare "$PROJ_B20.git"
git -C "$PROJ_B20" remote add origin "$PROJ_B20.git"
register_obj_project projb20 "$PROJ_B20" pr
AGB20=$(mk_requested_worktree wtb20 "$PROJ_B20" b20-key "B20 summary")
COMMITB20=$(jq_file "$AGB20/done.json" 'd.get("commit_sha")')
BRANCH_B20=$(jq_file "$AGB20/done.json" 'd.get("branch")')
accept_agent "$AGB20"
GHBIN_B20="$TMP/ghbin-b20"; GHLOG_B20="$TMP/b20-gh.log"
mk_gh_mock "$GHBIN_B20" "$GHLOG_B20"
PATH="$GHBIN_B20:$PATH" "$RUN" done-advance "$AGB20" >/dev/null 2>"$TMP/b20.err"; RCB20=$?
[[ "$RCB20" == 0 ]] && ok || fail "B20: done-advance (pr) проходит (got $RCB20: $(cat "$TMP/b20.err"))"
[[ "$(jq_file "$AGB20/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B20: state=integrated"
[[ "$(jq_file "$AGB20/done.json" 'd.get("integrate_mode")')" == "pr" ]] && ok || fail "B20: integrate_mode=pr"
[[ "$(jq_file "$AGB20/done.json" 'd.get("integrate_ref")')" == "https://github.com/x/y/pull/1" ]] && ok || fail "B20: integrate_ref = url PR"
[[ "$(git --git-dir="$PROJ_B20.git" rev-parse "refs/heads/$BRANCH_B20" 2>/dev/null)" == "$COMMITB20" ]] \
  && ok || fail "B20: ветка задачи реально запушена в origin с ожидаемым коммитом"
grep -q 'pr create' "$GHLOG_B20" && ok || fail "B20: gh pr create реально вызван"

# =============================================================== B21
echo "=== B21: pr: PR уже существует (gh pr list непуст) - переиспользован, второй не создается ==="
PROJ_B21="$TMP/proj-b21"; mkdir -p "$PROJ_B21"
mk_git_project "$PROJ_B21"
git init -q --bare "$PROJ_B21.git"
git -C "$PROJ_B21" remote add origin "$PROJ_B21.git"
register_obj_project projb21 "$PROJ_B21" pr
AGB21=$(mk_requested_worktree wtb21 "$PROJ_B21" b21-key "B21 summary")
BRANCH_B21=$(jq_file "$AGB21/done.json" 'd.get("branch")')
accept_agent "$AGB21"
GHBIN_B21="$TMP/ghbin-b21"; GHLOG_B21="$TMP/b21-gh.log"
mk_gh_mock "$GHBIN_B21" "$GHLOG_B21" "https://github.com/x/y/pull/42"
PATH="$GHBIN_B21:$PATH" "$RUN" done-advance "$AGB21" >/dev/null 2>"$TMP/b21.err"; RCB21=$?
[[ "$RCB21" == 0 ]] && ok || fail "B21: done-advance (pr, уже существующий) проходит (got $RCB21: $(cat "$TMP/b21.err"))"
[[ "$(jq_file "$AGB21/done.json" 'd.get("integrate_ref")')" == "https://github.com/x/y/pull/42" ]] \
  && ok || fail "B21: integrate_ref = url уже существующего PR"
CNT_CREATE_B21=$(grep -c 'pr create' "$GHLOG_B21" || true); CNT_CREATE_B21="${CNT_CREATE_B21:-0}"
[[ "$CNT_CREATE_B21" == "0" ]] && ok || fail "B21: gh pr create НЕ вызван повторно (got $CNT_CREATE_B21)"
grep -q 'pr list' "$GHLOG_B21" && ok || fail "B21: gh pr list вызван для проверки идемпотентности"
# (аудит серьезный 9, тестовый барьер): PR уже найден списком - push в
# origin вообще не должен случиться, не только "create не вызван повторно"
[[ -z "$(git --git-dir="$PROJ_B21.git" rev-parse --verify -q "refs/heads/$BRANCH_B21" 2>/dev/null)" ]] \
  && ok || fail "B21: push НЕ вызван - origin не получил ветку задачи (PR уже существовал)"

# =============================================================== B22
echo "=== B22: push в origin падает - phase_error+attention, state=accepted, следующий тик доставляет ==="
PROJ_B22="$TMP/proj-b22"; mkdir -p "$PROJ_B22"
mk_git_project "$PROJ_B22"
git init -q --bare "$PROJ_B22.git"
git -C "$PROJ_B22" remote add origin "$PROJ_B22.git"
chmod a-w "$PROJ_B22.git/objects"  # реальный push реально падает - git не мокается
register_obj_project projb22 "$PROJ_B22" pr
AGB22=$(mk_requested_worktree wtb22 "$PROJ_B22" b22-key "B22 summary")
accept_agent "$AGB22"
GHBIN_B22="$TMP/ghbin-b22"; GHLOG_B22="$TMP/b22-gh.log"
mk_gh_mock "$GHBIN_B22" "$GHLOG_B22"
PATH="$GHBIN_B22:$PATH" "$RUN" done-advance "$AGB22" >/dev/null 2>"$TMP/b22a.err"; RCB22A=$?
[[ "$RCB22A" == 3 ]] && ok || fail "B22: push упал -> exit 3 (got $RCB22A: $(cat "$TMP/b22a.err"))"
[[ "$(jq_file "$AGB22/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B22: state остается accepted"
[[ "$(jq_file "$AGB22/done.json" 'bool(d.get("phase_error"))')" == "True" ]] && ok || fail "B22: phase_error записан"
[[ "$(jq_file "$AGB22/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B22: attention выставлен"
chmod u+w "$PROJ_B22.git/objects"
PATH="$GHBIN_B22:$PATH" "$RUN" done-advance "$AGB22" >/dev/null 2>"$TMP/b22b.err"; RCB22B=$?
[[ "$RCB22B" == 0 ]] && ok || fail "B22: следующий тик (права восстановлены) доставляет (got $RCB22B: $(cat "$TMP/b22b.err"))"
[[ "$(jq_file "$AGB22/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B22: state=integrated после ретрая"

# =============================================================== B23
echo "=== B23: cleanup после integrate:merge - worktree снят, prune выполнен, ветка задачи удалена ==="
PROJ_B23="$TMP/proj-b23"; mkdir -p "$PROJ_B23"
mk_git_project "$PROJ_B23"
register_obj_project projb23 "$PROJ_B23" merge
AGB23=$(mk_requested_worktree wtb23 "$PROJ_B23" b23-key "B23 summary")
BRANCH_B23=$(jq_file "$AGB23/done.json" 'd.get("branch")')
accept_agent "$AGB23"
"$RUN" done-advance "$AGB23" >/dev/null 2>"$TMP/b23-integrate.err"
[[ "$(jq_file "$AGB23/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B23: fixture - фаза integrate довела до integrated ($(cat "$TMP/b23-integrate.err"))"
"$RUN" done-advance "$AGB23" >/dev/null 2>"$TMP/b23.err"; RCB23=$?
[[ "$RCB23" == 0 ]] && ok || fail "B23: фаза cleanup проходит (got $RCB23: $(cat "$TMP/b23.err"))"
[[ "$(jq_file "$AGB23/done.json" 'd.get("state")')" == "cleaned" ]] && ok || fail "B23: state=cleaned"
[[ ! -d "$AGB23/work" ]] && ok || fail "B23: worktree-каталог снят"
CNT_WT_B23=$(git -C "$PROJ_B23" worktree list | grep -c "$AGB23/work" || true)
[[ "$CNT_WT_B23" == "0" ]] && ok || fail "B23: prune выполнен (work не числится в worktree list)"
CNT_BR_B23=$(git -C "$PROJ_B23" branch --list "$BRANCH_B23" | wc -l | tr -d ' ')
[[ "$CNT_BR_B23" == "0" ]] && ok || fail "B23: ветка задачи удалена (integrate:merge)"

# =============================================================== B24
echo "=== B24: cleanup при integrate:pr и integrate:none - ветка задачи СОХРАНЕНА ==="
PROJ_B24A="$TMP/proj-b24a"; mkdir -p "$PROJ_B24A"
mk_git_project "$PROJ_B24A"
git init -q --bare "$PROJ_B24A.git"
git -C "$PROJ_B24A" remote add origin "$PROJ_B24A.git"
register_obj_project projb24a "$PROJ_B24A" pr
AGB24A=$(mk_requested_worktree wtb24a "$PROJ_B24A" b24a-key "B24a summary")
BRANCH_B24A=$(jq_file "$AGB24A/done.json" 'd.get("branch")')
accept_agent "$AGB24A"
GHBIN_B24A="$TMP/ghbin-b24a"; mk_gh_mock "$GHBIN_B24A" "$TMP/b24a-gh.log"
PATH="$GHBIN_B24A:$PATH" "$RUN" done-advance "$AGB24A" >/dev/null 2>"$TMP/b24a-integrate.err"
[[ "$(jq_file "$AGB24A/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B24a: fixture - integrate:pr довел до integrated ($(cat "$TMP/b24a-integrate.err"))"
"$RUN" done-advance "$AGB24A" >/dev/null 2>"$TMP/b24a.err"; RCB24A=$?
[[ "$RCB24A" == 0 ]] && ok || fail "B24a: cleanup после pr проходит (got $RCB24A: $(cat "$TMP/b24a.err"))"
[[ ! -d "$AGB24A/work" ]] && ok || fail "B24a: worktree снят"
[[ "$(git -C "$PROJ_B24A" branch --list "$BRANCH_B24A" | wc -l | tr -d ' ')" == "1" ]] && ok || fail "B24a: ветка задачи СОХРАНЕНА (integrate:pr)"

PROJ_B24B="$TMP/proj-b24b"; mkdir -p "$PROJ_B24B"
mk_git_project "$PROJ_B24B"
register_flat_project projb24bflat "$PROJ_B24B"
AGB24B=$(mk_requested_worktree wtb24b "$PROJ_B24B" b24b-key "B24b summary")
BRANCH_B24B=$(jq_file "$AGB24B/done.json" 'd.get("branch")')
accept_agent "$AGB24B"
"$RUN" done-advance "$AGB24B" >/dev/null 2>"$TMP/b24b-integrate.err"
[[ "$(jq_file "$AGB24B/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B24b: fixture - integrate:none довел до integrated ($(cat "$TMP/b24b-integrate.err"))"
"$RUN" done-advance "$AGB24B" >/dev/null 2>"$TMP/b24b.err"; RCB24B=$?
[[ "$RCB24B" == 0 ]] && ok || fail "B24b: cleanup после none проходит (got $RCB24B: $(cat "$TMP/b24b.err"))"
[[ ! -d "$AGB24B/work" ]] && ok || fail "B24b: worktree снят"
[[ "$(git -C "$PROJ_B24B" branch --list "$BRANCH_B24B" | wc -l | tr -d ' ')" == "1" ]] && ok || fail "B24b: ветка задачи СОХРАНЕНА (integrate:none)"

# =============================================================== B25
echo "=== B25: грязный worktree на cleanup - отказ, --force не применяется, worktree на месте ==="
PROJ_B25="$TMP/proj-b25"; mkdir -p "$PROJ_B25"
mk_git_project "$PROJ_B25"
register_obj_project projb25 "$PROJ_B25" merge
AGB25=$(mk_requested_worktree wtb25 "$PROJ_B25" b25-key "B25 summary")
accept_agent "$AGB25"
"$RUN" done-advance "$AGB25" >/dev/null 2>"$TMP/b25-integrate.err"
[[ "$(jq_file "$AGB25/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B25: fixture - integrate довел до integrated ($(cat "$TMP/b25-integrate.err"))"
echo "b25 dirty leftover" >> "$AGB25/work/f.txt"
"$RUN" done-advance "$AGB25" >/dev/null 2>"$TMP/b25.err"; RCB25=$?
[[ "$RCB25" == 3 ]] && ok || fail "B25: грязный worktree -> exit 3 (got $RCB25: $(cat "$TMP/b25.err"))"
[[ "$(jq_file "$AGB25/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B25: state остается integrated"
[[ -d "$AGB25/work" ]] && ok || fail "B25: worktree НЕ снят (--force не применялся)"
[[ "$(cat "$AGB25/work/f.txt")" == *"b25 dirty leftover"* ]] && ok || fail "B25: несохраненная работа на месте"

# =============================================================== B26
echo "=== B26: workspace direct/none на cleanup - no-op, сразу cleaned ==="
PROJ_B26="$TMP/proj-b26"; mkdir -p "$PROJ_B26"
AGB26=$(mk_created_none_agent evtb26 "$PROJ_B26" direct)
write_done_json_direct "$AGB26" "b26-key" "B26 summary" '["a.txt"]'
set_done_field "$AGB26" '
d["state"] = "integrated"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"
'
"$RUN" done-advance "$AGB26" >/dev/null 2>"$TMP/b26.err"; RCB26=$?
[[ "$RCB26" == 0 ]] && ok || fail "B26: cleanup workspace:direct - no-op (got $RCB26: $(cat "$TMP/b26.err"))"
[[ "$(jq_file "$AGB26/done.json" 'd.get("state")')" == "cleaned" ]] && ok || fail "B26: state=cleaned"

# =============================================================== B27
echo "=== B27: бегущий агент не архивируется - гасится штатным путем и выходит; архив на следующем тике ==="
PROJ_B27="$TMP/proj-b27"; mkdir -p "$PROJ_B27"
AGB27=$(mk_created_none_agent evtb27 "$PROJ_B27" none)
"$RC" agent start evtb27 >/dev/null 2>"$TMP/b27-start.err"
[[ "$(jq_file "$AGB27/control.json" 'd["desired"]')" == "running" ]] \
  && ok || fail "B27: fixture - desired=running ($(cat "$TMP/b27-start.err"))"
write_done_json "$AGB27" "b27-key" "B27 summary"
set_done_field "$AGB27" '
d["state"] = "cleaned"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
"$RUN" done-advance "$AGB27" >/dev/null 2>"$TMP/b27a.err"; RCB27A=$?
[[ "$RCB27A" == 0 ]] && ok || fail "B27: первый вызов на бегущем агенте не падает (got $RCB27A: $(cat "$TMP/b27a.err"))"
[[ -d "$AGB27" ]] && ok || fail "B27: агент НЕ архивирован (все еще в agents/)"
[[ "$(jq_file "$AGB27/control.json" 'd["desired"]')" == "stopped" ]] && ok || fail "B27: desired переведен в stopped (штатное гашение)"
"$RUN" done-advance "$AGB27" >/dev/null 2>"$TMP/b27b.err"; RCB27B=$?
[[ "$RCB27B" == 0 ]] && ok || fail "B27: второй тик архивирует (got $RCB27B: $(cat "$TMP/b27b.err"))"
[[ ! -d "$AGB27" ]] && ok || fail "B27: агент архивирован (agents/evtb27 отсутствует)"

# =============================================================== B28
echo "=== B28: архив - атомарный rename в archive/<name>-<ts>, надгробие создано ==="
PROJ_B28="$TMP/proj-b28"; mkdir -p "$PROJ_B28"
AGB28=$(mk_created_none_agent evtb28 "$PROJ_B28" none)
# create дает desired=paused (N15), а §6.1 требует "desired == stopped" для
# архивации за один тик - без явного stop это был бы сценарий B27 (гашение +
# выход), не "нормальный путь архива" из этого кейса.
"$RC" agent stop evtb28 >/dev/null 2>"$TMP/b28-stop.err"
write_done_json "$AGB28" "b28-key" "B28 summary"
set_done_field "$AGB28" '
d["state"] = "cleaned"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
"$RUN" done-advance "$AGB28" >/dev/null 2>"$TMP/b28.err"; RCB28=$?
[[ "$RCB28" == 0 ]] && ok || fail "B28: архив проходит (got $RCB28: $(cat "$TMP/b28.err"))"
[[ ! -d "$AGB28" ]] && ok || fail "B28: agents/evtb28 отсутствует"
ARCHIVE_ROOT_B28="$(dirname "$CLAUDE_AGENTS_DIR")/archive"
ARCHDIR_B28=$(find "$ARCHIVE_ROOT_B28" -maxdepth 1 -name 'evtb28-*' 2>/dev/null | head -1)
[[ -n "$ARCHDIR_B28" && -d "$ARCHDIR_B28" ]] && ok || fail "B28: archive/evtb28-<ts> создан (root: $ARCHIVE_ROOT_B28)"
[[ -f "$ARCHDIR_B28/done.json" ]] && ok || fail "B28: содержимое агента реально перенесено (done.json на месте)"
[[ "$(jq_file "$ARCHDIR_B28/done.json" 'bool(d.get("archived_at"))')" == "True" ]] && ok || fail "B28: archived_at заполнен"
TOMBSTONE_B28="$(dirname "$CLAUDE_AGENTS_DIR")/tombstones/evtb28.json"
[[ -f "$TOMBSTONE_B28" ]] && ok || fail "B28: надгробие tombstones/evtb28.json создано (path: $TOMBSTONE_B28)"

# =============================================================== B29
echo "=== B29: /new с именем из надгробия - не заводит дубль, отвечает что задача уже завершена ==="
TOMB_ROOT_B29="$(dirname "$CLAUDE_AGENTS_DIR")/tombstones"; mkdir -p "$TOMB_ROOT_B29"
printf '{"name":"task-tgb029","archived_at":"2026-02-01T00:03:00Z","archive_path":"archive/task-tgb029-2026-02-01T00:03:00Z"}\n' \
  > "$TOMB_ROOT_B29/task-tgb029.json"
OUTB29=$("$RC" agent new-task --name task-tgb029 --project demoproj --text "B29 attempt" 2>"$TMP/b29.err"); RCB29=$?
[[ "$RCB29" == 0 ]] && ok || fail "B29: редоставка на надгробие - не ошибка, идемпотентный ответ (got $RCB29: $(cat "$TMP/b29.err"))"
[[ "$OUTB29" == *"заверш"* ]] && ok || fail "B29: ответ сообщает, что задача уже завершена (got: $OUTB29)"
[[ ! -e "$CLAUDE_AGENTS_DIR/task-tgb029" ]] && ok || fail "B29: новый агент НЕ создан поверх надгробия"

# =============================================================== B30
echo "=== B30: reject - история дописана, событие-доработка со комментарием в spool, done.json снят ==="
PROJ_B30="$TMP/proj-b30"; mkdir -p "$PROJ_B30"
AGB30=$(mk_created_none_agent evtb30 "$PROJ_B30" none)
write_done_json "$AGB30" "b30-key" "B30 summary"
set_done_field "$AGB30" '
d["state"] = "rejected"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"
d["verdict_comment"] = "B30 нужно доделать X"
d["integrate_mode"] = None; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
'
"$RUN" done-advance "$AGB30" >/dev/null 2>"$TMP/b30.err"; RCB30=$?
[[ "$RCB30" == 0 ]] && ok || fail "B30: фаза revise проходит (got $RCB30: $(cat "$TMP/b30.err"))"
[[ ! -f "$AGB30/done.json" ]] && ok || fail "B30: done.json снят"
[[ -f "$AGB30/done.history.jsonl" ]] && ok || fail "B30: done.history.jsonl создан"
HIST_HAS_B30=$(python3 -c '
import json
found = False
for ln in open("'"$AGB30"'/done.history.jsonl"):
    ln = ln.strip()
    if not ln: continue
    d = json.loads(ln)
    if d.get("verdict_at") == "2026-02-01T00:00:00Z": found = True
print(found)
')
[[ "$HIST_HAS_B30" == "True" ]] && ok || fail "B30: история содержит запись с verdict_at отклонения"
SPOOL_HAS_B30=$(python3 -c '
import json, glob
found = False
for f in glob.glob("'"$CLAUDE_AGENT_SPOOL_BASE"'/evtb30/*.json"):
    d = json.load(open(f))
    if "B30 нужно доделать X" in json.dumps(d, ensure_ascii=False): found = True
print(found)
')
[[ "$SPOOL_HAS_B30" == "True" ]] && ok || fail "B30: событие-доработка со комментарием положено в spool"

# =============================================================== B31
echo "=== B31: повторный reject-вердикт (до revise) - no-op, комментарий не переписан ==="
PROJ_B31="$TMP/proj-b31"; mkdir -p "$PROJ_B31"
mk_git_project "$PROJ_B31"
AGB31=$(mk_requested_worktree wtb31 "$PROJ_B31" b31-key "B31 summary")
COMMITB31=$(jq_file "$AGB31/done.json" 'd.get("commit_sha")')
SHA8_B31="${COMMITB31:0:8}"
"$RUN" done-verdict "$AGB31" --reject --expect-sha "$SHA8_B31" --comment "первый комментарий" >/dev/null 2>"$TMP/b31a.err"; RCB31A=$?
[[ "$RCB31A" == 0 ]] && ok || fail "B31: fixture - первый reject проходит (got $RCB31A: $(cat "$TMP/b31a.err"))"
VERDICT_AT_B31=$(jq_file "$AGB31/done.json" 'd.get("verdict_at")')
"$RUN" done-verdict "$AGB31" --reject --expect-sha "$SHA8_B31" --comment "второй комментарий" >/dev/null 2>"$TMP/b31b.err"; RCB31B=$?
[[ "$RCB31B" == 0 ]] && ok || fail "B31: повторный reject - no-op, не ошибка (got $RCB31B: $(cat "$TMP/b31b.err"))"
[[ "$(jq_file "$AGB31/done.json" 'd.get("verdict_at")')" == "$VERDICT_AT_B31" ]] && ok || fail "B31: verdict_at не переписан"
[[ "$(jq_file "$AGB31/done.json" 'd.get("verdict_comment")')" == "первый комментарий" ]] && ok || fail "B31: verdict_comment не переписан повтором"

# =============================================================== B32
echo "=== B32: крах между шагами revise - событие не задвоилось (--id дедуп), история не задвоилась ==="
PROJ_B32="$TMP/proj-b32"; mkdir -p "$PROJ_B32"
AGB32=$(mk_created_none_agent evtb32 "$PROJ_B32" none)
write_done_json "$AGB32" "b32-key" "B32 summary"
set_done_field "$AGB32" '
d["state"] = "rejected"
d["verdict_at"] = "2026-02-02T00:00:00Z"; d["verdict_by"] = "tg:1001"
d["verdict_comment"] = "B32 доделать Y"
d["integrate_mode"] = None; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
'
python3 -c '
import json
d = json.load(open("'"$AGB32"'/done.json"))
open("'"$AGB32"'/done.history.jsonl", "w").write(json.dumps(d, ensure_ascii=False) + "\n")
'
"$RUN" spool-put evtb32 --text "B32 доделать Y" --id "rev:evtb32:2026-02-02T00:00:00Z" >/dev/null 2>"$TMP/b32-preseed.err"
"$RUN" done-advance "$AGB32" >/dev/null 2>"$TMP/b32.err"; RCB32=$?
[[ "$RCB32" == 0 ]] && ok || fail "B32: доигрывает с шага 3 (got $RCB32: $(cat "$TMP/b32.err"))"
[[ ! -f "$AGB32/done.json" ]] && ok || fail "B32: done.json снят (шаг 3 выполнен)"
HISTLINES_B32=$(wc -l < "$AGB32/done.history.jsonl" | tr -d ' ')
[[ "$HISTLINES_B32" == "1" ]] && ok || fail "B32: история НЕ задвоилась (got $HISTLINES_B32 строк)"
SPOOLCNT_B32=$(ls "$CLAUDE_AGENT_SPOOL_BASE/evtb32"/*.json 2>/dev/null | grep -c '\.json$')
[[ "$SPOOLCNT_B32" == "1" ]] && ok || fail "B32: событие в spool НЕ задвоилось (got $SPOOLCNT_B32)"

# =============================================================== B33
echo "=== B33: после снятия done.json (revise завершен) - агент может заявить готовность заново ==="
PROJ_B33="$TMP/proj-b33"; mkdir -p "$PROJ_B33"
mk_git_project "$PROJ_B33"
AGB33=$(mk_worktree_agent wtb33 "$PROJ_B33")
( cd "$AGB33/work" && echo "b33 v1" > b33.txt && git add b33.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b33 v1" )
mk_inflight "$AGB33" "b33-key-1"
call_done "$AGB33" "b33-key-1" --summary "B33 v1" >/dev/null 2>"$TMP/b33-done1.err"
set_done_field "$AGB33" '
d["state"] = "rejected"
d["verdict_at"] = "2026-02-03T00:00:00Z"; d["verdict_by"] = "tg:1001"
d["verdict_comment"] = "B33 доделать"
d["integrate_mode"] = None; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
'
"$RUN" done-advance "$AGB33" >/dev/null 2>"$TMP/b33-revise.err"
[[ ! -f "$AGB33/done.json" ]] && ok || fail "B33: fixture - revise снял done.json ($(cat "$TMP/b33-revise.err"))"
( cd "$AGB33/work" && echo "b33 v2 fix" > b33fix.txt && git add b33fix.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b33 v2 fix" )
mk_inflight "$AGB33" "b33-key-2"
call_done "$AGB33" "b33-key-2" --summary "B33 v2 fixed" >"$TMP/b33-redone.out" 2>"$TMP/b33-redone.err"; RCB33=$?
[[ "$RCB33" == 0 ]] && ok || fail "B33: повторная заявка готовности после reject проходит (got $RCB33: $(cat "$TMP/b33-redone.err"))"
[[ "$(jq_file "$AGB33/done.json" 'd.get("state")')" == "requested" ]] && ok || fail "B33: новая заявка requested"
[[ "$(jq_file "$AGB33/done.json" 'd.get("summary")')" == "B33 v2 fixed" ]] && ok || fail "B33: новая summary сохранена"

# =============================================================== B34 (аудит "тестовый барьер" дефект 10: матрица обрывов)
# Одна "крах в каждой фазе" в B34 закрывала ровно ОДИН сценарий (FF-ref уже
# сдвинут). Ниже - матрица по контрольным точкам, названным в аудите:
# push->PR, worktree-remove->branch-delete, state->rename, rename->
# надгробие, revise-шаги. Каждый под-кейс моделирует состояние ПОСЛЕ краха
# на конкретном шаге (не до него) и проверяет, что следующий тик доигрывает
# БЕЗ повторного внешнего эффекта.

# --- B34a (было B34 целиком): merge FF - ref уже сдвинут ---
# main ОБЯЗАН быть нигде не вычекаучена (та же оговорка, что у B48, аудит
# блокер 2): mission_base_branch уже зафиксирован как "main" (create успел
# случиться внутри mk_requested_worktree выше), поэтому уводим первичный
# чекаут проекта на служебную ветку. Иначе прямой update-ref под
# вычекаученным main создал бы ИМЕННО тот рассинхрон (ref продвинут, индекс/
# файлы - нет), который аудит требует ловить как отказ (см. новый B49), а не
# легитимизировать как "уже влито" - это НЕ тот сценарий, что здесь
# проверяется: здесь - идемпотентность настоящего краха между update-ref (в
# ветке "нигде не вычекаучена") и записью state.
echo "=== B34a: внешний эффект уже случился (merge FF ref сдвинут, ветка НИГДЕ не вычекаучена), запись state - нет; следующий тик доигрывает без повторного эффекта ==="
PROJ_B34="$TMP/proj-b34"; mkdir -p "$PROJ_B34"
mk_git_project "$PROJ_B34"
register_obj_project projb34 "$PROJ_B34" merge
AGB34=$(mk_requested_worktree wtb34 "$PROJ_B34" b34-key "B34 summary")
COMMITB34=$(jq_file "$AGB34/done.json" 'd.get("commit_sha")')
BASE_B34_BEFORE=$(jq_file "$AGB34/done.json" 'd.get("base")')
accept_agent "$AGB34"
git -C "$PROJ_B34" checkout -q -b scratch-b34a
[[ "$(git -C "$PROJ_B34" worktree list --porcelain | grep -c '^branch refs/heads/main$')" == "0" ]] \
  && ok || fail "B34a: fixture - main нигде не вычекаучена"
git -C "$PROJ_B34" update-ref refs/heads/main "$COMMITB34" "$BASE_B34_BEFORE"
"$RUN" done-advance "$AGB34" >/dev/null 2>"$TMP/b34.err"; RCB34=$?
[[ "$RCB34" == 0 ]] && ok || fail "B34a: доигрывает без ошибки, распознав уже сделанный эффект (got $RCB34: $(cat "$TMP/b34.err"))"
[[ "$(jq_file "$AGB34/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B34a: state=integrated"
[[ "$(jq_file "$AGB34/done.json" 'd.get("integrate_ref")')" == "$COMMITB34" ]] && ok || fail "B34a: integrate_ref верный (без повторного эффекта)"
[[ "$(git -C "$PROJ_B34" rev-parse refs/heads/main)" == "$COMMITB34" ]] && ok || fail "B34a: main остается на том же коммите (не задвоено)"

# --- B34b: push->PR - push прошел, gh pr create упал (крах); ретрай ОБЯЗАН
# сначала спросить gh pr list, не пушить вслепую (аудит серьезный 9: старый
# тестовый барьер проходил и с обратным порядком push-before-list, потому
# что retry-мок тоже отдавал [] и push тихо повторялся бы). Провокация
# порядка: после краха делаем origin НЕДОСТУПНЫМ для push и подкладываем в
# gh pr list уже существующий PR - list-first доигрывает несмотря на это
# (push вообще не нужен), push-first уперся бы в недоступный origin.
echo "=== B34b: крах между push и gh pr create - ретрай проверяет gh pr list ПЕРВЫМ, не пушит вслепую в недоступный origin ==="
PROJ_B34B="$TMP/proj-b34b"; mkdir -p "$PROJ_B34B"
mk_git_project "$PROJ_B34B"
git init -q --bare "$PROJ_B34B.git"
git -C "$PROJ_B34B" remote add origin "$PROJ_B34B.git"
register_obj_project projb34b "$PROJ_B34B" pr
AGB34B=$(mk_requested_worktree wtb34b "$PROJ_B34B" b34b-key "B34b summary")
BRANCH_B34B=$(jq_file "$AGB34B/done.json" 'd.get("branch")')
accept_agent "$AGB34B"
GHBIN_B34B_FAIL="$TMP/ghbin-b34b-fail"; GHLOG_B34B_FAIL="$TMP/b34b-gh-fail.log"
mkdir -p "$GHBIN_B34B_FAIL"
cat > "$GHBIN_B34B_FAIL/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GHLOG_B34B_FAIL"
case "\$1 \$2" in
  "pr list") echo "[]" ;;
  "pr create") exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$GHBIN_B34B_FAIL/gh"
PATH="$GHBIN_B34B_FAIL:$PATH" "$RUN" done-advance "$AGB34B" >/dev/null 2>"$TMP/b34b-1.err"; RCB34B1=$?
[[ "$RCB34B1" == 3 ]] && ok || fail "B34b: первая попытка (push ок, create упал) -> exit 3 (got $RCB34B1: $(cat "$TMP/b34b-1.err"))"
[[ "$(git --git-dir="$PROJ_B34B.git" rev-parse "refs/heads/$BRANCH_B34B" 2>/dev/null)" ]] \
  && ok || fail "B34b: fixture - push реально прошел до краха на create"
[[ "$(jq_file "$AGB34B/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B34b: state остается accepted после краха"
# origin подменен на несуществующий путь - ЛЮБОЙ push (в т.ч. push уже
# присутствующего на origin коммита - git счел бы его no-op и пропустил бы
# мимо прав на запись, поэтому один chmod a-w тут не барьер) гарантированно
# упадет; list-first доигрывает без единого push
git -C "$PROJ_B34B" remote set-url origin "$TMP/proj-b34b-gone.git"
GHBIN_B34B_OK="$TMP/ghbin-b34b-ok"; GHLOG_B34B_OK="$TMP/b34b-gh-ok.log"
mk_gh_mock "$GHBIN_B34B_OK" "$GHLOG_B34B_OK" "https://github.com/x/y/pull/77"
PATH="$GHBIN_B34B_OK:$PATH" "$RUN" done-advance "$AGB34B" >/dev/null 2>"$TMP/b34b-2.err"; RCB34B2=$?
[[ "$RCB34B2" == 0 ]] && ok || fail "B34b: ретрай доигрывает через СУЩЕСТВУЮЩИЙ PR, без push в недоступный origin (got $RCB34B2: $(cat "$TMP/b34b-2.err"))"
[[ "$(jq_file "$AGB34B/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B34b: state=integrated после ретрая"
[[ "$(jq_file "$AGB34B/done.json" 'd.get("integrate_ref")')" == "https://github.com/x/y/pull/77" ]] \
  && ok || fail "B34b: integrate_ref = url найденного PR (второй не создан)"
grep -q 'pr list' "$GHLOG_B34B_OK" && ok || fail "B34b: gh pr list реально вызван на ретрае"
CNT_CREATE_B34B=$(grep -c 'pr create' "$GHLOG_B34B_OK" || true); CNT_CREATE_B34B="${CNT_CREATE_B34B:-0}"
[[ "$CNT_CREATE_B34B" == "0" ]] && ok || fail "B34b: gh pr create НЕ вызван (PR уже найден списком) (got $CNT_CREATE_B34B)"

# --- B34c: worktree-remove->branch-delete - worktree уже снят (крах до
# удаления ветки); ретрай не падает на отсутствующем work/, доводит до
# cleaned и удаляет ветку ---
echo "=== B34c: крах между git worktree remove и удалением ветки - ретрай доигрывает без ошибки ==="
PROJ_B34C="$TMP/proj-b34c"; mkdir -p "$PROJ_B34C"
mk_git_project "$PROJ_B34C"
register_obj_project projb34c "$PROJ_B34C" merge
AGB34C=$(mk_requested_worktree wtb34c "$PROJ_B34C" b34c-key "B34c summary")
BRANCH_B34C=$(jq_file "$AGB34C/done.json" 'd.get("branch")')
accept_agent "$AGB34C"
"$RUN" done-advance "$AGB34C" >/dev/null 2>"$TMP/b34c-integrate.err"
[[ "$(jq_file "$AGB34C/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B34c: fixture - integrate довел до integrated ($(cat "$TMP/b34c-integrate.err"))"
# симулируем крах ПОСЛЕ worktree remove, ДО удаления ветки: снимаем worktree
# руками тем же способом, что и сама фаза cleanup
git -C "$PROJ_B34C" worktree remove "$AGB34C/work" >/dev/null 2>&1
git -C "$PROJ_B34C" worktree prune
[[ ! -d "$AGB34C/work" ]] && ok || fail "B34c: fixture - worktree реально снят руками (имитация краха после шага 1)"
[[ -n "$(git -C "$PROJ_B34C" branch --list "$BRANCH_B34C")" ]] && ok || fail "B34c: fixture - ветка задачи еще на месте (крах ДО ее удаления)"
"$RUN" done-advance "$AGB34C" >/dev/null 2>"$TMP/b34c.err"; RCB34C=$?
[[ "$RCB34C" == 0 ]] && ok || fail "B34c: ретрай не падает на отсутствующем work/ (got $RCB34C: $(cat "$TMP/b34c.err"))"
[[ "$(jq_file "$AGB34C/done.json" 'd.get("state")')" == "cleaned" ]] && ok || fail "B34c: state=cleaned"
[[ -z "$(git -C "$PROJ_B34C" branch --list "$BRANCH_B34C")" ]] && ok || fail "B34c: ветка задачи все же удалена ретраем"

# --- B34d: state->rename - state=archived уже записан, надгробия еще нет
# (крах ДО его записи); ретрай пишет надгробие и довершает rename ---
echo "=== B34d: крах между записью state=archived и надгробием - ретрай дописывает надгробие и переносит каталог ==="
PROJ_B34D="$TMP/proj-b34d"; mkdir -p "$PROJ_B34D"
AGB34D=$(mk_created_none_agent evtb34d "$PROJ_B34D" none)
"$RC" agent stop evtb34d >/dev/null 2>"$TMP/b34d-stop.err"
write_done_json "$AGB34D" "b34d-key" "B34d summary"
set_done_field "$AGB34D" '
d["state"] = "archived"
d["archived_at"] = "2026-02-05T00:00:00Z"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
TOMB_B34D="$(dirname "$CLAUDE_AGENTS_DIR")/tombstones/evtb34d.json"
[[ ! -f "$TOMB_B34D" ]] && ok || fail "B34d: fixture - надгробия еще нет (имитация краха до его записи)"
"$RUN" done-advance "$AGB34D" >/dev/null 2>"$TMP/b34d.err"; RCB34D=$?
[[ "$RCB34D" == 0 ]] && ok || fail "B34d: ретрай доигрывает (got $RCB34D: $(cat "$TMP/b34d.err"))"
[[ ! -d "$AGB34D" ]] && ok || fail "B34d: agents/evtb34d отсутствует (rename довершен)"
[[ -f "$TOMB_B34D" ]] && ok || fail "B34d: надгробие дописано ретраем"
[[ "$(jq_file "$TOMB_B34D" 'd.get("archived_at")')" == "2026-02-05T00:00:00Z" ]] \
  && ok || fail "B34d: надгробие несет ТОТ ЖЕ archived_at, что был записан до краха (детерминизм)"

# --- B34e: rename->надгробие - надгробие уже записано, rename еще не
# случился (крах ПОСЛЕ надгробия); ретрай не плодит второй archive/-каталог ---
echo "=== B34e: крах между надгробием и rename - ретрай не создает второй archive-каталог ==="
PROJ_B34E="$TMP/proj-b34e"; mkdir -p "$PROJ_B34E"
AGB34E=$(mk_created_none_agent evtb34e "$PROJ_B34E" none)
"$RC" agent stop evtb34e >/dev/null 2>"$TMP/b34e-stop.err"
write_done_json "$AGB34E" "b34e-key" "B34e summary"
set_done_field "$AGB34E" '
d["state"] = "archived"
d["archived_at"] = "2026-02-06T00:00:00Z"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
TOMB_ROOT_B34E="$(dirname "$CLAUDE_AGENTS_DIR")/tombstones"; mkdir -p "$TOMB_ROOT_B34E"
DEST_B34E="$(dirname "$CLAUDE_AGENTS_DIR")/archive/evtb34e-2026-02-06T00:00:00Z"
printf '{"name":"evtb34e","archived_at":"2026-02-06T00:00:00Z","archived_to":"%s"}\n' \
  "$DEST_B34E" > "$TOMB_ROOT_B34E/evtb34e.json"
[[ -d "$AGB34E" ]] && ok || fail "B34e: fixture - agents/evtb34e еще на месте (имитация краха до rename)"
"$RUN" done-advance "$AGB34E" >/dev/null 2>"$TMP/b34e.err"; RCB34E=$?
[[ "$RCB34E" == 0 ]] && ok || fail "B34e: ретрай доигрывает rename (got $RCB34E: $(cat "$TMP/b34e.err"))"
[[ ! -d "$AGB34E" ]] && ok || fail "B34e: agents/evtb34e отсутствует (rename выполнен ретраем)"
CNT_ARCHDIRS_B34E=$(find "$(dirname "$CLAUDE_AGENTS_DIR")/archive" -maxdepth 1 -name 'evtb34e-*' 2>/dev/null | wc -l | tr -d ' ')
[[ "$CNT_ARCHDIRS_B34E" == "1" ]] && ok || fail "B34e: ровно один archive/-каталог (got $CNT_ARCHDIRS_B34E - надгробие не задвоило rename)"

# --- B34f: revise-шаги - история дописана (шаг 1), события в spool еще нет
# (крах ПОСЛЕ шага 1, ДО шага 2); ретрай не задваивает историю и доводит
# до конца (шаг 2 + шаг 3) ---
echo "=== B34f: крах после шага 1 revise (история), ДО шага 2 (spool) - ретрай не задваивает историю и доводит до конца ==="
PROJ_B34F="$TMP/proj-b34f"; mkdir -p "$PROJ_B34F"
AGB34F=$(mk_created_none_agent evtb34f "$PROJ_B34F" none)
write_done_json "$AGB34F" "b34f-key" "B34f summary"
set_done_field "$AGB34F" '
d["state"] = "rejected"
d["verdict_at"] = "2026-02-07T00:00:00Z"; d["verdict_by"] = "tg:1001"
d["verdict_comment"] = "B34f нужно доделать Z"
d["integrate_mode"] = None; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
'
python3 -c '
import json
d = json.load(open("'"$AGB34F"'/done.json"))
open("'"$AGB34F"'/done.history.jsonl", "w").write(json.dumps(d, ensure_ascii=False) + "\n")
'
spool_files_b34f_pre=("$CLAUDE_AGENT_SPOOL_BASE/evtb34f"/*.json)
SPOOLCNT_B34F_PRE=${#spool_files_b34f_pre[@]}
[[ "${SPOOLCNT_B34F_PRE:-0}" == "0" ]] \
  && ok || fail "B34f: fixture - событие в spool еще не положено (имитация краха до шага 2)"
"$RUN" done-advance "$AGB34F" >/dev/null 2>"$TMP/b34f.err"; RCB34F=$?
[[ "$RCB34F" == 0 ]] && ok || fail "B34f: ретрай доигрывает шаги 2+3 (got $RCB34F: $(cat "$TMP/b34f.err"))"
[[ ! -f "$AGB34F/done.json" ]] && ok || fail "B34f: done.json снят (шаг 3 выполнен)"
HISTLINES_B34F=$(wc -l < "$AGB34F/done.history.jsonl" | tr -d ' ')
[[ "$HISTLINES_B34F" == "1" ]] && ok || fail "B34f: история НЕ задвоилась (got $HISTLINES_B34F строк)"
spool_files_b34f=("$CLAUDE_AGENT_SPOOL_BASE/evtb34f"/*.json)
SPOOLCNT_B34F=${#spool_files_b34f[@]}
[[ "$SPOOLCNT_B34F" == "1" ]] && ok || fail "B34f: событие-доработка положено в spool ровно один раз (got $SPOOLCNT_B34F)"

# =============================================================== B35
# (аудит "тестовый барьер" дефект 11): реконсилер обязан РЕАЛЬНО запускаться
# (`claude-agent-reconciler --once`), а не имитироваться двумя независимыми
# CLI-вызовами done-advance - иначе бульхед-свойство самого прохода (`for
# dir in ...; ... done-advance ... || true`) не проверяется вообще: две
# отдельные команды и так независимы друг от друга безо всякого || true.
echo "=== B35: бульхед - провал фазы у агента A (битый done.json) в ОДНОМ реальном проходе реконсилера не мешает агенту B ==="
BASE_B35="$TMP/agents-b35"; mkdir -p "$BASE_B35"
RCDIR_B35="$TMP/reconciler-b35"; mkdir -p "$RCDIR_B35"
PROJA_B35="$TMP/proj-b35a"; mkdir -p "$PROJA_B35"; mk_git_project "$PROJA_B35"
PROJB_B35="$TMP/proj-b35b"; mkdir -p "$PROJB_B35"; mk_git_project "$PROJB_B35"
register_flat_project projb35a "$PROJA_B35"
register_flat_project projb35b "$PROJB_B35"
AGA_B35=$(CLAUDE_AGENTS_DIR="$BASE_B35" mk_worktree_agent agenta "$PROJA_B35")
( cd "$AGA_B35/work" && echo x > x.txt && git add x.txt && git -c user.email=t@t -c user.name=t commit -qm x )
echo 'not valid json {{{' > "$AGA_B35/done.json"
AGB_B35=$(CLAUDE_AGENTS_DIR="$BASE_B35" mk_worktree_agent agentb "$PROJB_B35")
( cd "$AGB_B35/work" && echo y > y.txt && git add y.txt && git -c user.email=t@t -c user.name=t commit -qm y )
mk_inflight "$AGB_B35" "b35b-key"
call_done "$AGB_B35" "b35b-key" --summary "B35b summary" >/dev/null 2>"$TMP/b35b-done.err"
accept_agent "$AGB_B35"
CLAUDE_AGENTS_DIR="$BASE_B35" CLAUDE_RECONCILER_DIR="$RCDIR_B35" \
  "$RECON" --once >/dev/null 2>"$TMP/b35-recon.err"; RCB35=$?
[[ "$RCB35" == 0 ]] && ok || fail "B35: реальный проход реконсилера завершается штатно несмотря на битого агента A (got $RCB35: $(cat "$TMP/b35-recon.err"))"
[[ "$(jq_file "$AGA_B35/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B35: агент A получил attention (отказ его фазы не потерян)"
[[ "$(jq_file "$AGB_B35/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B35: агент B в ТОМ ЖЕ проходе независимо доведен до integrated несмотря на провал A"

# =============================================================== B36
echo "=== B36: нечитаемый/битый done.json - attention по агенту, реальный проход реконсилера продолжается (не исключение наружу) ==="
BASE_B36="$TMP/agents-b36"; mkdir -p "$BASE_B36"
RCDIR_B36="$TMP/reconciler-b36"; mkdir -p "$RCDIR_B36"
PROJ_B36="$TMP/proj-b36"; mkdir -p "$PROJ_B36"
mk_git_project "$PROJ_B36"
AGB36=$(CLAUDE_AGENTS_DIR="$BASE_B36" mk_worktree_agent wtb36 "$PROJ_B36")
echo 'not valid json {{{' > "$AGB36/done.json"
CLAUDE_AGENTS_DIR="$BASE_B36" CLAUDE_RECONCILER_DIR="$RCDIR_B36" \
  "$RECON" --once >/dev/null 2>"$TMP/b36.err"; RCB36=$?
[[ "$RCB36" == 0 ]] && ok || fail "B36: реальный проход реконсилера завершается штатно на битом done.json (got $RCB36: $(cat "$TMP/b36.err"))"
[[ "$(jq_file "$AGB36/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B36: attention выставлен на агенте (проход продолжился, не исключение наружу)"

# =============================================================== B37
echo "=== B37: одна фаза за вызов - из accepted один вызов доводит РОВНО до integrated (не дальше, до cleaned) ==="
PROJ_B37="$TMP/proj-b37"; mkdir -p "$PROJ_B37"
mk_git_project "$PROJ_B37"
register_flat_project projb37 "$PROJ_B37"
AGB37=$(mk_requested_worktree wtb37 "$PROJ_B37" b37-key "B37 summary")
accept_agent "$AGB37"
"$RUN" done-advance "$AGB37" >/dev/null 2>"$TMP/b37.err"; RCB37=$?
[[ "$RCB37" == 0 ]] && ok || fail "B37: done-advance проходит (got $RCB37: $(cat "$TMP/b37.err"))"
[[ "$(jq_file "$AGB37/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B37: state=integrated ровно (не cleaned)"
[[ -d "$AGB37/work" ]] && ok || fail "B37: worktree еще НЕ снят (cleanup - отдельный вызов/фаза)"

# =============================================================== B38
echo "=== B38: одинаковая ошибка фазы не шлет вторую карточку; смена подписи ошибки - шлет заново ==="
PROJ_B38="$TMP/proj-b38"; mkdir -p "$PROJ_B38"
mk_git_project "$PROJ_B38"
register_obj_project projb38 "$PROJ_B38" bogus
AGB38=$(mk_requested_worktree wtb38 "$PROJ_B38" b38-key "B38 summary")
accept_agent "$AGB38"
ALERT_LOG_B38="$TMP/b38-alert.log"
mk_alert_ok "$ALERT_LOG_B38" "$TMP/alert-ok-b38.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-b38.sh" "$RUN" done-advance "$AGB38" >/dev/null 2>"$TMP/b38a.err"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-b38.sh" "$RUN" done-advance "$AGB38" >/dev/null 2>"$TMP/b38b.err"
[[ "$(alert_block_count "$ALERT_LOG_B38")" == "1" ]] \
  && ok || fail "B38: одинаковая ошибка ('integrate: bogus') не шлет вторую карточку подряд (got $(alert_block_count "$ALERT_LOG_B38"))"
rewrite_project_integrate projb38 merge
python3 -c '
import json, sys
p = sys.argv[1] + "/control.json"
d = json.load(open(p))
d.pop("mission_base_branch", None)
json.dump(d, open(p, "w"), ensure_ascii=False)
' "$AGB38"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-b38.sh" "$RUN" done-advance "$AGB38" >/dev/null 2>"$TMP/b38c.err"
[[ "$(alert_block_count "$ALERT_LOG_B38")" == "2" ]] \
  && ok || fail "B38: смена подписи ошибки (integrate:bogus -> нет mission_base_branch) шлет карточку заново (got $(alert_block_count "$ALERT_LOG_B38"))"

####################################################################
# Adversarial-аудит 2026-07-26 (docs/design-2026-07-26-v2.7b-acceptance-
# integration.md, разбор находок): блокеры 1-4/6/7, серьезные 5/9, минор
# (already vs stale) - фиксы контракта закреплены новыми кейсами B39-B47.
####################################################################

mk_systemctl_mock() { # <bindir> <state> -> $bindir/systemctl отвечает на "--user is-active agent-*.service" заданным состоянием
  local bindir="$1" state="$2"
  mkdir -p "$bindir"
  cat > "$bindir/systemctl" <<EOF
#!/bin/sh
echo "$state"
case "$state" in
  active|activating) exit 0 ;;
  *) exit 3 ;;
esac
EOF
  chmod +x "$bindir/systemctl"
}

# =============================================================== B39 (серьезный 7)
echo "=== B39: fail-closed - 'deactivating' НЕ архивируется, только явные inactive/failed архивируются ==="
PROJ_B39="$TMP/proj-b39"; mkdir -p "$PROJ_B39"
AGB39=$(mk_created_none_agent evtb39 "$PROJ_B39" none)
"$RC" agent stop evtb39 >/dev/null 2>"$TMP/b39-stop.err"
write_done_json "$AGB39" "b39-key" "B39 summary"
set_done_field "$AGB39" '
d["state"] = "cleaned"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
SYSBIN_B39="$TMP/sysbin-b39"
mk_systemctl_mock "$SYSBIN_B39" "deactivating"
PATH="$SYSBIN_B39:$PATH" "$RUN" done-advance "$AGB39" >/dev/null 2>"$TMP/b39a.err"; RCB39A=$?
[[ "$RCB39A" == 0 ]] && ok || fail "B39: deactivating - не отказ фазы, просто wait (got $RCB39A: $(cat "$TMP/b39a.err"))"
[[ -d "$AGB39" ]] && ok || fail "B39: агент НЕ архивирован, пока systemd отвечает deactivating (fail-closed)"
mk_systemctl_mock "$SYSBIN_B39" "inactive"
PATH="$SYSBIN_B39:$PATH" "$RUN" done-advance "$AGB39" >/dev/null 2>"$TMP/b39b.err"; RCB39B=$?
[[ "$RCB39B" == 0 ]] && ok || fail "B39: inactive - архивирует (got $RCB39B: $(cat "$TMP/b39b.err"))"
[[ ! -d "$AGB39" ]] && ok || fail "B39: агент архивирован, когда systemd честно отвечает inactive"

# =============================================================== B40 (серьезный 9)
echo "=== B40: неудачная доставка карточки об отказе НЕ засчитывается - следующий тик с той же ошибкой все равно уведомляет ==="
PROJ_B40="$TMP/proj-b40"; mkdir -p "$PROJ_B40"
mk_git_project "$PROJ_B40"
register_obj_project projb40 "$PROJ_B40" bogus
AGB40=$(mk_requested_worktree wtb40 "$PROJ_B40" b40-key "B40 summary")
accept_agent "$AGB40"
ALERT_LOG_B40_FAIL="$TMP/b40-alert-fail.log"
mk_alert_fail "$ALERT_LOG_B40_FAIL" "$TMP/alert-fail-b40.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-fail-b40.sh" "$RUN" done-advance "$AGB40" >/dev/null 2>"$TMP/b40a.err"
[[ "$(alert_block_count "$ALERT_LOG_B40_FAIL")" == "1" ]] \
  && ok || fail "B40: fixture - первая (неудачная) попытка доставки все же была предпринята"
ALERT_LOG_B40_OK="$TMP/b40-alert-ok.log"
mk_alert_ok "$ALERT_LOG_B40_OK" "$TMP/alert-ok-b40.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-b40.sh" "$RUN" done-advance "$AGB40" >/dev/null 2>"$TMP/b40b.err"
[[ "$(alert_block_count "$ALERT_LOG_B40_OK")" == "1" ]] \
  && ok || fail "B40: та же ошибка ('integrate: bogus') повторно уведомляет, раз предыдущая доставка не подтверждена (got $(alert_block_count "$ALERT_LOG_B40_OK"))"

# =============================================================== B41 (блокер 1, порядок archive)
echo "=== B41: ошибка записи надгробия - отказ фазы archive, rename НЕ выполняется (не проглоченное исключение) ==="
# два уровня вложенности обязательны: _phase_archive поднимается от
# agent_dir на ДВА уровня ("..", "..") к корню archive/tombstones - один
# уровень (как у "$TMP/agents-b41") дал бы тот же "$TMP", что и глобальный
# CLAUDE_AGENTS_DIR="$TMP/agents", и rm/файл ниже задел бы tombstones
# остальных кейсов этого файла.
BASE_B41="$TMP/b41root/agents"; mkdir -p "$BASE_B41"
PROJ_B41="$TMP/proj-b41"; mkdir -p "$PROJ_B41"
AGB41=$(CLAUDE_AGENTS_DIR="$BASE_B41" mk_created_none_agent evtb41 "$PROJ_B41" none)
CLAUDE_AGENTS_DIR="$BASE_B41" "$RC" agent stop evtb41 >/dev/null 2>"$TMP/b41-stop.err"
write_done_json "$AGB41" "b41-key" "B41 summary"
set_done_field "$AGB41" '
d["state"] = "cleaned"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
# tombstones/ обязан быть каталогом - подкладываем ФАЙЛ с этим именем в
# ИЗОЛИРОВАННОМ (не глобальном) дереве, чтобы os.makedirs(tomb_root) упал
# (FileExistsError) и надгробие не записалось, не задев tombstones других кейсов
TOMB_ROOT_B41="$(dirname "$BASE_B41")/tombstones"
: > "$TOMB_ROOT_B41"
CLAUDE_AGENTS_DIR="$BASE_B41" "$RUN" done-advance "$AGB41" >/dev/null 2>"$TMP/b41.err"; RCB41=$?
[[ "$RCB41" == 3 ]] && ok || fail "B41: ошибка записи надгробия -> exit 3, не проглоченное исключение (got $RCB41: $(cat "$TMP/b41.err"))"
[[ -d "$AGB41" ]] && ok || fail "B41: агент НЕ переименован в архив (rename после надгробия не выполнялся)"
[[ "$(jq_file "$AGB41/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B41: attention выставлен"
rm -f "$TOMB_ROOT_B41"; mkdir -p "$TOMB_ROOT_B41"
CLAUDE_AGENTS_DIR="$BASE_B41" "$RUN" done-advance "$AGB41" >/dev/null 2>"$TMP/b41b.err"; RCB41B=$?
[[ "$RCB41B" == 0 ]] && ok || fail "B41: после починки каталога тик доигрывает (got $RCB41B: $(cat "$TMP/b41b.err"))"
[[ ! -d "$AGB41" ]] && ok || fail "B41: агент архивирован после починки"
# (аудит минор 11) успешный ретрай обязан снять И attention, И phase_error,
# записанные предыдущим неудачным проходом, пока каталог еще существовал по
# старому пути - иначе ложная незакрытая авария остается на архивированном
# агенте
ARCHIVE_ROOT_B41="$(dirname "$BASE_B41")/archive"
ARCHDIR_B41=$(find "$ARCHIVE_ROOT_B41" -maxdepth 1 -name 'evtb41-*' 2>/dev/null | head -1)
[[ -n "$ARCHDIR_B41" && -d "$ARCHDIR_B41" ]] && ok || fail "B41: archive/evtb41-<ts> создан (root: $ARCHIVE_ROOT_B41)"
[[ "$(jq_file "$ARCHDIR_B41/done.json" 'd.get("phase_error")')" == "None" ]] \
  && ok || fail "B41: phase_error снят после успешного архива (не остался от предыдущего отказа)"
[[ "$(jq_file "$ARCHDIR_B41/control.json" 'd.get("attention")')" == "None" ]] \
  && ok || fail "B41: attention снят после успешного архива (не остался от предыдущего отказа)"

# =============================================================== B42 (структурный, блокер 1 TOCTOU)
echo "=== B42 (структурный): проверка надгробия в new-task идет ПОСЛЕ взятия пер-именного лока (TOCTOU) ==="
# shellcheck disable=SC2016  # шаблоны grep - буквальный текст исходника claude-rc-agent, не shell-переменные
LOCK_LINE_B42=$(grep -n 'flock -x "\$lockfd"' "$HERE/../bin/claude-rc-agent" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
TOMB_LINE_B42=$(grep -n 'tomb_root/\$name\.json' "$HERE/../bin/claude-rc-agent" | grep -v 'local tomb_root' | head -1 | cut -d: -f1)
[[ -n "$LOCK_LINE_B42" && -n "$TOMB_LINE_B42" && "$TOMB_LINE_B42" -gt "$LOCK_LINE_B42" ]] \
  && ok || fail "B42: надгробие проверяется ПОСЛЕ flock (lock@$LOCK_LINE_B42, tomb-check@$TOMB_LINE_B42)"

# =============================================================== B43 (блокер 2)
echo "=== B43: empty:true, но ветка задачи уехала ПОСЛЕ приемки (агент закоммитил) - отказ, а НЕ тихий skipped ==="
PROJ_B43="$TMP/proj-b43"; mkdir -p "$PROJ_B43"
mk_git_project "$PROJ_B43"
register_flat_project projb43 "$PROJ_B43"
AGB43=$(mk_worktree_agent wtb43 "$PROJ_B43")
mk_inflight "$AGB43" "b43-key"
call_done "$AGB43" "b43-key" --summary "B43 summary" >/dev/null 2>"$TMP/b43-done.err"
[[ "$(jq_file "$AGB43/done.json" 'd.get("empty")')" == "True" ]] && ok || fail "B43: fixture - empty=true (ни одного коммита на момент заявки)"
BASE_B43=$(git -C "$PROJ_B43" rev-parse HEAD)
COMMITB43=$(jq_file "$AGB43/done.json" 'd.get("commit_sha")')
accept_agent "$AGB43"
( cd "$AGB43/work" && echo "b43 drift" > b43drift.txt && git add b43drift.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b43 drift after empty request" )
DRIFTED_B43=$(git -C "$AGB43/work" rev-parse HEAD)
[[ "$DRIFTED_B43" != "$COMMITB43" ]] && ok || fail "B43: fixture - ветка задачи реально уехала после empty-заявки"
"$RUN" done-advance "$AGB43" >/dev/null 2>"$TMP/b43.err"; RCB43=$?
[[ "$RCB43" == 3 ]] && ok || fail "B43: фенсинг ловит уехавшую ветку ДАЖЕ при empty:true -> exit 3 (got $RCB43: $(cat "$TMP/b43.err"))"
[[ "$(jq_file "$AGB43/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B43: state остается accepted (не integrated/skipped)"
[[ "$(git -C "$PROJ_B43" rev-parse refs/heads/main)" == "$BASE_B43" ]] && ok || fail "B43: main не тронута"

# =============================================================== B44 (блокер 3)
# (аудит серьезный 9, тестовый барьер): старая версия НЕ инжектировала
# реальный гоночный коммит между фенсингом и push (фенсинг и push идут
# синхронно внутри одного done-advance - гонку можно вставить только
# монки-патчем git_run на реальном модуле, как в B48). Без инъекции push
# адресовал бы тот же коммит что и при обычном push-по-branch, и тест
# оставался бы зеленым даже при возврате к `git push origin <branch>`.
echo "=== B44: pr - агент коммитит МЕЖДУ фенсингом и push (внедрено монки-патчем на реальном коде); в origin уезжает принятый commit_sha, а НЕ послегоночный коммит ==="
PROJ_B44="$TMP/proj-b44"; mkdir -p "$PROJ_B44"
mk_git_project "$PROJ_B44"
git init -q --bare "$PROJ_B44.git"
git -C "$PROJ_B44" remote add origin "$PROJ_B44.git"
register_obj_project projb44 "$PROJ_B44" pr
AGB44=$(mk_requested_worktree wtb44 "$PROJ_B44" b44-key "B44 summary")
COMMITB44=$(jq_file "$AGB44/done.json" 'd.get("commit_sha")')
BRANCH_B44=$(jq_file "$AGB44/done.json" 'd.get("branch")')
accept_agent "$AGB44"
GHBIN_B44="$TMP/ghbin-b44"; GHLOG_B44="$TMP/b44-gh.log"
mk_gh_mock "$GHBIN_B44" "$GHLOG_B44"
RESULT_B44=$(PATH="$GHBIN_B44:$PATH" python3 - "$HERE/../bin/claude-agent-run" "$AGB44" "$AGB44/work" <<'PY'
import importlib.util, json, subprocess, sys
from importlib.machinery import SourceFileLoader
path, agent_dir, work_dir = sys.argv[1:4]
loader = SourceFileLoader("run_b44race", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
real_git_run = mod.git_run
def spy_git_run(args, cwd, timeout=30):
    if args and args[0] == "push":
        # имитация гонки: агент коммитит НА ТУ ЖЕ ветку в точности между
        # фенсингом (который к этому моменту уже прошел) и самим push
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "--allow-empty", "-qm",
                        "b44 race after fencing"], cwd=work_dir, check=True)
    return real_git_run(args, cwd, timeout)
mod.git_run = spy_git_run
status, err = mod._phase_integrate(agent_dir, "wtb44", d)
print(json.dumps({"status": status, "err": err}, ensure_ascii=False))
PY
)
STATUS_B44=$(jq_str "$RESULT_B44" 'd.get("status")')
[[ "$STATUS_B44" == "ok" ]] && ok || fail "B44: интеграция проходит несмотря на гоночный коммит после фенсинга (got: $RESULT_B44)"
[[ "$(git -C "$AGB44/work" rev-parse HEAD)" != "$COMMITB44" ]] \
  && ok || fail "B44: fixture - гоночный коммит реально добавлен на ветку задачи после фенсинга"
[[ "$(git --git-dir="$PROJ_B44.git" rev-parse "refs/heads/$BRANCH_B44" 2>/dev/null)" == "$COMMITB44" ]] \
  && ok || fail "B44: push адресует ЗАФИКСИРОВАННЫЙ commit_sha, а НЕ уехавший после гонки HEAD ветки"
grep -q 'pr create' "$GHLOG_B44" && ok || fail "B44: gh pr create реально вызван"

# =============================================================== B45 (блокер 6)
echo "=== B45: проект исчез из реестра МЕЖДУ приемкой и интеграцией - отказ фазы с attention, НЕ тихий integrate:none ==="
PROJ_B45="$TMP/proj-b45"; mkdir -p "$PROJ_B45"
mk_git_project "$PROJ_B45"
register_flat_project projb45 "$PROJ_B45"
AGB45=$(mk_requested_worktree wtb45 "$PROJ_B45" b45-key "B45 summary")
BRANCH_B45=$(jq_file "$AGB45/done.json" 'd.get("branch")')
COMMITB45=$(jq_file "$AGB45/done.json" 'd.get("commit_sha")')
accept_agent "$AGB45"
# ключ переименован/снесен из реестра ПОСЛЕ create (project_name в
# control.json уже зафиксирован фазой create - см. §1 п.6): переписываем
# projects.yaml без строки projb45, имитируя переименование/удаление проекта
python3 -c '
import yaml
p = "'"$CLAUDE_RC_PROJECTS_FILE"'"
d = yaml.safe_load(open(p)) or {}
d.pop("projb45", None)
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
'
"$RUN" done-advance "$AGB45" >/dev/null 2>"$TMP/b45.err"; RCB45=$?
[[ "$RCB45" == 3 ]] && ok || fail "B45: пропавший проект -> отказ фазы, exit 3 (got $RCB45: $(cat "$TMP/b45.err"))"
[[ "$(jq_file "$AGB45/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B45: state остается accepted (интеграции не было)"
[[ "$(jq_file "$AGB45/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B45: attention выставлен"
[[ "$(git -C "$PROJ_B45" rev-parse "refs/heads/$BRANCH_B45")" == "$COMMITB45" ]] && ok || fail "B45: ветка задачи цела (никакой тихой интеграции не случилось)"

# =============================================================== B46 (блокер 4)
echo "=== B46: agent дописал коммит НА ТУ ЖЕ ветку ПОСЛЕ приемки/интеграции - уборка НЕ сносит ветку с новой работой (CAS) ==="
PROJ_B46="$TMP/proj-b46"; mkdir -p "$PROJ_B46"
mk_git_project "$PROJ_B46"
register_obj_project projb46 "$PROJ_B46" merge
AGB46=$(mk_requested_worktree wtb46 "$PROJ_B46" b46-key "B46 summary")
BRANCH_B46=$(jq_file "$AGB46/done.json" 'd.get("branch")')
accept_agent "$AGB46"
"$RUN" done-advance "$AGB46" >/dev/null 2>"$TMP/b46-integrate.err"
[[ "$(jq_file "$AGB46/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B46: fixture - integrate довел до integrated ($(cat "$TMP/b46-integrate.err"))"
# агент дописывает B поверх уже принятого и влитого A - ветка задачи
# сдвигается дальше принятого commit_sha; B в целевую (main) не попал
( cd "$AGB46/work" && echo "b46 extra work" > b46extra.txt && git add b46extra.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b46 extra after acceptance" )
EXTRA_B46=$(git -C "$AGB46/work" rev-parse HEAD)
"$RUN" done-advance "$AGB46" >/dev/null 2>"$TMP/b46.err"; RCB46=$?
[[ "$RCB46" == 0 ]] && ok || fail "B46: cleanup проходит без ошибки (got $RCB46: $(cat "$TMP/b46.err"))"
[[ "$(jq_file "$AGB46/done.json" 'd.get("state")')" == "cleaned" ]] && ok || fail "B46: state=cleaned"
[[ -n "$(git -C "$PROJ_B46" branch --list "$BRANCH_B46")" ]] \
  && ok || fail "B46: ветка задачи СОХРАНЕНА - в ней новая работа B, которую безусловный branch -D снес бы"
[[ "$(git -C "$PROJ_B46" rev-parse "refs/heads/$BRANCH_B46")" == "$EXTRA_B46" ]] \
  && ok || fail "B46: ветка задачи по-прежнему указывает на B (новая работа не потеряна)"

# =============================================================== B47 (минор: already vs stale)
echo "=== B47: повторный тап 'принять' ПОСЛЕ того, как FSM ушла дальше (integrated) - already, а НЕ ложное stale ==="
PROJ_B47="$TMP/proj-b47"; mkdir -p "$PROJ_B47"
mk_git_project "$PROJ_B47"
register_flat_project projb47 "$PROJ_B47"
AGB47=$(mk_requested_worktree wtb47 "$PROJ_B47" b47-key "B47 summary")
COMMITB47=$(jq_file "$AGB47/done.json" 'd.get("commit_sha")')
SHA8_B47="${COMMITB47:0:8}"
"$RUN" done-verdict "$AGB47" --accept --expect-sha "$SHA8_B47" >/dev/null 2>"$TMP/b47-accept.err"
"$RUN" done-advance "$AGB47" >/dev/null 2>"$TMP/b47-advance.err"
[[ "$(jq_file "$AGB47/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B47: fixture - FSM продвинулась до integrated ($(cat "$TMP/b47-advance.err"))"
OUT_B47=$("$RUN" done-verdict "$AGB47" --accept --expect-sha "$SHA8_B47" 2>"$TMP/b47.err"); RCB47=$?
[[ "$RCB47" == 0 ]] && ok || fail "B47: повторный accept на integrated -> exit 0, не ошибка (got $RCB47: $(cat "$TMP/b47.err"))"
[[ "$OUT_B47" == "already" ]] && ok || fail "B47: классификация - already, не stale (got: $OUT_B47)"

# =============================================================== B48 (дефект тестового барьера 14)
# B12 проверял только КОНЕЧНЫЙ ref - реализация без третьего (CAS) аргумента
# update-ref дала бы тот же зеленый результат. Здесь CAS проверяется как
# КОНТРАКТ: перехватываем реальный вызов git_run на update-ref, подменяем
# ПЕРЕДАННОЕ старое значение на заведомо неверное и убеждаемся, что git
# реально его сверяет (отказывает) - то есть CAS не декоративный аргумент,
# а рабочая защита от параллельного движения ветки. Цель - ветка НИГДЕ не
# вычекаучена (после блокера 5 путь "вычекаучена" мержит НЕ через update-ref,
# см. _integrate_merge_checked_out) - только тогда КОД идет через update-ref.
echo "=== B48: CAS-контракт update-ref - неверное старое значение реально отклоняется git'ом, не игнорируется ==="
PROJ_B48="$TMP/proj-b48"; mkdir -p "$PROJ_B48"
mk_git_project "$PROJ_B48"
register_obj_project projb48 "$PROJ_B48" merge
AGB48=$(mk_requested_worktree wtb48 "$PROJ_B48" b48-key "B48 summary")
# main освобождается от чекаута ПОСЛЕ create (mission_base_branch уже
# зафиксирован как "main") - переходим на служебную ветку, БЕЗ второго
# дерева: цель - "нигде не вычекаучена", не "вычекаучена в другом месте".
git -C "$PROJ_B48" checkout -q -b scratch-b48
accept_agent "$AGB48"
[[ "$(git -C "$PROJ_B48" worktree list --porcelain | grep -c '^branch refs/heads/main$')" == "0" ]] \
  && ok || fail "B48: fixture - main нигде не вычекаучена"
CAS_B48=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB48" "$PROJ_B48" wtb48 <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent_dir, project_path, branch = sys.argv[1:5]
loader = SourceFileLoader("run_b48cas", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
commit_sha = d["commit_sha"]
real_git_run = mod.git_run
calls = []
def spy_git_run(args, cwd, timeout=30):
    if args and args[0] == "update-ref":
        calls.append(list(args))
        corrupted = list(args)
        corrupted[-1] = "0" * 40  # заведомо неверное "старое" значение
        return real_git_run(corrupted, cwd, timeout)
    return real_git_run(args, cwd, timeout)
mod.git_run = spy_git_run
status, err = mod._integrate_merge(agent_dir, "wtb48", d, project_path,
                                   branch, commit_sha)
print(json.dumps({"status": status, "err": err, "calls": calls},
                 ensure_ascii=False))
PY
)
STATUS_B48=$(jq_str "$CAS_B48" 'd.get("status")')
[[ "$STATUS_B48" == "fail" ]] && ok || fail "B48: git реально отклонил update-ref с подмененным CAS-значением (got: $CAS_B48)"
NCALLS_B48=$(jq_str "$CAS_B48" 'len(d["calls"])')
[[ "$NCALLS_B48" == "1" ]] && ok || fail "B48: update-ref вызван ровно один раз (got: $CAS_B48)"
LENCALL_B48=$(jq_str "$CAS_B48" 'len(d["calls"][0])')
[[ "$LENCALL_B48" == "4" ]] && ok || fail "B48: update-ref реально получает 4 позиционных аргумента (ref, new, old) - CAS не декоративный (got: $CAS_B48)"
[[ "$(git -C "$PROJ_B48" rev-parse refs/heads/main)" != "$(jq_file "$AGB48/done.json" 'd.get("commit_sha")')" ]] \
  && ok || fail "B48: main НЕ сдвинута - подмененный CAS не прошел, эффекта нет"

####################################################################
# Второй adversarial-аудит 2026-07-27 (по самому фикс-паку выше): блокеры
# 1-5, серьезные 6-9, минор (уже vs stale после архива; attention/phase_error
# после успешного ретрая archive) - закреплены новыми кейсами B49-B56.
####################################################################

# =============================================================== B49 (блокер 2, must-fail)
# Ровно тот сценарий, который старый B34a легитимизировал (аудит: "смотрит
# только ref"): ref продвинут В ОБХОД мержа, ПОКА целевая ветка реально
# вычекаучена (project_path САМ - primary-чекаут main) - индекс/файлы
# остаются от старого коммита, git status покажет рассинхрон. Ветка "уже
# влито" обязана быть проверена ПОСЛЕ осмотра дерева и отказать, а не
# принять рассинхрон за успешную интеграцию.
echo "=== B49: ref продвинут в обход мержа, пока target реально вычекаучена (primary worktree) - рассинхрон обнаружен, отказ, не 'уже влито' ==="
PROJ_B49="$TMP/proj-b49"; mkdir -p "$PROJ_B49"
mk_git_project "$PROJ_B49"
register_obj_project projb49 "$PROJ_B49" merge
BASE_B49=$(git -C "$PROJ_B49" rev-parse HEAD)
AGB49=$(mk_requested_worktree wtb49 "$PROJ_B49" b49-key "B49 summary")
COMMITB49=$(jq_file "$AGB49/done.json" 'd.get("commit_sha")')
accept_agent "$AGB49"
git -C "$PROJ_B49" update-ref refs/heads/main "$COMMITB49" "$BASE_B49"
[[ -n "$(git -C "$PROJ_B49" status --porcelain)" ]] \
  && ok || fail "B49: fixture - рабочее дерево primary-чекаута реально рассинхронизировано"
"$RUN" done-advance "$AGB49" >/dev/null 2>"$TMP/b49.err"; RCB49=$?
[[ "$RCB49" == 3 ]] && ok || fail "B49: рассинхрон обнаружен и отказан, НЕ принят за успешную интеграцию (got $RCB49: $(cat "$TMP/b49.err"))"
[[ "$(jq_file "$AGB49/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B49: state остается accepted"

# =============================================================== B50 (блокер 3)
echo "=== B50: целевая ветка вычекаучена сразу в ДВУХ worktree (--force) - согласованно обновить нельзя, отказ ==="
PROJ_B50="$TMP/proj-b50"; mkdir -p "$PROJ_B50"
mk_git_project "$PROJ_B50"
register_obj_project projb50 "$PROJ_B50" merge
BASE_B50=$(git -C "$PROJ_B50" rev-parse HEAD)
AGB50=$(mk_requested_worktree wtb50 "$PROJ_B50" b50-key "B50 summary")
accept_agent "$AGB50"
SECONDARY_B50="$TMP/proj-b50-secondary"
git -C "$PROJ_B50" worktree add -q --force "$SECONDARY_B50" main
"$RUN" done-advance "$AGB50" >/dev/null 2>"$TMP/b50.err"; RCB50=$?
[[ "$RCB50" == 3 ]] && ok || fail "B50: main вычекаучена сразу в двух worktree -> отказ (got $RCB50: $(cat "$TMP/b50.err"))"
[[ "$(jq_file "$AGB50/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B50: state остается accepted"
[[ "$(git -C "$PROJ_B50" rev-parse refs/heads/main)" == "$BASE_B50" ]] && ok || fail "B50: main не тронута"
git -C "$PROJ_B50" worktree remove --force "$SECONDARY_B50" 2>/dev/null || true

# =============================================================== B51 (серьезный 6, монки-патч на реальном коде)
# Гонка внутри ОДНОГО done-advance: между поиском вычекаученного дерева
# (_branch_worktree_status) и самим мержем человек переключает чекаут на
# другую ветку. Инъекция - монки-патчем _branch_worktree_status (реальная
# функция отрабатывает как есть, переключение чекаута - побочный эффект
# ПОСЛЕ нее, перед тем как вызывающий использует результат).
echo "=== B51: чекаут переключили МЕЖДУ поиском дерева и мержем (внедрено монки-патчем) - перепроверка ловит, мержа в чужую ветку нет ==="
PROJ_B51="$TMP/proj-b51"; mkdir -p "$PROJ_B51"
mk_git_project "$PROJ_B51"
register_obj_project projb51 "$PROJ_B51" merge
BASE_B51=$(git -C "$PROJ_B51" rev-parse HEAD)
AGB51=$(mk_requested_worktree wtb51 "$PROJ_B51" b51-key "B51 summary")
COMMITB51=$(jq_file "$AGB51/done.json" 'd.get("commit_sha")')
BRANCH_B51=$(jq_file "$AGB51/done.json" 'd.get("branch")')
accept_agent "$AGB51"
RESULT_B51=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB51" "$PROJ_B51" "$BRANCH_B51" <<'PY'
import importlib.util, json, subprocess, sys
from importlib.machinery import SourceFileLoader
path, agent_dir, project_path, branch = sys.argv[1:5]
loader = SourceFileLoader("run_b51race", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
commit_sha = d["commit_sha"]
real_status = mod._branch_worktree_status
def spy_status(pp, target, lessons_path=None):
    result = real_status(pp, target, lessons_path)
    # имитация гонки: человек переключил чекаут ПОСЛЕ поиска дерева, ДО мержа
    subprocess.run(["git", "checkout", "-q", "-b", "race-switch-b51"],
                   cwd=pp, check=True)
    return result
mod._branch_worktree_status = spy_status
status, err = mod._integrate_merge(agent_dir, "wtb51", d, project_path,
                                   branch, commit_sha)
print(json.dumps({"status": status, "err": err}, ensure_ascii=False))
PY
)
STATUS_B51=$(jq_str "$RESULT_B51" 'd.get("status")')
[[ "$STATUS_B51" == "fail" ]] && ok || fail "B51: переключение чекаута между поиском и мержем обнаружено, отказ (got: $RESULT_B51)"
[[ "$(git -C "$PROJ_B51" symbolic-ref -q --short HEAD)" == "race-switch-b51" ]] \
  && ok || fail "B51: fixture - чекаут реально переключен гонкой"
[[ "$(git -C "$PROJ_B51" rev-parse refs/heads/main)" == "$BASE_B51" ]] && ok || fail "B51: main НЕ сдвинута (мержа в чужую ветку не было)"
[[ "$(git -C "$PROJ_B51" rev-parse "refs/heads/$BRANCH_B51")" == "$COMMITB51" ]] \
  && ok || fail "B51: ветка задачи цела с исходным коммитом (не тронута отказавшим мержем)"

# =============================================================== B52 (блокер 4)
# Подтверждено черным ящиком на реальном git (см. отчет задачи): `update-ref
# -d <symref> <old>` БЕЗ --no-deref разыменовывает символическую ссылку и
# удаляет ЦЕЛЬ (тут - release), а не саму ветку-алиас задачи.
echo "=== B52: удаление ветки задачи на cleanup - с --no-deref; ветка-алиас (символическая ссылка) не сносит цель ==="
PROJ_B52="$TMP/proj-b52"; mkdir -p "$PROJ_B52"
mk_git_project "$PROJ_B52"
BASE_B52=$(git -C "$PROJ_B52" rev-parse HEAD)
git -C "$PROJ_B52" branch release "$BASE_B52"
git -C "$PROJ_B52" symbolic-ref refs/heads/task-alias-b52 refs/heads/release
AGB52=$(mk_created_none_agent evtb52 "$PROJ_B52" none)
# workspace:none в create не фиксирует mission_base_branch (только worktree
# делает это) - фикстура белого ящика дописывает его вручную, симметрично
# B38 (аудит третий блокер 1: cleanup теперь сверяется с ТЕКУЩИМ tip'ом
# этой ветки, а не с сохраненным integrate_ref).
python3 -c '
import json, sys
p = sys.argv[1] + "/control.json"
d = json.load(open(p))
d["mission_base_branch"] = "main"
json.dump(d, open(p, "w"), ensure_ascii=False)
' "$AGB52"
write_done_json "$AGB52" "b52-key" "B52 summary"
set_done_field "$AGB52" '
d["workspace"] = "worktree"
d["state"] = "integrated"
d["branch"] = "task-alias-b52"
d["commit_sha"] = "'"$BASE_B52"'"
d["integrate_ref"] = "'"$BASE_B52"'"
d["integrate_mode"] = "merge"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"
'
"$RUN" done-advance "$AGB52" >/dev/null 2>"$TMP/b52.err"; RCB52=$?
[[ "$RCB52" == 0 ]] && ok || fail "B52: cleanup проходит (got $RCB52: $(cat "$TMP/b52.err"))"
[[ "$(jq_file "$AGB52/done.json" 'd.get("state")')" == "cleaned" ]] && ok || fail "B52: state=cleaned"
[[ "$(git -C "$PROJ_B52" rev-parse refs/heads/release)" == "$BASE_B52" ]] \
  && ok || fail "B52: release (цель символической ветки-алиаса) НЕ снесена (--no-deref сработал)"
[[ -z "$(git -C "$PROJ_B52" for-each-ref refs/heads/task-alias-b52)" ]] \
  && ok || fail "B52: сама ветка-алиас задачи удалена"

# =============================================================== B53 (серьезный 7)
echo "=== B53: ошибка самого удаления ветки (.lock, не CAS-несовпадение) - отказ фазы cleanup, retry+attention ==="
PROJ_B53="$TMP/proj-b53"; mkdir -p "$PROJ_B53"
mk_git_project "$PROJ_B53"
register_obj_project projb53 "$PROJ_B53" merge
AGB53=$(mk_requested_worktree wtb53 "$PROJ_B53" b53-key "B53 summary")
BRANCH_B53=$(jq_file "$AGB53/done.json" 'd.get("branch")')
accept_agent "$AGB53"
"$RUN" done-advance "$AGB53" >/dev/null 2>"$TMP/b53-integrate.err"
[[ "$(jq_file "$AGB53/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B53: fixture - integrate довел до integrated ($(cat "$TMP/b53-integrate.err"))"
: > "$PROJ_B53/.git/refs/heads/$BRANCH_B53.lock"
"$RUN" done-advance "$AGB53" >/dev/null 2>"$TMP/b53.err"; RCB53=$?
[[ "$RCB53" == 3 ]] && ok || fail "B53: ошибка удаления ветки (.lock) -> отказ фазы, exit 3 (got $RCB53: $(cat "$TMP/b53.err"))"
[[ "$(jq_file "$AGB53/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B53: state остается integrated (cleanup не завершен)"
[[ ! -d "$AGB53/work" ]] && ok || fail "B53: worktree все же снят (эта часть уборки успела пройти до сбоя на branch-delete)"
[[ "$(jq_file "$AGB53/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B53: attention выставлен"
rm -f "$PROJ_B53/.git/refs/heads/$BRANCH_B53.lock"
"$RUN" done-advance "$AGB53" >/dev/null 2>"$TMP/b53b.err"; RCB53B=$?
[[ "$RCB53B" == 0 ]] && ok || fail "B53: после снятия .lock ретрай доигрывает (got $RCB53B: $(cat "$TMP/b53b.err"))"
[[ "$(jq_file "$AGB53/done.json" 'd.get("state")')" == "cleaned" ]] && ok || fail "B53: state=cleaned"
[[ "$(git -C "$PROJ_B53" branch --list "$BRANCH_B53" | wc -l | tr -d ' ')" == "0" ]] && ok || fail "B53: ветка задачи в итоге удалена"

# =============================================================== B54 (блокер 5)
echo "=== B54: форма B без path - НЕ считается зарегистрированной, фаза отказывает вместо мержа по устаревшему spec.project ==="
PROJ_B54="$TMP/proj-b54"; mkdir -p "$PROJ_B54"
mk_git_project "$PROJ_B54"
register_obj_project projb54 "$PROJ_B54" merge
AGB54=$(mk_requested_worktree wtb54 "$PROJ_B54" b54-key "B54 summary")
BRANCH_B54=$(jq_file "$AGB54/done.json" 'd.get("branch")')
COMMITB54=$(jq_file "$AGB54/done.json" 'd.get("commit_sha")')
accept_agent "$AGB54"
# path исчез из реестра, ключ (и integrate) остались - хелпер обязан
# трактовать это как "нет в реестре" (§1 п.3), а не "путь неважен"
python3 -c '
import yaml
p = "'"$CLAUDE_RC_PROJECTS_FILE"'"
d = yaml.safe_load(open(p)) or {}
d["projb54"] = {"integrate": "merge"}
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
'
rc_project_integrate projb54 >/dev/null 2>&1; RC_B54_HELPER=$?
[[ "$RC_B54_HELPER" != "0" ]] && ok || fail "B54: project_integrate отдает код 'нет в реестре' на мапе без path (got rc=$RC_B54_HELPER)"
"$RUN" done-advance "$AGB54" >/dev/null 2>"$TMP/b54.err"; RCB54=$?
[[ "$RCB54" == 3 ]] && ok || fail "B54: мапа без path -> отказ фазы, exit 3 (got $RCB54: $(cat "$TMP/b54.err"))"
[[ "$(jq_file "$AGB54/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B54: state остается accepted"
[[ "$(jq_file "$AGB54/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B54: attention выставлен"
[[ "$(git -C "$PROJ_B54" rev-parse "refs/heads/$BRANCH_B54")" == "$COMMITB54" ]] \
  && ok || fail "B54: ветка задачи цела (тихого мержа по устаревшему spec.project не случилось)"

# =============================================================== B55 (минор 10)
echo "=== B55: повторный тап 'принять' ПОСЛЕ полной архивации - already, не устаревшая заявка/'нет каталога' ==="
PROJ_B55="$TMP/proj-b55"; mkdir -p "$PROJ_B55"
AGB55=$(mk_created_none_agent evtb55 "$PROJ_B55" none)
"$RC" agent stop evtb55 >/dev/null 2>"$TMP/b55-stop.err"
write_done_json "$AGB55" "b55-key" "B55 summary"
set_done_field "$AGB55" '
d["state"] = "cleaned"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
"$RUN" done-advance "$AGB55" >/dev/null 2>"$TMP/b55-archive.err"; RCB55ARCH=$?
[[ "$RCB55ARCH" == 0 ]] && ok || fail "B55: fixture - архив проходит (got $RCB55ARCH: $(cat "$TMP/b55-archive.err"))"
[[ ! -d "$AGB55" ]] && ok || fail "B55: fixture - agents/evtb55 отсутствует (архивирован)"
OUT_B55=$("$RUN" done-verdict "$AGB55" --accept --expect-sha - 2>"$TMP/b55.err"); RCB55=$?
[[ "$RCB55" == 0 ]] && ok || fail "B55: повторный accept ПОСЛЕ архивации -> exit 0, не ошибка (got $RCB55: $(cat "$TMP/b55.err"))"
[[ "$OUT_B55" == "already" ]] && ok || fail "B55: классификация - already, НЕ 'нет такого агента'/stale (got: $OUT_B55)"

####################################################################
# Третий adversarial-аудит 2026-07-27 (по фикс-паку второго аудита): блокеры
# 1/2/4, мелочь 5 (провалимость доказана скретч-копией/монки-патчем), плюс
# инжектированный отказ внешней команды для серьезного 3 и мелочи 6 -
# закреплены новыми кейсами B56-B61.
####################################################################

# =============================================================== B56 (аудит третий блокер 1)
echo "=== B56: main откатили ПОСЛЕ мержа - cleanup сверяется с ТЕКУЩИМ tip'ом целевой ветки, а не с сохраненным integrate_ref; ветка задачи сохранена ==="
PROJ_B56="$TMP/proj-b56"; mkdir -p "$PROJ_B56"
mk_git_project "$PROJ_B56"
register_obj_project projb56 "$PROJ_B56" merge
BASE_B56=$(git -C "$PROJ_B56" rev-parse HEAD)
AGB56=$(mk_requested_worktree wtb56 "$PROJ_B56" b56-key "B56 summary")
BRANCH_B56=$(jq_file "$AGB56/done.json" 'd.get("branch")')
COMMITB56=$(jq_file "$AGB56/done.json" 'd.get("commit_sha")')
accept_agent "$AGB56"
"$RUN" done-advance "$AGB56" >/dev/null 2>"$TMP/b56-integrate.err"
[[ "$(jq_file "$AGB56/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B56: fixture - integrate довел до integrated ($(cat "$TMP/b56-integrate.err"))"
[[ "$(git -C "$PROJ_B56" rev-parse refs/heads/main)" == "$COMMITB56" ]] \
  && ok || fail "B56: fixture - main реально перемотана до принятого коммита"
# оператор откатывает main НАЗАД после мержа (вне контроля контура) - main
# больше не содержит принятый коммит, но сохраненный integrate_ref все еще
# указывает на него
git -C "$PROJ_B56" update-ref refs/heads/main "$BASE_B56"
"$RUN" done-advance "$AGB56" >/dev/null 2>"$TMP/b56.err"; RCB56=$?
[[ "$RCB56" == 0 ]] && ok || fail "B56: cleanup проходит без ошибки (got $RCB56: $(cat "$TMP/b56.err"))"
[[ "$(jq_file "$AGB56/done.json" 'd.get("state")')" == "cleaned" ]] && ok || fail "B56: state=cleaned"
[[ -n "$(git -C "$PROJ_B56" branch --list "$BRANCH_B56")" ]] \
  && ok || fail "B56: ветка задачи СОХРАНЕНА - откаченный main больше не содержит принятый коммит, удалять по устаревшему integrate_ref нельзя"
[[ "$(git -C "$PROJ_B56" rev-parse "refs/heads/$BRANCH_B56")" == "$COMMITB56" ]] \
  && ok || fail "B56: ветка задачи по-прежнему на принятом коммите"

# =============================================================== B57 (аудит третий блокер 2)
# Целевая ветка НИГДЕ не вычекаучена в момент осмотра -> мерж НЕ fast-forward
# (main реально разошлась) идет через временный detached worktree - это НЕ
# мгновенная операция (§4 п.3). Монки-патчем на реальном коде (техника B48/
# B51) внедряем чекаут ПОСЛЕ мержа во временном дереве, но ДО перестановки
# ссылки - перепроверка обязана поймать это и отказать, не переставляя ref.
echo "=== B57: чекаут материализовался, пока шел не-FF мерж во временном дереве (внедрено монки-патчем) - перепроверка перед update-ref ловит, ref не переставлен ==="
PROJ_B57="$TMP/proj-b57"; mkdir -p "$PROJ_B57"
mk_git_project "$PROJ_B57"
register_obj_project projb57 "$PROJ_B57" merge
AGB57=$(mk_requested_worktree wtb57 "$PROJ_B57" b57-key "B57 summary")
BRANCH_B57=$(jq_file "$AGB57/done.json" 'd.get("branch")')
COMMITB57=$(jq_file "$AGB57/done.json" 'd.get("commit_sha")')
# main расходится с веткой задачи - мерж будет НЕ fast-forward
( cd "$PROJ_B57" && echo "main diverges" > main-b57.txt && git add main-b57.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "main diverges b57" )
MAIN_B57=$(git -C "$PROJ_B57" rev-parse refs/heads/main)
# main нигде не вычекаучена на момент интеграции (симметрично B48/B57-setup)
git -C "$PROJ_B57" checkout -q -b scratch-b57
accept_agent "$AGB57"
OTHER_WT_B57="$TMP/proj-b57-race-checkout"
RESULT_B57=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB57" "$PROJ_B57" "$BRANCH_B57" main "$OTHER_WT_B57" <<'PY'
import importlib.util, json, subprocess, sys
from importlib.machinery import SourceFileLoader
path, agent_dir, project_path, branch, target, other_wt = sys.argv[1:7]
loader = SourceFileLoader("run_b57race", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
commit_sha = d["commit_sha"]
tmp = agent_dir + "/.integrate-worktree"
real_git_run = mod.git_run
def spy_git_run(args, cwd, timeout=30):
    r = real_git_run(args, cwd, timeout)
    if args == ["rev-parse", "HEAD"] and cwd == tmp:
        # имитация гонки: чекаут материализуется ПОСЛЕ того, как код узнал
        # результат мержа во временном дереве, но ДО перестановки ссылки
        subprocess.run(["git", "worktree", "add", other_wt, target],
                       cwd=project_path, check=True, capture_output=True,
                       text=True)
    return r
mod.git_run = spy_git_run
status, err = mod._integrate_merge(agent_dir, "wtb57", d, project_path,
                                   branch, commit_sha)
print(json.dumps({"status": status, "err": err}, ensure_ascii=False))
PY
)
STATUS_B57=$(jq_str "$RESULT_B57" 'd.get("status")')
[[ "$STATUS_B57" == "fail" ]] && ok || fail "B57: чекаут, материализовавшийся во время мержа, обнаружен - отказ (got: $RESULT_B57)"
[[ "$(git -C "$OTHER_WT_B57" symbolic-ref -q --short HEAD)" == "main" ]] \
  && ok || fail "B57: fixture - гоночный чекаут реально материализовался"
[[ "$(git -C "$PROJ_B57" rev-parse refs/heads/main)" == "$MAIN_B57" ]] \
  && ok || fail "B57: main НЕ переставлена под материализовавшимся чекаутом"
[[ "$(git -C "$PROJ_B57" rev-parse "refs/heads/$BRANCH_B57")" == "$COMMITB57" ]] \
  && ok || fail "B57: ветка задачи цела (не тронута отказавшим мержем)"
[[ ! -d "$AGB57/.integrate-worktree" ]] \
  && ok || fail "B57: временный worktree мержа снят даже при отказе"
git -C "$PROJ_B57" worktree remove --force "$OTHER_WT_B57" 2>/dev/null || true

# =============================================================== B58 (аудит третий блокер 4)
# Три исхода git-проверки, а не два: подтвержденное удаление упало (например
# .lock), а последующий rev-parse --verify -q САМ не смог ответить (ошибка
# чтения репозитория, не просто "ветки нет") - это ТОЖЕ отказ, а не
# благополучное "видимо, ушла" (§8 "неизвестный исход - это отказ").
echo "=== B58: удаление ветки упало И проверочный rev-parse сам не смог ответить (внедрено монки-патчем) - третий исход тоже отказ, не тихое cleaned ==="
PROJ_B58="$TMP/proj-b58"; mkdir -p "$PROJ_B58"
mk_git_project "$PROJ_B58"
register_obj_project projb58 "$PROJ_B58" merge
AGB58=$(mk_requested_worktree wtb58 "$PROJ_B58" b58-key "B58 summary")
BRANCH_B58=$(jq_file "$AGB58/done.json" 'd.get("branch")')
accept_agent "$AGB58"
"$RUN" done-advance "$AGB58" >/dev/null 2>"$TMP/b58-integrate.err"
[[ "$(jq_file "$AGB58/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B58: fixture - integrate довел до integrated ($(cat "$TMP/b58-integrate.err"))"
RESULT_B58=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB58" wtb58 "$BRANCH_B58" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader


class FakeResult:
    def __init__(self, returncode, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


path, agent_dir, name, branch = sys.argv[1:5]
loader = SourceFileLoader("run_b58unknown", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
real_git_run = mod.git_run
verify_args = ["rev-parse", "--verify", "-q", "refs/heads/%s" % branch]


def spy_git_run(args, cwd, timeout=30):
    if args and args[0] == "update-ref" and "-d" in args:
        # удаление реально упало (аналог .lock) - НЕ выполняем настоящий git
        return FakeResult(1, "", "fatal: unable to lock ref (simulated)")
    if args == verify_args:
        # rev-parse сам не смог ответить - НЕ "ветки нет" (rc=1), а
        # реальная ошибка чтения репозитория (rc>1)
        return FakeResult(129, "", "fatal: simulated repo access error")
    return real_git_run(args, cwd, timeout)


mod.git_run = spy_git_run
status, err = mod._phase_cleanup(agent_dir, name, d)
print(json.dumps({"status": status, "err": err}, ensure_ascii=False))
PY
)
STATUS_B58=$(jq_str "$RESULT_B58" 'd.get("status")')
[[ "$STATUS_B58" == "fail" ]] \
  && ok || fail "B58: неизвестный исход rev-parse (не 0, не 1) -> отказ фазы, не тихое cleaned (got: $RESULT_B58)"
[[ "$(git -C "$PROJ_B58" rev-parse "refs/heads/$BRANCH_B58")" != "" ]] \
  && ok || fail "B58: ветка задачи физически цела (реального update-ref -d не было)"

# =============================================================== B59 (аудит третий мелочь 5)
# "task-a" и "task-a-extra" делят префикс "task-a-" - наивный startswith у
# task-a подхватил бы чужой архив. Плюс несколько архивов ТОЧНОГО имени
# (реюз имени после TTL надгробия) - обязаны перебираться ВСЕ в поисках
# нужного sha, а не только самый свежий.
echo "=== B59: точное имя архива (не префикс) + перебор ВСЕХ архивов точного имени, не только самого свежего ==="
ARCH_ROOT_B59="$TMP/archive-b59-root/archive"
mkdir -p "$ARCH_ROOT_B59"
mkdir -p "$ARCH_ROOT_B59/task-a-extra-2026-01-01T00:00:00Z"
printf '{"commit_sha": "%s"}' "decoy0000000000000000000000000000000000" \
  > "$ARCH_ROOT_B59/task-a-extra-2026-01-01T00:00:00Z/done.json"
mkdir -p "$ARCH_ROOT_B59/task-a-2026-01-01T00:00:00Z"
printf '{"commit_sha": "%s"}' "1111111111111111111111111111111111aaaa" \
  > "$ARCH_ROOT_B59/task-a-2026-01-01T00:00:00Z/done.json"
mkdir -p "$ARCH_ROOT_B59/task-a-2026-02-01T00:00:00Z"
printf '{"commit_sha": "%s"}' "2222222222222222222222222222222222bbbb" \
  > "$ARCH_ROOT_B59/task-a-2026-02-01T00:00:00Z/done.json"
RESULT_B59=$(python3 - "$HERE/../bin/claude-agent-run" "$TMP/archive-b59-root/agents/task-a" <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent_dir = sys.argv[1:3]
loader = SourceFileLoader("run_b59find", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
old = mod._find_archived_done(agent_dir, "task-a", "11111111")
new = mod._find_archived_done(agent_dir, "task-a", "22222222")
miss = mod._find_archived_done(agent_dir, "task-a", "99999999")
print(json.dumps({"old": old, "new": new, "miss": miss}, ensure_ascii=False))
PY
)
[[ "$(jq_str "$RESULT_B59" 'd["old"]["commit_sha"]')" == "1111111111111111111111111111111111aaaa" ]] \
  && ok || fail "B59: старый архив ТОЧНОГО имени найден по нужному sha (не подмят декоем/самым свежим) (got: $RESULT_B59)"
[[ "$(jq_str "$RESULT_B59" 'd["new"]["commit_sha"]')" == "2222222222222222222222222222222222bbbb" ]] \
  && ok || fail "B59: новый архив ТОЧНОГО имени тоже находится (got: $RESULT_B59)"
[[ "$(jq_str "$RESULT_B59" 'd["miss"]')" == "None" ]] \
  && ok || fail "B59: несуществующий sha -> None, не подмена декоем (got: $RESULT_B59)"

# =============================================================== B60 (аудит третий серьезный 3, инжектированный отказ)
# Сентинел битого done.json (.done-corrupt-alert) обязан засчитываться
# ТОЛЬКО после подтвержденной доставки - иначе первая неудачная попытка
# навсегда глушит уведомление об этой ошибке.
echo "=== B60: сентинел битого done.json НЕ засчитывается до подтвержденной доставки (инжектирован отказ alert-команды) ==="
PROJ_B60="$TMP/proj-b60"; mkdir -p "$PROJ_B60"
mk_git_project "$PROJ_B60"
AGB60=$(mk_worktree_agent wtb60 "$PROJ_B60")
echo 'not valid json {{{' > "$AGB60/done.json"
ALERT_LOG_B60F="$TMP/b60-fail.log"
mk_alert_fail "$ALERT_LOG_B60F" "$TMP/alert-fail-b60.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-fail-b60.sh" "$RUN" done-advance "$AGB60" >/dev/null 2>"$TMP/b60a.err"; RCB60A=$?
[[ "$RCB60A" == 3 ]] && ok || fail "B60: битый done.json -> exit 3 (got $RCB60A)"
[[ "$(alert_block_count "$ALERT_LOG_B60F")" == "1" ]] && ok || fail "B60: доставка реально попытана (мок с ненулевым кодом вызван)"
[[ ! -f "$AGB60/.done-corrupt-alert" ]] \
  && ok || fail "B60: сентинел НЕ записан после неудачной доставки (иначе уведомление глохнет навсегда)"
ALERT_LOG_B60O="$TMP/b60-ok.log"
mk_alert_ok "$ALERT_LOG_B60O" "$TMP/alert-ok-b60.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-b60.sh" "$RUN" done-advance "$AGB60" >/dev/null 2>"$TMP/b60b.err"; RCB60B=$?
[[ "$RCB60B" == 3 ]] && ok || fail "B60: тот же битый done.json на следующем тике снова exit 3 (got $RCB60B)"
[[ "$(alert_block_count "$ALERT_LOG_B60O")" == "1" ]] \
  && ok || fail "B60: на этот раз доставка успешна и реально отправлена (не проглочена как 'уже слали')"
[[ -f "$AGB60/.done-corrupt-alert" ]] \
  && ok || fail "B60: сентинел записан ПОСЛЕ подтвержденной доставки"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-b60.sh" "$RUN" done-advance "$AGB60" >/dev/null 2>"$TMP/b60c.err"
[[ "$(alert_block_count "$ALERT_LOG_B60O")" == "1" ]] \
  && ok || fail "B60: третий тик с той же подписью не шлет повторно (дедуп по сентинелу по-прежнему работает)"

# =============================================================== B61 (аудит третий мелочь 6, инжектированный отказ)
# Результат снятия attention (control-cas) обязан проверяться в archive:
# при реальной (не CAS-конфликтной) ошибке фаза обязана отказать и НЕ
# переименовывать каталог в архив - иначе непогашенный done_phase уедет в
# архив без единого шанса на retry.
echo "=== B61: transient-ошибка снятия attention (подмена claude-agent-io) - archive отказывает, rename НЕ происходит ==="
PROJ_B61="$TMP/proj-b61"; mkdir -p "$PROJ_B61"
AGB61=$(mk_created_none_agent evtb61 "$PROJ_B61" none)
"$RC" agent stop evtb61 >/dev/null 2>"$TMP/b61-stop.err"
write_done_json "$AGB61" "b61-key" "B61 summary"
set_done_field "$AGB61" '
d["state"] = "cleaned"
d["verdict_at"] = "2026-02-01T00:00:00Z"; d["verdict_by"] = "tg:1001"; d["verdict_comment"] = None
d["integrate_mode"] = "skipped"; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
d["integrated_at"] = "2026-02-01T00:01:00Z"; d["cleaned_at"] = "2026-02-01T00:02:00Z"
'
RESULT_B61=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB61" evtb61 <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent_dir, name = sys.argv[1:4]
loader = SourceFileLoader("run_b61clear", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
# подмена claude-agent-io (инжектированный отказ, не CAS-конфликт 4 -
# именно ЭТУ ветку "штатного no-op" _clear_attention обязана отличать от
# реальной transient-ошибки)
mod._clear_attention = lambda *a, **k: False
status, err = mod._phase_archive(agent_dir, name, d)
print(json.dumps({"status": status, "err": err}, ensure_ascii=False))
PY
)
STATUS_B61=$(jq_str "$RESULT_B61" 'd.get("status")')
[[ "$STATUS_B61" == "fail" ]] \
  && ok || fail "B61: transient-ошибка _clear_attention -> отказ фазы archive (got: $RESULT_B61)"
[[ -d "$AGB61" ]] && ok || fail "B61: каталог агента НЕ переименован в архив (rename не произошел после отказа)"

####################################################################
# Четвертый adversarial-аудит (docs/design-2026-07-26-v2.7b-acceptance-
# integration.md §8 "неизвестный исход - отказ"): четыре fail-open дефекта
# закреплены новыми кейсами B62-B65.
####################################################################

# =============================================================== B62 (аудит четвертый п.1)
# `git worktree list` сам упал (недоступный репозиторий, таймаут) -
# раньше это трактовалось как "ветка нигде не вычекаучена" (None), и
# update-ref мог переставить ссылку под живым чекаутом. Монки-патчем на
# реальном коде (техника B48/B57/B58) внедряем отказ ИМЕННО `worktree list`,
# оставляя остальной git настоящим.
echo "=== B62: git worktree list упал (внедрено монки-патчем) - _integrate_merge отказывает, ref не переставлен ==="
PROJ_B62="$TMP/proj-b62"; mkdir -p "$PROJ_B62"
mk_git_project "$PROJ_B62"
register_obj_project projb62 "$PROJ_B62" merge
BASE_B62=$(git -C "$PROJ_B62" rev-parse HEAD)
AGB62=$(mk_requested_worktree wtb62 "$PROJ_B62" b62-key "B62 summary")
BRANCH_B62=$(jq_file "$AGB62/done.json" 'd.get("branch")')
COMMITB62=$(jq_file "$AGB62/done.json" 'd.get("commit_sha")')
# main освобождается от чекаута (та же техника, что B48) - без этого код
# пошел бы через _integrate_merge_checked_out, не через _branch_worktree_status
git -C "$PROJ_B62" checkout -q -b scratch-b62
accept_agent "$AGB62"
RESULT_B62=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB62" "$PROJ_B62" wtb62 <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader


class FakeResult:
    def __init__(self, returncode, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


path, agent_dir, project_path, branch = sys.argv[1:5]
loader = SourceFileLoader("run_b62wtlist", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
commit_sha = d["commit_sha"]
real_git_run = mod.git_run


def spy_git_run(args, cwd, timeout=30):
    if args[:2] == ["worktree", "list"]:
        return FakeResult(1, "", "fatal: simulated worktree list failure")
    return real_git_run(args, cwd, timeout)


mod.git_run = spy_git_run
status, err = mod._integrate_merge(agent_dir, "wtb62", d, project_path,
                                   branch, commit_sha)
print(json.dumps({"status": status, "err": err}, ensure_ascii=False))
PY
)
STATUS_B62=$(jq_str "$RESULT_B62" 'd.get("status")')
[[ "$STATUS_B62" == "fail" ]] \
  && ok || fail "B62: git worktree list упал -> отказ, не благополучное 'нигде не вычекаучена' (got: $RESULT_B62)"
[[ "$(git -C "$PROJ_B62" rev-parse refs/heads/main)" == "$BASE_B62" ]] \
  && ok || fail "B62: main НЕ переставлена - до update-ref дело не дошло"
[[ "$(git -C "$PROJ_B62" rev-parse "refs/heads/$BRANCH_B62")" == "$COMMITB62" ]] \
  && ok || fail "B62: ветка задачи цела"

# =============================================================== B63 (аудит четвертый п.2)
# Первая попытка revise упала (несвязанный сбой) и поставила attention;
# следующая доставляет событие и должна снять attention ПЕРЕД снятием
# done.json, а не после. Монки-патчим _clear_attention на реальном
# _phase_revise (техника B61, но revise вместо archive): до фикса
# _phase_revise вообще не звал _clear_attention (это делала внешняя
# обвязка _phase_step уже ПОСЛЕ unlink) - на старом коде этот же вызов дал
# бы status="written" и снятый done.json НЕЗАВИСИМО от монки-патча, то есть
# тест был бы red именно там, где чинили.
echo "=== B63: transient-ошибка снятия attention в revise (инжектирована монки-патчем) - фаза отказывает ДО снятия done.json ==="
PROJ_B63="$TMP/proj-b63"; mkdir -p "$PROJ_B63"
AGB63=$(mk_created_none_agent evtb63 "$PROJ_B63" none)
"$RC" agent stop evtb63 >/dev/null 2>"$TMP/b63-stop.err"
write_done_json "$AGB63" "b63-key" "B63 summary"
set_done_field "$AGB63" '
d["state"] = "rejected"
d["verdict_at"] = "2026-02-08T00:00:00Z"; d["verdict_by"] = "tg:1001"
d["verdict_comment"] = "B63 нужно доделать"
d["integrate_mode"] = None; d["integrate_ref"] = None
d["phase_attempts"] = 0; d["phase_error"] = None
'
RESULT_B63A=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB63" evtb63 <<'PY'
import importlib.util, json, os, sys
from importlib.machinery import SourceFileLoader
path, agent_dir, name = sys.argv[1:4]
loader = SourceFileLoader("run_b63revise", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
dp = agent_dir + "/done.json"
d = mod.load_json(dp)
# инжектированный отказ control-cas (не CAS-конфликт "уже снята") - именно
# ЭТУ ветку старый _phase_revise не проверял вовсе
mod._clear_attention = lambda *a, **k: False
status, err = mod._phase_revise(agent_dir, name, d, dp)
print(json.dumps({"status": status, "err": err,
                  "dp_exists": os.path.exists(dp)}, ensure_ascii=False))
PY
)
STATUS_B63A=$(jq_str "$RESULT_B63A" 'd.get("status")')
[[ "$STATUS_B63A" == "fail" ]] \
  && ok || fail "B63: transient-ошибка _clear_attention -> отказ фазы revise, не 'written' (got: $RESULT_B63A)"
DPEXISTS_B63A=$(jq_str "$RESULT_B63A" 'd.get("dp_exists")')
[[ "$DPEXISTS_B63A" == "True" ]] \
  && ok || fail "B63: done.json НЕ снят - отказ случился ДО терминального шага (got: $RESULT_B63A)"
HISTLINES_B63A=$(wc -l < "$AGB63/done.history.jsonl" | tr -d ' ')
[[ "$HISTLINES_B63A" == "1" ]] && ok || fail "B63: история дописана шагом 1 (got $HISTLINES_B63A строк)"
spool_files_b63_pre=("$CLAUDE_AGENT_SPOOL_BASE/evtb63"/*.json)
SPOOLCNT_B63_PRE=${#spool_files_b63_pre[@]}
[[ "$SPOOLCNT_B63_PRE" == "1" ]] && ok || fail "B63: событие-доработка положено шагом 2 (got $SPOOLCNT_B63_PRE)"
# ретрай реальным done-advance (без монки-патча) - attention снимается
# по-настоящему, done.json снимается, шаги 1/2 не задваиваются
"$RUN" done-advance "$AGB63" >/dev/null 2>"$TMP/b63b.err"; RCB63B=$?
[[ "$RCB63B" == 0 ]] && ok || fail "B63: ретрай доигрывает (got $RCB63B: $(cat "$TMP/b63b.err"))"
[[ ! -f "$AGB63/done.json" ]] && ok || fail "B63: done.json снят ретраем"
HISTLINES_B63B=$(wc -l < "$AGB63/done.history.jsonl" | tr -d ' ')
[[ "$HISTLINES_B63B" == "1" ]] && ok || fail "B63: история НЕ задвоилась на ретрае (got $HISTLINES_B63B строк)"
spool_files_b63=("$CLAUDE_AGENT_SPOOL_BASE/evtb63"/*.json)
SPOOLCNT_B63=${#spool_files_b63[@]}
[[ "$SPOOLCNT_B63" == "1" ]] && ok || fail "B63: событие-доработка НЕ задвоено на ретрае (got $SPOOLCNT_B63)"

# =============================================================== B64 (аудит четвертый п.3)
# Ошибка чтения control.json (не отсутствие поля mission_base_branch)
# обязана быть отказом фазы cleanup, а не благополучным пропуском проверки
# и удаления ветки задачи с итоговым state=cleaned.
echo "=== B64: control.json нечитаем (внедрено монки-патчем load_json) - cleanup отказывает, ветка задачи НЕ пропущена молча ==="
PROJ_B64="$TMP/proj-b64"; mkdir -p "$PROJ_B64"
mk_git_project "$PROJ_B64"
register_obj_project projb64 "$PROJ_B64" merge
AGB64=$(mk_requested_worktree wtb64 "$PROJ_B64" b64-key "B64 summary")
BRANCH_B64=$(jq_file "$AGB64/done.json" 'd.get("branch")')
accept_agent "$AGB64"
"$RUN" done-advance "$AGB64" >/dev/null 2>"$TMP/b64-integrate.err"
[[ "$(jq_file "$AGB64/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B64: fixture - integrate довел до integrated ($(cat "$TMP/b64-integrate.err"))"
RESULT_B64=$(python3 - "$HERE/../bin/claude-agent-run" "$AGB64" wtb64 <<'PY'
import importlib.util, json, sys
from importlib.machinery import SourceFileLoader
path, agent_dir, name = sys.argv[1:4]
loader = SourceFileLoader("run_b64cleanup", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
d = mod.load_json(agent_dir + "/done.json")
control_path = agent_dir + "/control.json"
real_load_json = mod.load_json


def spy_load_json(path):
    if path == control_path:
        raise OSError("simulated read error")
    return real_load_json(path)


mod.load_json = spy_load_json
status, err = mod._phase_cleanup(agent_dir, name, d)
print(json.dumps({"status": status, "err": err}, ensure_ascii=False))
PY
)
STATUS_B64=$(jq_str "$RESULT_B64" 'd.get("status")')
[[ "$STATUS_B64" == "fail" ]] \
  && ok || fail "B64: control.json нечитаем -> отказ фазы cleanup, не тихое cleaned (got: $RESULT_B64)"
[[ -n "$(git -C "$PROJ_B64" branch --list "$BRANCH_B64")" ]] \
  && ok || fail "B64: ветка задачи цела - удаление даже не пыталось начаться на нечитаемом control.json"

# =============================================================== B65 (аудит четвертый п.4)
# Ненулевой код (и отдельно - битый JSON) от `gh pr list` раньше трактовался
# как "PR нет" - следующим шагом шел push+create. Здесь оба случая обязаны
# быть отказом фазы, без push, без создания PR; плюс --state all - иначе
# уже ЗАКРЫТЫЙ PR прошлой попытки не находится и создается дубль.
echo "=== B65: gh pr list падает / отдает битый JSON - отказ, push и повторный PR НЕ создаются; --state all реально передан ==="
PROJ_B65="$TMP/proj-b65"; mkdir -p "$PROJ_B65"
mk_git_project "$PROJ_B65"
git init -q --bare "$PROJ_B65.git"
git -C "$PROJ_B65" remote add origin "$PROJ_B65.git"
register_obj_project projb65 "$PROJ_B65" pr
AGB65=$(mk_requested_worktree wtb65 "$PROJ_B65" b65-key "B65 summary")
BRANCH_B65=$(jq_file "$AGB65/done.json" 'd.get("branch")')
accept_agent "$AGB65"
GHBIN_B65_FAIL="$TMP/ghbin-b65-fail"; GHLOG_B65_FAIL="$TMP/b65-gh-fail.log"
mkdir -p "$GHBIN_B65_FAIL"
cat > "$GHBIN_B65_FAIL/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GHLOG_B65_FAIL"
case "\$1 \$2" in
  "pr list") exit 1 ;;
  "pr create") echo "https://github.com/x/y/pull/999" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$GHBIN_B65_FAIL/gh"
PATH="$GHBIN_B65_FAIL:$PATH" "$RUN" done-advance "$AGB65" >/dev/null 2>"$TMP/b65a.err"; RCB65A=$?
[[ "$RCB65A" == 3 ]] && ok || fail "B65: gh pr list упал (ненулевой код) -> exit 3 (got $RCB65A: $(cat "$TMP/b65a.err"))"
[[ "$(jq_file "$AGB65/done.json" 'd.get("state")')" == "accepted" ]] \
  && ok || fail "B65: state остается accepted (ненулевой код list)"
[[ -z "$(git --git-dir="$PROJ_B65.git" rev-parse --verify -q "refs/heads/$BRANCH_B65" 2>/dev/null)" ]] \
  && ok || fail "B65: push НЕ вызван вслепую после отказа list (ненулевой код)"
grep -q -- '--state all' "$GHLOG_B65_FAIL" && ok || fail "B65: gh pr list реально вызван с --state all"

GHBIN_B65_BADJSON="$TMP/ghbin-b65-badjson"; GHLOG_B65_BADJSON="$TMP/b65-gh-badjson.log"
mkdir -p "$GHBIN_B65_BADJSON"
cat > "$GHBIN_B65_BADJSON/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GHLOG_B65_BADJSON"
case "\$1 \$2" in
  "pr list") echo "not valid json {{{" ;;
  "pr create") echo "https://github.com/x/y/pull/999" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$GHBIN_B65_BADJSON/gh"
PATH="$GHBIN_B65_BADJSON:$PATH" "$RUN" done-advance "$AGB65" >/dev/null 2>"$TMP/b65b.err"; RCB65B=$?
[[ "$RCB65B" == 3 ]] && ok || fail "B65: gh pr list отдал битый JSON -> exit 3 (got $RCB65B: $(cat "$TMP/b65b.err"))"
[[ "$(jq_file "$AGB65/done.json" 'd.get("state")')" == "accepted" ]] \
  && ok || fail "B65: state остается accepted (битый JSON list)"
[[ -z "$(git --git-dir="$PROJ_B65.git" rev-parse --verify -q "refs/heads/$BRANCH_B65" 2>/dev/null)" ]] \
  && ok || fail "B65: push НЕ вызван вслепую после отказа list (битый JSON)"

GHBIN_B65_OK="$TMP/ghbin-b65-ok"; GHLOG_B65_OK="$TMP/b65-gh-ok.log"
mk_gh_mock "$GHBIN_B65_OK" "$GHLOG_B65_OK"
PATH="$GHBIN_B65_OK:$PATH" "$RUN" done-advance "$AGB65" >/dev/null 2>"$TMP/b65c.err"; RCB65C=$?
[[ "$RCB65C" == 0 ]] && ok || fail "B65: рабочий gh доигрывает после двух отказов list (got $RCB65C: $(cat "$TMP/b65c.err"))"
[[ "$(jq_file "$AGB65/done.json" 'd.get("state")')" == "integrated" ]] \
  && ok || fail "B65: state=integrated после ретрая рабочим gh"

####################################################################
# V2.10 (T5): docs/design-2026-07-28-v2.10-task-actually-works.md §3
# Написано с чистого листа по спеке (SDD, RED-фаза) - bin/claude-agent-run,
# bin/_rc_projects.sh НЕ читаны. Публичный контракт и прием фикстур - из
# самой спеки V2.10 §3 и из уже установленного контракта B12/B13/B16/B17
# выше (FF/merge/конфликт/"целевая ветка вычекаучена в другом дереве и
# грязная"), плюс test-agent-lessons.sh (project_lessons_path, форма B
# реестра с полем lessons, дефолт .claude/rules/lessons.md - L18/L19).
####################################################################

# =============================================================== B66 (V2.10 T5.1)
echo "=== B66: единственный неотслеживаемый файл-зеркало уроков ВНУТРИ ранее не существовавшего каталога (?? .claude/) - НЕ грязно, integrate проходит ==="
PROJ_B66="$TMP/proj-b66"; mkdir -p "$PROJ_B66"
mk_git_project "$PROJ_B66"
register_obj_project projb66 "$PROJ_B66" merge
AGB66=$(mk_requested_worktree wtb66 "$PROJ_B66" b66-key "B66 summary")
COMMITB66=$(jq_file "$AGB66/done.json" 'd.get("commit_sha")')
accept_agent "$AGB66"
# зеркало - НОВЫЙ файл внутри ЕЩЕ НЕ СУЩЕСТВОВАВШЕГО каталога .claude/ (никто
# его не mkdir'ил и не git add'ил заранее) - ровно случай "?? .claude/" из
# §3.1: без --untracked-files=all git схлопнул бы каталог в одну запись и
# путь файла уроков в выводе не появился бы вовсе, сравнение не сработало бы.
mkdir -p "$PROJ_B66/.claude/rules"
printf 'b66-lesson-line\n' > "$PROJ_B66/.claude/rules/lessons.md"
[[ -n "$(git -C "$PROJ_B66" status --porcelain | grep -F '?? .claude/')" ]] \
  && ok || fail "B66: fixture - git реально схлопывает в '?? .claude/' без -uall"
"$RUN" done-advance "$AGB66" >/dev/null 2>"$TMP/b66.err"; RCB66=$?
[[ "$RCB66" == 0 ]] && ok || fail "B66: done-advance проходит несмотря на неотслеживаемое зеркало уроков (got $RCB66: $(cat "$TMP/b66.err"))"
[[ "$(jq_file "$AGB66/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B66: state=integrated"
[[ "$(git -C "$PROJ_B66" rev-parse refs/heads/main)" == "$COMMITB66" ]] && ok || fail "B66: main сдвинута (FF на commit задачи)"
[[ -f "$PROJ_B66/.claude/rules/lessons.md" ]] && ok || fail "B66: файл-зеркало уроков остался на месте"
[[ "$(cat "$PROJ_B66/.claude/rules/lessons.md")" == "b66-lesson-line" ]] && ok || fail "B66: содержимое зеркала не тронуто"

# =============================================================== B67 (V2.10 T5.2)
echo "=== B67: файл-зеркало уроков уже закоммичен и ЛОКАЛЬНО ИЗМЕНЕН (не только новый) - НЕ грязно ==="
PROJ_B67="$TMP/proj-b67"; mkdir -p "$PROJ_B67"
mk_git_project "$PROJ_B67"
mkdir -p "$PROJ_B67/.claude/rules"
printf 'b67-base-lesson\n' > "$PROJ_B67/.claude/rules/lessons.md"
( cd "$PROJ_B67" && git add .claude/rules/lessons.md \
  && git -c user.email=t@t -c user.name=t commit -qm "b67 base lesson mirror" )
register_obj_project projb67 "$PROJ_B67" merge
AGB67=$(mk_requested_worktree wtb67 "$PROJ_B67" b67-key "B67 summary")
COMMITB67=$(jq_file "$AGB67/done.json" 'd.get("commit_sha")')
accept_agent "$AGB67"
printf 'b67-base-lesson\nb67-new-appended-lesson\n' > "$PROJ_B67/.claude/rules/lessons.md"
[[ -n "$(git -C "$PROJ_B67" status --porcelain | grep -F 'M .claude/rules/lessons.md')" ]] \
  && ok || fail "B67: fixture - git реально видит модификацию отслеживаемого зеркала"
"$RUN" done-advance "$AGB67" >/dev/null 2>"$TMP/b67.err"; RCB67=$?
[[ "$RCB67" == 0 ]] && ok || fail "B67: done-advance проходит несмотря на модифицированное зеркало уроков (got $RCB67: $(cat "$TMP/b67.err"))"
[[ "$(jq_file "$AGB67/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B67: state=integrated"
[[ "$(git -C "$PROJ_B67" rev-parse refs/heads/main)" == "$COMMITB67" ]] && ok || fail "B67: main сдвинута (FF)"
[[ "$(cat "$PROJ_B67/.claude/rules/lessons.md")" == "$(printf 'b67-base-lesson\nb67-new-appended-lesson')" ]] \
  && ok || fail "B67: локальная незакоммиченная модификация зеркала сохранена (не затерта интеграцией)"

# =============================================================== B68 (V2.10 T5.3)
echo "=== B68: рядом с зеркалом уроков лежит ДРУГОЙ неотслеживаемый файл того же каталога - ГРЯЗНО, integrate отказывает ==="
PROJ_B68="$TMP/proj-b68"; mkdir -p "$PROJ_B68"
mk_git_project "$PROJ_B68"
register_obj_project projb68 "$PROJ_B68" merge
BASE_B68=$(git -C "$PROJ_B68" rev-parse HEAD)
AGB68=$(mk_requested_worktree wtb68 "$PROJ_B68" b68-key "B68 summary")
BRANCH_B68=$(jq_file "$AGB68/done.json" 'd.get("branch")')
COMMITB68=$(jq_file "$AGB68/done.json" 'd.get("commit_sha")')
accept_agent "$AGB68"
mkdir -p "$PROJ_B68/.claude/rules"
printf 'b68-lesson-line\n' > "$PROJ_B68/.claude/rules/lessons.md"
printf 'b68-unrelated-file\n' > "$PROJ_B68/.claude/rules/other.md"
"$RUN" done-advance "$AGB68" >/dev/null 2>"$TMP/b68.err"; RCB68=$?
[[ "$RCB68" == 3 ]] && ok || fail "B68: посторонний неотслеживаемый файл рядом с зеркалом -> отказ фазы, exit 3 (got $RCB68: $(cat "$TMP/b68.err"))"
[[ "$(jq_file "$AGB68/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B68: state остается accepted (мержа не было)"
[[ "$(git -C "$PROJ_B68" rev-parse refs/heads/main)" == "$BASE_B68" ]] && ok || fail "B68: main не сдвинута"
[[ "$(git -C "$PROJ_B68" rev-parse "refs/heads/$BRANCH_B68")" == "$COMMITB68" ]] && ok || fail "B68: ветка задачи цела"
[[ -f "$PROJ_B68/.claude/rules/other.md" ]] && ok || fail "B68: посторонний файл не тронут"

# =============================================================== B69 (V2.10 T5.4, fail-closed)
echo "=== B69: резолвер пути уроков отказал (escape-путь в реестре) - fail-closed, исключения нет, дерево ГРЯЗНОЕ ==="
PROJ_B69="$TMP/proj-b69"; mkdir -p "$PROJ_B69"
mk_git_project "$PROJ_B69"
register_obj_project_lessons projb69 "$PROJ_B69" merge "../../escape-b69/lessons.md"
BASE_B69=$(git -C "$PROJ_B69" rev-parse HEAD)
AGB69=$(mk_requested_worktree wtb69 "$PROJ_B69" b69-key "B69 summary")
BRANCH_B69=$(jq_file "$AGB69/done.json" 'd.get("branch")')
accept_agent "$AGB69"
# тот же безобидный по умолчанию файл, что в B66 - но реестр явно задает
# НЕВАЛИДНЫЙ (escape за пределы проекта) путь зеркала: project_lessons_path
# обязан отказать, и §3.2 требует в этом случае считать дерево грязным как
# раньше ("резолвер не смог" != "нечего вычитать = чисто", fail-open запрещен)
mkdir -p "$PROJ_B69/.claude/rules"
printf 'b69-lesson-line\n' > "$PROJ_B69/.claude/rules/lessons.md"
rc_project_lessons_path projb69 >/dev/null 2>&1
[[ "$?" != "0" ]] && ok || fail "B69: fixture - project_lessons_path реально отказывает на escape-пути в реестре"
"$RUN" done-advance "$AGB69" >/dev/null 2>"$TMP/b69.err"; RCB69=$?
[[ "$RCB69" == 3 ]] && ok || fail "B69: fail-closed - отказ резолвера НЕ снимает грязь, exit 3 (got $RCB69: $(cat "$TMP/b69.err"))"
[[ "$(jq_file "$AGB69/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B69: state остается accepted"
[[ "$(git -C "$PROJ_B69" rev-parse refs/heads/main)" == "$BASE_B69" ]] && ok || fail "B69: main не сдвинута"

# =============================================================== B70 (V2.10 T5.5)
echo "=== B70: ветка задачи сама меняет файл уроков, main тоже разошелся на нем - реальный git-конфликт, phase_error (не тихий успех) ==="
PROJ_B70="$TMP/proj-b70"; mkdir -p "$PROJ_B70"
git init -q --initial-branch=main "$PROJ_B70"
mkdir -p "$PROJ_B70/.claude/rules"
printf 'b70-base-lesson\n' > "$PROJ_B70/.claude/rules/lessons.md"
( cd "$PROJ_B70" && git add .claude/rules/lessons.md \
  && git -c user.email=t@t -c user.name=t commit -qm "b70 base lesson mirror" )
register_obj_project projb70 "$PROJ_B70" merge
AGB70=$(mk_worktree_agent wtb70 "$PROJ_B70")
( cd "$AGB70/work" && printf 'b70-base-lesson\nb70-task-branch-change\n' > .claude/rules/lessons.md \
  && git add .claude/rules/lessons.md \
  && git -c user.email=t@t -c user.name=t commit -qm "b70 task changed lessons mirror" )
mk_inflight "$AGB70" "b70-key"
call_done "$AGB70" "b70-key" --summary "B70 summary" >/dev/null 2>"$TMP/b70-done.err"
( cd "$PROJ_B70" && printf 'b70-base-lesson\nb70-main-diverged-change\n' > .claude/rules/lessons.md \
  && git -c user.email=t@t -c user.name=t commit -qam "b70 main diverged lessons mirror" )
MAIN_TIP_B70=$(git -C "$PROJ_B70" rev-parse refs/heads/main)
accept_agent "$AGB70"
"$RUN" done-advance "$AGB70" >/dev/null 2>"$TMP/b70.err"; RCB70=$?
[[ "$RCB70" == 3 ]] && ok || fail "B70: конфликт на файле уроков -> exit 3 (got $RCB70: $(cat "$TMP/b70.err"))"
[[ "$(jq_file "$AGB70/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B70: state остается accepted (dwl разруливает, как любой другой конфликт)"
[[ "$(git -C "$PROJ_B70" rev-parse refs/heads/main)" == "$MAIN_TIP_B70" ]] && ok || fail "B70: main не сдвинута (merge --abort)"
[[ "$(jq_file "$AGB70/control.json" 'd.get("attention") is not None')" == "True" ]] && ok || fail "B70: attention выставлен"

# =============================================================== B71 (V2.10 T5, поправка -z)
# Важно: пробел/кириллица нужны в ПУТИ ЗЕРКАЛА (относительно корня репо) - в
# `git status --porcelain` попадают именно такие пути, а не абсолютный путь
# каталога проекта (тот в вывод git status вообще не входит). Провалено на
# первой версии кейса (см. отчет задачи) - путь проекта не экранируется,
# экранируется только сам ОТСЛЕЖИВАЕМЫЙ/НЕОТСЛЕЖИВАЕМЫЙ путь внутри репо.
echo "=== B71: путь зеркала уроков с пробелом и кириллицей - без -z git экранирует путь кавычками, наивное сравнение не сойдется без него ==="
PROJ_B71="$TMP/proj-b71"; mkdir -p "$PROJ_B71"
mk_git_project "$PROJ_B71"
LESSONS_REL_B71="заметки урока/lessons мои.md"
register_obj_project_lessons projb71 "$PROJ_B71" merge "$LESSONS_REL_B71"
AGB71=$(mk_requested_worktree wtb71 "$PROJ_B71" b71-key "B71 summary")
COMMITB71=$(jq_file "$AGB71/done.json" 'd.get("commit_sha")')
accept_agent "$AGB71"
[[ "$(rc_project_lessons_path projb71)" == "$PROJ_B71/$LESSONS_REL_B71" ]] \
  && ok || fail "B71: fixture - project_lessons_path резолвит явный путь с пробелом/кириллицей (got: $(rc_project_lessons_path projb71))"
# зеркало - НОВЫЙ файл внутри ЕЩЕ НЕ существовавшего каталога "заметки
# урока/" (совмещаем оба требования §3.1 в одной честной фикстуре: без
# -uall каталог схлопнулся бы в одну запись, без -z путь ушел бы в кавычках)
mkdir -p "$PROJ_B71/заметки урока"
printf 'b71-lesson-line\n' > "$PROJ_B71/$LESSONS_REL_B71"
# fixture-честность: без -z git реально отдает путь с пробелом/кириллицей
# C-экранированным в кавычках - именно это обязан пережить парсер (§3.1)
RAW_STATUS_B71=$(git -C "$PROJ_B71" status --porcelain)
[[ "$RAW_STATUS_B71" == *'"'* ]] && ok \
  || fail "B71: fixture - без -z git экранирует путь с пробелом/кириллицей кавычками (got: $RAW_STATUS_B71)"
"$RUN" done-advance "$AGB71" >/dev/null 2>"$TMP/b71.err"; RCB71=$?
[[ "$RCB71" == 0 ]] && ok || fail "B71: путь зеркала с пробелом+кириллицей - все равно распознан, done-advance проходит (got $RCB71: $(cat "$TMP/b71.err"))"
[[ "$(jq_file "$AGB71/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B71: state=integrated"
[[ "$(git -C "$PROJ_B71" rev-parse refs/heads/main)" == "$COMMITB71" ]] && ok || fail "B71: main сдвинута (FF)"

####################################################################
# V2.10 фикс-пак (docs/design-2026-07-28-v2.10-task-actually-works.md,
# после аудита): T7 (обертка claude-agent-commit, §1.2), T9 (финализация
# заявки, §3a), T10 (дрейф реестра, §3b), плюс серьезные находки аудита -
# симлинк снимает исключение уроков (§3.2) и условный --untracked-files=all
# (§3.1 п.0). Написано с чистого листа по контракту - bin/claude-agent-run,
# bin/claude-agent-commit, bin/_rc_projects.sh НЕ читаны для вывода
# ожидаемого поведения (оно целиком зафиксировано в контракте выше).
####################################################################

# --- фикстура: git-проект для T7 (claude-agent-commit) ---
PROJ_GIT_T7="$TMP/proj-git-t7"; git init -q "$PROJ_GIT_T7"
( cd "$PROJ_GIT_T7" && echo hi > f.txt && git add . \
  && git -c user.email=t@t -c user.name=t commit -qm init )

# =============================================================== B72 (V2.10 T7, §1.2 - коммитит содержимое worktree)
echo "=== B72: claude-agent-commit индексирует ВСЕ изменения worktree (git add -A) и создает коммит с текстом --message ==="
AGB72=$(mk_worktree_agent wtb72 "$PROJ_GIT_T7")
BASEB72=$(git -C "$AGB72/work" rev-parse HEAD)
( cd "$AGB72/work" && echo "b72 new file" > new-b72.txt && mkdir -p sub && echo "nested" > sub/nested-b72.txt )
mk_inflight "$AGB72" "b72-key"
call_commit "$AGB72" "b72-key" --message "B72 commit message" >"$TMP/b72.out" 2>"$TMP/b72.err"; RCB72=$?
[[ "$RCB72" == 0 ]] && ok || fail "B72: exit 0 (got $RCB72: $(cat "$TMP/b72.err"))"
NEWHEADB72=$(git -C "$AGB72/work" rev-parse HEAD)
[[ "$NEWHEADB72" != "$BASEB72" ]] && ok || fail "B72: HEAD продвинулся (коммит создан)"
[[ "$(git -C "$AGB72/work" log -1 --format=%B)" == "B72 commit message" ]] && ok || fail "B72: тело коммита == --message"
[[ -z "$(git -C "$AGB72/work" status --porcelain)" ]] && ok || fail "B72: worktree чист после коммита"
git -C "$AGB72/work" show --stat -1 | grep -q "new-b72.txt" && ok || fail "B72: новый файл верхнего уровня в коммите"
git -C "$AGB72/work" show --stat -1 | grep -q "sub/nested-b72.txt" && ok || fail "B72: вложенный новый файл тоже в коммите (git add -A, не add .)"

# =============================================================== B73 (V2.10 T7, §1.2 - пустой индекс)
echo "=== B73: пустой индекс (нечего коммитить) - отказ, HEAD не двигается, коммит НЕ создан ==="
AGB73=$(mk_worktree_agent wtb73 "$PROJ_GIT_T7")
BASEB73=$(git -C "$AGB73/work" rev-parse HEAD)
mk_inflight "$AGB73" "b73-key"
call_commit "$AGB73" "b73-key" --message "B73 should be refused" >"$TMP/b73.out" 2>"$TMP/b73.err"; RCB73=$?
[[ "$RCB73" != 0 ]] && ok || fail "B73: exit != 0 на пустом индексе (got $RCB73)"
[[ -s "$TMP/b73.err" ]] && ok || fail "B73: внятное сообщение об ошибке"
[[ "$(git -C "$AGB73/work" rev-parse HEAD)" == "$BASEB73" ]] && ok || fail "B73: HEAD не сдвинулся - пустой коммит не создан"

# =============================================================== B74 (V2.10 T7, §1.2 - только worktree своего агента)
echo "=== B74: вызов вне worktree своего агента - отказ; незакоммиченное в work остается незакоммиченным (не подмена таргета) ==="
AGB74=$(mk_worktree_agent wtb74 "$PROJ_GIT_T7")
BASEB74=$(git -C "$AGB74/work" rev-parse HEAD)
echo "b74 pending in work" > "$AGB74/work/pending-b74.txt"
mk_inflight "$AGB74" "b74-key"
# запускается из ДРУГОГО git-каталога (не agent_dir/work) - фикстура из
# самого проекта (PROJ_GIT_T7), т.к. вне worktree своего агента коммит
# нужно суметь отбить, даже если cwd тоже git-репозиторий
( cd "$PROJ_GIT_T7" && CLAUDE_AGENT_DIR="$AGB74" CLAUDE_AGENT_EVENT_KEY="b74-key" \
    "$COMMIT" --message "B74 wrong cwd" >"$TMP/b74.out" 2>"$TMP/b74.err" ); RCB74=$?
[[ "$RCB74" != 0 ]] && ok || fail "B74: exit != 0 при вызове из чужого каталога (got $RCB74)"
[[ -s "$TMP/b74.err" ]] && ok || fail "B74: внятное сообщение об ошибке"
[[ "$(git -C "$AGB74/work" rev-parse HEAD)" == "$BASEB74" ]] \
  && ok || fail "B74: work HEAD не сдвинулся - незакоммиченное в work НЕ закоммичено обходным вызовом"
[[ -n "$(git -C "$AGB74/work" status --porcelain)" ]] \
  && ok || fail "B74: pending-b74.txt в work остается незакоммиченным (still dirty)"

# =============================================================== B75 (V2.10 T7, §1.2 - фиксированный argv)
echo "=== B75: посторонние флаги НЕ доезжают до git - неизвестный флаг отбит, текст сообщения с флагоподобным содержимым идет ТОЛЬКО в тело коммита ==="
AGB75=$(mk_worktree_agent wtb75 "$PROJ_GIT_T7")
BASEB75=$(git -C "$AGB75/work" rev-parse HEAD)
echo "b75 pending" > "$AGB75/work/pending-b75.txt"
mk_inflight "$AGB75" "b75-key"
call_commit "$AGB75" "b75-key" --output "$TMP/b75-pwned.txt" --message "B75 with --output flag" \
  >"$TMP/b75a.out" 2>"$TMP/b75a.err"; RCB75A=$?
[[ "$RCB75A" != 0 ]] && ok || fail "B75a: посторонний флаг --output отбит (exit != 0, got $RCB75A)"
[[ ! -e "$TMP/b75-pwned.txt" ]] && ok || fail "B75a: файл по постороннему пути НЕ создан"
[[ "$(git -C "$AGB75/work" rev-parse HEAD)" == "$BASEB75" ]] && ok || fail "B75a: HEAD не сдвинулся (отказ до коммита)"

call_commit "$AGB75" "b75-key" --message "-c user.name=evil not-a-flag" \
  >"$TMP/b75b.out" 2>"$TMP/b75b.err"; RCB75B=$?
[[ "$RCB75B" == 0 ]] && ok || fail "B75b: exit 0 - текст, похожий на git-флаг, но переданный как --message, не отбивается (got $RCB75B: $(cat "$TMP/b75b.err"))"
[[ "$(git -C "$AGB75/work" log -1 --format=%B)" == "-c user.name=evil not-a-flag" ]] \
  && ok || fail "B75b: флагоподобный текст ушел байт-в-байт в тело коммита, а не был исполнен как флаг"
[[ "$(git -C "$AGB75/work" log -1 --format='%an <%ae>')" != *"evil"* ]] \
  && ok || fail "B75b: автор коммита НЕ подменен ('user.name=evil' не сработал как git-флаг)"

# =============================================================== B76 (V2.10 T7, §1.2 - хуки выключены)
echo "=== B76: pre-commit хук НЕ исполняется через claude-agent-commit (core.hooksPath=/dev/null + --no-verify); тот же репозиторий - честная фикстура: обычный git commit хук ИСПОЛНЯЕТ ==="
PROJ_HOOK_B76="$TMP/proj-hook-b76"; mkdir -p "$PROJ_HOOK_B76/.githooks"
git init -q --initial-branch=main "$PROJ_HOOK_B76"
cat > "$PROJ_HOOK_B76/.githooks/pre-commit" <<'HOOK'
#!/bin/sh
touch "$(git rev-parse --show-toplevel)/HOOK_MARKER_B76"
HOOK
chmod +x "$PROJ_HOOK_B76/.githooks/pre-commit"
( cd "$PROJ_HOOK_B76" && git config core.hooksPath .githooks \
  && echo base > f.txt && git add f.txt .githooks/pre-commit \
  && git -c user.email=t@t -c user.name=t commit -qm init )
AGB76=$(mk_worktree_agent wtb76 "$PROJ_HOOK_B76")
# честность фикстуры: обычный git commit В ЭТОМ ЖЕ worktree реально
# исполняет хук - иначе "маркера нет" ничего бы не доказывал
( cd "$AGB76/work" && echo x1 > x1-b76.txt && git add x1-b76.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "plain commit fixture-honesty" )
[[ -f "$AGB76/work/HOOK_MARKER_B76" ]] \
  && ok || fail "B76: fixture - обычный git commit реально исполняет pre-commit хук в этом worktree"
rm -f "$AGB76/work/HOOK_MARKER_B76"
echo "b76 real work" > "$AGB76/work/x2-b76.txt"
mk_inflight "$AGB76" "b76-key"
call_commit "$AGB76" "b76-key" --message "B76 via obertka" >"$TMP/b76.out" 2>"$TMP/b76.err"; RCB76=$?
[[ "$RCB76" == 0 ]] && ok || fail "B76: exit 0 (got $RCB76: $(cat "$TMP/b76.err"))"
[[ ! -f "$AGB76/work/HOOK_MARKER_B76" ]] \
  && ok || fail "B76: pre-commit хук НЕ исполнился через claude-agent-commit"

# --- фикстура: git-проект для T9 (финализация заявки) ---
PROJ_GIT_T9="$TMP/proj-git-t9"; git init -q "$PROJ_GIT_T9"
( cd "$PROJ_GIT_T9" && echo hi > f.txt && git add . \
  && git -c user.email=t@t -c user.name=t commit -qm init )

# =============================================================== B77 (V2.10 T9, §3a - коммит после преждевременного done)
echo "=== B77: claude-agent-done позван ДО правок (empty:true на базовом коммите), затем сделан коммит В ТОМ ЖЕ прогоне - терминальная ветка runner'а перечитывает HEAD, commit_sha/empty обновлены ==="
AGB77=$(mk_worktree_agent wtb77 "$PROJ_GIT_T9")
"$RUN" spool-put wtb77 --text "b77-event" >/dev/null
"$RUN" intake "$AGB77" >/dev/null
echo done_early_worktree_commit > "$MOCK_MODE_FILE"
MOCK_LATE_FILE="late-b77.txt" MOCK_LATE_MARKER="late-b77-marker" \
  MOCK_DONE_SNAPSHOT="$TMP/b77-midrun.json" \
  "$RUN" step "$AGB77" >/dev/null 2>"$TMP/b77-step.err"
echo ok > "$MOCK_MODE_FILE"
[[ -f "$TMP/b77-midrun.json" ]] && ok || fail "B77: fixture - снимок done.json мид-run снят"
[[ "$(jq_file "$TMP/b77-midrun.json" 'd.get("empty")')" == "True" ]] \
  && ok || fail "B77: fixture - мид-run (сразу после раннего claude-agent-done) empty=true"
REALHEAD_B77=$(git -C "$AGB77/work" rev-parse HEAD)
DJ77="$AGB77/done.json"
[[ "$(jq_file "$DJ77" 'd.get("commit_sha")')" == "$REALHEAD_B77" ]] \
  && ok || fail "B77: terminal-финализация перечитала commit_sha из HEAD (актуальный, не ранний пустой)"
[[ "$(jq_file "$DJ77" 'd.get("empty")')" == "False" ]] \
  && ok || fail "B77: empty пересчитан относительно base -> false (есть поздний коммит)"
[[ "$(jq_file "$DJ77" 'd.get("state")')" == "requested" ]] \
  && ok || fail "B77: state остается requested (заявка валидна, не инвалидирована)"

# =============================================================== B78 (V2.10 T9, §3a - грязное дерево на финализации)
echo "=== B78: claude-agent-done позван рано, дерево остается ГРЯЗНЫМ (незакоммиченное) на терминальной ветке - заявка ИНВАЛИДИРУЕТСЯ ==="
AGB78=$(mk_worktree_agent wtb78 "$PROJ_GIT_T9")
"$RUN" spool-put wtb78 --text "b78-event" >/dev/null
"$RUN" intake "$AGB78" >/dev/null
echo done_early_worktree_dirty > "$MOCK_MODE_FILE"
MOCK_DIRTY_FILE="dirty-b78.txt" MOCK_DIRTY_MARKER="dirty-b78-marker" \
  "$RUN" step "$AGB78" >/dev/null 2>"$TMP/b78-step.err"
echo ok > "$MOCK_MODE_FILE"
[[ -n "$(git -C "$AGB78/work" status --porcelain)" ]] \
  && ok || fail "B78: fixture - worktree реально грязный после прогона (незакоммиченный dirty-b78.txt)"
DJ78="$AGB78/done.json"
[[ "$(jq_file "$DJ78" 'd.get("state")')" == "invalid" ]] \
  && ok || fail "B78: state=invalid (заявка инвалидирована, не предъявлена как готовая)"
[[ "$(jq_file "$DJ78" 'bool(d.get("invalid_reason"))')" == "True" ]] \
  && ok || fail "B78: причина инвалидации записана и непуста (внятная причина)"

# =============================================================== B79 (V2.10 T9, §3a - чужой прогон не финализирует)
echo "=== B79: заявка с ЧУЖИМ envelope_key - терминальная финализация ТЕКУЩЕГО прогона ее не трогает (envelope_key/workspace обязаны совпасть) ==="
AGB79=$(mk_worktree_agent wtb79 "$PROJ_GIT_T9")
STALE_COMMIT_B79="0000000000000000000000000000000000dead"
python3 -c '
import json, sys
d = {"state": "requested", "requested_at": "2026-01-01T00:00:00Z", "envelope_key": sys.argv[2],
     "workspace": "worktree", "summary": "B79 foreign stale claim",
     "branch": "task/foreign-branch", "base": sys.argv[3], "commit_sha": sys.argv[3], "empty": True,
     "changes": None,
     "pushed_at": None, "accepted_at": None, "integrated_at": None, "cleaned_at": None, "archived_at": None}
json.dump(d, open(sys.argv[1] + "/done.json", "w"), ensure_ascii=False)
' "$AGB79" "b79-foreign-key" "$STALE_COMMIT_B79"
"$RUN" spool-put wtb79 --text "b79-event" >/dev/null
"$RUN" intake "$AGB79" >/dev/null
( cd "$AGB79/work" && echo "b79 real work" > real-b79.txt && git add real-b79.txt \
  && git -c user.email=t@t -c user.name=t commit -qm "b79 real commit" )
REALHEAD_B79=$(git -C "$AGB79/work" rev-parse HEAD)
echo ok > "$MOCK_MODE_FILE"
"$RUN" step "$AGB79" >/dev/null 2>"$TMP/b79-step.err"
DJ79="$AGB79/done.json"
[[ "$(jq_file "$DJ79" 'd.get("envelope_key")')" == "b79-foreign-key" ]] \
  && ok || fail "B79: envelope_key чужой заявки не переписан текущим прогоном"
[[ "$(jq_file "$DJ79" 'd.get("commit_sha")')" == "$STALE_COMMIT_B79" ]] \
  && ok || fail "B79: commit_sha чужой заявки НЕ обновлен до реального HEAD ($REALHEAD_B79) - финализация чужого прогона не коснулась"
[[ "$(jq_file "$DJ79" 'd.get("empty")')" == "True" ]] \
  && ok || fail "B79: empty чужой заявки не пересчитан"

# --- фикстура: git-проект + реестр для T10 (дрейф проекта) ---
PROJ_T10_OLD="$TMP/proj-t10-old"; mkdir -p "$PROJ_T10_OLD"
mk_git_project "$PROJ_T10_OLD"
register_obj_project projt10 "$PROJ_T10_OLD" merge

# =============================================================== B80 (V2.10 T10, §3b - путь проекта в реестре изменился)
echo "=== B80: путь проекта в реестре изменился ПОСЛЕ создания задачи - фаза интеграции отказывает (phase_error), НЕ мержит ни в старый, ни в новый чекаут ==="
AGB80=$(mk_requested_worktree wtb80 "$PROJ_T10_OLD" b80-key "B80 summary")
accept_agent "$AGB80"
PROJ_T10_NEW="$TMP/proj-t10-new"; mkdir -p "$PROJ_T10_NEW"
mk_git_project "$PROJ_T10_NEW"
BASE_OLD_B80=$(git -C "$PROJ_T10_OLD" rev-parse refs/heads/main)
BASE_NEW_B80=$(git -C "$PROJ_T10_NEW" rev-parse refs/heads/main)
rewrite_project_path projt10 "$PROJ_T10_NEW"
"$RUN" done-advance "$AGB80" >/dev/null 2>"$TMP/b80.err"; RCB80=$?
[[ "$RCB80" == 3 ]] && ok || fail "B80: exit 3 (phase_error), не тихий успех (got $RCB80: $(cat "$TMP/b80.err"))"
[[ "$(jq_file "$AGB80/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B80: state остается accepted"
[[ "$(jq_file "$AGB80/done.json" 'bool(d.get("phase_error"))')" == "True" ]] && ok || fail "B80: phase_error записан"
[[ "$(git -C "$PROJ_T10_OLD" rev-parse refs/heads/main)" == "$BASE_OLD_B80" ]] \
  && ok || fail "B80: СТАРЫЙ чекаут не тронут (не тихий мерж в старый чекаут)"
[[ "$(git -C "$PROJ_T10_NEW" rev-parse refs/heads/main)" == "$BASE_NEW_B80" ]] \
  && ok || fail "B80: НОВЫЙ чекаут тоже не тронут"
# восстановим реестр для аккуратности следующих кейсов этого файла
rewrite_project_path projt10 "$PROJ_T10_OLD"

# =============================================================== B81 (V2.10 T10, §3b - имя проекта пропало из реестра)
echo "=== B81: имя проекта ИСЧЕЗЛО из реестра между созданием задачи и интеграцией - тоже отказ фазы (phase_error), не тихий успех ==="
PROJ_T10B="$TMP/proj-t10b"; mkdir -p "$PROJ_T10B"
mk_git_project "$PROJ_T10B"
register_obj_project projt10b "$PROJ_T10B" merge
AGB81=$(mk_requested_worktree wtb81 "$PROJ_T10B" b81-key "B81 summary")
accept_agent "$AGB81"
BASE_B81=$(git -C "$PROJ_T10B" rev-parse refs/heads/main)
remove_project projt10b
"$RUN" done-advance "$AGB81" >/dev/null 2>"$TMP/b81.err"; RCB81=$?
[[ "$RCB81" == 3 ]] && ok || fail "B81: exit 3 (phase_error) (got $RCB81: $(cat "$TMP/b81.err"))"
[[ "$(jq_file "$AGB81/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B81: state остается accepted"
[[ "$(jq_file "$AGB81/done.json" 'bool(d.get("phase_error"))')" == "True" ]] && ok || fail "B81: phase_error записан"
[[ "$(git -C "$PROJ_T10B" rev-parse refs/heads/main)" == "$BASE_B81" ]] && ok || fail "B81: main не сдвинута"

# =============================================================== B82 (аудит серьезная 6, форма 1 - симлинк НА МЕСТЕ файла-зеркала)
echo "=== B82: зеркало уроков - СИМЛИНК на другой файл ВНУТРИ проекта; человек правит этот другой файл - дерево ГРЯЗНОЕ, интеграция не проходит (посторонняя грязь не вычитается) ==="
PROJ_B82="$TMP/proj-b82"; mkdir -p "$PROJ_B82/src"
git init -q --initial-branch=main "$PROJ_B82"
echo "config v1" > "$PROJ_B82/src/config.py"
( cd "$PROJ_B82" && git add src/config.py && git -c user.email=t@t -c user.name=t commit -qm init )
mkdir -p "$PROJ_B82/.claude/rules"
( cd "$PROJ_B82/.claude/rules" && ln -s ../../src/config.py lessons.md )
( cd "$PROJ_B82" && git add .claude/rules/lessons.md && git -c user.email=t@t -c user.name=t commit -qm "lessons mirror is a symlink" )
register_obj_project projb82 "$PROJ_B82" merge
AGB82=$(mk_requested_worktree wtb82 "$PROJ_B82" b82-key "B82 summary")
accept_agent "$AGB82"
BASE_B82=$(git -C "$PROJ_B82" rev-parse refs/heads/main)
echo "unrelated human edit" >> "$PROJ_B82/src/config.py"
"$RUN" done-advance "$AGB82" >/dev/null 2>"$TMP/b82.err"; RCB82=$?
[[ "$RCB82" == 3 ]] && ok || fail "B82: посторонняя грязь через symlink-зеркало -> отказ фазы, exit 3 (got $RCB82: $(cat "$TMP/b82.err"))"
[[ "$(jq_file "$AGB82/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B82: state остается accepted"
[[ "$(git -C "$PROJ_B82" rev-parse refs/heads/main)" == "$BASE_B82" ]] && ok || fail "B82: main не сдвинута"

# =============================================================== B83 (аудит серьезная 6, форма 2 - симлинк В КАТАЛОГЕ ПУТИ)
echo "=== B83: симлинк - каталог-компонент пути (.claude/rules -> другой каталог), а не сам файл; реальный НЕСВЯЗАННЫЙ файл по совпавшему после realpath пути - тоже дерево ГРЯЗНОЕ ==="
PROJ_B83="$TMP/proj-b83"; mkdir -p "$PROJ_B83/shared/notes"
git init -q --initial-branch=main "$PROJ_B83"
echo "team notes v1" > "$PROJ_B83/shared/notes/lessons.md"
( cd "$PROJ_B83" && git add shared/notes/lessons.md && git -c user.email=t@t -c user.name=t commit -qm init )
mkdir -p "$PROJ_B83/.claude"
( cd "$PROJ_B83/.claude" && ln -s ../shared/notes rules )
( cd "$PROJ_B83" && git add .claude/rules && git -c user.email=t@t -c user.name=t commit -qm "rules dir is a symlink" )
register_obj_project projb83 "$PROJ_B83" merge
AGB83=$(mk_requested_worktree wtb83 "$PROJ_B83" b83-key "B83 summary")
accept_agent "$AGB83"
BASE_B83=$(git -C "$PROJ_B83" rev-parse refs/heads/main)
echo "unrelated team notes edit" >> "$PROJ_B83/shared/notes/lessons.md"
"$RUN" done-advance "$AGB83" >/dev/null 2>"$TMP/b83.err"; RCB83=$?
[[ "$RCB83" == 3 ]] && ok || fail "B83: посторонняя грязь через dir-symlink alias -> отказ фазы, exit 3 (got $RCB83: $(cat "$TMP/b83.err"))"
[[ "$(jq_file "$AGB83/done.json" 'd.get("state")')" == "accepted" ]] && ok || fail "B83: state остается accepted"
[[ "$(git -C "$PROJ_B83" rev-parse refs/heads/main)" == "$BASE_B83" ]] && ok || fail "B83: main не сдвинута"

# =============================================================== B84 (аудит мелкая 9, §3.1 п.0 - условный --untracked-files=all)
echo "=== B84: исключения НЕТ (резолвер отказал на escape-пути) - идет ПРЕЖНЯЯ команда без -uall; showUntrackedFiles=no по-прежнему прячет посторонний неотслеживаемый файл, дерево ЧИСТОЕ ==="
PROJ_B84="$TMP/proj-b84"; mkdir -p "$PROJ_B84"
mk_git_project "$PROJ_B84"
git -C "$PROJ_B84" config status.showUntrackedFiles no
register_obj_project_lessons projb84 "$PROJ_B84" merge "../../escape-b84/lessons.md"
AGB84=$(mk_requested_worktree wtb84 "$PROJ_B84" b84-key "B84 summary")
COMMITB84=$(jq_file "$AGB84/done.json" 'd.get("commit_sha")')
accept_agent "$AGB84"
rc_project_lessons_path projb84 >/dev/null 2>&1
[[ "$?" != "0" ]] && ok || fail "B84: fixture - project_lessons_path реально отказывает на escape-пути (исключения не будет)"
echo "generated, unrelated to lessons" > "$PROJ_B84/generated-b84.log"
"$RUN" done-advance "$AGB84" >/dev/null 2>"$TMP/b84.err"; RCB84=$?
[[ "$RCB84" == 0 ]] \
  && ok || fail "B84: showUntrackedFiles=no по-прежнему прячет посторонний untracked файл - интеграция проходит как до V2.10 (got $RCB84: $(cat "$TMP/b84.err"))"
[[ "$(jq_file "$AGB84/done.json" 'd.get("state")')" == "integrated" ]] && ok || fail "B84: state=integrated"
[[ "$(git -C "$PROJ_B84" rev-parse refs/heads/main)" == "$COMMITB84" ]] && ok || fail "B84: main сдвинута (FF) - семантика чистоты не изменилась там, где исключение не применяется"

echo
echo "test-agent-task-lifecycle: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
