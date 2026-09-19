#!/usr/bin/env bash
# Offline-тесты TG-бота (auth/валидация/эскейпинг) - см. selftest в самом боте.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BOT="$HERE/../bin/claude-agent-tgbot"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

# HOME переопределен: selftest дергает только чистые функции и явно
# подменяет пути состояния (CLAUDE_AGENT_TG_CARDS_COUNT и т.п.) на
# временные, но LOG_FILE/OFFSET_FILE в bin/claude-agent-tgbot резолвятся
# от $HOME - страхуемся на случай появления в selftest вызовов log().
export HOME="$TMP/home"
mkdir -p "$HOME"

if "$BOT" selftest; then ok; else fail "bin/claude-agent-tgbot selftest (внутренние проверки бота)"; fi

echo "=== раздел C спеки 2026-09-19-spec-session-titles.md: фон, троттлинг лога, устойчивость карточки ==="
# Ни один из вызываемых ниже атрибутов модуля (titles_log_step,
# titles_refresh_due, titles_every, run_titles) в спеке по имени не назван -
# спека описывает только НАБЛЮДАЕМОЕ поведение бота (троттлинг лога, интервал
# фона, устойчивость карточки к провалу refresh), а не точки входа. Имена
# ниже - предположение по конвенции модуля (run_rc(args, timeout=60) в
# bin/claude-agent-tgbot) и подлежат сверке с тем, что впишет реализация;
# если имена будут другими - это ожидаемо и не считается дефектом спеки, а
# просто требует поправить эти тесты. Модуль импортируется через
# importlib (без чтения его логики), а не запуском подкоманды: у section C
# нет отдельной подкоманды CLI, только внутренние функции.
PYCHECK="$TMP/section_c.py"
cat > "$PYCHECK" <<'PY'
import importlib.machinery, importlib.util, os, subprocess as _subprocess, sys

# spec_from_file_location без явного loader'а не опознает файл без расширения
# .py (сам бот назван без него) и молча возвращает None - поэтому loader
# передается явно, а не выводится по имени файла.
bot_path = os.environ["BOT_PATH"]
loader = importlib.machinery.SourceFileLoader("tgbot_section_c", bot_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

results = []


def record(name, cond):
    results.append((name, bool(cond)))


def scenario(name, fn):
    # Каждый сценарий - в своей обертке: пока функции нет вовсе, обращение к
    # ней роняет ИМЕННО этот сценарий (AttributeError и т.п.), а не весь
    # прогон целиком - иначе один нереализованный кусок маскирует остальные.
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)


def s_three_failures():
    # "Провалы refresh подряд не логируются каждый раз - только смена
    # состояния (ok -> провал, провал -> ok) и каждый десятый провал подряд".
    streak = 0
    logged = 0
    for _ in range(3):
        streak, should_log = mod.titles_log_step(streak, 4)
        if should_log:
            logged += 1
    record("три провала подряд refresh - одна запись в лог (переход ok->провал)",
           logged == 1)
    record("titles_log_step считает подряд идущие провалы", streak == 3)


scenario("троттлинг: три провала подряд", s_three_failures)


def s_tenth_failure():
    streak = 0
    logged_at = []
    for i in range(1, 11):
        streak, should_log = mod.titles_log_step(streak, 4)
        if should_log:
            logged_at.append(i)
    record("десятый провал подряд залогирован тоже (не только первый)",
           logged_at == [1, 10])


scenario("троттлинг: каждый десятый провал подряд", s_tenth_failure)


def s_recovery():
    streak, _ = mod.titles_log_step(0, 4)
    streak, should_log_ok = mod.titles_log_step(streak, 0)
    record("возврат к успеху после провала - тоже смена состояния, логируется",
           should_log_ok is True)
    record("успех сбрасывает streak провалов", streak == 0)


scenario("троттлинг: смена состояния провал->ok", s_recovery)


def s_ok_after_ok():
    _, should_log_ok2 = mod.titles_log_step(0, 0)
    record("успех после успеха не логируется", should_log_ok2 is False)


scenario("троттлинг: успех после успеха тихий", s_ok_after_ok)


def s_due():
    # "Первый прогон - при старте бота", дальше не чаще
    # CLAUDE_TGBOT_TITLES_EVERY секунд (по умолчанию 180).
    record("нет предыдущего прогона -> обновление положено сразу (старт бота)",
           mod.titles_refresh_due(None, 1000, 180) is True)
    record("интервал не истек -> обновления не положено",
           mod.titles_refresh_due(1000, 1050, 180) is False)
    record("интервал истек -> обновление положено",
           mod.titles_refresh_due(1000, 1181, 180) is True)
    record("ровно на границе интервала - тоже положено",
           mod.titles_refresh_due(1000, 1180, 180) is True)


