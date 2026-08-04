#!/usr/bin/env bash
# Tests for bin/_rc_meta.py - пакетное чтение транскриптов для страницы сессий.
#
# Помощник заменяет собой связку "yq на каждую строку + grep по всему файлу":
# страница списка стоила ~120 форков (119 из них - yq в first_user_preview),
# то есть почти секунду на тап в боте. Здесь проверяется КОНТРАКТ помощника,
# а не скорость: скорость проверяется глазами, а вот совпадение с прежним
# поведением - только тестом, иначе ускорение молча меняет то, что видно в меню.
#
# Два режима:
#   rows --limit N --offset M <файлы...> -> sid \t mtime \t origin \t cwd \t preview \t путь
#   titles <файлы...>                    -> путь \t имя-сессии
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
META="$HERE/../bin/_rc_meta.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

rows()   { python3 "$META" rows "$@" 2>"$TMP/err"; }
titles() { python3 "$META" titles "$@" 2>"$TMP/err"; }

D="$TMP/t"; mkdir -p "$D"
CWD_PROJ="/home/u/proj"
CWD_WT="/home/u/proj/.claude/worktrees/wt-1"

# --- фикстуры: каждая строка транскрипта - отдельный JSON-объект ---

mk_user_array() { # <файл> <текст>
  printf '{"type":"user","message":{"content":[{"type":"text","text":%s}]},"cwd":"%s"}\n' \
    "$2" "$CWD_PROJ" > "$1"
}

echo "=== rows: превью первой человеческой реплики ==="

mk_user_array "$D/a.jsonl" '"привет мир"'
OUT="$(rows --limit 8 --offset 0 "$D/a.jsonl")"
[[ "$(awk -F'\t' 'NR==1{print NF}' <<<"$OUT")" == 6 ]] \
  && ok || fail "rows: ровно 6 полей в строке (got '$OUT')"
[[ "$(cut -f1 <<<"$OUT")" == "a" ]] && ok || fail "rows: sid = имя файла без .jsonl"
[[ "$(cut -f3 <<<"$OUT")" == "project" ]] && ok || fail "rows: origin=project для обычного cwd"
[[ "$(cut -f4 <<<"$OUT")" == "$CWD_PROJ" ]] && ok || fail "rows: cwd прочитан"
[[ "$(cut -f5 <<<"$OUT")" == "привет мир" ]] && ok || fail "rows: превью = текст первой реплики"
[[ "$(cut -f6 <<<"$OUT")" == "$D/a.jsonl" ]] && ok || fail "rows: последним полем - путь к транскрипту"
[[ "$(cut -f2 <<<"$OUT")" =~ ^[0-9]+$ ]] && ok || fail "rows: mtime - число эпохи"

echo "--- content скаляром (не массивом блоков) - тоже превью ---"
printf '{"type":"user","message":{"content":"строкой, не массивом"},"cwd":"%s"}\n' "$CWD_PROJ" \
  > "$D/scalar.jsonl"
[[ "$(rows --limit 8 --offset 0 "$D/scalar.jsonl" | cut -f5)" == "строкой, не массивом" ]] \
  && ok || fail "rows: content-строка разобрана как превью"

echo "--- результат тула (user без текстовых блоков) пропускается, берется следующая реплика ---"
{
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"вывод"}]},"cwd":"%s"}\n' "$CWD_PROJ"
  printf '{"type":"user","message":{"content":[{"type":"text","text":"настоящая первая"}]}}\n'
} > "$D/toolres.jsonl"
[[ "$(rows --limit 8 --offset 0 "$D/toolres.jsonl" | cut -f5)" == "настоящая первая" ]] \
  && ok || fail "rows: реплика без текстовых блоков не считается превью"

echo "--- несколько текстовых блоков склеиваются пробелом ---"
printf '{"type":"user","message":{"content":[{"type":"text","text":"раз"},{"type":"text","text":"два"}]},"cwd":"%s"}\n' \
  "$CWD_PROJ" > "$D/two.jsonl"
[[ "$(rows --limit 8 --offset 0 "$D/two.jsonl" | cut -f5)" == "раз два" ]] \
  && ok || fail "rows: текстовые блоки склеены пробелом"

echo "=== rows: файл без человеческой реплики выпадает из выдачи целиком ==="
printf '{"type":"summary","summary":"служебное"}\n{"type":"assistant","message":{"content":[]}}\n' \
  > "$D/lifecycle.jsonl"
# Рядом с обычным файлом, а не в одиночку: на одиночном проверка "вывод пуст"
# зеленая и когда помощник не выдал НИЧЕГО - то есть при полной поломке.
LIFE="$(rows --limit 8 --offset 0 "$D/lifecycle.jsonl" "$D/a.jsonl" | cut -f1 | tr '\n' ' ')"
[[ "$LIFE" == "a " ]] \
  && ok || fail "rows: транскрипт без реплики человека выпал, соседний остался (got '$LIFE')"

