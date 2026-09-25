#!/usr/bin/env bash
# Тесты вслепую по спеке docs/dev/2026-09-25-spec-yandex-cloud-balance.md
# (со ссылкой на docs/dev/done/2026-09-24-spec-openrouter-balance.md как на
# образец поведения). Тег группы - INV-LIM-15. Реализации (build_yandex,
# yandex_alerts, http_post) еще нет - весь прогон обязан быть КРАСНЫМ; это
# ожидаемо и не чинится правкой теста.
#
# Сеть не трогаем: http_get и http_post подменяются в каждом python-блоке
# заглушками. Ключ сервисного аккаунта - одноразовый RSA 2048, созданный
# самим тестом через cryptography (см. gen_yandex_key ниже), в реальный
# Yandex Cloud тест не ходит.
#
# Модуль bin/claude-agent-limits-digest (без расширения) импортируется через
# importlib.machinery.SourceFileLoader, как в tests/test-agent-limits-openrouter.sh -
# spec_from_file_location без явного loader'а файл без .py не опознает.
#
# CLAUDE_CONTROL_DIR и LIMITS_YANDEX_KEY_FILE читаются модулем на этапе
# импорта, поэтому переменные окружения выставляются в bash ДО запуска
# python3 - каждый python-блок получает свой набор путей через отдельный env
# для подпроцесса (грабли из test-agent-limits-openrouter.sh: перепутанное
# имя переменной пишет в боевой каталог - здесь имя проверено по спеке).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin/claude-agent-limits-digest"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

# Одноразовый ключ сервисного аккаунта: RSA 2048 через cryptography, поля
# id/service_account_id/private_key как в спеке ("Доступ к API"). Отдельный
# ключ на каждый вызов - чтобы сценарии не делили состояние по ошибке.
gen_yandex_key() {
  local out="$1" keyid="$2" said="$3"
  mkdir -p "$(dirname "$out")"
  python3 - "$out" "$keyid" "$said" <<'PY'
import json, sys
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

out, keyid, said = sys.argv[1], sys.argv[2], sys.argv[3]
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pem = key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
).decode("utf-8")
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"id": keyid, "service_account_id": said, "private_key": pem}, fh)
PY
}

run_block() {
  # $1 - имя python-файла в TMP, $2 - CLAUDE_CONTROL_DIR, $3 - KEY_FILE
  # (может не существовать - это сам по себе сценарий "не настроен").
  local pyfile="$1" control_dir="$2" key_file="$3"
  local out="$TMP/$(basename "$pyfile").out" err="$TMP/$(basename "$pyfile").err"
  mkdir -p "$control_dir"
  BIN_PATH="$BIN" YA_CONTROL_DIR="$control_dir" YA_KEY_FILE="$key_file" \
    CLAUDE_CONTROL_DIR="$control_dir" LIMITS_YANDEX_KEY_FILE="$key_file" \
    python3 "$pyfile" >"$out" 2>"$err"
  local rc=$?
  if [[ "$rc" != 0 ]]; then
    fail "INV-LIM-15 $(basename "$pyfile"): обвязка упала (код $rc) - см. stderr ниже"
  fi
  if [[ ! -s "$out" ]]; then
    fail "INV-LIM-15 $(basename "$pyfile"): не напечатано ни одного PASS/FAIL (см. stderr)"
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

# ===========================================================================
# YAMAIN: нарратив одного счета во времени - критерии 1, 2, 3, 4, 13, 14.
# Один и тот же CLAUDE_CONTROL_DIR/KEY_FILE на весь блок: history накапливается
# последовательными вызовами build_yandex(now=...).
# ===========================================================================
KEY_MAIN="$TMP/keys/main-key.json"
gen_yandex_key "$KEY_MAIN" "aje-main-key-id" "aje-main-sa-id"
YAMAIN="$TMP/yamain.py"
cat > "$YAMAIN" <<'PY'
import importlib.machinery, importlib.util, json, os, re, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
CONTROL_DIR = os.environ["YA_CONTROL_DIR"]
loader = importlib.machinery.SourceFileLoader("limits_ya_main", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_main", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

results = []
def record(name, cond):
    results.append((name, bool(cond)))

def scenario(name, fn):
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)

logs = []
mod.log = lambda m: logs.append(m)

def s_functions_exist():
    record("INV-LIM-15 build_yandex существует", hasattr(mod, "build_yandex"))
    record("INV-LIM-15 yandex_alerts существует", hasattr(mod, "yandex_alerts"))
    record("INV-LIM-15 http_post существует", hasattr(mod, "http_post"))
scenario("проверка наличия точек входа", s_functions_exist)

if not (hasattr(mod, "build_yandex") and hasattr(mod, "http_post")):
    for name, cond in results:
        print(("PASS " if cond else "FAIL ") + name)
    print("FAIL INV-LIM-15 критерии 1/2/3/4/13/14: build_yandex/http_post "
          "отсутствуют (RED)")
    sys.exit(0)

def good_post(url, body, headers, proxy):
    return (200, {"iamToken": "iam-token-yamain",
                  "expiresAt": (t0 + timedelta(hours=12)).isoformat()})

t0 = datetime(2026, 9, 25, 3, 17, 0, tzinfo=timezone.utc)

def make_get(balance_str):
    return lambda url, headers, proxy: (200, {"balance": balance_str})

# --- шаг 1 (критерий 1): первый опрос, без истории --------------------------
section0, rendered0 = None, None
def s_first_poll():
    global section0, rendered0
    mod.http_post = good_post
    mod.http_get = make_get("4982.9166")
    section = mod.build_yandex(now=t0)
    record("критерий 1: build_yandex вернул словарь секции", isinstance(section, dict))
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t0)
    record("критерий 1: остаток 4982.9166 -> 4 983 руб. в секции",
           abs(section.get("balance", -1) - 4982.9166) < 0.01)
    record("критерий 1: строка '0% / 4 983 ₽' на первом опросе",
           "0% / 4 983 ₽" in rendered)
    bar = re.search(r"([▓░]{10})\s+0% / 4 983 ₽", rendered)
    record("критерий 1: шкала полностью пуста при 0%",
           bar is not None and bar.group(1) == "░" * 10)
    record("критерий 1/6: блок не показывает 0 ₽ при живом остатке",
           re.search(r"(?<!\d)0\s₽", rendered) is None)
    section0, rendered0 = section, rendered
