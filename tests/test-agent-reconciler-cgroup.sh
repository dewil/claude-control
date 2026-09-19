#!/usr/bin/env bash
# Тесты вслепую (INV-RECON-07) по спеке
# docs/dev/2026-09-19-spec-cgroup-unknown.md: "не удалось проверить" не равно
# "пусто" при освобождении lease. Реализации еще нет - все проверки ниже
# КРАСНЫЕ: сейчас `cgroup_procs` игнорирует systemctl вовсе (путь собирается
# из захардкоженных сегментов /sys/fs/cgroup/user.slice/..., которого на
# тестовой машине не существует), поэтому любой сценарий читается как "пусто".
#
# Техника: bin/claude-agent-reconciler исполняет "main" (flock + run_pass) на
# любое подключение файла, поэтому подключаем не весь файл, а срез до строки
# `mode=` (начало диспетчера argv) - все функции определены раньше этой строки.
# systemctl подменяется мок-скриптом в PATH; "файловая система" cgroup - это
# обычный временный каталог, путь к которому отдает мок
# `systemctl --user show -p ControlGroup`. $0 при подключении среза выставлен
# в реальный путь bin/claude-agent-reconciler (через `bash -c '...' "$REAL_RECON"`),
# поэтому BIN_DIR внутри среза резолвится верно и IO указывает на настоящий
# claude-agent-io.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
REAL_RECON="$ROOT/bin/claude-agent-reconciler"
IO="$ROOT/bin/claude-agent-io"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL (INV-RECON-07): $1" >&2; }

if [[ ! -f "$REAL_RECON" ]]; then
  fail "bin/claude-agent-reconciler не найден - технически невозможно продолжить"
  echo "test-agent-reconciler-cgroup: $PASS ok, $FAIL FAIL"
  exit 1
fi

MARKER_LINE="$(grep -n '^mode=' "$REAL_RECON" | head -1 | cut -d: -f1)"
if [[ -z "$MARKER_LINE" ]]; then
  fail "не нашли строку 'mode=' (начало диспетчера argv) - срез файла невозможен"
  echo "test-agent-reconciler-cgroup: $PASS ok, $FAIL FAIL"
  exit 1
fi
FUNCS="$TMP/reconciler-funcs.sh"
head -n "$((MARKER_LINE - 1))" "$REAL_RECON" > "$FUNCS"

AGENTS_DIR="$TMP/agents"
RC_DIR="$TMP/rc"
CFG_DIR="$TMP/claude-config"
MOCKBIN="$TMP/mockbin"
SCEN_DIR="$TMP/scen"
CGROOT="$TMP/cgroups"
CALL_LOG="$TMP/systemctl-calls.log"
mkdir -p "$AGENTS_DIR" "$RC_DIR" "$MOCKBIN" "$SCEN_DIR" "$CGROOT"
: > "$CALL_LOG"

# --- мок systemctl: поведение "show" на юнит читается из файла сценария ---
# $SCEN_DIR/<юнит> - bash-присвоения SCN_RC (код возврата), SCN_LOAD
# (LoadState), SCN_CG (значение ControlGroup - абсолютный путь к фейковой
# cgroup-директории в этом временном каталоге). Юнита без сценария трактуем
# как реальный systemctl трактует несуществующий юнит: LoadState=not-found,
# ControlGroup пуст.
cat > "$MOCKBIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG:?CALL_LOG не задан}"
unit="${!#}"
case "$*" in
  *" show "*)
    scen="$SCEN_DIR/$unit"
    if [[ -f "$scen" ]]; then
      # shellcheck disable=SC1090
      . "$scen"
    else
      SCN_RC=0; SCN_LOAD=not-found; SCN_CG=
    fi
    if [[ "${SCN_RC:-0}" != 0 ]]; then exit "${SCN_RC}"; fi
    props=(); prev=""
    for a in "$@"; do
      if [[ "$prev" == "-p" ]]; then
        IFS=',' read -ra parts <<< "$a"
        props+=("${parts[@]}")
      fi
      prev="$a"
    done
    [[ ${#props[@]} -eq 0 ]] && props=(LoadState ControlGroup)
    valueof() {
      case "$1" in
        LoadState) echo "${SCN_LOAD:-loaded}" ;;
        ControlGroup) echo "${SCN_CG:-}" ;;
        ActiveState) echo "${SCN_ACTIVE:-active}" ;;
        *) echo "" ;;
      esac
    }
    if [[ " $* " == *" --value "* ]]; then
      for p in "${props[@]}"; do valueof "$p"; done
    else
      for p in "${props[@]}"; do echo "$p=$(valueof "$p")"; done
    fi
    exit 0 ;;
  *" stop "*) exit 0 ;;
  *" kill "*) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/systemctl"