scenario("фон: не чаще интервала между прогонами", s_due)


def s_env_default():
    env_had = "CLAUDE_TGBOT_TITLES_EVERY" in os.environ
    env_old = os.environ.get("CLAUDE_TGBOT_TITLES_EVERY")
    os.environ.pop("CLAUDE_TGBOT_TITLES_EVERY", None)
    try:
        record("интервал фона по умолчанию 180 с (CLAUDE_TGBOT_TITLES_EVERY не задан)",
               mod.titles_every() == 180)
        os.environ["CLAUDE_TGBOT_TITLES_EVERY"] = "42"
        record("интервал фона читается из CLAUDE_TGBOT_TITLES_EVERY",
               mod.titles_every() == 42)
    finally:
        if env_had:
            os.environ["CLAUDE_TGBOT_TITLES_EVERY"] = env_old
        else:
            os.environ.pop("CLAUDE_TGBOT_TITLES_EVERY", None)


scenario("фон: CLAUDE_TGBOT_TITLES_EVERY читается с дефолтом 180", s_env_default)


def s_timeout_safe():
    # "Провал или таймаут не мешают показу: карточка рисуется из кэша" -
    # обертка вызова _rc_titles.py обязана вернуть код ошибки, а не уронить
    # вызывающего исключением, иначе рендер карточки прервется вместе с ней.
    real_run = _subprocess.run

    def boom(*a, **kw):
        raise _subprocess.TimeoutExpired(cmd="_rc_titles.py",
                                          timeout=kw.get("timeout", 5))

    mod.subprocess.run = boom
    try:
        rc, out, err = mod.run_titles(["refresh"], timeout=5)
        record("таймаут хелпера _rc_titles.py не роняет вызывающего исключением", True)
        record("таймаут хелпера возвращает код завершения != 0", rc != 0)
    finally:
        mod.subprocess.run = real_run


scenario("карточка: устойчивость к таймауту refresh", s_timeout_safe)

for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
PY

SECTION_C_OUT="$TMP/section_c.out"
BOT_PATH="$BOT" python3 "$PYCHECK" >"$SECTION_C_OUT" 2>"$TMP/section_c.err"
rc_c=$?
if [[ "$rc_c" != 0 ]]; then
  fail "раздел C: сама проверочная обвязка упала (код $rc_c) - см. stderr ниже"
fi
if [[ ! -s "$SECTION_C_OUT" ]]; then
  fail "раздел C: обвязка не напечатала ни одного PASS/FAIL (см. stderr)"
else
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok ;;
      "FAIL "*) fail "${line#FAIL }" ;;
    esac
  done < "$SECTION_C_OUT"
fi
[[ -s "$TMP/section_c.err" ]] && cat "$TMP/section_c.err" >&2

# --- INV-BOT-57: markdown-жирный превращается в HTML-жирный -------------------
# Модель пишет **важно**, бот шлет HTML и экранирует все подряд, поэтому
# звездочки доезжали до получателя буквально (заявка dwl 19.09.2026).
# Спека: docs/dev/2026-09-19-spec-tg-markdown.md
MDCHECK="$TMP/md_bold.py"
cat > "$MDCHECK" <<'MDPY'
import importlib.machinery, importlib.util, os, sys, html as _html
path = os.environ["BOT_PATH"]
loader = importlib.machinery.SourceFileLoader("bot_md", path)
spec = importlib.util.spec_from_file_location("bot_md", path, loader=loader)
bot = importlib.util.module_from_spec(spec)
loader.exec_module(bot)

def check(name, got, want):
    print(("PASS " if got == want else "FAIL ") +
          "INV-BOT-57 %s: ожидалось %r, получено %r" % (name, want, got))

f = getattr(bot, "md_bold_to_html", None)
if f is None:
    print("FAIL INV-BOT-57: в боте нет функции md_bold_to_html")
    sys.exit(0)

check("одна пара", f("текст **важно** дальше"), "текст <b>важно</b> дальше")
check("две пары", f("**раз** и **два**"), "<b>раз</b> и <b>два</b>")
check("непарная", f("2 ** 3 и все"), "2 ** 3 и все")
check("пустая пара", f("****"), "****")
check("через перевод строки", f("**раз\nдва**"), "**раз\nдва**")
check("после экранирования", f(_html.escape("**<b>x</b>**")),
      "<b>&lt;b&gt;x&lt;/b&gt;</b>")