scenario("шаг 1: первый опрос без истории", s_first_poll)

# --- шаг 2 (критерий 2, 4): остаток упал на 42 - расход виден, история < суток
t1 = t0 + timedelta(minutes=15)
def s_spend_short_history():
    mod.http_get = make_get("4940.9166")
    section = mod.build_yandex(now=t1)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t1)
    record("критерий 2: шкала показывает потраченное - процент вырос "
           "с 0% (осталась та же шкала 4 983 ₽)",
           "0% / 4 983 ₽" not in rendered and "/ 4 983 ₽" in rendered)
    record("критерий 4: истории меньше суток -> 'копим историю'",
           "копим историю" in rendered)
scenario("шаг 2: расход виден, история < суток", s_spend_short_history)

# --- шаг 3 (критерий 4 продолжение): история >= суток - расход появляется --
t2 = t0 + timedelta(hours=25)
def s_day_history():
    mod.http_get = make_get("4882.9166")
    section = mod.build_yandex(now=t2)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t2)
    record("критерий 4: история от суток - больше не 'копим историю'",
           "копим историю" not in rendered)
    record("критерий 4: строка расхода с рублями (сутки ... ₽)",
           re.search(r"сутки\s*\d+\s?₽", rendered) is not None)
scenario("шаг 3: история от суток дает расход", s_day_history)

# --- шаг 4 (критерий 3): остаток вырос - пополнение, шкала сбрасывается ----
t3 = t0 + timedelta(hours=26)
def s_topup():
    mod.http_get = make_get("9982.9166")
    section = mod.build_yandex(now=t3)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t3)
    record("критерий 3: остаток после пополнения 9982.9166 в секции",
           abs(section.get("balance", -1) - 9982.9166) < 0.01)
    record("критерий 3: пополнение сбрасывает шкалу в '0% / 9 983 ₽'",
           "0% / 9 983 ₽" in rendered)
scenario("шаг 4: пополнение сбрасывает шкалу", s_topup)

# --- критерий 13: рубли - пробел между разрядами, без копеек ---------------
def s_ruble_format():
    section = mod.build_yandex(now=t3)
    rendered = mod.render({"snapshot": {"yandex": section or {}}}, now=t3)
    record("критерий 13: тысячи разделены пробелом ('9 983 ₽')",
           "9 983 ₽" in rendered)
    record("критерий 13: без копеек - нет точки/запятой перед ₽",
           re.search(r"[.,]\d{1,2}\s?₽", rendered) is None)
