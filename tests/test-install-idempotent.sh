#!/usr/bin/env bash
# Повторная установка не плодит мусор, а демонтаж уносит все, что поставил.
#
# Две находки с Mac (2026-08-13), обе не видны на одном прогоне:
#   1. backup_existing снимал .bak.XXXXXX БЕЗУСЛОВНО - даже когда файл не менялся
#      (проверено diff'ом: копии байт-в-байт равны оригиналам). Каждый апгрейд
#      добавлял по копии на все 29 файлов.
#   2. uninstall.sh знал пять имен из 29: после демонтажа оставались весь пояс
#      claude-agent-*, claude-rc-agent, claude-rc-takeover и python-хелперы.
#      Вместе с бэкапами это дало 53 сироты в ~/.local/bin.
#
# Прогон идет по macOS-ветке (CLAUDE_CONTROL_OS=Darwin, launchctl - стаб): у нее
# нет обращений к systemd, поэтому тест не трогает системные юниты машины.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ccidem.XXXXXX")" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

STUB="$SANDBOX/stub"; mkdir -p "$STUB" "$SANDBOX/home/Library/LaunchAgents"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/launchctl"
chmod +x "$STUB/launchctl"

BIN="$SANDBOX/local/bin"
AGENTS="$SANDBOX/home/Library/LaunchAgents"
LABEL="com.test.claude-control"

install_run() {
  env HOME="$SANDBOX/home" PATH="$STUB:$PATH" CLAUDE_CONTROL_OS=Darwin \
      "$ROOT/install.sh" --prefix "$SANDBOX/local" --label "$LABEL" >"$SANDBOX/log" 2>&1
}
baks() { find "$BIN" "$AGENTS" -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' '; }

# --- прогон 1: чистая установка
install_run && ok || fail "первый install вернул $? (см. $SANDBOX/log)"
mapfile -t manifest < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$ROOT/scripts.manifest" | grep -v '^$')
missing=0
for n in "${manifest[@]}"; do [[ -e "$BIN/$n" ]] || missing=$((missing+1)); done
(( missing == 0 )) && ok || fail "после установки в BIN_DIR не хватает $missing файлов из манифеста"
[[ "$(baks)" == "0" ]] && ok || fail "на чистой установке уже появились бэкапы: $(baks)"

# --- прогон 2: тот же код - ни одного бэкапа
install_run && ok || fail "второй install вернул ненулевой код"
if [[ "$(baks)" == "0" ]]; then ok
else fail "повторная установка того же кода создала $(baks) бэкапов - копии не сравниваются"; fi

# --- прогон 3: файл РЕАЛЬНО изменился - бэкап обязан появиться
printf '\n# local edit\n' >> "$BIN/claude-rc"
install_run && ok || fail "третий install вернул ненулевой код"
n_bak="$(find "$BIN" -name 'claude-rc.bak.*' | wc -l | tr -d ' ')"
[[ "$n_bak" == "1" ]] && ok || fail "изменение файла дало $n_bak бэкапов, ожидался ровно 1"
if [[ "$(baks)" == "1" ]]; then ok
else fail "бэкап сняли не только с изменившегося файла: всего $(baks)"; fi

# --- демонтаж: уносит и файлы манифеста, и бэкапы
env HOME="$SANDBOX/home" PATH="$STUB:$PATH" CLAUDE_CONTROL_OS=Darwin \
    "$ROOT/uninstall.sh" --prefix "$SANDBOX/local" --label "$LABEL" >"$SANDBOX/log.un" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok || fail "uninstall вернул $rc (см. $SANDBOX/log.un)"

left=()
for n in "${manifest[@]}"; do [[ -e "$BIN/$n" ]] && left+=("$n"); done
if (( ${#left[@]} == 0 )); then ok
else fail "после демонтажа осталось ${#left[@]} файлов: ${left[*]:0:5}..."; fi
if [[ "$(baks)" == "0" ]]; then ok
else fail "после демонтажа осталось $(baks) бэкапов"; fi

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
