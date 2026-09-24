#!/usr/bin/env bash
# Тесты вслепую по спеке docs/dev/2026-09-24-spec-openrouter-balance.md.
# Тег группы - INV-LIM-14. Реализации (build_openrouter, openrouter_alerts)
# еще нет - весь прогон обязан быть КРАСНЫМ; это ожидаемо и не чинится
# правкой теста.
#
# Сеть не трогаем: http_get подменяется в каждом python-блоке заглушкой.
# Модуль bin/claude-agent-limits-digest (без расширения) импортируется через
# importlib.machinery.SourceFileLoader, как в tests/test-agent-tgbot.sh -
# spec_from_file_location без явного loader'а файл без .py не опознает.
#
# CONTROL_DIR и LIMITS_OPENROUTER_KEY_FILE читаются модулем на этапе импорта
# (как существующий CONTROL_DIR/CACHE_FILE), поэтому переменные окружения
# выставляются в bash ДО запуска python3 - каждый python-блок получает свой
# набор путей через отдельный env для подпроцесса, а не общий CONTROL_DIR.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin/claude-agent-limits-digest"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

run_block() {
  # $1 - имя python-файла в TMP, $2 - CONTROL_DIR, $3 - KEY_FILE (может не
  # существовать - это сам по себе сценарий "не настроен").
  local pyfile="$1" control_dir="$2" key_file="$3"
  local out="$TMP/$(basename "$pyfile").out" err="$TMP/$(basename "$pyfile").err"
  mkdir -p "$control_dir"
  BIN_PATH="$BIN" OR_CONTROL_DIR="$control_dir" OR_KEY_FILE="$key_file" \
    CLAUDE_CONTROL_DIR="$control_dir" LIMITS_OPENROUTER_KEY_FILE="$key_file" \
    python3 "$pyfile" >"$out" 2>"$err"
  local rc=$?
  if [[ "$rc" != 0 ]]; then
    fail "INV-LIM-14 $(basename "$pyfile"): обвязка упала (код $rc) - см. stderr ниже"
  fi
  if [[ ! -s "$out" ]]; then
    fail "INV-LIM-14 $(basename "$pyfile"): не напечатано ни одного PASS/FAIL (см. stderr)"
  else
    while IFS= read -r line; do
      case "$line" in
        "PASS "*) ok ;;
        "FAIL "*) fail "${line#FAIL }" ;;
      esac
    done < "$out"
  fi
  [[ -s "$err" ]] && cat "$err" >&2
}

SECRET="sk-or-SECRET-test-123"
export OR_SECRET="$SECRET"

# ===========================================================================
# ORMAIN: нарратив одного счета во времени - критерии 1, 2, 3, 4, 6, 11(part),
# 12. Один и тот же CONTROL_DIR/KEY_FILE на весь блок: history накапливается
# последовательными вызовами build_openrouter(now=...), как советует бриф
# ("серия вызовов с now через 15 минут/сутки строит историю").
# ===========================================================================
ORMAIN="$TMP/ormain.py"
cat > "$ORMAIN" <<'PY'
import importlib.machinery, importlib.util, json, os, re, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
CONTROL_DIR = os.environ["OR_CONTROL_DIR"]
loader = importlib.machinery.SourceFileLoader("limits_or_main", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_or_main", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

SECRET = os.environ["OR_SECRET"]

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    # Как в test-agent-tgbot.sh: один упавший сценарий не маскирует остальные.
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

logs = []
mod.log = lambda m: logs.append(m)

calls = []
def make_stub(queue):
    def stub(url, headers, proxy):
        calls.append(url)
        if queue:
            return queue.pop(0)
        return (200, {"data": {"total_credits": 0, "total_usage": 0}})
    return stub

def dollar_present(text, value):
    # "$9.21" как в примере панели спеки - ищем именно отформатированную
    # сумму, а не голое число (могло бы совпасть случайно с другим полем).
    return ("$%.2f" % value) in text

def s_functions_exist():
    # Не блокирует остальные сценарии (в отличие от отдельных ORxxx-блоков,
    # где build_openrouter обязателен) - digits_signature ниже существует уже
    # сейчас и должна проверяться независимо от секции openrouter.
    record("INV-LIM-14 build_openrouter существует", hasattr(mod, "build_openrouter"))
    record("INV-LIM-14 openrouter_alerts существует", hasattr(mod, "openrouter_alerts"))
scenario("проверка наличия точек входа", s_functions_exist)

t0 = datetime(2026, 9, 24, 3, 17, 0, tzinfo=timezone.utc)

# --- шаг 1 (критерии 1, 2): первый опрос, без истории ----------------------
def s_first_poll():
    mod.http_get = make_stub([(200, {"data": {"total_credits": 10.00, "total_usage": 0.79}})])
    section = mod.build_openrouter(now=t0)
    record("критерий 1: build_openrouter вернул словарь секции", isinstance(section, dict))
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t0)
    record("критерий 1: остаток $9.21 (10.00 - 0.79) в рендере",
           dollar_present(rendered, 9.21))
    record("критерий 1: полная сумма $10 (или $10.00) в рендере",
           re.search(r"\$10(\.00)?\b", rendered) is not None)
    record("критерий 2: первый запуск подписан 'с начала учета'",
           "с начала учета" in rendered)
    record("критерий 1/9: блок не показывает $0.00 при живом балансе",
           "$0.00" not in rendered)
    return section, rendered

