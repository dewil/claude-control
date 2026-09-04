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

echo
echo "test-transcript-gc: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