scenario("критерий 13: формат рублей без копеек, с пробелом", s_ruble_format)

# --- критерий 14: секция yandex не влияет на digits_signature --------------
def s_digits_signature():
    snap_a = {"claude": {"status": "ok", "five_hour": {"remaining": 80}},
              "codex": {"status": "ok", "seven_day": {"remaining": 40}}}
    snap_b = dict(snap_a)
    snap_b["yandex"] = section0 if isinstance(section0, dict) else {"status": "ok"}
    sig_a = mod.digits_signature(snap_a)
    sig_b = mod.digits_signature(snap_b)
    record("критерий 14: digits_signature одинакова с секцией yandex и без",
           sig_a == sig_b)
scenario("критерий 14: digits_signature не зависит от yandex", s_digits_signature)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YAMAIN" "$TMP/control-main" "$KEY_MAIN"

# ===========================================================================
# YATOKEN: критерии 7, 8 - кэш IAM-токена. Второй опрос в пределах срока не
# зовет обмен на токен; когда до истечения меньше часа - зовет; 401 биллинга
# сбрасывает кэш, следующий опрос зовет обмен на токен снова независимо от
# оставшегося срока.
# ===========================================================================
KEY_TOKEN="$TMP/keys/token-key.json"
gen_yandex_key "$KEY_TOKEN" "aje-token-key-id" "aje-token-sa-id"
YATOKEN="$TMP/yatoken.py"
cat > "$YATOKEN" <<'PY'
import importlib.machinery, importlib.util, os, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_ya_token", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_token", BIN_PATH, loader=loader)
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

if not (hasattr(mod, "build_yandex") and hasattr(mod, "http_post")):
    print("FAIL INV-LIM-15 критерии 7/8: build_yandex/http_post отсутствуют (RED)")
    sys.exit(0)

t0 = datetime(2026, 9, 25, 0, 0, 0, tzinfo=timezone.utc)

post_calls = []
post_queue = []
def fake_post(url, body, headers, proxy):
    post_calls.append(url)
    if post_queue:
        return post_queue.pop(0)
    return (200, {"iamToken": "iam-token-fallback",
                  "expiresAt": (t0 + timedelta(hours=40)).isoformat()})
mod.http_post = fake_post

get_calls = []
get_status = {"mode": "ok", "balance": "1000.00"}
def fake_get(url, headers, proxy):
    get_calls.append(url)
    if get_status["mode"] == "401":
        return (401, None)
    return (200, {"balance": get_status["balance"]})
mod.http_get = fake_get

def s_first_poll():
    post_queue.append((200, {"iamToken": "iam-token-1",
                              "expiresAt": (t0 + timedelta(hours=12)).isoformat()}))
    mod.build_yandex(now=t0)
    record("критерий 8: первый опрос зовет обмен на токен ровно раз",
           len(post_calls) == 1)
    record("критерий 8: первый опрос зовет биллинг ровно раз",
           len(get_calls) == 1)
scenario("шаг 1: первый опрос выпускает токен", s_first_poll)

def s_cache_reused():
    mod.build_yandex(now=t0 + timedelta(minutes=15))
    record("критерий 8: второй опрос в пределах срока - обмен на токен не "
           "звался (кэш использован)", len(post_calls) == 1)
    record("критерий 8: биллинг звался снова", len(get_calls) == 2)
scenario("шаг 2: второй опрос в пределах срока - кэш", s_cache_reused)

def s_renew_near_expiry():
    post_queue.append((200, {"iamToken": "iam-token-2",
                              "expiresAt": (t0 + timedelta(hours=52)).isoformat()}))
    # до истечения первого токена (t0+12h) остается меньше часа
    mod.build_yandex(now=t0 + timedelta(hours=11, minutes=30))
    record("критерий 8: до истечения меньше часа - обмен на токен позван снова",
           len(post_calls) == 2)
scenario("шаг 3: обновление токена меньше чем за час до истечения",
        s_renew_near_expiry)

def s_cache_reused_after_renew():
    mod.build_yandex(now=t0 + timedelta(hours=11, minutes=45))
    record("критерий 8: сразу после обновления кэш снова используется",
           len(post_calls) == 2)
scenario("шаг 4: кэш используется после обновления", s_cache_reused_after_renew)