sent = []
bot.api = lambda token, proxy, method, **kw: (sent.append(kw) or {"ok": True})
bot.send_message("t", None, 1, "вот **важно**")
check("send_message обычный", sent[-1].get("text"), "вот <b>важно</b>")
bot.send_message("t", None, 1, "вот **важно**", pre=True)
check("send_message --pre", sent[-1].get("text"), "<pre>вот **важно**</pre>")
MDPY
MD_OUT="$TMP/md_bold.out"
BOT_PATH="$BOT" python3 "$MDCHECK" >"$MD_OUT" 2>"$TMP/md_bold.err"
if [[ ! -s "$MD_OUT" ]]; then
  fail "INV-BOT-57: обвязка не напечатала PASS/FAIL ($(head -c 200 "$TMP/md_bold.err"))"
else
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok ;;
      "FAIL "*) fail "${line#FAIL }" ;;
    esac
  done < "$MD_OUT"
fi

# --- INV-BOT-58: пересланное сообщение - данные, а не поручение --------------
# Спека: docs/dev/2026-09-19-spec-forwarded-as-data.md. Реализации еще нет -
# бот пока не смотрит на forward_origin/forward_from/forward_from_chat/
# forward_sender_name вовсе, поэтому пересланный текст сегодня уходит в тот
# же исполняющий путь, что и обычная реплика владельца. Проверки ниже гоняют
# ОДИН апдейт через mode_poll() целиком (это единственная точка, где апдейт
# разбирается) с подмененными bot.api (перехват исходящих sendMessage),
# bot.sticky_route (это и есть исполняющий путь для простого текста - его
# заглушка только пишет в список executed) и bot.log (список строк лога).
# bot.titles_background_refresh подменен на no-op, чтобы не дергать реальный
# _rc_titles.py subprocess-ом на каждой итерации - это фон соседней спеки, к
# пересылке отношения не имеет. Второй вызов getUpdates внутри mode_poll
# роняет цикл управляемым исключением _StopPoll - это и есть выход из
# бесконечного long-poll после ровно одного апдейта.
FWDCHECK="$TMP/forward.py"
cat > "$FWDCHECK" <<'FWDPY'
import importlib.machinery, importlib.util, os, sys, html as _html

path = os.environ["BOT_PATH"]
loader = importlib.machinery.SourceFileLoader("bot_forward", path)
spec = importlib.util.spec_from_file_location("bot_forward", path, loader=loader)
bot = importlib.util.module_from_spec(spec)
loader.exec_module(bot)

OWNER = 4242


class _StopPoll(Exception):
    """Сентинел, чтобы выйти из бесконечного цикла mode_poll после одного апдейта."""


def make_fake_api(update, sent):
    calls = {"n": 0}

    def fake_api(token, proxy, method, **kw):
        if method == "getUpdates":
            calls["n"] += 1
            if calls["n"] == 1:
                return {"result": [update]}
            raise _StopPoll()
        if method == "sendMessage":
            sent.append(kw)
            return {"ok": True, "result": {"message_id": 9000 + len(sent)}}
        return {"ok": True}

    return fake_api


def run_update(update):
    """Прогоняет ОДИН апдейт через mode_poll с подмененными api/sticky_route/
    log/фоном; возвращает (executed, sent, logs)."""
    os.environ["CLAUDE_AGENT_TG_TOKEN"] = "testtoken"
    os.environ["CLAUDE_AGENT_TG_WHITELIST"] = str(OWNER)
    os.environ["CLAUDE_AGENT_TG_PROXY"] = ""
    executed = []
    sent = []
    logs = []
    bot.titles_background_refresh = lambda: None
    bot.sticky_route = lambda msg, text, update_id, now=None: (
        executed.append((msg, text)) or None)
    bot.log = lambda m: logs.append(m)
    bot.api = make_fake_api(update, sent)
    try:
        bot.mode_poll()
    except _StopPoll:
        pass
    return executed, sent, logs


def msg_base(**over):
    m = {"message_id": over.pop("message_id", 1),
         "chat": {"id": OWNER, "type": "private"},
         "from": {"id": OWNER}}
    m.update(over)
    return m


def update_with(msg, update_id):
    return {"update_id": update_id, "message": msg}


results = []


def record(name, cond):
    results.append((name, bool(cond)))


def scenario(name, fn):
    # Как в section C: один упавший сценарий не должен маскировать остальные.
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)


