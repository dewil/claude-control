#!/usr/bin/env bash
# Tests for _agent_trust_preseed.py - протокол блокировки .claude.json.
#
# Зачем отдельный файл: preseed берет лок на том же пути, что и сам CLI
# (<config>.lock), и протокол обязан совпадать. CLI держит там ДИРЕКТОРИЮ
# (mkdir на захвате, rmdir на отпускании - проверено опытом 2026-08-02).
# Мы держали файл под flock - имя занималось навсегда, mkdir у CLI не проходил
# никогда, и он писал конфиг вообще без взаимного исключения, сыпля
# "Failed to save config with lock: ENOTDIR ... rmdir". За неделю - 151 такая
# ошибка во всех сессиях: общий 180-килобайтный конфиг (доверие проектам,
# история, учетка) переписывался четырьмя процессами наперегонки.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/../bin/_agent_trust_preseed.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

CFG="$TMP/.claude.json"
LOCK="$CFG.lock"
WORK="$TMP/work"; mkdir -p "$WORK"

# 1. После работы на пути лока не остается НИЧЕГО. Файл, оставленный там
#    навсегда, - это и есть исходный дефект: он глушит мьютекс CLI.
python3 "$HELPER" "$CFG" "$WORK" >/dev/null 2>&1
if [[ ! -e "$LOCK" ]]; then ok; else fail "на пути лока осталось: $(stat -c '%F' "$LOCK")"; fi

# 2. Профильная работа не сломана: флаг доверия проставлен.
if python3 -c "
import json,sys
d=json.load(open('$CFG'))
sys.exit(0 if d['projects']['$WORK']['hasTrustDialogAccepted'] is True else 1)"; then ok
else fail "hasTrustDialogAccepted не проставлен"; fi

# 3. Чужие ключи конфига переживают правку.
python3 -c "
import json
d=json.load(open('$CFG')); d['someOtherKey']='keep-me'
json.dump(d, open('$CFG','w'))"
python3 "$HELPER" "$CFG" "$WORK" >/dev/null 2>&1
if grep -q 'keep-me' "$CFG"; then ok; else fail "preseed затер чужой ключ"; fi

# 4. Захваченный лок уважается: пока директория на месте и свежая, preseed ждет,
#    а не лезет писать. Без этого мьютекс односторонний - мы бы не мешали CLI,
#    но и он нам.
mkdir -p "$LOCK"
before="$(stat -c '%y %s' "$CFG" 2>/dev/null)"
python3 "$HELPER" "$CFG" "$TMP/other" >/dev/null 2>&1 &
worker=$!
sleep 1
after="$(stat -c '%y %s' "$CFG" 2>/dev/null)"
if [[ "$before" == "$after" ]]; then ok; else fail "preseed записал конфиг при захваченном локе"; fi

# 5. Лок отпустили - preseed доводит дело до конца.
rmdir "$LOCK"
if wait "$worker" && grep -q "$TMP/other" "$CFG"; then ok
else fail "после освобождения лока preseed не дописал конфиг"; fi
if [[ ! -e "$LOCK" ]]; then ok; else fail "лок не убран за собой после ожидания"; fi

# 6. Протухший лок (процесс умер, не отпустив) отбирается, иначе одна смерть
#    навсегда выключает мьютекс - ровно та беда, которую чиним.
mkdir -p "$LOCK"
touch -d '-1 hour' "$LOCK"
start="$(date +%s)"
python3 "$HELPER" "$CFG" "$TMP/third" >/dev/null 2>&1
took=$(( $(date +%s) - start ))
if grep -q "$TMP/third" "$CFG" && (( took < 8 )); then ok
else fail "протухший лок не отобран (took=${took}s)"; fi
if [[ ! -e "$LOCK" ]]; then ok; else fail "после отбора лок не убран"; fi

# 7. Сломанный конфиг: пишем валидный документ с доверием, а не падаем молча.
printf 'not json at all' > "$CFG"
python3 "$HELPER" "$CFG" "$WORK" >/dev/null 2>&1
if python3 -c "
import json,sys
d=json.load(open('$CFG'))
sys.exit(0 if d['projects']['$WORK']['hasTrustDialogAccepted'] is True else 1)"; then ok
else fail "сломанный конфиг не восстановлен"; fi

# 8. Параллельные вызовы не теряют правки друг друга - ради этого лок и нужен.
rm -f "$CFG"
for i in 1 2 3 4 5 6; do
  python3 "$HELPER" "$CFG" "$TMP/p$i" >/dev/null 2>&1 &
done
wait
missing=""
for i in 1 2 3 4 5 6; do
  grep -q "$TMP/p$i\"" "$CFG" || missing="$missing p$i"
done
if [[ -z "$missing" ]]; then ok; else fail "потеряны правки:$missing"; fi

echo "test-trust-preseed-lock: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