def s_billing_401_resets_cache():
    get_status["mode"] = "401"
    section = mod.build_yandex(now=t0 + timedelta(hours=12))
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t0 + timedelta(hours=12))
    record("критерий 6/7: 401 биллинга дает 'нет данных'",
           "нет данных" in rendered)
    record("критерий 7: 401 биллинга не звал обмен на токен повторно "
           "на этом же опросе", len(post_calls) == 2)
    get_status["mode"] = "ok"
    post_queue.append((200, {"iamToken": "iam-token-3",
                              "expiresAt": (t0 + timedelta(hours=64)).isoformat()}))
    mod.build_yandex(now=t0 + timedelta(hours=12, minutes=15))
    record("критерий 7: после 401 следующий опрос зовет обмен на токен "
           "снова (кэш был сброшен)", len(post_calls) == 3)
scenario("критерий 7: 401 биллинга сбрасывает кэш IAM-токена",
        s_billing_401_resets_cache)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YATOKEN" "$TMP/control-token" "$KEY_TOKEN"

# ===========================================================================
# YAFAIL: критерии 6, 9 - отказ биллинга (401/403/таймаут/битый JSON) и отказ
# обмена на токен дают "нет данных" с последним известным остатком, а не
# 0 руб.
# ===========================================================================
KEY_FAIL="$TMP/keys/fail-key.json"
gen_yandex_key "$KEY_FAIL" "aje-fail-key-id" "aje-fail-sa-id"
YAFAIL="$TMP/yafail.py"
cat > "$YAFAIL" <<'PY'
import importlib.machinery, importlib.util, os, re, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_ya_fail", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_fail", BIN_PATH, loader=loader)
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

if not (hasattr(mod, "build_yandex") and hasattr(mod, "http_post")):
    print("FAIL INV-LIM-15 критерии 6/9: build_yandex/http_post отсутствуют (RED)")
    sys.exit(0)

t0 = datetime(2026, 9, 25, 0, 0, 0, tzinfo=timezone.utc)

def good_post(url, body, headers, proxy):
    return (200, {"iamToken": "iam-token-fail-good",
                  "expiresAt": (t0 + timedelta(hours=12)).isoformat()})

def run_billing_failure(label, bad_response, now_fail):
    mod.http_post = good_post
    mod.http_get = lambda url, headers, proxy: (200, {"balance": "2500.00"})
    mod.build_yandex(now=t0)  # успешный опрос - остаток 2500.00
    mod.http_get = lambda url, headers, proxy: bad_response
    section = mod.build_yandex(now=now_fail)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=now_fail)
    record("критерий 6 (%s): блок 'нет данных'" % label,
           "нет данных" in rendered)
    record("критерий 6 (%s): последний известный остаток 2 500 ₽ показан"
           % label, "2 500" in rendered)
    record("критерий 6 (%s): не показывает 0 ₽" % label,
           re.search(r"(?<!\d)0\s₽", rendered) is None)

scenario("критерий 6: отказ биллинга 401", lambda: run_billing_failure(
    "401", (401, None), t0 + timedelta(minutes=15)))
scenario("критерий 6: отказ биллинга 403", lambda: run_billing_failure(
    "403", (403, None), t0 + timedelta(minutes=30)))
scenario("критерий 6: отказ биллинга таймаут", lambda: run_billing_failure(
    "timeout", (0, None), t0 + timedelta(minutes=45)))
scenario("критерий 6: отказ биллинга битый JSON", lambda: run_billing_failure(
    "bad-json", (200, {"unexpected": "shape"}), t0 + timedelta(minutes=60)))

def s_token_exchange_fails_first_ever():
    # Переписано 25.09.2026 основным агентом. Прежняя редакция шла по кэшу
    # токена, оставленному предыдущими сценариями: обмен не вызывался вовсе,
    # подмененный http_get бросал AssertionError, и "нет данных" появлялось
    # из общего перехвата исключений - критерий 9 фактически не проверялся.
    # Теперь кэш токена удаляется, и отдельно проверяется, что обмен БЫЛ
    # вызван, а биллинг - нет.
    iam_cache = os.path.join(os.path.dirname(mod.YANDEX_STATE_FILE), "yandex-iam.json")
    if os.path.exists(iam_cache):
        os.remove(iam_cache)
    calls = {"post": 0, "get": 0}
    def post(url, body, headers, proxy):
        calls["post"] += 1
        return (500, None)
    def get(url, headers, proxy):
        calls["get"] += 1
        return (200, {"balance": "999"})
    mod.http_post = post
    mod.http_get = get
    section = mod.build_yandex(now=t0 + timedelta(hours=5))
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t0 + timedelta(hours=5))
    record("критерий 9: обмен на токен действительно вызывался", calls["post"] >= 1)
    record("критерий 9: без токена биллинг не вызывался", calls["get"] == 0)
    record("критерий 9: отказ обмена на токен дает 'нет данных'",
           "нет данных" in rendered)
    record("критерий 9: причина названа как отказ обмена на токен, а не общий сбой",
           "сбой замера" not in rendered and "токен" in rendered.lower())
    record("критерий 9: отказ обмена на токен не показывает 0 ₽",
           re.search(r"(?<!\d)0\s₽", rendered) is None)
