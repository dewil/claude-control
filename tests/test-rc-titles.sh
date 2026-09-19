#!/usr/bin/env bash
# Tests for bin/_rc_titles.py - кэш серверных имен сессий claude.ai (спека
# docs/dev/2026-09-19-spec-session-titles.md, раздел A).
#
# _rc_titles.py refresh [--max-age-days N] [--timeout S] [--max-pages P]
# _rc_titles.py lookup <bridge_id>
#
# Сервер API поднимается локально (python3 http.server), базовый URL уходит
# через CLAUDE_RC_TITLES_API. Реализации еще нет - все проверки КРАСНЫЕ.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TITLES="$HERE/../bin/_rc_titles.py"
TMP="$(mktemp -d)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# Локальные адреса не должны уходить через прокси этой машины - иначе тест
# зависит от того, поднят ли туннель, а не от реализации.
export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"

export CLAUDE_CONFIG_DIR="$TMP/claude"
export CLAUDE_RC_STATE_DIR="$TMP/state"
mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_RC_STATE_DIR"

TOKEN="tok-SECRET-123"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$TOKEN" > "$CLAUDE_CONFIG_DIR/.credentials.json"

CACHE="$CLAUDE_RC_STATE_DIR/session-titles.json"

refresh() { python3 "$TITLES" refresh "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
lookup()  { python3 "$TITLES" lookup "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

# --- фикстура сервера: поведение выбирается переменной SCENARIO ---
SERVER_PY="$TMP/fixture_server.py"
cat > "$SERVER_PY" <<'PYEOF'
import http.server, json, os, sys
from urllib.parse import urlparse, parse_qs

SCENARIO = os.environ["SCENARIO"]
PORT = int(sys.argv[1])
TOKEN = os.environ.get("FIXTURE_TOKEN", "")

PAGE1 = {"data": [
    {"id": "cse_aaa", "title": "Первая", "status": "active",
     "connection_status": "connected", "updated_at": "2026-09-01T00:00:00Z"},
    {"id": "cse_bbb", "title": "Вторая", "status": "active",
     "connection_status": "disconnected", "updated_at": "2026-09-02T00:00:00Z"},
], "next_cursor": "PAGE2CURSOR"}
PAGE2 = {"data": [
    {"id": "cse_ccc", "title": "Третья", "status": "archived",
     "connection_status": "disconnected", "updated_at": "2026-09-03T00:00:00Z"},
], "next_cursor": None}
# Второй прогон: одна страница без курсора, уже известная сессия с пустым
# именем (не должно затереть прежнее); остальные id в выдаче отсутствуют и
# обязаны остаться в кэше от первого прогона (слияние, не перезапись).
MERGE_EMPTY_TITLE = {"data": [
    {"id": "cse_aaa", "title": "", "status": "active",
     "connection_status": "connected", "updated_at": "2026-09-04T00:00:00Z"},
], "next_cursor": None}
# Для --max-pages 1: обе страницы имеют next_cursor - без лимита листание
# продолжилось бы на вторую.
LIMITED_PAGE1 = {"data": [
    {"id": "cse_lim1", "title": "лимит1", "status": "active",
     "connection_status": "connected", "updated_at": "2026-09-05T00:00:00Z"},
], "next_cursor": "LIMITEDCURSOR"}
LIMITED_PAGE2 = {"data": [
    {"id": "cse_lim2", "title": "лимит2", "status": "active",
     "connection_status": "connected", "updated_at": "2026-09-05T00:00:00Z"},
], "next_cursor": None}

hits = {"n": 0}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        hits["n"] += 1
        q = parse_qs(urlparse(self.path).query)

        if SCENARIO == "paged":
            auth = self.headers.get("Authorization", "")
            ver = self.headers.get("anthropic-version", "")
            if auth != "Bearer " + TOKEN:
                self._send(403, b'{"error":"bad token"}'); return
            if ver != "2023-06-01":
                self._send(400, b'{"error":"bad version header"}'); return
            if hits["n"] == 1:
                self._send(200, json.dumps(PAGE1).encode())
            else:
                if q.get("cursor", [None])[0] != "PAGE2CURSOR":
                    self._send(400, b'{"error":"missing or wrong cursor"}')
                else:
                    self._send(200, json.dumps(PAGE2).encode())
        elif SCENARIO == "merge_empty_title":
            self._send(200, json.dumps(MERGE_EMPTY_TITLE).encode())
        elif SCENARIO == "unauth":
            self._send(401, b'{"error":"unauthorized"}')
        elif SCENARIO == "servererror":
            self._send(500, b'{"error":"boom"}')
        elif SCENARIO == "badjson":
            self._send(200, b'{not valid json')
        elif SCENARIO == "maxpages":
            if hits["n"] == 1:
                self._send(200, json.dumps(LIMITED_PAGE1).encode())
            else:
                self._send(200, json.dumps(LIMITED_PAGE2).encode())
        else:
            self._send(500, b'{"error":"unknown scenario"}')


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

find_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_ready() { # <port>
  python3 - "$1" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
for _ in range(50):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.settimeout(0.2)
        s.connect(("127.0.0.1", port))
        sys.exit(0)
    except OSError:
        time.sleep(0.1)
    finally:
        s.close()
sys.exit(1)
PY
}

start_server() { # <scenario>
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" >/dev/null 2>&1
  PORT="$(find_free_port)"
  SCENARIO="$1" FIXTURE_TOKEN="$TOKEN" python3 "$SERVER_PY" "$PORT" &
  SERVER_PID=$!
  wait_ready "$PORT" || fail "фикстура-сервер ($1) не поднялась на порту $PORT"
  export CLAUDE_RC_TITLES_API="http://127.0.0.1:$PORT"
}

stop_server() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" >/dev/null 2>&1
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}

cache_title() { # <id> -> title из кэша (или пусто)
  python3 -c "
import json, sys
try:
    d = json.load(open('$CACHE', encoding='utf-8'))
except Exception:
    sys.exit(0)
print(d.get('titles', {}).get('$1', {}).get('title', ''))
"
}
cache_has() { [[ -n "$(cache_title "$1")" ]]; }

echo "=== refresh: две страницы, курсор обязателен на второй ==="
start_server paged
rc="$(refresh --max-pages 5)"
[[ "$rc" == 0 ]] && ok || fail "refresh (paged) код $rc, ожидалось 0 ($(cat "$TMP/err"))"
[[ -f "$CACHE" ]] && ok || fail "кэш не создан"
[[ "$(cache_title cse_aaa)" == "Первая" ]] && ok || fail "cse_aaa не попал в кэш"
[[ "$(cache_title cse_bbb)" == "Вторая" ]] && ok || fail "cse_bbb не попал в кэш"
# cse_ccc лежит на второй странице - попадет в кэш, только если refresh
# передал курсор именно тот, что вернула первая страница (иначе сервер
# отвечает 400, и вся операция должна была бы провалиться).
[[ "$(cache_title cse_ccc)" == "Третья" ]] && ok || fail "cse_ccc (вторая страница) не найден - курсор не дошел"
[[ "$(python3 -c "import json; print(json.load(open('$CACHE'))['schema'])" 2>/dev/null)" == "1" ]] \
  && ok || fail "поле schema не равно 1"
grep -Eq '^titles: 3 known, 3 fetched, 2 pages$' "$TMP/out" \
  && ok || fail "stdout не по формату: $(cat "$TMP/out")"
stop_server

echo "=== refresh: повторный прогон одной страницей не теряет id со второй, пустой title не затирает ==="
start_server merge_empty_title
rc="$(refresh --max-pages 5)"
[[ "$rc" == 0 ]] && ok || fail "повторный refresh код $rc, ожидалось 0"
[[ "$(cache_title cse_aaa)" == "Первая" ]] && ok || fail "пустой title затер известное имя cse_aaa: '$(cache_title cse_aaa)'"
[[ "$(cache_title cse_bbb)" == "Вторая" ]] && ok || fail "cse_bbb (вне свежей страницы) пропал из кэша"
[[ "$(cache_title cse_ccc)" == "Третья" ]] && ok || fail "cse_ccc (вне свежей страницы) пропал из кэша"
stop_server

echo "=== refresh: 401 -> код 3, кэш не тронут, токен не в stderr ==="
BEFORE="$(cat "$CACHE")"
start_server unauth
rc="$(refresh)"
[[ "$rc" == 3 ]] && ok || fail "401 дал код $rc, ожидалось 3"
[[ "$(cat "$CACHE")" == "$BEFORE" ]] && ok || fail "кэш изменился после 401"
[[ -s "$TMP/err" ]] && ok || fail "нет строки в stderr про 401"
grep -q "$TOKEN" "$TMP/err" && fail "токен утек в stderr при 401" || ok
stop_server

echo "=== refresh: 500 -> код 4, кэш не тронут ==="
start_server servererror
rc="$(refresh)"
[[ "$rc" == 4 ]] && ok || fail "500 дал код $rc, ожидалось 4"
[[ "$(cat "$CACHE")" == "$BEFORE" ]] && ok || fail "кэш изменился после 500"
grep -q "$TOKEN" "$TMP/err" && fail "токен утек в stderr при 500" || ok
stop_server

echo "=== refresh: битый JSON -> код 4, кэш не тронут ==="
start_server badjson
rc="$(refresh)"
[[ "$rc" == 4 ]] && ok || fail "битый JSON дал код $rc, ожидалось 4"
[[ "$(cat "$CACHE")" == "$BEFORE" ]] && ok || fail "кэш изменился после битого JSON"
grep -q "$TOKEN" "$TMP/err" && fail "токен утек в stderr при битом JSON" || ok
stop_server

echo "=== lookup: известный и неизвестный id ==="
rc="$(lookup cse_aaa)"
[[ "$rc" == 0 ]] && ok || fail "lookup известного id код $rc, ожидалось 0"
[[ "$(cat "$TMP/out")" == "Первая" ]] && ok || fail "lookup вернул '$(cat "$TMP/out")', ожидалось 'Первая'"

rc="$(lookup cse_no_such)"
[[ "$rc" == 1 ]] && ok || fail "lookup неизвестного id код $rc, ожидалось 1"
[[ ! -s "$TMP/out" ]] && ok || fail "lookup неизвестного id напечатал что-то в stdout: '$(cat "$TMP/out")'"

echo "=== lookup: кэша нет -> код 1, stdout пуст ==="
rm -f "$CACHE"
rc="$(lookup cse_aaa)"
[[ "$rc" == 1 ]] && ok || fail "lookup без кэша код $rc, ожидалось 1"
[[ ! -s "$TMP/out" ]] && ok || fail "lookup без кэша напечатал что-то в stdout"

echo "=== lookup: кэш битый -> код 1 плюс строка в stderr ==="
printf 'не json вовсе' > "$CACHE"
rc="$(lookup cse_aaa)"
[[ "$rc" == 1 ]] && ok || fail "lookup с битым кэшем код $rc, ожидалось 1"
[[ -s "$TMP/err" ]] && ok || fail "lookup с битым кэшем ничего не написал в stderr"
rm -f "$CACHE"

echo "=== refresh: --max-pages 1 останавливает листание ==="
start_server maxpages
rc="$(refresh --max-pages 1)"
[[ "$rc" == 0 ]] && ok || fail "--max-pages 1 код $rc, ожидалось 0"
[[ "$(cache_title cse_lim1)" == "лимит1" ]] && ok || fail "первая страница не попала в кэш"
cache_has cse_lim2 && fail "--max-pages 1 не остановил листание: вторая страница все равно в кэше" || ok
stop_server
rm -f "$CACHE"

echo "=== refresh: нет файла credentials -> код 3, кэш (отсутствующий) не создается ==="
mv "$CLAUDE_CONFIG_DIR/.credentials.json" "$TMP/creds.bak"
start_server paged
rc="$(refresh)"
[[ "$rc" == 3 ]] && ok || fail "без credentials код $rc, ожидалось 3"
[[ ! -f "$CACHE" ]] && ok || fail "кэш создан без токена"
grep -q "$TOKEN" "$TMP/err" && fail "токен утек в stderr без credentials" || ok
mv "$TMP/creds.bak" "$CLAUDE_CONFIG_DIR/.credentials.json"
stop_server

echo "=== refresh: поле accessToken отсутствует -> код 3 ==="
printf '{"claudeAiOauth":{}}\n' > "$TMP/no-token-creds.json"
cp "$CLAUDE_CONFIG_DIR/.credentials.json" "$TMP/creds.good.bak"
cp "$TMP/no-token-creds.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
start_server paged
rc="$(refresh)"
[[ "$rc" == 3 ]] && ok || fail "без accessToken код $rc, ожидалось 3"
cp "$TMP/creds.good.bak" "$CLAUDE_CONFIG_DIR/.credentials.json"
stop_server

echo "=== refresh: мусорный аргумент -> код 2, кэш не тронут ==="
rc="$(refresh --max-pages не-число)"
[[ "$rc" == 2 ]] && ok || fail "мусорный --max-pages код $rc, ожидалось 2"

echo
echo "test-rc-titles: $PASS ok, $FAIL FAIL"
[[ "$FAIL" == 0 ]]
