#!/usr/bin/env bash
# Tests for claude-control-transcript-gc - сборщик машинных транскриптов.
#
# Каждый прогон claude -p из cron оставляет полноценный транскрипт рядом с
# рабочими сессиями; в домашнем каталоге их накопилось 246 за месяц. Удаление
# необратимо, поэтому проверяются в первую очередь ОТКАЗЫ удалять: именованные
# (это рабочие сессии человека), свежие, живые, чужие каталоги.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GC="${GC_BIN:-$HERE/../bin/claude-control-transcript-gc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

export HOME="$TMP"
mkdir -p "$TMP/bin" "$TMP/.claude-control"
DIR="$TMP/.claude/projects/-home-x"; mkdir -p "$DIR"
LOG="$TMP/.claude-control/transcript-gc.log"

# Живые сессии - мок systemctl: одна живая, по uuid без дефисов.
LIVE="aaaaaaaa-1111-4111-8111-111111111111"
cat > "$TMP/bin/systemctl" <<MOCK
#!/usr/bin/env bash
case "\$*" in *list-units*) echo "ccsession-${LIVE//-/}.service loaded active running";; esac
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

mk() { # <имя> <дней назад> [named]
  local f="$DIR/$1.jsonl"
  if [[ "${3:-}" == named ]]; then
    printf '{"type":"custom-title","customTitle":"моя работа"}\n{"type":"assistant"}\n' > "$f"
  else
    printf '{"type":"user","message":{"content":"Ты собираешь дайджест"}}\n{"type":"assistant"}\n' > "$f"
  fi
  touch -d "$2 days ago" "$f"
}

mk old-unnamed 10
mk fresh-unnamed 2
mk old-named 30 named
mk "$LIVE" 30
# "ровно 7 дней" по mtime нестабилен: touch и прогон разделяют секунды, и граница
# оказывается уже позади. Проверяем "младше срока на волос", а не саму секунду.
mk boundary 6

echo "=== сухой прогон ничего не удаляет, но называет кандидатов ==="
out="$("$GC" --dir "$DIR" --days 7 --dry-run 2>&1)"
[[ -f "$DIR/old-unnamed.jsonl" ]] && ok || fail "dry-run удалил файл"
grep -q "old-unnamed" <<<"$out" && ok || fail "dry-run не назвал кандидата ($out)"
grep -q "old-named" <<<"$out" && fail "dry-run назвал именованный" || ok

echo "=== боевой прогон ==="
"$GC" --dir "$DIR" --days 7 >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok || fail "выход $rc"
[[ ! -f "$DIR/old-unnamed.jsonl" ]] && ok || fail "старый безымянный не удален"
[[ -f "$DIR/fresh-unnamed.jsonl" ]] && ok || fail "свежий удален"
[[ -f "$DIR/old-named.jsonl" ]] && ok || fail "ИМЕНОВАННЫЙ удален - это рабочая сессия человека"
[[ -f "$DIR/$LIVE.jsonl" ]] && ok || fail "транскрипт ЖИВОЙ сессии удален"
[[ -f "$DIR/boundary.jsonl" ]] && ok || fail "младше срока на волос - оставить"

echo "=== исход виден в логе, включая пустой прогон ==="
grep -qE "удалено 1" "$LOG" && ok || fail "число удаленных не записано ($(tail -2 "$LOG"))"
"$GC" --dir "$DIR" --days 7 >/dev/null 2>&1
grep -qE "удалено 0" "$LOG" && ok || fail "пустой прогон молчит - тишина неотличима от поломки"

echo "=== защита от чужого каталога ==="
mkdir -p "$TMP/elsewhere"; printf '{"type":"user"}\n' > "$TMP/elsewhere/x.jsonl"; touch -d "30 days ago" "$TMP/elsewhere/x.jsonl"
"$GC" --dir "$TMP/elsewhere" --days 7 >/dev/null 2>&1; rc=$?
[[ "$rc" != 0 && -f "$TMP/elsewhere/x.jsonl" ]] && ok || fail "каталог вне ~/.claude/projects принят к чистке (rc=$rc)"
"$GC" --dir "$TMP/.claude/projects/net-takogo" --days 7 >/dev/null 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok || fail "несуществующий каталог - не 0"

echo "=== без --days не запускается: срок хранения не угадывается ==="
"$GC" --dir "$DIR" >/dev/null 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok || fail "прогон без срока прошел"

echo "=== INV-RECON-21: опрос живых сессий - три исхода, а не два ==="
# Ненулевой код с пустым выводом читался как "живых нет" и уборка сносила
# транскрипты работающих сессий, отчитавшись успехом. Каждая проверка ниже
# смотрит на ДВА факта - что стало с файлами и какой код возврата получен.