# --- критерий 1: forward_origin - не исполняется, карточка с источником,
# цитатой и подсказкой. sender_user_name - реальное поле Bot API у варианта
# MessageOriginHiddenUser, естественный кандидат для отображения источника.
def s_forward_origin():
    text = "сделай Х по этому"
    msg = msg_base(text=text, forward_origin={
        "type": "hidden_user", "sender_user_name": "Скрытый Клиент",
        "date": 1700000000})
    executed, sent, logs = run_update(update_with(msg, 101))
    record("INV-BOT-58 forward_origin: исполняющий путь не вызван",
           executed == [])
    body = " ".join(str(s.get("text", "")) for s in sent)
    record("INV-BOT-58 forward_origin: карточка с источником отправлена",
           "Скрытый Клиент" in body)
    record("INV-BOT-58 forward_origin: карточка содержит цитату исходного текста",
           text in body or _html.escape(text) in body)
    record("INV-BOT-58 forward_origin: карточка содержит подсказку "
           "'своими словами'", "своими словами" in body.lower())


scenario("критерий 1: forward_origin", s_forward_origin)


# --- критерий 2: каждое из четырех полей пересылки проверяется отдельно -----
def s_field(field_name, field_value, expect_marker, update_id):
    text = "пункт из чужого чата"
    msg = msg_base(text=text, **{field_name: field_value})
    executed, sent, logs = run_update(update_with(msg, update_id))
    record("INV-BOT-58 %s: исполняющий путь не вызван" % field_name,
           executed == [])
    body = " ".join(str(s.get("text", "")) for s in sent)
    record("INV-BOT-58 %s: карточка отправлена с источником" % field_name,
           expect_marker in body)
    record("INV-BOT-58 %s: карточка содержит подсказку" % field_name,
           "своими словами" in body.lower())


def s_forward_from():
    s_field("forward_from",
            {"id": 555, "is_bot": False, "first_name": "Петр",
             "username": "petr_client"},
            "Петр", 200)


def s_forward_from_chat():
    s_field("forward_from_chat",
            {"id": -100999, "type": "channel", "title": "Новости Клиента"},
            "Новости Клиента", 201)


def s_forward_sender_name():
    s_field("forward_sender_name", "Скрытый Абонент", "Скрытый Абонент", 202)


scenario("критерий 2: forward_from отдельно", s_forward_from)
scenario("критерий 2: forward_from_chat отдельно", s_forward_from_chat)
scenario("критерий 2: forward_sender_name отдельно", s_forward_sender_name)


# --- критерий 3: обычное сообщение владельца исполняется как раньше --------
def s_plain_message():
    msg = msg_base(text="запусти регресс по проекту Х")
    executed, sent, logs = run_update(update_with(msg, 300))
    record("INV-BOT-58 обычное сообщение владельца по прежнему исполняется",
           len(executed) == 1)


scenario("критерий 3: обычное сообщение", s_plain_message)


# --- критерий 4: скрытый отправитель - имя из forward_sender_name, а не
# "неизвестно" (forward_from нарочно отсутствует).
def s_hidden_sender_name():
    msg = msg_base(text="важная реплика",
                   forward_sender_name="Скрытая Ивановна")
    executed, sent, logs = run_update(update_with(msg, 400))
    body = " ".join(str(s.get("text", "")) for s in sent)
    record("INV-BOT-58 скрытый отправитель: имя из forward_sender_name "
           "в карточке", "Скрытая Ивановна" in body)
    record("INV-BOT-58 скрытый отправитель: не подставлено 'неизвестно'",
           "неизвестно" not in body.lower())


scenario("критерий 4: скрытый отправитель", s_hidden_sender_name)


# --- критерий 5: экранирование и маскировка секрета в цитате ---------------
# Проверяем не только ОТСУТСТВИЕ опасного/секретного, но и ПРИСУТСТВИЕ
# безопасной части цитаты - иначе проверка молчаливо проходит и сейчас,
# просто потому что карточки нет вовсе (см. правило про тихий отказ).
def s_escape_and_redact():
    secret_text = "Смотри <b>важное</b>: token=abc123 и все."
    msg = msg_base(text=secret_text,
                   forward_from={"id": 777, "is_bot": False,
                                 "first_name": "Иван"})
    executed, sent, logs = run_update(update_with(msg, 500))
    body = " ".join(str(s.get("text", "")) for s in sent)
    record("INV-BOT-58 цитата: безопасная часть текста попала в карточку",
           "Смотри" in body and "важное" in body)
    record("INV-BOT-58 цитата: тег <b> не работает как разметка",
           "<b>важное</b>" not in body)
    record("INV-BOT-58 цитата: секрет token=abc123 промаскирован",
           "abc123" not in body and "Смотри" in body)


scenario("критерий 5: экранирование и маскировка секрета", s_escape_and_redact)


