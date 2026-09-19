#!/usr/bin/env python3
"""Кэш имен сессий с сервера claude.ai (спека
docs/dev/2026-09-19-spec-session-titles.md, раздел A).

Приложение хранит переименование мостовой сессии только у себя - в транскрипт
оно не попадает (сервер не ретранслирует rename_session в процесс). Здесь -
единственный источник этого имени: список сессий из API, положенный в локальный
кэш, который потом читает `_rc_meta.py` (режим titles) и, через него, `claude-rc`.

  _rc_titles.py refresh [--max-age-days N] [--timeout S] [--max-pages P]
  _rc_titles.py lookup <bridge_id>

Кэш обновляется целиком списком, а не по одной сессии: переименовать можно
только поднятую сессию, а сервер отдает имена всех, включая опущенные и
заархивированные (см. "Инвариант" в спеке) - значит проверки "перед усыплением"
и TTL по возрасту не нужны, обновление просто идет раз в несколько минут и перед
показом карточки.

Только stdlib (urllib/json/os): вызывается субпроцессом из бота и из claude-rc,
тащить сторонние пакеты в них незачем.
"""

import datetime
import json
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

API_PATH = "/v1/code/sessions"
ANTHROPIC_VERSION = "2023-06-01"
PAGE_LIMIT = 100

DEFAULT_MAX_AGE_DAYS = 60
DEFAULT_TIMEOUT = 10.0
DEFAULT_MAX_PAGES = 5


def _cache_path():
    state_dir = os.environ.get("CLAUDE_RC_STATE_DIR") or \
        os.path.expanduser("~/.claude-control/state")
    return os.path.join(state_dir, "session-titles.json")


def _credentials_path():
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or \
        os.path.expanduser("~/.claude")
    return os.path.join(config_dir, ".credentials.json")


def _read_token():
    """(token, "") или (None, сообщение) - сообщение никогда не несет значения
    токена, только путь к файлу и что в нем не так."""
    path = _credentials_path()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None, "нет файла с токеном или он не JSON: %s" % path
    token = ((data or {}).get("claudeAiOauth") or {}).get("accessToken")
    if not isinstance(token, str) or not token:
        return None, "в %s нет claudeAiOauth.accessToken" % path
    return token, ""


def _parse_iso(ts):
    if not isinstance(ts, str) or not ts:
        return None
    s = ts[:-1] + "+00:00" if ts.endswith("Z") else ts
    try:
        return datetime.datetime.fromisoformat(s)
    except ValueError:
        return None


def _iso_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


def _load_cache_titles(path):
    """Прежние записи кэша - для слияния. Отсутствие или порча файла - пустой
    словарь: слияние с пустышкой просто ничего не добавляет от старого."""
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    titles = data.get("titles") if isinstance(data, dict) else None
    return titles if isinstance(titles, dict) else {}


