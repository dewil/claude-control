#!/usr/bin/env bash
# Tests for `claude-rc sessions <project> --porcelain` (V3.0 §5): машиночитаемый
# список сессий, из которого бот строит меню. Человеческое меню остается как было.
#
# Формат строки: uuid \t mtime \t origin \t cwd \t title \t live \t ctx%
# title - имя сессии (custom-title, то же что в Cursor); это НЕДОВЕРЕННЫЕ данные из
# транскрипта, поэтому проверяется санитизация: таб или перевод строки внутри имени
# не имеют права разъехать TSV, иначе бот распарсит чужой текст как поля.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/../bin/claude-rc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

export CLAUDE_CONFIG_DIR="$TMP/claude"
export CLAUDE_RC_PROJECTS_FILE="$TMP/projects.yaml"
export CLAUDE_RC_LOG_DIR="$TMP/logs"
mkdir -p "$CLAUDE_RC_LOG_DIR"

PROJ="$TMP/proj"; mkdir -p "$PROJ"
printf 'proj: %s\n' "$PROJ" > "$CLAUDE_RC_PROJECTS_FILE"
SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
TDIR="$CLAUDE_CONFIG_DIR/projects/$SLUG"
mkdir -p "$TDIR"

mk_session() { # <uuid> <первая-реплика> [<title>]
  local sid="$1" first="$2" title="${3:-}"
  {
    printf '{"type":"user","message":{"content":[{"type":"text","text":"%s"}]},"cwd":"%s"}\n' "$first" "$PROJ"
    [[ -n "$title" ]] && printf '{"type":"custom-title","customTitle":%s,"sessionId":"%s"}\n' "$title" "$sid"
  } > "$TDIR/$sid.jsonl"
}

SID_A="aaaaaaaa-1111-4111-8111-111111111111"
SID_B="bbbbbbbb-2222-4222-8222-222222222222"
SID_C="cccccccc-3333-4333-8333-333333333333"
mk_session "$SID_A" "первая"  '"сессия 1"'
mk_session "$SID_B" "вторая"  ''
# Имя с табом и переводом строки - проверка, что TSV не разъедется.
mk_session "$SID_C" "третья"  '"злое\tимя\nвторая строка"'
touch -d '2020-01-01 10:00' "$TDIR/$SID_B.jsonl"
touch -d '2020-01-02 10:00' "$TDIR/$SID_C.jsonl"
touch -d '2020-01-03 10:00' "$TDIR/$SID_A.jsonl"

# Мок systemctl: живым считается только юнит сессии A. Список активных отдаем
# одним ответом на list-units - именно так его теперь и спрашивают, по разу на
# страницу вместо двух вызовов is-active на каждую сессию.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${*}" in
  *list-units*) echo "ccsession-aaaaaaaa111141118111111111111111.service loaded active running"
                exit 0 ;;
esac
for a in "$@"; do
  case "$a" in
    ccsession-aaaaaaaa*) exit 0 ;;
    ccsession-*)         exit 3 ;;
  esac
done
exit 0
MOCK
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

OUT="$TMP/out"
"$RC" sessions proj --porcelain > "$OUT" 2>"$TMP/err"

# 1. Три строки, по одной на сессию, без шапки и подсказок.
n="$(wc -l < "$OUT")"
if [[ "$n" == 3 ]]; then ok; else fail "строк $n, ожидалось 3 ($(head -c150 "$TMP/err"))"; fi

# 2. Ровно 7 полей в каждой строке.
bad="$(awk -F'\t' 'NF!=7 {c++} END {print c+0}' "$OUT")"
if [[ "$bad" == 0 ]]; then ok; else fail "$bad строк не с 7 полями"; fi

# 3. Порядок - от свежих: A (03.01), C (02.01), B (01.01).
order="$(cut -f1 "$OUT" | cut -c1-8 | tr '\n' ',')"
if [[ "$order" == "aaaaaaaa,cccccccc,bbbbbbbb," ]]; then ok
else fail "порядок '$order', ожидался aaaaaaaa,cccccccc,bbbbbbbb,"; fi