section0, rendered0 = None, None
def run_first():
    global section0, rendered0
    section0, rendered0 = s_first_poll()
scenario("шаг 1: первый опрос без истории", run_first)

# --- шаг 2 (критерий 6): второй опрос через 15 минут - истории < суток -----
def s_short_history():
    mod.http_get = make_stub([(200, {"data": {"total_credits": 10.00, "total_usage": 0.85}})])
    section = mod.build_openrouter(now=t0 + timedelta(minutes=15))
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t0 + timedelta(minutes=15))
    record("критерий 6: истории меньше суток -> 'копим историю'",
           "копим историю" in rendered)
scenario("шаг 2: истории меньше суток", s_short_history)

# --- шаг 3 (критерий 5 частично, история >= суток): расход появляется ------
t3 = t0 + timedelta(hours=25)
def s_day_history():
    mod.http_get = make_stub([(200, {"data": {"total_credits": 10.00, "total_usage": 1.79}})])
    section = mod.build_openrouter(now=t3)
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t3)
    record("история от суток: расход больше не 'копим историю'",
           "копим историю" not in rendered)
    record("история от суток: строка расхода с числом (сутки $...)",
           re.search(r"сутки\s*\$\d", rendered) is not None)
scenario("шаг 3: история от суток дает расход", s_day_history)

# --- шаг 4 (критерий 3): рост total_credits - новая полная шкала -----------
t4 = t0 + timedelta(hours=26)
def s_payment():
    mod.http_get = make_stub([(200, {"data": {"total_credits": 20.00, "total_usage": 1.80}})])
    section = mod.build_openrouter(now=t4)
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t4)
    record("критерий 3: остаток после пополнения $18.20 (20.00 - 1.80)",
           dollar_present(rendered, 18.20))
    record("критерий 3: шкала полная сразу после пополнения ($18.20 из $18.20)",
           re.search(r"\$18\.20\D+\$18\.20", rendered) is not None)
    record("критерий 3: подпись пополнения с датой (дд.мм)",
           re.search(r"пополнение\s+\d{2}\.\d{2}", rendered) is not None)
scenario("шаг 4: рост total_credits - новая шкала", s_payment)

# --- шаг 5 (критерий 4): уменьшение total_credits - НЕ платеж ---------------
t5 = t0 + timedelta(hours=27)
def s_decrease():
    logs_before = len(logs)
    mod.http_get = make_stub([(200, {"data": {"total_credits": 15.00, "total_usage": 1.81}})])
    section = mod.build_openrouter(now=t5)
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t5)
    record("критерий 4: остаток после уменьшения $13.19 (15.00 - 1.81)",
           dollar_present(rendered, 13.19))
    record("критерий 4: уменьшение total_credits пишет строку в лог",
           len(logs) > logs_before)
scenario("шаг 5: уменьшение total_credits - не платеж", s_decrease)