# --- критерий 6: пересланное медиа с подписью не исполняется, подпись идет
# в карточку. У фото нет поля text вовсе - только caption.
def s_media_with_caption():
    msg = msg_base(
        photo=[{"file_id": "AAA", "file_unique_id": "u1",
                "width": 90, "height": 90}],
        caption="гляньте, что скинули: token=abc123",
        forward_from={"id": 888, "is_bot": False, "first_name": "Мария"})
    executed, sent, logs = run_update(update_with(msg, 600))
    record("INV-BOT-58 медиа с подписью: исполняющий путь не вызван",
           executed == [])
    body = " ".join(str(s.get("text", "")) for s in sent)
    record("INV-BOT-58 медиа с подписью: карточка отправлена",
           len(sent) >= 1)
    record("INV-BOT-58 медиа с подписью: подпись в карточке без секрета",
           "гляньте" in body and "abc123" not in body)


scenario("критерий 6: пересланное медиа с подписью", s_media_with_caption)


# --- критерий 7: ровно одна строка в лог на пересланное сообщение ----------
def s_single_log_line():
    msg = msg_base(text="еще один пересланный текст",
                   forward_origin={"type": "hidden_user",
                                   "sender_user_name": "X",
                                   "date": 1700000001})
    executed, sent, logs = run_update(update_with(msg, 700))
    forward_logs = [l for l in logs if "пересл" in str(l).lower()]
    record("INV-BOT-58 лог: ровно одна строка на пересланное сообщение",
           len(forward_logs) == 1)


scenario("критерий 7: одна строка в лог", s_single_log_line)


for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
FWDPY

FWD_OUT="$TMP/forward.out"
BOT_PATH="$BOT" python3 "$FWDCHECK" >"$FWD_OUT" 2>"$TMP/forward.err"
rc_fwd=$?
if [[ "$rc_fwd" != 0 ]]; then
  fail "INV-BOT-58: сама проверочная обвязка упала (код $rc_fwd) - см. stderr ниже"
fi
if [[ ! -s "$FWD_OUT" ]]; then
  fail "INV-BOT-58: обвязка не напечатала ни одного PASS/FAIL (см. stderr)"
else
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok ;;
      "FAIL "*) fail "${line#FAIL }" ;;
    esac
  done < "$FWD_OUT"
fi
[[ -s "$TMP/forward.err" ]] && cat "$TMP/forward.err" >&2

# --- INV-BOT-59: единый рубеж маскировки на выходе в Telegram --------------
# Спека: docs/dev/2026-09-19-spec-redact-boundary.md. Реализации еще нет -
# маскировка на границе (внутри api()) сегодня отсутствует вовсе, поэтому
# часть проверок ниже обязана быть КРАСНОЙ. Ключевое отличие от предыдущих
# блоков: транспорт (bot.api) здесь НЕ подменяется - подмена api() обошла бы
# именно тот код, который спека просит защитить. Подменяется только сетевой
# слой ПОД api() (urllib.request.build_opener), поэтому настоящая (будущая)
# логика маскировки внутри api() реально исполняется при каждом вызове.
REDCHECK="$TMP/redact_boundary.py"
cat > "$REDCHECK" <<'REDPY'
import importlib.machinery, importlib.util, json, os, sys
import urllib.parse

path = os.environ["BOT_PATH"]
loader = importlib.machinery.SourceFileLoader("bot_redact", path)
spec = importlib.util.spec_from_file_location("bot_redact", path, loader=loader)
bot = importlib.util.module_from_spec(spec)
loader.exec_module(bot)

results = []


def record(name, cond):
    results.append((name, bool(cond)))


def scenario(name, fn):
    # Как в предыдущих блоках: один упавший сценарий не маскирует остальные.
    try:
        fn()
    except Exception as e:
        record(name, False)
        print("  (%s: %r)" % (name, e), file=sys.stderr)


class _FakeResponse:
    def __init__(self, data):
        self._data = data

    def read(self):
        return self._data

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class _FakeOpener:
    """Стоит вместо реального HTTP-соединения. Разбирает urlencode-тело
    запроса обратно в параметры - так видно, что РЕАЛЬНО ушло бы в Telegram,
    после того как отработает (или не отработает) api()."""

    def __init__(self, calls):
        self._calls = calls

    def open(self, req, timeout=None):
        self._calls.append({
            "url": req.full_url,
            "params": urllib.parse.parse_qs((req.data or b"").decode(),
                                            keep_blank_values=True),
        })
        return _FakeResponse(b'{"ok": true, "result": {"message_id": 1}}')