write_scenario() { # <unit> <rc> <loadstate> <cgpath-or-empty> [activestate]
  cat > "$SCEN_DIR/$1" <<EOF
SCN_RC=$2
SCN_LOAD="$3"
SCN_CG="$4"
SCN_ACTIVE="${5:-active}"
EOF
}

# --- фикстура агента: control.json с lease active (валидный минимум по
# схеме claude-agent-io, образец взят из tests/test-agent-io.sh) ---
mk_agent() { # <name> -> печатает путь каталога агента
  local name="$1"
  local dir="$AGENTS_DIR/$name"
  rm -rf "$dir"; mkdir -p "$dir"
  local control='{"schema":1,"seq":0,"desired":"paused","generation":0,
"session_id":null,"started_at":null,"deadline_extension_h":0,
"mission_base":null,
"lease":{"state":"active","start_attempt_id":null,"gen_base":null,
"socket":null,"unit":null,"main_pid":null,"pid_start":null,
"granted_at":null,"renewed_at":null,"ttl_s":300},
"acceptance":{"status":"pending","artifact":null,"verdict_by":null,
"checked_at":null,"note":null,"check_job":null,"check_runs":[]},
"attention":null,"hold":null,"handoff":null}'
  "$IO" control-init "$dir" "$control" >/dev/null
  echo "$dir"
}

lease_state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease"]["state"])' "$1/control.json"; }
attention_of() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["attention"]))' "$1/control.json"; }

# запуск функции реконсилера в чистом окружении: $0 внутри среза = REAL_RECON,
# поэтому BIN_DIR/IO резолвятся на настоящий bin/. STOP_GRACE переопределяем
# переменной CLAUDE_AGENT_STOP_GRACE (та же, что читает реконсилер).
run_recon() { # <stop_grace> <expr-to-eval-after-source>...
  local grace="$1"; shift
  env FUNCS="$FUNCS" PATH="$MOCKBIN:$PATH" SCEN_DIR="$SCEN_DIR" CALL_LOG="$CALL_LOG" \
      CLAUDE_AGENTS_DIR="$AGENTS_DIR" CLAUDE_RECONCILER_DIR="$RC_DIR" \
      CLAUDE_CONFIG_DIR="$CFG_DIR" CLAUDE_AGENT_STOP_GRACE="$grace" \
      timeout 30 bash -c '. "$FUNCS"; '"$1" "$REAL_RECON" "${@:2}"
}

# =====================================================================
# Критерий 1: пустой cgroup при доступном пути - исход "пусто", lease
# освобождается. Проверяем и низкоуровневую функцию (проверка пустоты
# cgroup), и последствие (гашение агента).
# =====================================================================
NAME=cg1; UNIT="agent-$NAME.service"
DIR="$(mk_agent "$NAME")"
CG="$CGROOT/$NAME/root"; mkdir -p "$CG"; : > "$CG/cgroup.procs"
write_scenario "$UNIT" 0 loaded "$CG"

out="$(run_recon 1 'out=$(cgroup_procs "$1"); rc=$?; printf "OUT=[%s] RC=%s\n" "$out" "$rc"' "$NAME")"
if [[ "$out" == "OUT=[] RC=0" ]]; then ok
else fail "критерий 1: cgroup_procs при пустом читаемом корне должна вернуть пустую строку и код 0 (получено: $out)"; fi