# --- шаг 6: шкала после уменьшения = остаток НА МОМЕНТ уменьшения, а не
# текущий total_credits (15.00) и не старая шкала платежа (20.00/18.20) -----
t6 = t0 + timedelta(hours=27, minutes=15)
def s_scale_after_decrease():
    mod.http_get = make_stub([(200, {"data": {"total_credits": 15.00, "total_usage": 1.91}})])
    section = mod.build_openrouter(now=t6)
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t6)
    record("критерий 4: шкала после уменьшения зафиксирована на $13.19, "
           "не на текущих total_credits ($15) и не на прежнем платеже ($18.20/$20)",
           "из $13.19" in rendered.replace("\n", " "))
scenario("шаг 6: шкала после уменьшения не платеж и не сырой total_credits",
        s_scale_after_decrease)

# --- критерий 12: секция openrouter не влияет на digits_signature ----------
def s_digits_signature():
    snap_a = {"claude": {"status": "ok", "five_hour": {"remaining": 80}},
              "codex": {"status": "ok", "seven_day": {"remaining": 40}}}
    snap_b = dict(snap_a)
    snap_b["openrouter"] = section0 if isinstance(section0, dict) else {"status": "ok"}
    sig_a = mod.digits_signature(snap_a)
    sig_b = mod.digits_signature(snap_b)
    record("критерий 12: digits_signature одинакова с секцией openrouter и без",
           sig_a == sig_b)
scenario("критерий 12: digits_signature не зависит от openrouter", s_digits_signature)

# --- критерий 11: ключ не появляется ни в рендере, ни в логе, ни в state ---
def s_no_secret_leak():
    all_rendered = " ".join([rendered0 or ""])
    record("критерий 11: секрета нет в рендере панели", SECRET not in all_rendered)
    record("критерий 11: секрета нет в перехваченных строках log()",
           SECRET not in " ".join(str(l) for l in logs))
    state_path = os.path.join(CONTROL_DIR, "limits", "openrouter-state.json")
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as fh:
            state_text = fh.read()
        record("критерий 11: секрета нет в файле состояния", SECRET not in state_text)
    else:
        record("критерий 11: файл состояния создан (иначе проверку "
               "содержимого не выполнить)", False)
scenario("критерий 11: ключ не течет в рендер/лог/state", s_no_secret_leak)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
KEY_MAIN="$TMP/keys/main-key"
mkdir -p "$(dirname "$KEY_MAIN")"
printf '%s\n' "$SECRET" > "$KEY_MAIN"
run_block "$ORMAIN" "$TMP/control-main" "$KEY_MAIN"

# ===========================================================================
# ORSPEND: критерий 5 - расход считается по total_usage счета из истории,
# НЕ по usage_daily/usage_weekly из /api/v1/key (эти поля - на другой ключ).
# Подсовываем в ответ /key заведомо другие (огромные) числа и проверяем, что
# они не попадают в рендер.
# ===========================================================================
ORSPEND="$TMP/orspend.py"
cat > "$ORSPEND" <<'PY'
import importlib.machinery, importlib.util, os, re, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_or_spend", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_or_spend", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

mod.log = lambda m: None

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

if not hasattr(mod, "build_openrouter"):
    print("FAIL INV-LIM-14 критерий 5: build_openrouter отсутствует (RED)")
    sys.exit(0)

calls = {"n": 0}
def fake_http_get(url, headers, proxy):
    calls["n"] += 1
    u = url.lower()
    if "key" in u and "credit" not in u:
        # заведомо другие числа - если реализация читает их, тест это поймает
        return (200, {"data": {"usage_daily": 999.0, "usage_weekly": 9999.0,
                                "label": "wrong-key-endpoint"}})
    if calls["n"] == 1:
        return (200, {"data": {"total_credits": 5.00, "total_usage": 1.00}})
    return (200, {"data": {"total_credits": 5.00, "total_usage": 1.50}})

mod.http_get = fake_http_get

t0 = datetime(2026, 9, 24, 0, 0, 0, tzinfo=timezone.utc)
def s_baseline():
    mod.build_openrouter(now=t0)
scenario("критерий 5: базовый опрос (история)", s_baseline)