scenario("критерий 9: отказ обмена на токен", s_token_exchange_fails_first_ever)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YAFAIL" "$TMP/control-fail" "$KEY_FAIL"

# ===========================================================================
# YANOKEY: критерий 10 - нет файла ключа: блока нет, ошибки в логе нет.
# ===========================================================================
YANOKEY="$TMP/yanokey.py"
cat > "$YANOKEY" <<'PY'
import importlib.machinery, importlib.util, os, sys

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_ya_nokey", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_nokey", BIN_PATH, loader=loader)
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

if not hasattr(mod, "build_yandex"):
    print("FAIL INV-LIM-15 критерий 10: build_yandex отсутствует (RED)")
    sys.exit(0)

def s_no_key_file():
    def stub_get(url, headers, proxy):
        raise AssertionError("http_get не должен вызываться без файла ключа")
    def stub_post(url, body, headers, proxy):
        raise AssertionError("http_post не должен вызываться без файла ключа")
    mod.http_get = stub_get
    mod.http_post = stub_post
    section = mod.build_yandex()
    record("критерий 10: без файла ключа build_yandex возвращает None",
           section is None)
    record("критерий 10: отсутствие ключа не пишет в лог (это не сбой)",
           logs == [])
scenario("критерий 10: нет файла ключа", s_no_key_file)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YANOKEY" "$TMP/control-nokey" "$TMP/no-such-key.json"

# ===========================================================================
# YANEG: критерий 12 - отрицательный остаток: шкала 100%, "пора пополнить",
# знак минус в отдельном сообщении.
# ===========================================================================
KEY_NEG="$TMP/keys/neg-key.json"
gen_yandex_key "$KEY_NEG" "aje-neg-key-id" "aje-neg-sa-id"
YANEG="$TMP/yaneg.py"
cat > "$YANEG" <<'PY'
import importlib.machinery, importlib.util, os, re, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_ya_neg", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_neg", BIN_PATH, loader=loader)
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

if not (hasattr(mod, "build_yandex") and hasattr(mod, "http_post")
        and hasattr(mod, "yandex_alerts")):
    print("FAIL INV-LIM-15 критерий 12: build_yandex/http_post/yandex_alerts "
          "отсутствуют (RED)")
    sys.exit(0)

t0 = datetime(2026, 9, 25, 0, 0, 0, tzinfo=timezone.utc)

def s_negative_balance():
    mod.http_post = lambda url, body, headers, proxy: (
        200, {"iamToken": "iam-token-neg",
              "expiresAt": (t0 + timedelta(hours=12)).isoformat()})
    mod.http_get = lambda url, headers, proxy: (200, {"balance": "500.00"})
    mod.build_yandex(now=t0)
    mod.http_get = lambda url, headers, proxy: (200, {"balance": "-150.00"})
    t1 = t0 + timedelta(minutes=15)
    section = mod.build_yandex(now=t1)
    record("критерий 12: остаток -150.00 в секции",
           abs(section.get("balance", 1) - (-150.0)) < 0.01)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t1)
    bar = re.search(r"([▓░]{10})", rendered)
    record("критерий 12: шкала полностью заполнена (100%)",
           bar is not None and bar.group(1) == "▓" * 10)
    record("критерий 12: 'пора пополнить' при отрицательном остатке",
           "пора пополнить" in rendered)
    msgs = mod.yandex_alerts(section, now=t1)
    record("критерий 12: отдельное сообщение содержит знак минус с рублями",
           any(re.search(r"-\s?150\s?₽", m) for m in msgs))
scenario("критерий 12: отрицательный остаток", s_negative_balance)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YANEG" "$TMP/control-neg" "$KEY_NEG"

