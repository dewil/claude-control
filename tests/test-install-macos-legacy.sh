#!/usr/bin/env bash
# macOS-ветка установщика: legacy-обвязка НЕ поднимается и снимается с машины.
#
# Зачем тест. V3.0 (2026-08-01) убрал вечную control-сессию и оба watchdog'а, но
# правка легла только в Linux-ветку: macOS продолжал bootstrap'ить их при каждом
# апгрейде, и заметить это было негде - Mac у проекта не в проверочном контуре.
# Ветка, которую нельзя прогнать, отстает молча, поэтому здесь она прогоняется на
# Linux: OS выбирается переменной CLAUDE_CONTROL_OS, а launchctl подменяется
# стабом, который пишет вызовы в лог и держит список "загруженных" меток.
#
# Что тест НЕ проверяет: настоящую семантику launchd (коды возврата bootstrap,
# валидность plist'а для launchd). Это ловится только живым прогоном на Mac.
# Здесь проверяется поток управления - кого поднимаем, кого снимаем.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ccinst.XXXXXX")" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

STUB="$SANDBOX/stub"
mkdir -p "$STUB" "$SANDBOX/home" "$SANDBOX/home/Library/LaunchAgents"

LOADED="$SANDBOX/loaded"      # метки, которые launchd "уже держит"
CALLS="$SANDBOX/launchctl.log"
: > "$CALLS"

# Стаб launchctl. print - есть ли метка среди загруженных; bootout - снять;
# bootstrap - поднять. Все вызовы протоколируются, по ним и судим.
cat > "$STUB/launchctl" <<'STUBEOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
case "${1:-}" in
  print)
    label="${2##*/}"
    grep -qxF "$label" "$LAUNCHCTL_LOADED" 2>/dev/null && exit 0
    exit 1 ;;
  bootout)
    label="${2##*/}"
    if [[ -f "$LAUNCHCTL_LOADED" ]]; then
      grep -vxF "$label" "$LAUNCHCTL_LOADED" > "$LAUNCHCTL_LOADED.tmp" 2>/dev/null || true
      mv "$LAUNCHCTL_LOADED.tmp" "$LAUNCHCTL_LOADED"
    fi
    exit 0 ;;
  bootstrap)
    plist="${3:-}"
    label="$(basename "$plist" .plist)"
    printf '%s\n' "$label" >> "$LAUNCHCTL_LOADED"
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/launchctl"

LABEL="com.test.claude-control"
# Машина ДО апгрейда: legacy-обвязка загружена. Именно ее установщик обязан снять,
# а не просто "не поднимать заново" - пропуск bootstrap загруженный агент не трогает.
printf '%s\n' "$LABEL" "$LABEL-watchdog" "$LABEL-project-watchdog" > "$LOADED"

out="$SANDBOX/install.out"
env -u CLAUDE_CONTROL_OS \
    HOME="$SANDBOX/home" \
    PATH="$STUB:$PATH" \
    LAUNCHCTL_LOG="$CALLS" \
    LAUNCHCTL_LOADED="$LOADED" \
    CLAUDE_CONTROL_OS=Darwin \
    "$ROOT/install.sh" --prefix "$SANDBOX/local" --label "$LABEL" \
    > "$out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok || fail "install.sh на macOS-ветке вышел с кодом $rc (см. $out)"

# 1. Legacy НЕ поднимается.
for lbl in "$LABEL" "$LABEL-watchdog" "$LABEL-project-watchdog"; do
  if grep -q "bootstrap .*/$lbl\.plist" "$CALLS"; then
    fail "legacy-метка $lbl была bootstrap'нута"
  else ok; fi
done

# 2. Legacy снимается с уже установленной машины.
for lbl in "$LABEL" "$LABEL-watchdog" "$LABEL-project-watchdog"; do
  if grep -q "bootout .*/$lbl\$" "$CALLS"; then ok
  else fail "legacy-метка $lbl не снята (bootout не вызван)"; fi
done
if grep -qxF "$LABEL" "$LOADED"; then
  fail "control-сессия осталась загруженной после установки"
else ok; fi

# 3. Ротация логов - единственное, что остается поднятым.
if grep -q "bootstrap .*/$LABEL-logrotate\.plist" "$CALLS"; then ok
else fail "logrotate не поднят - логи останутся без ротации"; fi
if grep -qxF "$LABEL-logrotate" "$LOADED"; then ok
else fail "logrotate не числится загруженным"; fi

# 4. Файлы legacy остаются на диске: паритет с Linux-веткой, это откат.
for lbl in "$LABEL" "$LABEL-watchdog" "$LABEL-project-watchdog"; do
  if [[ -f "$SANDBOX/home/Library/LaunchAgents/$lbl.plist" ]]; then ok
  else fail "$lbl.plist не отрендерен - откатываться будет нечем"; fi
done

# 5. Скрипты доехали в prefix (общая проверка, что прогон вообще что-то сделал).
if [[ -x "$SANDBOX/local/bin/claude-rc" ]]; then ok
else fail "claude-rc не установлен в prefix"; fi

# 6. Ни одного обращения к systemd на macOS-ветке.
if grep -q 'systemctl' "$out"; then
  fail "на macOS-ветке засветился systemctl"
else ok; fi

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