def s_day_later():
    section = mod.build_openrouter(now=t0 + timedelta(hours=24))
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t0 + timedelta(hours=24))
    record("критерий 5: числа /key (999/9999) не попали в рендер",
           "999" not in rendered and "9999" not in rendered)
    record("критерий 5: расход посчитан по счету ($0.50 за сутки из "
           "total_usage 1.00->1.50), не по /key",
           re.search(r"сутки\s*\$0\.50\b", rendered) is not None)
scenario("критерий 5: расход через сутки - из истории счета, не из /key",
        s_day_later)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
KEY_SPEND="$TMP/keys/spend-key"
mkdir -p "$(dirname "$KEY_SPEND")"
printf '%s\n' "$SECRET" > "$KEY_SPEND"
run_block "$ORSPEND" "$TMP/control-spend" "$KEY_SPEND"

# ===========================================================================
# ORZERO: критерий 7 - нулевой расход не делит на ноль и говорит
# "расход не идет".
# ===========================================================================
ORZERO="$TMP/orzero.py"
cat > "$ORZERO" <<'PY'
import importlib.machinery, importlib.util, os, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_or_zero", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_or_zero", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.log = lambda m: None

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

if not hasattr(mod, "build_openrouter"):
    print("FAIL INV-LIM-14 критерий 7: build_openrouter отсутствует (RED)")
    sys.exit(0)

t0 = datetime(2026, 9, 24, 0, 0, 0, tzinfo=timezone.utc)
def s_zero_spend():
    mod.http_get = lambda url, headers, proxy: (
        200, {"data": {"total_credits": 3.00, "total_usage": 1.00}})
    mod.build_openrouter(now=t0)
    # тот же total_usage сутки спустя - расход ровно ноль
    section = mod.build_openrouter(now=t0 + timedelta(hours=24))
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t0 + timedelta(hours=24))
    record("критерий 7: нулевой расход -> 'расход не идет'",
           "расход не идет" in rendered)
scenario("критерий 7: нулевой расход, без деления на ноль", s_zero_spend)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
KEY_ZERO="$TMP/keys/zero-key"
mkdir -p "$(dirname "$KEY_ZERO")"
printf '%s\n' "$SECRET" > "$KEY_ZERO"
run_block "$ORZERO" "$TMP/control-zero" "$KEY_ZERO"

# ===========================================================================
# ORFAIL: критерий 9 - три вида отказа (401, таймаут-как-статус-0, битый
# JSON) не показывают $0 и показывают последний известный остаток со
# временем замера. Плюс критерий 11 (секрет не течет в текст ошибки).
# ===========================================================================
ORFAIL="$TMP/orfail.py"
cat > "$ORFAIL" <<'PY'
import importlib.machinery, importlib.util, json, os, re, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
CONTROL_DIR = os.environ["OR_CONTROL_DIR"]
loader = importlib.machinery.SourceFileLoader("limits_or_fail", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_or_fail", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

SECRET = os.environ["OR_SECRET"]
logs = []
mod.log = lambda m: logs.append(m)

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

if not hasattr(mod, "build_openrouter"):
    print("FAIL INV-LIM-14 критерий 9: build_openrouter отсутствует (RED)")
    sys.exit(0)

t0 = datetime(2026, 9, 24, 3, 17, 0, tzinfo=timezone.utc)

def make_good():
    return lambda url, headers, proxy: (
        200, {"data": {"total_credits": 8.50, "total_usage": 2.13}})

def run_case(label, bad_response, now_fail):
    mod.http_get = make_good()
    mod.build_openrouter(now=t0)  # успешный опрос - остаток $6.37
    mod.http_get = lambda url, headers, proxy: bad_response
    section = mod.build_openrouter(now=now_fail)
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=now_fail)
    record("критерий 9 (%s): блок 'нет данных'" % label,
           "нет данных" in rendered)
    record("критерий 9 (%s): последний известный остаток $6.37 показан"
           % label, "$6.37" in rendered)
    record("критерий 9 (%s): не показывает $0.00" % label,
           "$0.00" not in rendered and "$0 " not in rendered)
    # Время и сумма последнего успешного замера - из state["last_ok"], а не
    # эвристикой по тексту (схема зафиксирована спекой 24.09.2026, правка по
    # вопросу 2 из первого отчета тестов).
    state_path = os.path.join(CONTROL_DIR, "limits", "openrouter-state.json")
    last_ok = None
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as fh:
            last_ok = json.load(fh).get("last_ok")
    record("критерий 9 (%s): state['last_ok'] заполнен последним успешным "
           "замером" % label, isinstance(last_ok, dict))
    if isinstance(last_ok, dict):
        at = mod.parse_iso(last_ok.get("at"))
        record("критерий 9 (%s): state['last_ok']['at'] - время УСПЕШНОГО "
               "опроса (t0=03:17), а не время отказа" % label,
               at is not None and at == t0)
        record("критерий 9 (%s): state['last_ok']['balance'] == 6.37 "
               "(последний известный остаток, не 0)" % label,
               isinstance(last_ok.get("balance"), (int, float))
               and abs(last_ok["balance"] - 6.37) < 0.01)
    record("критерий 11 (%s): секрет не течет в текст ошибки/рендер/last_ok"
           % label, SECRET not in rendered and SECRET not in str(section)
           and SECRET not in str(last_ok))