# ===========================================================================
# YAALERT: критерий 5 (без "откат признака при сбое отправки" - см. вопрос в
# отчете: публичный контракт yandex_alerts не называет внутреннюю функцию
# отправки, как это было у OpenRouter, поэтому откат вслепую не проверяем).
# Прогноз меньше 3 дней - ⚠ и "пора пополнить" в панели, одно отдельное
# сообщение при первом пересечении, дедуп повторов, одно сообщение при
# восстановлении.
# ===========================================================================
KEY_ALERT="$TMP/keys/alert-key.json"
gen_yandex_key "$KEY_ALERT" "aje-alert-key-id" "aje-alert-sa-id"
YAALERT="$TMP/yaalert.py"
cat > "$YAALERT" <<'PY'
import importlib.machinery, importlib.util, os, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
loader = importlib.machinery.SourceFileLoader("limits_ya_alert", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_alert", BIN_PATH, loader=loader)
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

if not (hasattr(mod, "build_yandex") and hasattr(mod, "http_post")
        and hasattr(mod, "yandex_alerts")):
    print("FAIL INV-LIM-15 критерий 5: build_yandex/http_post/yandex_alerts "
          "отсутствуют (RED)")
    sys.exit(0)

t0 = datetime(2026, 9, 25, 0, 0, 0, tzinfo=timezone.utc)

def good_post(url, body, headers, proxy):
    return (200, {"iamToken": "iam-token-alert",
                  "expiresAt": (t0 + timedelta(hours=200)).isoformat()})
mod.http_post = good_post

t_after = None
def s_threshold_first_cross():
    global t_after
    mod.http_get = lambda url, headers, proxy: (200, {"balance": "10000.00"})
    mod.build_yandex(now=t0)  # база, история < суток
    mod.http_get = lambda url, headers, proxy: (200, {"balance": "1000.00"})
    t1 = t0 + timedelta(hours=24)
    section = mod.build_yandex(now=t1)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t1)
    record("критерий 5: прогноз < 3 суток - метка ⚠ в панели", "⚠" in rendered)
    record("критерий 5: прогноз < 3 суток - 'пора пополнить' в панели",
           "пора пополнить" in rendered)
    msgs1 = mod.yandex_alerts(section, now=t1)
    record("критерий 5: первое пересечение порога дает ровно одно сообщение",
           len(msgs1) == 1)
    msgs1b = mod.yandex_alerts(section, now=t1)
    record("критерий 5: повторный вызов при том же пересечении - пусто",
           msgs1b == [])
    t_after = t1
scenario("критерий 5: первое пересечение порога прогноза",
        s_threshold_first_cross)

def s_recovery():
    t2 = t_after + timedelta(hours=1)
    mod.http_get = lambda url, headers, proxy: (200, {"balance": "500000.00"})
    section = mod.build_yandex(now=t2)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t2)
    record("критерий 5: восстановление - панель больше не показывает "
           "'пора пополнить'", "пора пополнить" not in rendered)
    msgs = mod.yandex_alerts(section, now=t2)
    record("критерий 5: восстановление дает ровно одно сообщение",
           len(msgs) == 1)
    msgs2 = mod.yandex_alerts(section, now=t2)
    record("критерий 5: повторный вызов после восстановления - пусто",
           msgs2 == [])
scenario("критерий 5: восстановление после порога прогноза", s_recovery)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YAALERT" "$TMP/control-alert" "$KEY_ALERT"

# ===========================================================================
# YAROLLBACK: критерий 5, дыра спеки закрыта координатором - имя внутренней
# функции отправки зафиксировано: _send_yandex_alerts(section). По образцу
# блока "к16" в test-agent-limits-openrouter.sh: сбой отправки (первый вызов
# subprocess.run падает) дает False и откатывает признак события в
# yandex-state.json; следующий вызов отправляет повторно; после успеха
# повтора нет. Обязательна позитивная проверка, что подмененный
# subprocess.run вообще звался - иначе "признак откачен" пройдет на пустом
# месте (сообщение не сформировалось вовсе).
# ===========================================================================
KEY_ROLLBACK="$TMP/keys/rollback-key.json"
YAROLLBACK="$TMP/yarollback.py"
cat > "$YAROLLBACK" <<'PY'
import importlib.machinery, importlib.util, json, os, sys