echo "=== rows: превью - недоверенный текст, TSV разъехать не имеет права ==="
mk_user_array "$D/evil.jsonl" '"злое\tимя\nвторая строка"'
EVIL="$(rows --limit 8 --offset 0 "$D/evil.jsonl")"
[[ "$(wc -l <<<"$EVIL")" == 1 ]] && ok || fail "rows: перевод строки в превью не порождает вторую строку"
[[ "$(awk -F'\t' '{print NF}' <<<"$EVIL")" == 6 ]] \
  && ok || fail "rows: таб в превью не порождает лишнее поле"
[[ "$(cut -f5 <<<"$EVIL")" == "злое имя вторая строка" ]] \
  && ok || fail "rows: таб и перевод строки заменены пробелом (got '$(cut -f5 <<<"$EVIL")')"

echo "--- управляющие символы выброшены, ведущие пробелы срезаны ---"
printf '{"type":"user","message":{"content":[{"type":"text","text":"   \\u0007с отступом"}]},"cwd":"%s"}\n' \
  "$CWD_PROJ" > "$D/ctrl.jsonl"
[[ "$(rows --limit 8 --offset 0 "$D/ctrl.jsonl" | cut -f5)" == "с отступом" ]] \
  && ok || fail "rows: BEL выброшен, ведущие пробелы срезаны (got '$(rows --limit 8 --offset 0 "$D/ctrl.jsonl" | cut -f5)')"

echo "--- превью обрезано до 120 символов (кнопка в боте, а не документ) ---"
LONG="$(python3 -c 'print("я"*300, end="")')"
mk_user_array "$D/long.jsonl" "\"$LONG\""
[[ "$(rows --limit 8 --offset 0 "$D/long.jsonl" | cut -f5 | python3 -c 'import sys; print(len(sys.stdin.readline().rstrip("\n")))')" == 120 ]] \
  && ok || fail "rows: превью обрезано до 120 СИМВОЛОВ, не байтов"

echo "=== rows: origin по cwd ==="
printf '{"type":"user","message":{"content":[{"type":"text","text":"в ворктри"}]},"cwd":"%s"}\n' \
  "$CWD_WT" > "$D/wt.jsonl"
[[ "$(rows --limit 8 --offset 0 "$D/wt.jsonl" | cut -f3)" == "worktree" ]] \
  && ok || fail "rows: cwd внутри .claude/worktrees -> origin=worktree"

echo "=== rows: порядок аргументов сохраняется, offset и limit считаются ПОСЛЕ отсева ==="
for i in 1 2 3 4; do mk_user_array "$D/s$i.jsonl" "\"реплика $i\""; done
ORDER="$(rows --limit 8 --offset 0 "$D/s3.jsonl" "$D/s1.jsonl" "$D/s2.jsonl" | cut -f1 | tr '\n' ' ')"
[[ "$ORDER" == "s3 s1 s2 " ]] && ok || fail "rows: порядок как в аргументах (got '$ORDER')"

# Служебный файл стоит МЕЖДУ обычными: если бы offset считался до отсева,
# страницы разъехались бы - в них попадало бы разное число видимых сессий.
PAGE="$(rows --limit 2 --offset 1 "$D/s1.jsonl" "$D/lifecycle.jsonl" "$D/s2.jsonl" "$D/s3.jsonl" "$D/s4.jsonl" | cut -f1 | tr '\n' ' ')"
[[ "$PAGE" == "s2 s3 " ]] && ok || fail "rows: offset пропускает видимые, а не все подряд (got '$PAGE')"

LIM="$(rows --limit 1 --offset 0 "$D/s1.jsonl" "$D/s2.jsonl" | wc -l)"
[[ "$LIM" == 1 ]] && ok || fail "rows: limit ограничивает выдачу"

echo "--- несуществующий файл в списке не роняет проход ---"
MISS="$(rows --limit 8 --offset 0 "$D/нет-такого.jsonl" "$D/s1.jsonl" | cut -f1 | tr '\n' ' ')"
[[ "$MISS" == "s1 " ]] && ok || fail "rows: пропавший файл пропущен молча (got '$MISS')"

echo "=== rows: имя файла с пробелом и с ведущим дефисом ==="
mk_user_array "$D/-минус файл.jsonl" '"край"'
DASH="$(rows --limit 8 --offset 0 "$D/-минус файл.jsonl")"
[[ "$(cut -f1 <<<"$DASH")" == "-минус файл" ]] && ok || fail "rows: sid из имени с пробелом и дефисом"
[[ "$(cut -f6 <<<"$DASH")" == "$D/-минус файл.jsonl" ]] && ok || fail "rows: путь с пробелом отдан целиком"