scenario("критерий 9: отказ 401", lambda: run_case(
    "401", (401, None), t0 + timedelta(minutes=15)))
scenario("критерий 9: отказ таймаут (статус 0)", lambda: run_case(
    "timeout", (0, None), t0 + timedelta(minutes=30)))
scenario("критерий 9: битый JSON (200, но не тот формат)", lambda: run_case(
    "bad-json", (200, {"unexpected": "shape"}), t0 + timedelta(minutes=45)))

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
KEY_FAIL="$TMP/keys/fail-key"
mkdir -p "$(dirname "$KEY_FAIL")"
printf '%s\n' "$SECRET" > "$KEY_FAIL"
run_block "$ORFAIL" "$TMP/control-fail" "$KEY_FAIL"

# ===========================================================================
# ORNOKEY: критерий 10 - нет файла ключа: блока нет, ошибки в логе нет.
# Собственный процесс: LIMITS_OPENROUTER_KEY_FILE указывает на несуществующий
# путь.
# ===========================================================================
ORNOKEY="$TMP/ornokey.py"
cat > "$ORNOKEY" <<'PY'
import importlib.machinery, importlib.util, os, sys

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_or_nokey", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_or_nokey", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

logs = []
mod.log = lambda m: logs.append(m)

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

if not hasattr(mod, "build_openrouter"):
    print("FAIL INV-LIM-14 критерий 10: build_openrouter отсутствует (RED)")
    sys.exit(0)

def s_no_key_file():
    def stub(url, headers, proxy):
        raise AssertionError("http_get не должен вызываться без файла ключа")
    mod.http_get = stub
    section = mod.build_openrouter()
    record("критерий 10: без файла ключа build_openrouter возвращает None",
           section is None)
    record("критерий 10: отсутствие ключа не пишет в лог (это не сбой)",
           logs == [])

scenario("критерий 10: нет файла ключа", s_no_key_file)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$ORNOKEY" "$TMP/control-nokey" "$TMP/no-such-key-file"

# ===========================================================================
# ORALERTS: критерии 8 и 13. Прогноз меньше 3 суток дает ⚠/"пора пополнить" в
# панели и ОДНО отдельное сообщение при первом пересечении; три отказа
# подряд (~45 мин) дают ОДНО сообщение; повторные вызовы при том же условии -
# пустой список; восстановление - ОДНО сообщение.
# ===========================================================================
ORALERTS="$TMP/oralerts.py"
cat > "$ORALERTS" <<'PY'
import importlib.machinery, importlib.util, os, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_or_alerts", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_or_alerts", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.log = lambda m: None

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

if not hasattr(mod, "build_openrouter") or not hasattr(mod, "openrouter_alerts"):
    print("FAIL INV-LIM-14 критерии 8/13: build_openrouter/openrouter_alerts "
          "отсутствуют (RED)")
    sys.exit(0)

t0 = datetime(2026, 9, 24, 0, 0, 0, tzinfo=timezone.utc)