BIN_PATH = os.environ["BIN_PATH"]
CONTROL_DIR = os.environ["YA_CONTROL_DIR"]
loader = importlib.machinery.SourceFileLoader("limits_ya_rollback", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_rollback", BIN_PATH, loader=loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.log = lambda *a, **k: None

results = []
def record(name, cond):
    results.append((name, bool(cond)))

if not hasattr(mod, "_send_yandex_alerts"):
    print("FAIL INV-LIM-15 критерий 5 (откат): _send_yandex_alerts отсутствует (RED)")
    for name, cond in results:
        print(("PASS " if cond else "FAIL ") + name)
    sys.exit(0)

section = {"status": "ok", "balance": 100.0, "forecast_days": 1.0}

class Fail:
    returncode = 1; stderr = "boom"; stdout = ""
class Okr:
    returncode = 0; stderr = ""; stdout = ""
calls = []
def fake_run(*a, **k):
    calls.append(k.get("input", ""))
    return Fail() if len(calls) == 1 else Okr()
mod.subprocess.run = fake_run

r1 = mod._send_yandex_alerts(section)
record("критерий 5 (откат): сбой отправки дает False", r1 is False)
record("проверка непуста: subprocess.run был вызван - иначе сообщение не "
       "формировалось и откат нечего проверять", len(calls) == 1)

state_path = os.path.join(CONTROL_DIR, "limits", "yandex-state.json")
state = {}
if os.path.exists(state_path):
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)
low = (state.get("alerts") or {}).get("low")
record("критерий 5 (откат): признак события откачен после сбоя отправки "
       "(low=%r)" % low, not low)

r2 = mod._send_yandex_alerts(section)
record("критерий 5 (откат): на следующем вызове предупреждение уходит "
       "повторно (вызовов subprocess.run: %d)" % len(calls),
       r2 is True and len(calls) == 2)

r3 = mod._send_yandex_alerts(section)
record("критерий 5 (откат): после успешной отправки повтора нет (вызовов "
       "subprocess.run: %d)" % len(calls), len(calls) == 2)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YAROLLBACK" "$TMP/control-rollback" "$KEY_ROLLBACK"

# ===========================================================================
# YASECRET: критерий 11 - закрытый ключ, JWT (тело, отправленное в http_post)
# и IAM-токен не появляются ни в рендере панели, ни в состоянии
# (yandex-state.json), ни в логе, ни в самой секции снапшота. Кэш-файл
# IAM-токена (yandex-iam.json) - отдельная проверка (дыра спеки закрыта
# координатором): он ОБЯЗАН существовать и иметь права 600, но по смыслу
# спеки хранит токен по определению - его содержимое на утечку не проверяем.
# ===========================================================================
KEY_SECRET="$TMP/keys/secret-key.json"
gen_yandex_key "$KEY_SECRET" "aje-secret-key-id" "aje-secret-sa-id"
YASECRET="$TMP/yasecret.py"
cat > "$YASECRET" <<'PY'
import importlib.machinery, importlib.util, json, os, stat, sys
from datetime import datetime, timedelta, timezone

BIN_PATH = os.environ["BIN_PATH"]
CONTROL_DIR = os.environ["YA_CONTROL_DIR"]
KEY_FILE = os.environ["YA_KEY_FILE"]
loader = importlib.machinery.SourceFileLoader("limits_ya_secret", BIN_PATH)
spec = importlib.util.spec_from_file_location("limits_ya_secret", BIN_PATH, loader=loader)
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

if not (hasattr(mod, "build_yandex") and hasattr(mod, "http_post")):
    print("FAIL INV-LIM-15 критерий 11: build_yandex/http_post отсутствуют (RED)")
    sys.exit(0)

with open(KEY_FILE, encoding="utf-8") as fh:
    key_data = json.load(fh)
PRIVATE_KEY_PEM = key_data["private_key"]
IAM_TOKEN = "iam-token-SECRET-MARKER-xyz789"

post_calls = []
def fake_post(url, body, headers, proxy):
    post_calls.append(body)
    return (200, {"iamToken": IAM_TOKEN,
                  "expiresAt": (t0 + timedelta(hours=12)).isoformat()})
mod.http_post = fake_post
mod.http_get = lambda url, headers, proxy: (200, {"balance": "777.00"})

t0 = datetime(2026, 9, 25, 0, 0, 0, tzinfo=timezone.utc)