def with_fake_transport(fn):
    """Подменяет ТОЛЬКО сетевой слой на время fn(); bot.api остается
    настоящим. Возвращает список перехваченных вызовов транспорта."""
    calls = []
    real_build_opener = bot.urllib.request.build_opener
    bot.urllib.request.build_opener = lambda *h: _FakeOpener(calls)
    try:
        fn()
    finally:
        bot.urllib.request.build_opener = real_build_opener
    return calls


def last_param(calls, key):
    if not calls:
        return None
    vals = calls[-1]["params"].get(key)
    return vals[0] if vals else None


def all_text(calls):
    """Текст всех перехваченных чанков подряд (send_message режет длинный
    текст на несколько сообщений/вызовов api())."""
    return " ".join(str((c["params"].get("text") or [""])[0]) for c in calls)


# --- критерии 1-3: api() маскирует text/caption для sendMessage и
# editMessageText - это единственная точка выхода по спеке.
def s_sendmessage_text():
    secret = "смотри token=abc123zz дальше"
    calls = with_fake_transport(lambda: bot.api(
        "tkn", "", "sendMessage", 5, chat_id=1, text=secret))
    record("INV-BOT-59 api sendMessage: вызов дошел до транспорта",
           len(calls) == 1)
    got = last_param(calls, "text")
    record("INV-BOT-59 api sendMessage: секрет в text промаскирован "
           "(критерий 1)", got is not None and "abc123zz" not in got)
    record("INV-BOT-59 api sendMessage: безопасная часть text сохранена",
           got is not None and "смотри" in got and "дальше" in got)


scenario("критерий 1: api sendMessage маскирует text", s_sendmessage_text)


def s_editmessagetext_text():
    secret = "правка: token=xyz9911qq готово"
    calls = with_fake_transport(lambda: bot.api(
        "tkn", "", "editMessageText", 5, chat_id=1, message_id=7,
        text=secret))
    record("INV-BOT-59 api editMessageText: вызов дошел до транспорта",
           len(calls) == 1)
    got = last_param(calls, "text")
    record("INV-BOT-59 api editMessageText: секрет в text промаскирован "
           "(критерий 2)", got is not None and "xyz9911qq" not in got)
    record("INV-BOT-59 api editMessageText: безопасная часть text сохранена",
           got is not None and "правка" in got and "готово" in got)


scenario("критерий 2: api editMessageText маскирует text", s_editmessagetext_text)


def s_sendmessage_caption():
    secret = "подпись token=cap4455rr к фото"
    calls = with_fake_transport(lambda: bot.api(
        "tkn", "", "sendMessage", 5, chat_id=1, caption=secret))
    got = last_param(calls, "caption")
    record("INV-BOT-59 api sendMessage: секрет в caption промаскирован "
           "(критерий 3)", got is not None and "cap4455rr" not in got)
    record("INV-BOT-59 api sendMessage: безопасная часть caption сохранена",
           got is not None and "подпись" in got and "фото" in got)


scenario("критерий 3: api sendMessage маскирует caption", s_sendmessage_caption)


# --- критерий 4: методы без текста вызов не ломают и полей не портят -------
def s_answercallbackquery_unchanged():
    original_text = "token=answercb123"
    calls = with_fake_transport(lambda: bot.api(
        "tkn", "", "answerCallbackQuery", 5, callback_query_id="cq1",
        text=original_text, show_alert=True))
    record("INV-BOT-59 api answerCallbackQuery: вызов не падает",
           len(calls) == 1)
    record("INV-BOT-59 api answerCallbackQuery: callback_query_id не тронут",
           last_param(calls, "callback_query_id") == "cq1")
    record("INV-BOT-59 api answerCallbackQuery: поле text вне границы "
           "маскировки метода - не тронуто побайтно",
           last_param(calls, "text") == original_text)


scenario("критерий 4: answerCallbackQuery не ломается и не портится",
        s_answercallbackquery_unchanged)


def s_getupdates_unchanged():
    calls = with_fake_transport(lambda: bot.api(
        "tkn", "", "getUpdates", 5, offset=42, timeout=30))
    record("INV-BOT-59 api getUpdates: вызов не падает", len(calls) == 1)
    record("INV-BOT-59 api getUpdates: offset не тронут",
           last_param(calls, "offset") == "42")
    record("INV-BOT-59 api getUpdates: timeout не тронут",
           last_param(calls, "timeout") == "30")


scenario("критерий 4: getUpdates не ломается и не портится",
        s_getupdates_unchanged)