# --- порог прогноза: день0 - база, день1 - расход $90/сутки при остатке
# $10 -> прогноз ~0.11 дня < 3 -----------------------------------------------
def s_threshold_first_cross():
    mod.http_get = lambda url, headers, proxy: (
        200, {"data": {"total_credits": 100.00, "total_usage": 0.00}})
    mod.build_openrouter(now=t0)  # база, история < суток
    mod.http_get = lambda url, headers, proxy: (
        200, {"data": {"total_credits": 100.00, "total_usage": 90.00}})
    t1 = t0 + timedelta(hours=24)
    section = mod.build_openrouter(now=t1)
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t1)
    record("критерий 8: прогноз < 3 суток - метка ⚠ в панели", "⚠" in rendered)
    record("критерий 8: прогноз < 3 суток - 'пора пополнить' в панели",
           "пора пополнить" in rendered)
    msgs1 = mod.openrouter_alerts(section, now=t1)
    record("критерий 13: первое пересечение порога дает ровно одно сообщение",
           len(msgs1) == 1)
    # повторный вызов при том же условии (тот же now, то же состояние) -
    # дедуп, сообщение не повторяется.
    msgs1b = mod.openrouter_alerts(section, now=t1)
    record("критерий 13: повторный вызов при том же пересечении - пусто",
           msgs1b == [])
    # следующий опрос все еще ниже порога - тоже не должно повторяться.
    mod.http_get = lambda url, headers, proxy: (
        200, {"data": {"total_credits": 100.00, "total_usage": 90.20}})
    t1b = t1 + timedelta(minutes=15)
    section2 = mod.build_openrouter(now=t1b)
    msgs2 = mod.openrouter_alerts(section2, now=t1b)
    record("критерий 13: следующий опрос все еще ниже порога - без повтора",
           msgs2 == [])
    return t1b

t_after_threshold = None
def run_threshold():
    global t_after_threshold
    t_after_threshold = s_threshold_first_cross()
scenario("критерии 8/13: первое пересечение порога прогноза", run_threshold)

# --- восстановление: платеж поднимает остаток и прогноз выше порога --------
def s_recovery_from_threshold():
    t2 = t_after_threshold + timedelta(hours=1)
    mod.http_get = lambda url, headers, proxy: (
        200, {"data": {"total_credits": 500.00, "total_usage": 90.50}})
    section = mod.build_openrouter(now=t2)
    envelope = {"snapshot": {"openrouter": section}}
    rendered = mod.render(envelope, now=t2)
    record("восстановление: панель больше не показывает 'пора пополнить'",
           "пора пополнить" not in rendered)
    msgs = mod.openrouter_alerts(section, now=t2)
    record("критерий 13: восстановление после порога дает ровно одно "
           "сообщение", len(msgs) == 1)
    msgs2 = mod.openrouter_alerts(section, now=t2)
    record("критерий 13: повторный вызов после восстановления - пусто",
           msgs2 == [])
scenario("критерий 13: восстановление после порога прогноза",
        s_recovery_from_threshold)

# --- три отказа подряд (~45 мин) - отдельное состояние ----------------------
def s_three_failures_alert():
    t0f = datetime(2026, 9, 25, 0, 0, 0, tzinfo=timezone.utc)
    mod.http_get = lambda url, headers, proxy: (
        200, {"data": {"total_credits": 50.00, "total_usage": 1.00}})
    mod.build_openrouter(now=t0f)
    mod.http_get = lambda url, headers, proxy: (0, None)
    s1 = mod.build_openrouter(now=t0f + timedelta(minutes=15))
    m1 = mod.openrouter_alerts(s1, now=t0f + timedelta(minutes=15))
    record("критерий 13: первый отказ подряд - без сообщения", m1 == [])
    s2 = mod.build_openrouter(now=t0f + timedelta(minutes=30))
    m2 = mod.openrouter_alerts(s2, now=t0f + timedelta(minutes=30))
    record("критерий 13: второй отказ подряд - без сообщения", m2 == [])
    s3 = mod.build_openrouter(now=t0f + timedelta(minutes=45))
    m3 = mod.openrouter_alerts(s3, now=t0f + timedelta(minutes=45))
    record("критерий 13: третий отказ подряд (~45 мин) - ровно одно "
           "сообщение", len(m3) == 1)
    m3b = mod.openrouter_alerts(s3, now=t0f + timedelta(minutes=45))
    record("критерий 13: повторный вызов при том же отказе - пусто",
           m3b == [])
    # восстановление после серии отказов
    mod.http_get = lambda url, headers, proxy: (
        200, {"data": {"total_credits": 50.00, "total_usage": 1.10}})
    s4 = mod.build_openrouter(now=t0f + timedelta(minutes=60))
    m4 = mod.openrouter_alerts(s4, now=t0f + timedelta(minutes=60))
    record("критерий 13: восстановление после серии отказов - ровно одно "
           "сообщение", len(m4) == 1)