: > "$CALL_LOG"
exit_code="$(run_recon 1 'shutdown_agent "$1" "$2"; echo "EXIT=$?"' "$DIR" "$NAME" | grep -o 'EXIT=[0-9]*' | cut -d= -f2)"
[[ "$exit_code" == "0" ]] && ok || fail "критерий 1: shutdown_agent должен вернуть 0 (получено: $exit_code)"
[[ "$(lease_state "$DIR")" == "none" ]] && ok || fail "критерий 1: lease.state должен стать none (получено: $(lease_state "$DIR"))"
grep -q -- 'kill' "$CALL_LOG" && fail "критерий 1: SIGKILL не должен понадобиться при изначально пустом cgroup" || ok

# =====================================================================
# Критерий 2: непустой cgroup.procs КОРНЯ - исход "не пусто", lease не
# освобождается, ставится attention.
# =====================================================================
NAME=cg2; UNIT="agent-$NAME.service"
DIR="$(mk_agent "$NAME")"
CG="$CGROOT/$NAME/root"; mkdir -p "$CG"; echo "11111" > "$CG/cgroup.procs"
write_scenario "$UNIT" 0 loaded "$CG"

out="$(run_recon 1 'out=$(cgroup_procs "$1"); rc=$?; printf "OUT=[%s] RC=%s\n" "$out" "$rc"' "$NAME")"
[[ "$out" == "OUT=[11111] RC=0" ]] && ok || fail "критерий 2: cgroup_procs при непустом корне должна вернуть pid и код 0 (получено: $out)"

exit_code="$(run_recon 1 'shutdown_agent "$1" "$2"; echo "EXIT=$?"' "$DIR" "$NAME" | grep -o 'EXIT=[0-9]*' | cut -d= -f2)"
[[ "$exit_code" == "1" ]] && ok || fail "критерий 2: shutdown_agent должен вернуть 1 при непустом cgroup (получено: $exit_code)"
[[ "$(lease_state "$DIR")" != "none" ]] && ok || fail "критерий 2: lease НЕ должен освободиться (стал none)"
ATT2="$(attention_of "$DIR")"
[[ "$ATT2" != "null" ]] && ok || fail "критерий 2: attention должен быть установлен (получено: null)"

# =====================================================================
# Критерий 3: непустой cgroup.procs ВЛОЖЕННОГО cgroup при пустом корне -
# исход "не пусто". Это главная проверка дефекта: старый код читает только
# корневой cgroup.procs и пропускает вложенные scope.
# =====================================================================
NAME=cg3; UNIT="agent-$NAME.service"
DIR="$(mk_agent "$NAME")"
CG="$CGROOT/$NAME/root"; mkdir -p "$CG"; : > "$CG/cgroup.procs"
mkdir -p "$CG/child.scope"; echo "22222" > "$CG/child.scope/cgroup.procs"
write_scenario "$UNIT" 0 loaded "$CG"

out="$(run_recon 1 'out=$(cgroup_procs "$1"); rc=$?; printf "OUT=[%s] RC=%s\n" "$out" "$rc"' "$NAME")"
if [[ "$out" == *"22222"* && "$out" == *"RC=0"* ]]; then ok
else fail "критерий 3 (ГЛАВНЫЙ): непустой ВЛОЖЕННЫЙ cgroup при пустом корне должен быть виден как непустой (получено: $out)"; fi

exit_code="$(run_recon 1 'shutdown_agent "$1" "$2"; echo "EXIT=$?"' "$DIR" "$NAME" | grep -o 'EXIT=[0-9]*' | cut -d= -f2)"
[[ "$exit_code" == "1" ]] && ok || fail "критерий 3: shutdown_agent должен вернуть 1 (процесс жив во вложенном cgroup), получено: $exit_code"
[[ "$(lease_state "$DIR")" != "none" ]] && ok || fail "критерий 3: lease НЕ должен освободиться при живом процессе во вложенном cgroup"