def s_no_secret_leak():
    section = mod.build_yandex(now=t0)
    envelope = {"snapshot": {"yandex": section}}
    rendered = mod.render(envelope, now=t0)
    record("проверка непуста: рендер панели не пустой (иначе negative-check "
           "тривиален)", bool(rendered))
    record("критерий 11: закрытого ключа нет в рендере панели",
           PRIVATE_KEY_PEM not in rendered)
    record("критерий 11: IAM-токена нет в рендере панели",
           IAM_TOKEN not in rendered)
    record("критерий 11: закрытого ключа нет в секции снапшота",
           PRIVATE_KEY_PEM not in str(section))
    record("критерий 11: IAM-токена нет в секции снапшота",
           IAM_TOKEN not in str(section))
    record("критерий 11: закрытого ключа нет в перехваченных строках log()",
           PRIVATE_KEY_PEM not in " ".join(str(l) for l in logs))
    record("критерий 11: IAM-токена нет в перехваченных строках log()",
           IAM_TOKEN not in " ".join(str(l) for l in logs))

    state_path = os.path.join(CONTROL_DIR, "limits", "yandex-state.json")
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as fh:
            state_text = fh.read()
        record("проверка непуста: файл состояния не пустой (иначе "
               "negative-check тривиален)", bool(state_text.strip()))
        record("критерий 11: закрытого ключа нет в файле состояния",
               PRIVATE_KEY_PEM not in state_text)
        record("критерий 11: IAM-токена нет в файле состояния",
               IAM_TOKEN not in state_text)
    else:
        record("критерий 11: файл состояния создан (иначе проверку "
               "содержимого не выполнить)", False)

    record("проверка непуста: http_post вызван хотя бы раз (иначе JWT "
           "негде проверить)", len(post_calls) >= 1)
    if post_calls:
        body_text = json.dumps(post_calls[0], default=str)
        # JWT - самая длинная строка в теле запроса на обмен токена; ищем
        # ее в теле и убеждаемся, что она нигде дальше не всплывает.
        candidates = []
        def collect(v):
            if isinstance(v, str):
                candidates.append(v)
            elif isinstance(v, dict):
                for vv in v.values():
                    collect(vv)
            elif isinstance(v, list):
                for vv in v:
                    collect(vv)
        collect(post_calls[0])
        jwt_candidate = max(candidates, key=len) if candidates else ""
        record("проверка непуста: тело обмена на токен содержит непустую "
               "строку (кандидат на JWT)", len(jwt_candidate) > 20)
        if len(jwt_candidate) > 20:
            record("критерий 11: JWT (тело обмена на токен) не течет в "
                   "рендер панели", jwt_candidate not in rendered)
            record("критерий 11: JWT не течет в лог",
                   jwt_candidate not in " ".join(str(l) for l in logs))
            if os.path.exists(state_path):
                with open(state_path, encoding="utf-8") as fh:
                    state_text = fh.read()
                record("критерий 11: JWT не течет в файл состояния",
                       jwt_candidate not in state_text)

    # Дыра спеки закрыта координатором: yandex-iam.json хранит токен по
    # определению (иначе кэш бесполезен) - проверяем существование и права
    # 600, а не отсутствие токена внутри.
    iam_path = os.path.join(CONTROL_DIR, "limits", "yandex-iam.json")
    record("критерий 11: кэш IAM-токена создан по пути из спеки "
           "(yandex-iam.json)", os.path.exists(iam_path))
    if os.path.exists(iam_path):
        mode = stat.S_IMODE(os.stat(iam_path).st_mode)
        record("критерий 11: кэш IAM-токена имеет права 600 (реально: %o)"
               % mode, mode == 0o600)
scenario("критерий 11: ключ/JWT/IAM-токен не течет", s_no_secret_leak)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY
run_block "$YASECRET" "$TMP/control-secret" "$KEY_SECRET"

# ===========================================================================
# критерий 15: все проверки OpenRouter и selftest дайджеста остаются
# зелеными - общее ядро не меняет их поведения. Оба запуска тривиальны на
# сегодняшний день: реализация OpenRouter уже есть и уже зеленая, здесь
# только фиксируем регрессию, а не находим новую логику.
# ===========================================================================
if "$HERE/test-agent-limits-openrouter.sh" >"$TMP/or.out" 2>"$TMP/or.err"; then
  ok
else
  fail "критерий 15 (тривиально): test-agent-limits-openrouter.sh упал - см. stderr ниже"
  tail -40 "$TMP/or.out" "$TMP/or.err" >&2
fi

export HOME="$TMP/home-selftest"
mkdir -p "$HOME"
if CLAUDE_CONTROL_DIR="$TMP/control-selftest" "$BIN" selftest >"$TMP/selftest.out" 2>"$TMP/selftest.err"; then
  ok
else
  fail "критерий 15 (тривиально): bin/claude-agent-limits-digest selftest сломан - см. stderr ниже"
  cat "$TMP/selftest.err" >&2
fi

echo "test-agent-limits-yandex: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