scenario("критерий 13: три отказа подряд и восстановление",
        s_three_failures_alert)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
KEY_ALERTS="$TMP/keys/alerts-key"
mkdir -p "$(dirname "$KEY_ALERTS")"
printf '%s\n' "$SECRET" > "$KEY_ALERTS"
run_block "$ORALERTS" "$TMP/control-alerts" "$KEY_ALERTS"

# ===========================================================================
# ORHISTORY: критерий 14 - история обрезается до 8 суток, граница
# включительная. Схема state зафиксирована спекой (правка 24.09.2026, раздел
# "Точки входа", пункт "Схема состояния зафиксирована в минимуме"):
# state["history"] - список {"at", "total_credits", "total_usage"} по
# времени, state["last_ok"] - {"at", "balance"} последнего успешного замера
# или null. Обрезка - по ВОЗРАСТУ записи (at не старше 8 суток от now), а не
# по числу записей: при суточных замерах и включительной границе корректная
# реализация оставляет 9 записей (дни 3..11 при последнем now на дне 11), а
# не 8 - поэтому проверяем возраст напрямую, а не длину списка.
# ===========================================================================
ORHISTORY="$TMP/orhistory.py"
cat > "$ORHISTORY" <<'PY'
import importlib.machinery, importlib.util, json, os, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
CONTROL_DIR = os.environ["OR_CONTROL_DIR"]
loader = importlib.machinery.SourceFileLoader("limits_or_hist", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_or_hist", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.log = lambda m: None

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

if not hasattr(mod, "build_openrouter"):
    print("FAIL INV-LIM-14 критерий 14: build_openrouter отсутствует (RED)")
    sys.exit(0)

def s_history_trim():
    t0 = datetime(2026, 9, 1, 0, 0, 0, tzinfo=timezone.utc)
    last_now = t0 + timedelta(days=11)
    # 12 суточных замеров, дни 0..11 - последний опрос last_now (день 11).
    # Граница включительная: замер 8-суточной давности (день 3) обязан
    # остаться, 9-суточной (день 2) - обязан быть удален.
    for day in range(12):
        mod.http_get = lambda url, headers, proxy, d=day: (
            200, {"data": {"total_credits": 1000.00, "total_usage": float(d)}})
        mod.build_openrouter(now=t0 + timedelta(days=day))
    state_path = os.path.join(CONTROL_DIR, "limits", "openrouter-state.json")
    record("критерий 14: файл состояния создан", os.path.exists(state_path))
    if not os.path.exists(state_path):
        return
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)
    history = state.get("history")
    record("критерий 14: state['history'] - список", isinstance(history, list))
    if not isinstance(history, list):
        return
    ages_days = []
    day3_present = False
    day2_present = False
    for entry in history:
        at = mod.parse_iso(entry.get("at")) if isinstance(entry, dict) else None
        if at is None:
            continue
        age = (last_now - at).total_seconds() / 86400.0
        ages_days.append(age)
        if abs(age - 8.0) < 0.01:
            day3_present = True
        if abs(age - 9.0) < 0.01:
            day2_present = True
    record("критерий 14: во всех оставленных записях возраст не старше 8 "
           "суток от последнего now (макс. найденный возраст: %.2f)"
           % (max(ages_days) if ages_days else -1),
           bool(ages_days) and max(ages_days) <= 8.0 + 1e-6)
    record("критерий 14: замер ровно 8-суточной давности (день 3) сохранен "
           "- пин на включительную границу", day3_present)
    record("критерий 14: замер 9-суточной давности (день 2) удален",
           not day2_present)

scenario("критерий 14: история обрезается до 8 суток (включительно)",
        s_history_trim)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
KEY_HISTORY="$TMP/keys/history-key"
mkdir -p "$(dirname "$KEY_HISTORY")"
printf '%s\n' "$SECRET" > "$KEY_HISTORY"
run_block "$ORHISTORY" "$TMP/control-history" "$KEY_HISTORY"