# =====================================================================
# Критерий 4: `systemctl show -p ControlGroup` завершается ненулевым
# кодом - исход "не удалось", lease НЕ освобождается, ставится attention.
# =====================================================================
NAME=cg4; UNIT="agent-$NAME.service"
DIR="$(mk_agent "$NAME")"
write_scenario "$UNIT" 3 loaded ""

out="$(run_recon 1 'out=$(cgroup_procs "$1"); rc=$?; printf "OUT=[%s] RC=%s\n" "$out" "$rc"' "$NAME")"
if [[ "$out" == *"RC=0"* ]]; then
  fail "критерий 4: ненулевой код systemctl show должен давать код неудачи != 0 у проверки (получено: $out)"
else
  ok
fi

exit_code="$(run_recon 1 'shutdown_agent "$1" "$2"; echo "EXIT=$?"' "$DIR" "$NAME" | grep -o 'EXIT=[0-9]*' | cut -d= -f2)"
[[ "$exit_code" == "1" ]] && ok || fail "критерий 4: shutdown_agent должен вернуть 1, когда проверка не удалась (получено: $exit_code)"
[[ "$(lease_state "$DIR")" != "none" ]] && ok || fail "критерий 4: lease НЕ должен освободиться при неудавшейся проверке"
ATT4="$(attention_of "$DIR")"
[[ "$ATT4" != "null" ]] && ok || fail "критерий 4: attention должен быть установлен при 'не удалось'"

# =====================================================================
# Критерий 5: путь получен, но cgroup.procs не читается (нет прав) -
# исход "не удалось", lease не освобождается. Отдельный от критерия 4
# способ получить ту же неудачу: тут systemctl отвечает штатно (rc=0,
# путь есть), ломается чтение файла.
# =====================================================================
NAME=cg5; UNIT="agent-$NAME.service"
DIR="$(mk_agent "$NAME")"
CG="$CGROOT/$NAME/root"; mkdir -p "$CG"; : > "$CG/cgroup.procs"; chmod 000 "$CG/cgroup.procs"
write_scenario "$UNIT" 0 loaded "$CG"

out="$(run_recon 1 'out=$(cgroup_procs "$1"); rc=$?; printf "OUT=[%s] RC=%s\n" "$out" "$rc"' "$NAME")"
if [[ "$out" == *"RC=0"* ]]; then
  fail "критерий 5: нечитаемый cgroup.procs при полученном пути должен давать код неудачи != 0 (получено: $out), а не 'пусто'"
else
  ok
fi

exit_code="$(run_recon 1 'shutdown_agent "$1" "$2"; echo "EXIT=$?"' "$DIR" "$NAME" | grep -o 'EXIT=[0-9]*' | cut -d= -f2)"
[[ "$exit_code" == "1" ]] && ok || fail "критерий 5: shutdown_agent должен вернуть 1 при нечитаемом cgroup.procs (получено: $exit_code)"
[[ "$(lease_state "$DIR")" != "none" ]] && ok || fail "критерий 5: lease НЕ должен освободиться при нечитаемом cgroup.procs"

# =====================================================================
# Критерий 6: юнит не загружен вовсе - исход "пусто" (доказанная, не
# неизвестность), lease освобождается: гасить нечего.
# =====================================================================
NAME=cg6; UNIT="agent-$NAME.service"
DIR="$(mk_agent "$NAME")"
write_scenario "$UNIT" 0 not-found ""

exit_code="$(run_recon 1 'shutdown_agent "$1" "$2"; echo "EXIT=$?"' "$DIR" "$NAME" | grep -o 'EXIT=[0-9]*' | cut -d= -f2)"
[[ "$exit_code" == "0" ]] && ok || fail "критерий 6: юнит не загружен - shutdown_agent должен вернуть 0 (получено: $exit_code)"
[[ "$(lease_state "$DIR")" == "none" ]] && ok || fail "критерий 6: lease.state должен стать none, когда юнит не загружен (получено: $(lease_state "$DIR"))"

