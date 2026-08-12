#!/usr/bin/env bash
# Машина без systemd: claude-rc обязан отказывать словами, а не умирать молча.
#
# Зачем тест. На macOS `claude-rc live` завершался с rc=127 и ПУСТЫМ выводом
# (замерено 2026-08-13, macOS 26.5.2): под `set -euo pipefail` отсутствующий
# systemctl дает 127 в пайпе, pipefail тащит его в статус присваивания, `set -e`
# убивает скрипт, а `2>/dev/null` съедает объяснение. Снаружи это читается как
# "ничего не поднято" - то есть неотличимо от нормальной работы, а для скрипта,
# который смотрит на rc, это ложная авария.
#
# Systemd тут не подделывается: наоборот, собирается PATH из симлинков на все
# обычные каталоги БЕЗ одного имени - systemd-run. Пустой PATH не годится:
# claude-rc раньше гейта проверяет yq и зовет uname, и тест ловил бы не то.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$(cd "$HERE/.." && pwd)/bin/claude-rc"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/rcnosd.XXXXXX")" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
NOSD="$SANDBOX/path-without-systemd-run"
mkdir -p "$NOSD"
IFS=':' read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    [[ -e "$f" ]] || continue
    n="${f##*/}"
    [[ "$n" == "systemd-run" ]] && continue
    [[ -e "$NOSD/$n" ]] || ln -s "$f" "$NOSD/$n" 2>/dev/null || true
  done
done
if command -v systemd-run >/dev/null 2>&1; then ok
else fail "на этой машине нет systemd-run - тест не проверяет то, что должен"; fi
if PATH="$NOSD" command -v systemd-run >/dev/null 2>&1; then
  fail "systemd-run виден и в урезанном PATH - песочница собрана неверно"
else ok; fi

run_rc() { PATH="$NOSD" "$BASH" "$RC" "$@" 2>"$SANDBOX/err" >"$SANDBOX/out"; }

for verb in live up new down reap compact; do
  run_rc "$verb" nosuchproject 00000000-0000-0000-0000-000000000000
  rc=$?
  err="$(cat "$SANDBOX/err")"

  [[ $rc -eq 1 ]] && ok || fail "$verb: rc=$rc, ожидался 1 (127 - это молчаливая смерть)"
  if [[ -n "$err" ]]; then ok; else fail "$verb: пустой stderr - отказ должен быть словами"; fi
  if grep -q 'systemd-run' <<<"$err"; then ok
  else fail "$verb: в отказе не назван systemd-run, из такого сообщения не понять причину"; fi
  # Сообщение обязано вести к тому, что на этой машине все-таки работает.
  if grep -q 'sessions' <<<"$err"; then ok
  else fail "$verb: отказ не подсказывает читающие команды"; fi
done

# Справка не зависит от systemd и обязана работать где угодно.
run_rc --help
rc=$?
[[ $rc -eq 0 ]] && ok || fail "--help вернул $rc на машине без systemd"
if grep -q 'claude-rc' "$SANDBOX/out"; then ok; else fail "--help ничего не напечатал"; fi

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