# ===========================================================================
# критерий 15: существующий selftest дайджеста остается зеленым. Отдельный
# процесс, свой HOME/CONTROL_DIR - не трогаем то, что использовали выше.
# ===========================================================================
export HOME="$TMP/home-selftest"
mkdir -p "$HOME"
if CLAUDE_CONTROL_DIR="$TMP/control-selftest" "$BIN" selftest >"$TMP/selftest.out" 2>"$TMP/selftest.err"; then
  ok
else
  fail "критерий 15: bin/claude-agent-limits-digest selftest сломан (см. stderr ниже)"
  cat "$TMP/selftest.err" >&2
fi

echo
# --- INV-LIM-14, критерий 16 (добавлен 24.09.2026 основным агентом, НЕ
# вслепую): сбой отправки отдельного сообщения откатывает признак события.
# Иначе предупреждение "деньги кончаются" теряется навсегда: флаг ставится
# до отправки, следующий опрос его видит и молчит.
ORROLLBACK="$TMP/or_rollback.py"
cat > "$ORROLLBACK" <<'RPY'
import importlib.machinery, importlib.util, json, os, subprocess
path = os.environ["DIGEST_PATH"]
loader = importlib.machinery.SourceFileLoader("dig_rb", path)
spec = importlib.util.spec_from_file_location("dig_rb", path, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.log = lambda *a, **k: None
section = {"status": "ok", "balance": 1.0, "forecast_days": 1.0}

class Fail:
    returncode = 1; stderr = "boom"; stdout = ""
class Okr:
    returncode = 0; stderr = ""; stdout = ""
calls = []
def fake_run(*a, **k):
    calls.append(k.get("input", ""))
    return Fail() if len(calls) == 1 else Okr()
mod.subprocess.run = fake_run

r1 = mod._send_openrouter_alerts(section)
print(("PASS " if r1 is False else "FAIL ") + "INV-LIM-14 к16: сбой отправки дает False")
state = json.load(open(mod.OPENROUTER_STATE_FILE))
low = (state.get("alerts") or {}).get("low")
print(("PASS " if not low else "FAIL ") + "INV-LIM-14 к16: признак порога откачен после сбоя (low=%r)" % low)
r2 = mod._send_openrouter_alerts(section)
print(("PASS " if r2 is True and len(calls) == 2 else "FAIL ")
      + "INV-LIM-14 к16: на следующем опросе предупреждение уходит повторно (вызовов %d)" % len(calls))
r3 = mod._send_openrouter_alerts(section)
print(("PASS " if len(calls) == 2 else "FAIL ")
      + "INV-LIM-14 к16: после успешной отправки повтора нет (вызовов %d)" % len(calls))
RPY
RB_DIR="$TMP/rb-control"; mkdir -p "$RB_DIR/limits"
RB_OUT="$TMP/or_rollback.out"
# CLAUDE_CONTROL_DIR, а не CONTROL_DIR: модуль читает именно эту переменную,
# и с неверным именем проверка писала в боевой ~/.claude-control (случилось
# 24.09.2026 на первой редакции этого блока).
CLAUDE_CONTROL_DIR="$RB_DIR" LIMITS_OPENROUTER_KEY_FILE="$TMP/no-such-key" DIGEST_PATH="$BIN" \
  python3 "$ORROLLBACK" >"$RB_OUT" 2>"$TMP/or_rollback.err"; RB_RC=$?
# Падение скрипта на середине оставляет часть строк PASS - без проверки кода
# возврата оно засчитывалось как успех (тот же случай, 24.09.2026).
[[ "$RB_RC" == 0 ]] || fail "INV-LIM-14 к16: скрипт проверки упал (код $RB_RC): $(tail -1 "$TMP/or_rollback.err")"
if [[ ! -s "$RB_OUT" ]]; then
  fail "INV-LIM-14 к16: обвязка не напечатала PASS/FAIL ($(head -c 200 "$TMP/or_rollback.err"))"
else
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok ;;
      "FAIL "*) fail "${line#FAIL }" ;;
    esac
  done < "$RB_OUT"
fi

echo "test-agent-limits-openrouter: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