# =====================================================================
# Критерий 7: ожидание после SIGKILL ограничено STOP_GRACE, а не
# фиксированными двумя секундами. Проверяем СЧЕТОМ вызовов: cgroup
# остается непустым и до, и после SIGKILL, поэтому корректная реализация
# опрашивает "show ControlGroup" НЕСКОЛЬКО раз в окне STOP_GRACE и после
# kill, а не один раз после фиксированного sleep 2 (текущий баг).
# =====================================================================
NAME=cg7; UNIT="agent-$NAME.service"
DIR="$(mk_agent "$NAME")"
CG="$CGROOT/$NAME/root"; mkdir -p "$CG"; echo "33333" > "$CG/cgroup.procs"
write_scenario "$UNIT" 0 loaded "$CG"
: > "$CALL_LOG"

run_recon 2 'shutdown_agent "$1" "$2"; echo "EXIT=$?"' "$DIR" "$NAME" >/dev/null

KILL_LINE="$(grep -n -- '-s SIGKILL' "$CALL_LOG" | head -1 | cut -d: -f1)"
if [[ -z "$KILL_LINE" ]]; then
  fail "критерий 7: SIGKILL так и не был вызван при постоянно непустом cgroup"
else
  ok
  AFTER_KILL_SHOWS="$(tail -n "+$((KILL_LINE + 1))" "$CALL_LOG" | grep -c -- ' show ')"
  if [[ "$AFTER_KILL_SHOWS" -gt 1 ]]; then ok
  else fail "критерий 7 (ГЛАВНЫЙ): после SIGKILL должно быть НЕСКОЛЬКО опросов cgroup в окне STOP_GRACE, а не фиксированный один после sleep 2 (получено опросов после kill: $AFTER_KILL_SHOWS)"; fi
fi

# =====================================================================
# Критерий 8: существующие проверки реконсилера и fault-суиты остаются
# зелеными. Отдельно не гоняем весь набор здесь (это задача общего
# прогона тестов, не этого файла) - фиксируем намерение явной пометкой,
# чтобы критерий не потерялся из виду.
# =====================================================================
echo "критерий 8 (регресс существующих тестов реконсилера и fault-суиты) проверяется общим прогоном tests/*.sh и tests/fault/run-fault-tests.sh, не этим файлом" >&2

# =====================================================================
# Критерий 9 (добавлен 20.09.2026 основным агентом, НЕ вслепую): пустой
# ControlGroup у ЗАГРУЖЕННОГО юнита. Исполнитель фикса отступил тут от
# буквы спеки, и отступление лежит на главном пути: после SIGKILL
# транзиентный юнит остается loaded с пустым ControlGroup, и буквальное
# "пустой путь = не удалось" заморозило бы lease именно в том сценарии,
# ради которого гашение и делается. Принятое прочтение: пустой путь -
# доказанная пустота, когда сам systemd говорит not-found / inactive /
# failed; при ЖИВОМ юните с пустым путем - "не удалось". Без этой
# проверки отступление держалось бы только на словах в отчете.
# =====================================================================
for st in inactive failed; do
  NAME9="cg9$st"
  write_scenario "agent-$NAME9.service" 0 "loaded" "" "$st"
  out9="$(run_recon 1 'out=$(cgroup_procs "$1"); rc=$?; printf "OUT=[%s] RC=%s\n" "$out" "$rc"' "$NAME9")"
  [[ "$out9" == "OUT=[] RC=0" ]] && ok \
    || fail "INV-RECON-07 критерий 9: пустой ControlGroup при ActiveState=$st - доказанная пустота (получено: $out9)"
done
write_scenario "agent-cg9live.service" 0 "loaded" "" "active"
out9="$(run_recon 1 'out=$(cgroup_procs "$1"); rc=$?; printf "OUT=[%s] RC=%s\n" "$out" "$rc"' "cg9live")"
if [[ "$out9" == "OUT=[] RC=0" ]]; then
  fail "INV-RECON-07 критерий 9: пустой ControlGroup при ЖИВОМ юните обязан давать отказ, а не пустоту (получено: $out9)"
else ok; fi

echo "test-agent-reconciler-cgroup: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