# --- критерий 5: сценарий блокера - карточка сессии с именем token=abc123 --
# Проверяем через РЕНДЕР карточки (session_card_view/send_session_card) плюс
# фактическую отправку (транспорт под api() подменен, сам api() настоящий),
# а не прямым вызовом redact() - иначе проверка ничего не говорит про то,
# что реально уходит наружу с текущего пути отправки карточки сессии.
def s_session_card_blocker():
    row = {"short": "sess0001", "title": "token=cardsecret99", "live": True,
           "ctx": None}
    calls = with_fake_transport(lambda: bot.send_session_card(
        "tkn", "", 4242, 777, "myproj", "sess0001", row=row))
    record("INV-BOT-59 карточка сессии: сообщение ушло на транспорт",
           len(calls) == 1)
    got = all_text(calls)
    record("INV-BOT-59 карточка сессии: имя token=... промаскировано в "
           "ОТПРАВЛЕННОМ тексте (блокер состязательного аудита 19.09.2026)",
           "cardsecret99" not in got)
    record("INV-BOT-59 карточка сессии: карточка реально ушла с безопасной "
           "частью (проект), а не пропала целиком", "myproj" in got)


scenario("критерий 5: карточка сессии - блокер token=abc123",
        s_session_card_blocker)


# --- критерий 6: карточка готовности (project, branch) уходит маскированной
def s_readiness_card_project_branch():
    detail = {
        "kind": "done",
        "agent": "a1",
        "project": "myproj token=projsecret1",
        "commit_sha": "deadbeef1234abcd",
        "branch": "feat token=branchsecret2",
        "summary": "готово",
        "changes": [],
    }
    card_text, card_kb = bot.question_card(detail)
    record("INV-BOT-59 карточка готовности: рендер вернул текст карточки",
           card_text is not None)
    kb_json = json.dumps(card_kb, ensure_ascii=False) if card_kb else None
    calls = with_fake_transport(lambda: bot.send_message(
        "tkn", "", 4242, card_text or "", reply_markup=kb_json))
    full = all_text(calls)
    record("INV-BOT-59 карточка готовности: project промаскирован при "
           "отправке", "projsecret1" not in full)
    record("INV-BOT-59 карточка готовности: branch промаскирован при "
           "отправке", "branchsecret2" not in full)
    record("INV-BOT-59 карточка готовности: безопасная часть (myproj, "
           "feat) дошла до отправки", "myproj" in full and "feat" in full)


scenario("критерий 6: карточка готовности project/branch маскируются",
        s_readiness_card_project_branch)


# --- критерий 6 (продолжение): сигнал ожидания уходит маскированным.
# tests/test-waiting-hook.sh подменяет claude-agent-tgbot целиком заглушкой
# (пишет argv в файл) и проверяет только САМ ВЫЗОВ хука ("notify --no-preview
# ..."), а не то, что бот делает с текстом внутри. Маскировка сигнала ожидания
# - работа бота на CLI-пути "notify" (mode_notify), поэтому та часть, что
# реально проходит через границу api(), проверяется здесь, а не в хук-тесте.
def s_waiting_signal_masked():
    os.environ["CLAUDE_AGENT_TG_TOKEN"] = "testtoken"
    os.environ["CLAUDE_AGENT_TG_WHITELIST"] = "4242"
    os.environ["CLAUDE_AGENT_TG_PROXY"] = ""
    argv = ["--no-preview", "сессия", "ждет:", "token=waitsecret6",
            "выбери", "вариант"]

    def run():
        try:
            bot.mode_notify(argv)
        except SystemExit:
            pass

    calls = with_fake_transport(run)
    full = all_text(calls)
    record("INV-BOT-59 сигнал ожидания: сообщение дошло до транспорта",
           len(calls) >= 1)
    record("INV-BOT-59 сигнал ожидания: секрет в тексте промаскирован",
           "waitsecret6" not in full)
    record("INV-BOT-59 сигнал ожидания: безопасная часть текста дошла",
           "выбери" in full and "вариант" in full)


scenario("критерий 6: сигнал ожидания (mode_notify) маскируется",
        s_waiting_signal_masked)


# --- критерий 7: карточка урока проходит БЕЗ маскировки - поля essence/why/
# how_to_apply в отправленном сообщении побайтно равны исходным, включая то,
# что redact() заведомо поймал бы. Без секрета в этих полях проверка молчаливо
# проходила бы и сейчас, и после правильной реализации - секрет обязателен.
def s_lesson_fields_not_masked():
    detail = {
        "kind": "done",
        "agent": "a1",
        "project": "myproj",
        "commit_sha": "deadbeef1234abcd",
        "branch": "main",
        "summary": "готово",
        "changes": [],
        "lessons": [{
            "cid8": "aaaaaaaa",
            "essence": "суть token=lessonsecret3",
            "why": "потому что token=lessonsecret4",
            "how_to_apply": "применяй token=lessonsecret5",
        }],
    }
    card_text, card_kb = bot.question_card(detail)
    kb_json = json.dumps(card_kb, ensure_ascii=False) if card_kb else None
    calls = with_fake_transport(lambda: bot.send_message(
        "tkn", "", 4242, card_text or "", reply_markup=kb_json))
    full = all_text(calls)
    record("INV-BOT-59 карточка урока: essence уходит без маскировки "
           "побайтно", "token=lessonsecret3" in full)
    record("INV-BOT-59 карточка урока: why уходит без маскировки побайтно",
           "token=lessonsecret4" in full)
    record("INV-BOT-59 карточка урока: how_to_apply уходит без маскировки "
           "побайтно", "token=lessonsecret5" in full)