# 4. title названной сессии - ее имя.
t_a="$(awk -F'\t' '$1 ~ /^aaaaaaaa/ {print $5}' "$OUT")"
if [[ "$t_a" == "сессия 1" ]]; then ok; else fail "title A = '$t_a'"; fi

# 5. Сессия без имени: title пустой (бот сам решит, что показать) - но поле есть.
t_b="$(awk -F'\t' '$1 ~ /^bbbbbbbb/ {print $5}' "$OUT")"
if [[ -z "$t_b" ]]; then ok; else fail "title B = '$t_b', ожидалось пустое"; fi

# 6. Злое имя санитизировано: таб и перевод строки не пролезли (строка осталась одна
#    и полей по-прежнему 6 - это уже проверено выше; здесь - что таба нет внутри).
t_c="$(awk -F'\t' '$1 ~ /^cccccccc/ {print $5}' "$OUT")"
if [[ "$t_c" == *"злое"* && "$t_c" != *$'\t'* ]]; then ok
else fail "злое имя не санитизировано: '$t_c'"; fi

# 7. live: у A юнит активен -> 1, у остальных 0.
l_a="$(awk -F'\t' '$1 ~ /^aaaaaaaa/ {print $6}' "$OUT")"
l_b="$(awk -F'\t' '$1 ~ /^bbbbbbbb/ {print $6}' "$OUT")"
if [[ "$l_a" == 1 && "$l_b" == 0 ]]; then ok; else fail "live: A=$l_a B=$l_b, ожидалось 1 и 0"; fi

# 8. Человеческое меню не сломано: без --porcelain по-прежнему есть строка [0] fresh.
"$RC" sessions proj > "$TMP/human" 2>/dev/null
if grep -q '\[0\] fresh' "$TMP/human"; then ok; else fail "человеческое меню потеряло [0] fresh"; fi

# 9. Сессия, начатая на другой машине: в транскрипте записан ЧУЖОЙ cwd (Mac-путь
#    до переезда), а сам файл лежит в слаге текущего проекта. Имя обязано читаться:
#    иначе у половины реальной истории пустое имя, и меню показывает безымянные
#    строки. Путь транскрипта выводится от каталога ПРОЕКТА, а не от записанного cwd.
SID_D="dddddddd-4444-4444-8444-444444444444"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"с мака"}]},"cwd":"/Users/dwl/Yandex.Disk/obs/2024-12 проект 1"}\n'
  printf '{"type":"custom-title","customTitle":"LLM start","sessionId":"%s"}\n' "$SID_D"
} > "$TDIR/$SID_D.jsonl"
touch -d '2020-01-04 10:00' "$TDIR/$SID_D.jsonl"
"$RC" sessions proj --porcelain > "$OUT" 2>/dev/null
t_d="$(awk -F'\t' '$1 ~ /^dddddddd/ {print $5}' "$OUT")"
if [[ "$t_d" == "LLM start" ]]; then ok
else fail "имя сессии с чужим cwd не прочиталось: '$t_d'"; fi

# 10. Проект, записанный в реестре через симлинк (или "~"), обязан отдавать те же
#     сессии. Claude Code пишет транскрипт по РЕЗОЛВНУТОМУ cwd, поэтому слаг надо
#     считать от него же; иначе список молча пуст - именно так и случилось на живом
#     реестре 2026-08-01, когда пути переписали на ~/Work/... .
LINKED="$TMP/link-to-proj"
ln -s "$PROJ" "$LINKED"
printf 'proj: %s\nlinked: %s\n' "$PROJ" "$LINKED" > "$CLAUDE_RC_PROJECTS_FILE"
"$RC" sessions linked --porcelain > "$TMP/out-linked" 2>/dev/null
n_linked="$(wc -l < "$TMP/out-linked")"
n_direct="$(wc -l < "$OUT")"
if [[ "$n_linked" == "$n_direct" && "$n_linked" != 0 ]]; then ok
else fail "проект через симлинк отдал $n_linked строк вместо $n_direct"; fi