# Своя песочница (свой HOME/PATH) на каждый сценарий, чтобы моки systemctl не
# пересекались друг с другом и с проверками выше.
recon_setup() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/.claude/projects/-home-x" "$d/.claude-control"
  printf '{"type":"user","message":{"content":"старый безымянный"}}\n' \
    > "$d/.claude/projects/-home-x/old-unnamed.jsonl"
  touch -d "10 days ago" "$d/.claude/projects/-home-x/old-unnamed.jsonl"
  printf '{"type":"user","message":{"content":"живая сессия"}}\n' \
    > "$d/.claude/projects/-home-x/$LIVE.jsonl"
  touch -d "30 days ago" "$d/.claude/projects/-home-x/$LIVE.jsonl"
  echo "$d"
}
# Причину ищем по ключевым словам, а не по точной фразе - формулировка в логе
# может измениться, а факт отказа должен остаться виден.
recon_reason_logged() { grep -qi "живых" "$1" 2>/dev/null && grep -qiE "отказ|не удал" "$1"; }

# Критерий 1: systemctl существует, но ненулевой код и пустой вывод.
R1="$(recon_setup)"; mkdir -p "$R1/bad-bin"
cat > "$R1/bad-bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$R1/bad-bin/systemctl"
env HOME="$R1" PATH="$R1/bad-bin:$PATH" \
  "$GC" --dir "$R1/.claude/projects/-home-x" --days 7 >/dev/null 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok || fail "INV-RECON-21: ненулевой код опроса с пустым выводом дал rc=0"
[[ -f "$R1/.claude/projects/-home-x/old-unnamed.jsonl" ]] && ok || fail "INV-RECON-21: удалил файлы при непроверенном опросе (rc=$rc)"
recon_reason_logged "$R1/.claude-control/transcript-gc.log" && ok || fail "INV-RECON-21: в логе нет причины отказа (код без вывода)"
rm -rf "$R1"

# Критерий 2: то же самое, но команда отсутствует вовсе (исключение) - теперь
# тоже обязан быть ненулевой код возврата.
R2="$(recon_setup)"; mkdir -p "$R2/fakebin"
ln -s "$(command -v python3)" "$R2/fakebin/python3"
env HOME="$R2" PATH="$R2/fakebin" \
  "$GC" --dir "$R2/.claude/projects/-home-x" --days 7 >/dev/null 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok || fail "INV-RECON-21: systemctl отсутствует, а rc=0"
[[ -f "$R2/.claude/projects/-home-x/old-unnamed.jsonl" ]] && ok || fail "INV-RECON-21: удалил файлы при отсутствующем systemctl (rc=$rc)"
recon_reason_logged "$R2/.claude-control/transcript-gc.log" && ok || fail "INV-RECON-21: в логе нет причины отказа (команда отсутствует)"
rm -rf "$R2"

# Критерий 3: нулевой код и пустой вывод - законное "живых нет", уборка идет.
R3="$(recon_setup)"; mkdir -p "$R3/bin-ok"
cat > "$R3/bin-ok/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$R3/bin-ok/systemctl"
env HOME="$R3" PATH="$R3/bin-ok:$PATH" \
  "$GC" --dir "$R3/.claude/projects/-home-x" --days 7 >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok || fail "INV-RECON-21: легитимный пустой список живых дал отказ (rc=$rc)"
[[ ! -f "$R3/.claude/projects/-home-x/old-unnamed.jsonl" ]] && ok || fail "INV-RECON-21: легитимный пустой список не почистил старье"
rm -rf "$R3"

# Критерий 4: нулевой код и непустой список - живая сессия по-прежнему цела
# (прежнее поведение), а старье все равно уходит.
R4="$(recon_setup)"; mkdir -p "$R4/bin-live"
cat > "$R4/bin-live/systemctl" <<MOCK
#!/usr/bin/env bash
case "\$*" in *list-units*) echo "ccsession-${LIVE//-/}.service loaded active running";; esac
exit 0
MOCK
chmod +x "$R4/bin-live/systemctl"
env HOME="$R4" PATH="$R4/bin-live:$PATH" \
  "$GC" --dir "$R4/.claude/projects/-home-x" --days 7 >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok || fail "INV-RECON-21: непустой список живых дал отказ (rc=$rc)"
[[ -f "$R4/.claude/projects/-home-x/$LIVE.jsonl" ]] && ok || fail "INV-RECON-21: транскрипт живой сессии удален при исправном опросе"
[[ ! -f "$R4/.claude/projects/-home-x/old-unnamed.jsonl" ]] && ok || fail "INV-RECON-21: старый безымянный не удален при исправном опросе"
rm -rf "$R4"

echo
echo "test-transcript-gc: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
