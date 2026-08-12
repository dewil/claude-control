#!/usr/bin/env bash
# Полнота установщика: каждый вспомогательный модуль, который скрипты зовут в
# рантайме, обязан попадать в ~/.local/bin.
#
# Зачем отдельный тест. install.sh перечисляет файлы СПИСКОМ, а не копирует
# bin/* целиком. Новый помощник легко забыть - и тогда в репозитории все
# работает, а на машине нет: скрипт молча теряет функцию, потому что зовет
# helper рядом с собой ($(dirname $0)), а его там не положили. Ровно так
# 2026-08-03 уехал _rc_ctx.py: проценты занятости контекста считались при
# проверке из репозитория и были пустыми у развернутой копии, которую крутит бот.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

MANIFEST="$ROOT/scripts.manifest"
[[ -r "$MANIFEST" ]] && ok || fail "нет scripts.manifest - списка установки"
mapfile -t manifest < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$MANIFEST" | grep -v '^$')
if (( ${#manifest[@]} )); then ok; else fail "scripts.manifest пуст"; fi

# Помощники - файлы bin/_*.py и bin/_*.sh: их не запускают напрямую, их зовет
# соседний скрипт, поэтому пропажу видно только в бою.
mapfile -t helpers < <(cd "$ROOT/bin" && ls _*.py _*.sh 2>/dev/null)
if (( ${#helpers[@]} )); then ok; else fail "в bin/ не найдено ни одного помощника - тест бесполезен"; fi

for h in "${helpers[@]}"; do
  if printf '%s\n' "${manifest[@]}" | grep -qxF "$h"; then ok
  else fail "$h зовется скриптами, но не попадает в scripts.manifest"; fi
done

# Обратная проверка: в списке нет имен, которых уже нет в репозитории. Такой
# мусор ломает установку целиком - cp падает, и часть файлов остается старой
# (так после удаления claude-control-run сессии неделю крутили прошлую версию).
for l in "${manifest[@]}"; do
  if [[ -f "$ROOT/bin/$l" ]]; then ok
  else fail "в манифесте есть $l, которого нет в bin/"; fi
done

# Список ровно один. Раньше их было два - install.sh знал 29 имен, uninstall.sh
# пять, и после демонтажа на машине оставались 24 сироты (Mac, 2026-08-13).
# Расхождение двух списков не видит ни один прогон, поэтому проверяем не их
# совпадение, а то, что второго списка не существует.
for s in install.sh uninstall.sh; do
  if grep -q 'scripts\.manifest' "$ROOT/$s"; then ok
  else fail "$s не читает scripts.manifest - завел свой список?"; fi
  if grep -qE '^\s*for script in (claude|_)' "$ROOT/$s"; then
    fail "$s снова несет встроенный список имен вместо манифеста"
  else ok; fi
done

echo "test-install-completeness: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