scenario("критерий 7: карточка урока идет без маскировки",
        s_lesson_fields_not_masked)


# --- критерий 8: повторная маскировка уже маскированного текста не портит --
# Гоняем ЧЕРЕЗ ГРАНИЦУ (api реальный) текст, уже прошедший redact() один раз:
# результат обязан остаться тем же самым текстом. У этой проверки нет четкого
# RED сейчас (нулевая маскировка на границе тоже дает "не испортил") - это не
# дефект теста, а свойство самого критерия (см. примечание в отчете).
def s_double_redact_at_boundary():
    secret_text = "ключ: token=doubled789xyz"
    once = bot.redact(secret_text)
    calls = with_fake_transport(lambda: bot.api(
        "tkn", "", "sendMessage", 5, chat_id=1, text=once))
    got = last_param(calls, "text")
    record("INV-BOT-59 повторная маскировка на границе не портит уже "
           "маскированный текст", got == once)


scenario("критерий 8: повторная маскировка безвредна",
        s_double_redact_at_boundary)


for name, cond in results:
    print(("PASS " if cond else "FAIL ") + name)
sys.exit(0)
REDPY

RED_OUT="$TMP/redact_boundary.out"
BOT_PATH="$BOT" python3 "$REDCHECK" >"$RED_OUT" 2>"$TMP/redact_boundary.err"
rc_red=$?
if [[ "$rc_red" != 0 ]]; then
  fail "INV-BOT-59: сама проверочная обвязка упала (код $rc_red) - см. stderr ниже"
fi
if [[ ! -s "$RED_OUT" ]]; then
  fail "INV-BOT-59: обвязка не напечатала ни одного PASS/FAIL (см. stderr)"
else
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok ;;
      "FAIL "*) fail "${line#FAIL }" ;;
    esac
  done < "$RED_OUT"
fi
[[ -s "$TMP/redact_boundary.err" ]] && cat "$TMP/redact_boundary.err" >&2

# --- INV-BOT-59, критерий 10: подпись голосового идет своим транспортом ------
# (multipart) мимо api(), а текст подписи приходит от модели - тот же корень
# "путь отправки в обход границы". Тест писался НЕ вслепую: остаток нашел
# исполнитель уже после реализации.
VOICECHECK="$TMP/voice_redact.py"
cat > "$VOICECHECK" <<'VPY'
import importlib.machinery, importlib.util, os
path = os.environ["BOT_PATH"]
loader = importlib.machinery.SourceFileLoader("bot_v", path)
spec = importlib.util.spec_from_file_location("bot_v", path, loader=loader)
bot = importlib.util.module_from_spec(spec)
loader.exec_module(bot)

seen = {}
def fake_post(token, proxy, method, field, chat_id, p, fields):
    seen.clear(); seen.update(fields); seen["__method"] = method
    return {"ok": True}
bot._post_audio = fake_post
bot.send_voice("t", None, 1, "/tmp/nonexistent.ogg", caption="итог token=abc123 готов")
cap = seen.get("caption", "")
print(("PASS " if "abc123" not in cap else "FAIL ")
      + "INV-BOT-59 подпись голосового: секрет в caption, получено %r" % cap)
print(("PASS " if "итог" in cap else "FAIL ")
      + "INV-BOT-59 подпись голосового: безопасная часть на месте, получено %r" % cap)
VPY
V_OUT="$TMP/voice_redact.out"
BOT_PATH="$BOT" python3 "$VOICECHECK" >"$V_OUT" 2>"$TMP/voice_redact.err"
if [[ ! -s "$V_OUT" ]]; then
  fail "INV-BOT-59 голос: обвязка не напечатала PASS/FAIL ($(head -c 200 "$TMP/voice_redact.err"))"
else
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok ;;
      "FAIL "*) fail "${line#FAIL }" ;;
    esac
  done < "$V_OUT"
fi

echo
echo "test-agent-tgbot: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