# 11. Занятость контекста - седьмым полем. Считается по usage ПОСЛЕДНЕГО ответа
#     модели: там лежит то, что реально ушло в запрос. Сумма по всей переписке не
#     годится - она растет вечно и после сжатия не падает.
printf 'proj: %s\n' "$PROJ" > "$CLAUDE_RC_PROJECTS_FILE"
SID_E="eeeeeeee-5555-4555-8555-555555555555"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"с токенами"}]},"cwd":"%s"}\n' "$PROJ"
  printf '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":0,"output_tokens":7}}}\n'
  printf '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100000,"cache_creation_input_tokens":390,"output_tokens":7}}}\n'
} > "$TDIR/$SID_E.jsonl"
touch -d '2020-01-05 10:00' "$TDIR/$SID_E.jsonl"
CLAUDE_RC_CTX_WINDOW=200000 "$RC" sessions proj --porcelain > "$OUT" 2>/dev/null

bad="$(awk -F'\t' 'NF!=7 {c++} END {print c+0}' "$OUT")"
if [[ "$bad" == 0 ]]; then ok; else fail "$bad строк не с 7 полями"; fi

pct_e="$(awk -F'\t' '$1 ~ /^eeeeeeee/ {print $7}' "$OUT")"
if [[ "$pct_e" == 50 ]]; then ok
else fail "процент контекста '$pct_e', ожидалось 50 (100400 из 200000)"; fi

# Сессия без единого ответа модели: поле пустое, а не 0 - "не смогли посчитать"
# и "контекст пуст" читаются по-разному.
pct_a="$(awk -F'\t' '$1 ~ /^aaaaaaaa/ {print $7}' "$OUT")"
if [[ -z "$pct_a" ]]; then ok; else fail "у сессии без usage процент '$pct_a', ожидалось пустое"; fi

# Окно в миллион: те же токены дают вдесятеро меньший процент. Гадать по
# наблюдаемому максимуму нельзя - сессия на миллионе показала бы 50% там, где
# занято 10, и человек погнал бы сжимать зря.
CLAUDE_RC_CTX_WINDOW=1000000 "$RC" sessions proj --porcelain > "$TMP/out-1m" 2>/dev/null
pct_1m="$(awk -F'\t' '$1 ~ /^eeeeeeee/ {print $7}' "$TMP/out-1m")"
if [[ "$pct_1m" == 10 ]]; then ok; else fail "при окне 1M процент '$pct_1m', ожидалось 10"; fi

# 12. Постраничность: --offset пропускает уже показанные, --limit режет страницу.
#     Без этого сессии за первым десятком недостижимы вовсе - кнопок на них нет.
"$RC" sessions proj --porcelain --limit 2 > "$TMP/p0" 2>/dev/null
"$RC" sessions proj --porcelain --limit 2 --offset 2 > "$TMP/p1" 2>/dev/null
if [[ "$(wc -l < "$TMP/p0")" == 2 && "$(wc -l < "$TMP/p1")" == 2 ]]; then ok
else fail "страницы не по 2 строки: $(wc -l < "$TMP/p0") и $(wc -l < "$TMP/p1")"; fi

# Страницы не пересекаются и идут подряд по тому же порядку, что и без пагинации.
"$RC" sessions proj --porcelain --limit 4 > "$TMP/all" 2>/dev/null
if [[ "$(cut -f1 "$TMP/p0"; cut -f1 "$TMP/p1")" == "$(cut -f1 "$TMP/all")" ]]; then ok
else fail "склейка страниц не совпала со сплошным списком"; fi

# Offset за концом списка - пусто и код 0, а не ошибка: последняя страница
# должна быть проходимой без гадания, сколько всего сессий.
"$RC" sessions proj --porcelain --offset 999 > "$TMP/pN" 2>/dev/null
rc_far=$?
if [[ "$rc_far" == 0 && ! -s "$TMP/pN" ]]; then ok
else fail "offset за концом: rc=$rc_far, строк $(wc -l < "$TMP/pN")"; fi

# Мусорные значения не превращаются в "показать все" или в падение.
"$RC" sessions proj --porcelain --offset ой --limit 2 > "$TMP/pBad" 2>/dev/null
if [[ "$(wc -l < "$TMP/pBad")" == 2 ]]; then ok
else fail "мусорный offset сломал выдачу: $(wc -l < "$TMP/pBad") строк"; fi