echo "=== titles: побеждает ПОСЛЕДНЯЯ запись custom-title ==="
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"старт"}]},"cwd":"%s"}\n' "$CWD_PROJ"
  printf '{"type":"custom-title","customTitle":"первое имя"}\n'
  printf '{"type":"custom-title","customTitle":"второе имя"}\n'
} > "$D/renamed.jsonl"
[[ "$(titles "$D/renamed.jsonl" | cut -f2)" == "второе имя" ]] \
  && ok || fail "titles: последняя запись побеждает"

echo "--- пробелы ПОСЛЕ двоеточия (не компактный JSON) тоже считаются ---"
# Ровно та терпимость, что была у grep в claude-rc: запись, дописанную не самим
# CLI, иначе прочитали бы как отсутствие имени.
printf '{"type": "custom-title", "customTitle": "с пробелами"}\n' > "$D/pretty.jsonl"
[[ "$(titles "$D/pretty.jsonl" | cut -f2)" == "с пробелами" ]] \
  && ok || fail "titles: запись с пробелами после двоеточия прочитана"

echo "--- имя санитизируется так же, как превью ---"
printf '{"type":"custom-title","customTitle":"злое\\tимя\\nстрока"}\n' > "$D/eviltitle.jsonl"
ET="$(titles "$D/eviltitle.jsonl")"
[[ "$(wc -l <<<"$ET")" == 1 ]] && ok || fail "titles: перевод строки в имени не разъезжает вывод"
[[ "$(cut -f2 <<<"$ET")" == "злое имя строка" ]] \
  && ok || fail "titles: таб и перевод строки в имени заменены пробелом"

echo "--- нет записи / пустое / null -> пустое поле, а не слово 'null' ---"
mk_user_array "$D/noname.jsonl" '"без имени"'
printf '{"type":"custom-title","customTitle":null}\n'  > "$D/nulltitle.jsonl"
printf '{"type":"custom-title","customTitle":""}\n'    > "$D/emptytitle.jsonl"
# Проверяется не только пустое имя, но и НАЛИЧИЕ строки с двумя полями: иначе
# "имя пустое" неотличимо от "помощник не выдал ничего".
empty_title() { # <файл> -> 0, если строка есть и имя в ней пусто
  local out; out="$(titles "$1")"
  [[ "$(awk -F'\t' 'END{print NR"/"NF}' <<<"$out")" == "1/2" && "$(cut -f2 <<<"$out")" == "" ]]
}
empty_title "$D/noname.jsonl"    && ok || fail "titles: нет custom-title -> строка есть, имя пусто"
empty_title "$D/nulltitle.jsonl" && ok || fail "titles: null -> строка есть, имя пусто"
empty_title "$D/emptytitle.jsonl" && ok || fail "titles: пустая строка -> строка есть, имя пусто"

echo "--- путь отдается первым полем: по нему бот сопоставляет строку с сессией ---"
[[ "$(titles "$D/renamed.jsonl" | cut -f1)" == "$D/renamed.jsonl" ]] \
  && ok || fail "titles: первым полем путь"
[[ "$(titles "$D/renamed.jsonl" "$D/noname.jsonl" | wc -l)" == 2 ]] \
  && ok || fail "titles: строка на каждый поданный файл"

echo "=== titles: имя, до которого не достает хвостовое чтение, все равно найдено ==="
# Чтение с хвоста - оптимизация (транскрипты доходят до десятков мегабайт), но
# сессия, переименованная в самом начале и с тех пор долго работавшая, держит
# запись у ГОЛОВЫ. Без отката на полный проход такая сессия молча стала бы
# безымянной - то есть неотличимой в меню от новой.
{
  printf '{"type":"custom-title","customTitle":"имя у головы"}\n'
  printf '{"type":"user","message":{"content":[{"type":"text","text":"старт"}]},"cwd":"%s"}\n' "$CWD_PROJ"
  python3 - <<'PY'
import json, sys
line = json.dumps({"type": "assistant", "message": {"content": "x" * 900}}) + "\n"
sys.stdout.write(line * 1200)   # ~1.1 МБ, заведомо больше хвостового окна
PY
} > "$D/big.jsonl"
[[ "$(stat -c %s "$D/big.jsonl" 2>/dev/null || stat -f %z "$D/big.jsonl")" -gt 1000000 ]] \
  && ok || fail "big: фикстура действительно больше хвостового окна"
[[ "$(titles "$D/big.jsonl" | cut -f2)" == "имя у головы" ]] \
  && ok || fail "titles: имя у головы большого файла найдено (откат на полный проход)"
[[ "$(rows --limit 8 --offset 0 "$D/big.jsonl" | cut -f5)" == "старт" ]] \
  && ok || fail "rows: превью в большом файле найдено"

echo "=== пустой список файлов - пустой вывод и нулевой код возврата ==="
rows --limit 8 --offset 0 >/dev/null 2>&1 && ok || fail "rows: без файлов выходит с 0"
titles >/dev/null 2>&1 && ok || fail "titles: без файлов выходит с 0"

echo
echo "test-rc-meta: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
