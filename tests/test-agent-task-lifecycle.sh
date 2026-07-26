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
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
ALERT_LOG14="$TMP/n14-alert.log"
mk_alert_ok "$ALERT_LOG14" "$TMP/alert-ok-n14.sh"
CLAUDE_AGENT_ALERT_CMD="$TMP/alert-ok-n14.sh" "$RUN" done-notify "$AG14" >/dev/null 2>"$TMP/n14.err"
[[ "$(alert_block_count "$ALERT_LOG14")" == "1" ]] && ok || fail "N14: fixture - карточка реально пушится ($(cat "$TMP/n14.err"))"
ALERT_CONTENT14=$(cat "$ALERT_LOG14" 2>/dev/null)
[[ "$ALERT_CONTENT14" != *"hunter2"* ]] && ok || fail "N14: секрет 'hunter2' не должен быть в вызове alert-команды (ни в одном аргументе)"
[[ "$ALERT_CONTENT14" != *"abc.def.ghi"* ]] && ok || fail "N14: секрет 'abc.def.ghi' не должен быть в вызове alert-команды (ни в одном аргументе)"

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

echo
echo "test-agent-task-lifecycle: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