# 13. `--only <id>` - одна сессия по короткому или полному id, БЕЗ обхода всего
#     списка. Без этого бот на каждый тап поднимал весь список проекта, чтобы
#     найти в нем одну строку: 10,5 с на сотне сессий (замер 2026-08-03).
"$RC" sessions proj --porcelain --only "${SID_A:0:8}" > "$TMP/only" 2>/dev/null
if [[ "$(wc -l < "$TMP/only")" == 1 ]]; then ok
else fail "--only отдал $(wc -l < "$TMP/only") строк вместо одной"; fi
if [[ "$(cut -f1 "$TMP/only")" == "$SID_A" ]]; then ok
else fail "--only нашел не ту сессию: $(cut -f1 "$TMP/only")"; fi
if [[ "$(awk -F'\t' '{print NF}' "$TMP/only")" == 7 ]]; then ok
else fail "--only отдал строку не в 7 полей"; fi
if [[ "$(cut -f5 "$TMP/only")" == "сессия 1" ]]; then ok
else fail "--only потерял имя: '$(cut -f5 "$TMP/only")'"; fi

# Полный uuid тоже принимается - бот знает и его.
"$RC" sessions proj --porcelain --only "$SID_A" > "$TMP/only2" 2>/dev/null
if [[ "$(cut -f1 "$TMP/only2")" == "$SID_A" ]]; then ok
else fail "--only по полному uuid не нашел сессию"; fi

# Сессия из глубины списка достается так же - тот самый случай, когда подъем со
# второй страницы отвечал "No such session".
"$RC" sessions proj --porcelain --only "${SID_E:0:8}" > "$TMP/only3" 2>/dev/null
if [[ "$(cut -f1 "$TMP/only3")" == "$SID_E" ]]; then ok
else fail "--only не достал сессию из глубины"; fi

# Несуществующий и мусорный id - пусто и код 0: это не авария, это "нет такой".
"$RC" sessions proj --porcelain --only "ffffffff" > "$TMP/only4" 2>/dev/null
if [[ ! -s "$TMP/only4" ]]; then ok; else fail "--only выдумал сессию"; fi
"$RC" sessions proj --porcelain --only 'ой; rm -rf /' > "$TMP/only5" 2>/dev/null
if [[ ! -s "$TMP/only5" ]]; then ok; else fail "--only принял мусорный id"; fi

# 14. Пустой usage не считается ответом модели. После сжатия CLI дописывает
#     запись, где все счетчики нулевые; если брать ее как последнюю, занятость
#     показывается как 0% - то есть сессия на 74% выглядит пустой.
SID_Z="7777777f-7777-4777-8777-777777777777"
{
  printf '{"type":"user","message":{"content":[{"type":"text","text":"с нулем"}]},"cwd":"%s"}\n' "$PROJ"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":80000,"cache_creation_input_tokens":0,"output_tokens":7}}}\n'
  printf '{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}\n'
} > "$TDIR/$SID_Z.jsonl"
CLAUDE_RC_CTX_WINDOW=200000 "$RC" sessions proj --porcelain --only "${SID_Z:0:8}" > "$TMP/zero" 2>/dev/null
if [[ "$(cut -f7 "$TMP/zero")" == 40 ]]; then ok
else fail "нулевая запись принята за последний ответ: '$(cut -f7 "$TMP/zero")'"; fi

# 15. Человеческое меню и `last` печатают ПРЕВЬЮ, а не превью с приклеенным
#     путем к транскрипту. Строка списка несет шесть полей, а читалась в пять
#     переменных - последняя забирает остаток вместе с разделителем, и путь
#     вылезал в вывод для человека (тот же класс, что унес путь в чужую
#     переменную в --only).
"$RC" sessions proj > "$TMP/menu" 2>/dev/null
if ! grep -q '\.jsonl' "$TMP/menu"; then ok
else fail "меню печатает путь к транскрипту: $(grep -m1 '\.jsonl' "$TMP/menu" | cut -c1-90)"; fi
"$RC" last proj > "$TMP/lastout" 2>/dev/null
if ! grep -q '\.jsonl' "$TMP/lastout"; then ok
else fail "last печатает путь к транскрипту: $(grep -m1 '\.jsonl' "$TMP/lastout" | cut -c1-90)"; fi

echo "test-rc-sessions-porcelain: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