def _atomic_write_json(path, data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".session-titles-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _is_posint(s):
    return s.isdigit() and int(s) > 0


def _fetch_page(base, token, timeout, cursor):
    """Одна страница /v1/code/sessions. Возвращает dict ответа или бросает
    _FetchError(rc) - код возврата уже решен на месте ошибки."""
    params = {"limit": PAGE_LIMIT}
    if cursor:
        params["cursor"] = cursor
    url = base.rstrip("/") + API_PATH + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + token,
        "anthropic-version": ANTHROPIC_VERSION,
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            sys.stderr.write("сервер не авторизовал запрос (код %s)\n" % e.code)
            raise _FetchError(3)
        sys.stderr.write("сервер ответил ошибкой (код %s)\n" % e.code)
        raise _FetchError(4)
    except (urllib.error.URLError, OSError) as e:
        sys.stderr.write("сеть: %s\n" % e)
        raise _FetchError(4)
    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        sys.stderr.write("ответ сервера не JSON\n")
        raise _FetchError(4)
    if not isinstance(data, dict) or not isinstance(data.get("data"), list):
        sys.stderr.write("ответ сервера не по формату\n")
        raise _FetchError(4)
    return data


class _FetchError(Exception):
    def __init__(self, rc):
        super().__init__(rc)
        self.rc = rc


def cmd_refresh(argv):
    max_age_days = DEFAULT_MAX_AGE_DAYS
    timeout = DEFAULT_TIMEOUT
    max_pages = DEFAULT_MAX_PAGES
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--max-age-days" and i + 1 < len(argv):
            i += 1
            if not _is_posint(argv[i]):
                sys.stderr.write("--max-age-days требует целое число > 0\n")
                return 2
            max_age_days = int(argv[i])
        elif a == "--timeout" and i + 1 < len(argv):
            i += 1
            try:
                timeout = float(argv[i])
                if timeout <= 0:
                    raise ValueError
            except ValueError:
                sys.stderr.write("--timeout требует положительное число\n")
                return 2
        elif a == "--max-pages" and i + 1 < len(argv):
            i += 1
            if not _is_posint(argv[i]):
                sys.stderr.write("--max-pages требует целое число > 0\n")
                return 2
            max_pages = int(argv[i])
        else:
            sys.stderr.write("аргумент не распознан: %s\n" % a)
            return 2
        i += 1

    token, err = _read_token()
    if token is None:
        sys.stderr.write(err + "\n")
        return 3

    base = os.environ.get("CLAUDE_RC_TITLES_API", "https://api.anthropic.com")
    cutoff = datetime.datetime.now(datetime.timezone.utc) - \
        datetime.timedelta(days=max_age_days)

    fetched = {}
    fetched_count = 0
    pages = 0
    cursor = None
    while True:
        try:
            data = _fetch_page(base, token, timeout, cursor)
        except _FetchError as e:
            return e.rc
        items = data.get("data") or []
        for it in items:
            if not isinstance(it, dict):
                continue
            sid = it.get("id")
            if not isinstance(sid, str) or not sid:
                continue
            fetched_count += 1
            title = it.get("title")
            fetched[sid] = {
                "title": title if isinstance(title, str) else "",
                "updated_at": it.get("updated_at")
                if isinstance(it.get("updated_at"), str) else "",
                "status": it.get("status")
                if isinstance(it.get("status"), str) else "",
            }
        pages += 1
        cursor = data.get("next_cursor")
        if not cursor or pages >= max_pages:
            break
        last_dt = _parse_iso(items[-1].get("updated_at")) if items else None
        if last_dt is not None and last_dt < cutoff:
            break

    cache_path = _cache_path()
    merged = dict(_load_cache_titles(cache_path))
    for sid, rec in fetched.items():
        if rec["title"]:
            merged[sid] = rec
        # пустой/отсутствующий title не затирает уже известное имя (и не
        # заводит запись под пустое имя там, где ее раньше не было)

    _atomic_write_json(cache_path,
                        {"schema": 1, "fetched_at": _iso_now(),
                         "titles": merged})
    print("titles: %d known, %d fetched, %d pages"
          % (len(merged), fetched_count, pages))
    return 0


def cmd_lookup(argv):
    if len(argv) != 1 or not argv[0]:
        sys.stderr.write("usage: _rc_titles.py lookup <bridge_id>\n")
        return 2
    bridge_id = argv[0]
    path = _cache_path()
    if not os.path.isfile(path):
        return 1
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        sys.stderr.write("кэш имен сессий поврежден: %s\n" % path)
        return 1
    if not isinstance(data, dict) or data.get("schema") != 1 or \
            not isinstance(data.get("titles"), dict):
        sys.stderr.write("кэш имен сессий поврежден (не та схема): %s\n" % path)
        return 1
    rec = data["titles"].get(bridge_id)
    title = rec.get("title") if isinstance(rec, dict) else None
    if not isinstance(title, str) or not title:
        return 1
    sys.stdout.write(title + "\n")
    return 0


def main(argv):
    if not argv:
        sys.stderr.write("usage: _rc_titles.py refresh|lookup ...\n")
        return 2
    mode, rest = argv[0], argv[1:]
    if mode == "refresh":
        return cmd_refresh(rest)
    if mode == "lookup":
        return cmd_lookup(rest)
    sys.stderr.write("usage: _rc_titles.py refresh|lookup ...\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
