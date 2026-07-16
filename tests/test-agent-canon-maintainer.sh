#!/usr/bin/env bash
# Tests for bin/claude-agent-canon-maintainer: fleet-reconciler canon-sync (этап 8c).
# Контракт: docs/design-2026-07-14-stage8-canon-sync.md §5; план docs/dev/plan-2026-07-14-stage8-part-c.md.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CM="$HERE/../bin/claude-agent-canon-maintainer"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CANON_DIR="$TMP/canon"
# замок изолируем от боевого фикс-пути (T16): тесты не должны толкаться с
# таймером на этой же машине и друг с другом
export CLAUDE_CANON_LOCK="$TMP/canon/.lock"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
assert() { # <desc> <expected-exit> <cmd...>
  local desc="$1" want="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [[ "$got" == "$want" ]]; then ok; else
    fail "$desc: exit $got != $want ($(head -c200 "$TMP/err"))"; fi
}
out_has() { # <desc> <needle> (ищет в $TMP/out)
  local desc="$1" needle="$2"
  if grep -q "$needle" "$TMP/out"; then ok; else
    fail "$desc: '$needle' нет в stdout ($(head -c200 "$TMP/out"))"; fi
}
jq_out() { # <py-expr over dict d> (парсит $TMP/out как JSON)
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$TMP/out" "$1"
}
jq_file() { # <file> <py-expr over dict d>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))' "$1" "$2"
}

# --- T01: скелет ---

# 1) once на пустом инвентаре (fleet.yaml нет): 0 проектов, exit 0, machine-log
assert "once: пустой инвентарь" 0 "$CM" once
out_has "once: лог несет pass_id" '"pass_id"'
out_has "once: лог несет projects=0" '"projects": 0'

# 2) status: валидный JSON, armed=false по умолчанию, пустые проекты
assert "status: exit 0" 0 "$CM" status
[[ "$(jq_out 'd["armed"]')" == "False" ]] && ok || fail "status: armed по умолчанию не false"
[[ "$(jq_out 'len(d["projects"])')" == "0" ]] && ok || fail "status: projects не пуст"

# 3) arm / disarm: durable-флаг
assert "arm: exit 0" 0 "$CM" arm
"$CM" status >"$TMP/out" 2>/dev/null
[[ "$(jq_out 'd["armed"]')" == "True" ]] && ok || fail "arm: status не показывает armed=true"
assert "disarm: exit 0" 0 "$CM" disarm
"$CM" status >"$TMP/out" 2>/dev/null
[[ "$(jq_out 'd["armed"]')" == "False" ]] && ok || fail "disarm: status не показывает armed=false"

# 4) durable armed.json: atomic-write, без temp-мусора
assert "arm повторно" 0 "$CM" arm
ls "$TMP/canon"/.armed.json.tmp.* >/dev/null 2>&1 && fail "temp-мусор от atomic-write" || ok

# 5) singleton-lock: параллельный once при удержанном локе -> exit 5
python3 - "$CM" "$TMP" <<'PY' && ok || fail "lock-busy: параллельный once не отвергнут (want exit 5)"
import fcntl, os, subprocess, sys
cm, tmp = sys.argv[1], sys.argv[2]
lock_path = os.path.join(os.environ["CLAUDE_CANON_DIR"], ".lock")
os.makedirs(os.path.dirname(lock_path), exist_ok=True)
fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
r = subprocess.run([cm, "once"], capture_output=True)
sys.exit(0 if r.returncode == 5 else 1)
PY

# 5b) T16: дефолт замка - фикс-путь вне CLAUDE_CANON_DIR (оба триггера берут
# один и тот же независимо от env); CLAUDE_CANON_LOCK - явный override
python3 - "$CM" <<'PY' && ok || fail "T16: lock_path не фикс-путь"
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
cm = importlib.util.module_from_spec(spec)
loader.exec_module(cm)
env = os.environ
env["CLAUDE_CANON_LOCK"] = "/x/override.lock"
assert cm.lock_path() == "/x/override.lock"
del env["CLAUDE_CANON_LOCK"]
env["XDG_RUNTIME_DIR"] = "/tmp"
assert cm.lock_path() == "/tmp/claude-stage8-canon.lock", cm.lock_path()
del env["XDG_RUNTIME_DIR"]
p = cm.lock_path()
assert p.startswith("/") and f"-{os.getuid()}." in os.path.basename(p), p
assert env["CLAUDE_CANON_DIR"] not in p, f"фолбэк зависит от CANON_DIR: {p}"
PY

# 6) ack без latch: ничего снимать -> exit 0 с сообщением
assert "ack: нет latch -> no-op" 0 "$CM" ack canon-v1 canary

# 7) recover без проектов: no-op exit 0
assert "recover: пустой инвентарь" 0 "$CM" recover

# 8) неизвестная субкоманда -> exit 2
assert "неизвестная субкоманда" 2 "$CM" bogus

# фикстура: локальный "канон-репо" (нужна уже T02-проходам: офлайн-зеркало)
CANON_SRC="$TMP/canon-src"
mkdir -p "$CANON_SRC/rules"
git -C "$CANON_SRC" init -q
printf 'universal:\n  - rules/a.md\n' > "$CANON_SRC/manifest.yaml"
printf 'rule A v1\n' > "$CANON_SRC/rules/a.md"
printf '{"schema_version": 1}\n' > "$CANON_SRC/canon.lock.json"
git -C "$CANON_SRC" add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$CANON_SRC" commit -qm "canon v1"
git -C "$CANON_SRC" tag -a canon-v1 -m "release v1"
V1_SHA=$(git -C "$CANON_SRC" rev-parse 'canon-v1^{commit}')
export CLAUDE_CANON_REPO_URL="$CANON_SRC"

# --- T02: fleet.yaml парсер + валидатор ---

FLEET="$TMP/canon/fleet.yaml"
mkdir -p "$TMP/canon" "$TMP/gitproj" "$TMP/plainproj"
git -C "$TMP/gitproj" init -q

# 9) валидный fleet.yaml: git-проект policy=branch + не-git policy=observe
cat > "$FLEET" <<EOF
# инвентарь fleet (тест)
webapp:
  repo_url: git@github.com:dewil/webapp.git
  policy: branch
  ring: canary
local-vault:
  path: $TMP/plainproj
  policy: observe
local-git:
  path: $TMP/gitproj
  policy: branch
  smoke_cmd: "true"
EOF
assert "once: валидный fleet" 0 "$CM" once
out_has "once: видит 3 проекта" '"projects": 3'

# 10) status перечисляет проекты
"$CM" status >"$TMP/out" 2>/dev/null
[[ "$(jq_out 'sorted(d["projects"].keys())')" == "['webapp', 'local-git', 'local-vault']" ]] \
  && ok || fail "status: не перечислил проекты fleet"

# 11) невалидная policy -> exit 2
cat > "$FLEET" <<EOF
bad:
  path: $TMP/gitproj
  policy: yolo
EOF
assert "невалидная policy" 2 "$CM" once

# 12) не-git path с мутирующей policy -> exit 2 (R2)
cat > "$FLEET" <<EOF
vault:
  path: $TMP/plainproj
  policy: branch
EOF
assert "не-git + branch отвергнут (R2)" 2 "$CM" once

# 13) ни path, ни repo_url -> exit 2
cat > "$FLEET" <<EOF
ghost:
  policy: observe
EOF
assert "нет path/repo_url" 2 "$CM" once

# 14) невалидный ring -> exit 2
cat > "$FLEET" <<EOF
r:
  path: $TMP/gitproj
  policy: observe
  ring: turbo
EOF
assert "невалидный ring" 2 "$CM" once

rm -f "$FLEET"

# --- T03: host-side зеркало канона (фикстура создана до T02) ---

# 15) mirror: первый вызов клонирует, резолвит тег -> commit, достает lock
assert "mirror: sync + resolve" 0 "$CM" mirror canon-v1
[[ "$(jq_out 'd["commit_sha"]')" == "$V1_SHA" ]] && ok || fail "mirror: commit_sha != тегу"
[[ "$(jq_out 'd["lock_found"]')" == "True" ]] && ok || fail "mirror: lock не достался"
[[ -d "$TMP/canon/mirror" ]] && ok || fail "mirror: каталог зеркала не создан"

# 16) новая ревизия: fetch подхватывает canon-v2
printf 'rule A v2\n' > "$CANON_SRC/rules/a.md"
git -C "$CANON_SRC" add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$CANON_SRC" commit -qm "canon v2"
git -C "$CANON_SRC" tag -a canon-v2 -m "release v2"
V2_SHA=$(git -C "$CANON_SRC" rev-parse 'canon-v2^{commit}')
assert "mirror: fetch новой ревизии" 0 "$CM" mirror canon-v2
[[ "$(jq_out 'd["commit_sha"]')" == "$V2_SHA" ]] && ok || fail "mirror: v2 commit_sha не совпал"

# 17) прошлый lock достается по СТАРОМУ sha (полная история, для отката)
assert "mirror: прошлая ревизия жива" 0 "$CM" mirror canon-v1
[[ "$(jq_out 'd["commit_sha"]')" == "$V1_SHA" ]] && ok || fail "mirror: v1 недоступен после fetch v2"

# 18) несуществующий тег -> transient exit 3 (transport)
assert "mirror: неизвестный тег" 3 "$CM" mirror canon-v99

# 19) недоступный источник -> transient exit 3, зеркало не сломано
CLAUDE_CANON_REPO_URL="$TMP/no-such-repo" "$CM" mirror canon-v1 >"$TMP/out" 2>"$TMP/err"
[[ "$?" == "3" ]] && ok || fail "mirror: недоступный источник не дал exit 3"
assert "mirror: после сбоя источника зеркало работает" 0 "$CM" mirror canon-v1

# --- T04: карта exit-кодов delta (unit через importlib на бинаре) ---

# 20) все 5 кодов классифицируются; stdout парсится как недоверенный JSON
python3 - "$CM" "$HERE/mock-canon-delta" <<'PY' && ok || fail "delta-карта: классификация кодов"
import importlib.machinery, importlib.util, json, os, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
cm = importlib.util.module_from_spec(spec)
loader.exec_module(cm)
os.environ["CLAUDE_CANON_DELTA"] = sys.argv[2]
want = {"0": "ok", "10": "conflicts", "1": "transient", "2": "incompat", "3": "recovery"}
for code, klass in want.items():
    os.environ["MOCK_DELTA_EXIT"] = code
    res = cm.delta_call(["sync", "--lock", "x"])
    assert res["klass"] == klass, f"exit {code}: {res['klass']} != {klass}"
    assert res["code"] == int(code)
# недоверенный stdout: битый JSON не роняет, verdict=None
os.environ["MOCK_DELTA_EXIT"] = "0"
os.environ["MOCK_DELTA_JSON"] = "not-a-json {"
res = cm.delta_call(["sync"])
assert res["verdict"] is None and res["klass"] == "ok"
# неизвестный код -> unknown (fail-closed, не ok)
os.environ["MOCK_DELTA_EXIT"] = "42"
os.environ.pop("MOCK_DELTA_JSON")
res = cm.delta_call(["sync"])
assert res["klass"] == "unknown", res["klass"]
sys.exit(0)
PY

# --- T05: walking skeleton - полный observe-проход ---

export CLAUDE_CANON_DELTA="$HERE/mock-canon-delta"
export MOCK_DELTA_EXIT=0
export MOCK_DELTA_JSON='{"counts": {"apply": 1, "escalate": 0, "retire": 0, "noop": 2}, "release_ready": true}'

# intent для gitproj (fleet-managed observe-цель)
mkdir -p "$TMP/gitproj/.claude"
printf 'project_type: []\ntrack: stable\n' > "$TMP/gitproj/.claude/canon.intent.yaml"

cat > "$FLEET" <<EOF
local-git:
  path: $TMP/gitproj
  policy: branch
remote-only:
  repo_url: $TMP/no-such-remote.git
  policy: branch
local-vault:
  path: $TMP/plainproj
  policy: observe
EOF

# снапшот деревьев проектов (проверка "ничего не мутируем")
find "$TMP/gitproj" "$TMP/plainproj" -type f | sort > "$TMP/before"

# 21) полный проход: mirror + per-project вердикты, exit 0
assert "once: полный observe-проход" 0 "$CM" once
out_has "once: вердикт local-git" '"project": "local-git"'
out_has "once: local-git классифицирован" '"klass": "ok"'
out_has "once: недоступный remote -> transient" '"klass": "transient"'
out_has "once: вердикт vault" '"project": "local-vault"'

# 22) digest-файл создан и несет проекты
DIGEST=$(ls -t "$TMP/canon/digest/"*.md 2>/dev/null | head -1)
[[ -n "$DIGEST" ]] && ok || fail "digest: файл не создан"
grep -q "local-git" "$DIGEST" && ok || fail "digest: нет local-git"
grep -q "remote-only" "$DIGEST" && ok || fail "digest: нет remote-only"

# 23) проекты не мутированы (observe!)
find "$TMP/gitproj" "$TMP/plainproj" -type f | sort > "$TMP/after"
diff -q "$TMP/before" "$TMP/after" >/dev/null && ok || fail "observe мутировал проекты"

# 24) intent отсутствует -> needs-bootstrap (не ошибка прохода)
rm "$TMP/gitproj/.claude/canon.intent.yaml"
assert "once: без intent" 0 "$CM" once
out_has "once: needs-bootstrap" 'needs-bootstrap'
printf 'project_type: []\ntrack: stable\n' > "$TMP/gitproj/.claude/canon.intent.yaml"

# 25) delta exit 10 (conflicts) -> вердикт conflicts, проход жив, exit 0
MOCK_DELTA_EXIT=10 "$CM" once >"$TMP/out" 2>"$TMP/err"
[[ "$?" == "0" ]] && ok || fail "once: conflicts уронил проход"
out_has "once: klass=conflicts" '"klass": "conflicts"'

# 26) real-delta интеграция (если toolkit доступен): plan против handcrafted lock
REAL_DELTA="/Users/dwl/Work/claude-toolkit/scripts/canon-delta.py"
if [[ -f "$REAL_DELTA" ]]; then
  # настоящий lock: rules/a.md с корректным git-blob-sha
  python3 - "$TMP" <<'PY'
import hashlib, json, sys
tmp = sys.argv[1]
data = open(f"{tmp}/canon-src/rules/a.md", "rb").read()
sha = hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()
lock = {"schema_version": 1, "manifest_digest": "t" * 64,
        "files": {"rules/a.md": {"blob_sha": sha, "mode": "100644"}},
        "membership": {"rules/a.md": ["universal"]},
        "min_cli_version": 1, "plugin_source": None}
json.dump(lock, open(f"{tmp}/canon-src/canon.lock.json", "w"))
PY
  git -C "$CANON_SRC" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$CANON_SRC" commit -qm "real lock"
  git -C "$CANON_SRC" tag -a canon-v3 -m "release v3"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "real-delta: проход упал ($(head -c200 "$TMP/err"))"
  grep -q '"klass": "ok"' "$TMP/out" && ok || fail "real-delta: klass не ok"
  # plan read-only: rules/a.md НЕ материализован в проект
  [[ ! -e "$TMP/gitproj/rules/a.md" ]] && ok || fail "real-delta: plan мутировал проект!"
else
  echo "skip: real-delta недоступен ($REAL_DELTA)"
fi

# --- T08: observe-first + kill switch ---

export MOCK_DELTA_EXIT=0
export CLAUDE_CANON_DELTA="$HERE/mock-canon-delta"
export CLAUDE_CANON_OBSERVE_PASSES=2

# 27) arm взводит observe-first счетчик
assert "arm с observe-first" 0 "$CM" arm
"$CM" status >"$TMP/out" 2>/dev/null
[[ "$(jq_out 'd["observe_passes_left"]')" == "2" ]] && ok || fail "arm: observe_passes_left != 2"

# 28) armed-проход декрементирует счетчик, режим observe-first
assert "once: observe-first проход" 0 "$CM" once
out_has "once: mode=observe-first" '"mode": "observe-first"'
"$CM" status >"$TMP/out" 2>/dev/null
[[ "$(jq_out 'd["observe_passes_left"]')" == "1" ]] && ok || fail "once: счетчик не декрементнулся"

# 29) после исчерпания счетчика - mode=armed
"$CM" once >/dev/null 2>&1
assert "once: третий проход" 0 "$CM" once
out_has "once: mode=armed" '"mode": "armed"'

# 30) disarm мгновенно возвращает observe
assert "disarm (kill switch)" 0 "$CM" disarm
assert "once после disarm" 0 "$CM" once
out_has "once: mode=observe" '"mode": "observe"'

# --- T09: layout клонов fleet-репо (модель B) ---

# фикстура: "удаленный" fleet-репо (bare) с main и intent внутри
FLEET_SRC="$TMP/fleet-src"
mkdir -p "$FLEET_SRC"
git -C "$FLEET_SRC" init -q -b main
mkdir -p "$FLEET_SRC/.claude"
printf 'project_type: []\ntrack: stable\n' > "$FLEET_SRC/.claude/canon.intent.yaml"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$FLEET_SRC" add -A 2>/dev/null
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$FLEET_SRC" commit -qm "init fleet project"
FLEET_BARE="$TMP/fleet-bare.git"
git clone -q --bare "$FLEET_SRC" "$FLEET_BARE"

export MOCK_DELTA_EXIT=0
cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF

# 31) once клонирует repo_url в canon/repos/<name>, вердикт по клону (не skipped)
assert "once: клонирует fleet-репо" 0 "$CM" once
[[ -d "$TMP/canon/repos/sandbox/.git" ]] && ok || fail "клон не создан"
grep -qv 'skipped-no-clone' "$TMP/out" && ok || fail "вердикт остался skipped-no-clone"
out_has "once: клон-проект классифицирован" '"klass": "ok"'

# 32) повторный once: fetch, не переклонирование (маркер-файл переживает проход)
touch "$TMP/canon/repos/sandbox/.git/KEEPME"
assert "once: повторный проход (fetch)" 0 "$CM" once
[[ -f "$TMP/canon/repos/sandbox/.git/KEEPME" ]] && ok || fail "клон был пересоздан"

# 33) dirty-клон -> held(dirty-clone), файл не тронут
echo "manual mess" > "$TMP/canon/repos/sandbox/dirty.txt"
assert "once: dirty-клон" 0 "$CM" once
out_has "once: held dirty-clone" 'held-dirty-clone'
[[ -f "$TMP/canon/repos/sandbox/dirty.txt" ]] && ok || fail "dirty-файл затерт"
rm "$TMP/canon/repos/sandbox/dirty.txt"

# --- T10: candidate worktree + delta sync внутрь (armed, только repo_url) ---

if [[ -f "$REAL_DELTA" ]]; then
  export CLAUDE_CANON_DELTA="$REAL_DELTA"
  export CLAUDE_CANON_OBSERVE_PASSES=0
  export CLAUDE_CANON_GH="$HERE/mock-gh"   # gh мокается на весь armed-блок
  export MOCK_GH_LOG="$TMP/gh.log"
  "$CM" arm >/dev/null 2>&1

  # intent в fleet-репо (иначе needs-bootstrap)
  ( cd "$FLEET_SRC" && \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
      git commit -q --allow-empty -m noop )
  git -C "$FLEET_BARE" fetch -q "$FLEET_SRC" main:main 2>/dev/null

  cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF
  rm -rf "$TMP/canon/repos/sandbox"   # свежий клон под armed-тест

  # 34) armed-проход: worktree создан, канон применен, ветка canon/v3 в клоне
  assert "once(armed): candidate-поток" 0 "$CM" once
  out_has "once(armed): klass=candidate-pr-open" 'candidate-pr-open'
  WT="$TMP/canon/worktrees/sandbox/canon-v3"
  [[ -f "$WT/rules/a.md" ]] && ok || fail "worktree: канон не материализован"
  git -C "$TMP/canon/repos/sandbox" rev-parse --verify -q canon/v3 >/dev/null \
    && ok || fail "ветка canon/v3 не создана"
  # коммит в ветке несет канон-файл
  git -C "$TMP/canon/repos/sandbox" show canon/v3:rules/a.md >/dev/null 2>&1 \
    && ok || fail "канон не закоммичен в ветку"
  # рантайм-артефакты delta (замок/журнал/стейдж) НЕ коммитятся в PR-ветку
  git -C "$TMP/canon/repos/sandbox" show canon/v3:.claude/.canon-lock >/dev/null 2>&1 \
    && fail "рантайм .canon-lock утек в ветку" || ok
  # а machine-state проекта - едет с веткой (это правильно)
  git -C "$TMP/canon/repos/sandbox" show canon/v3:.claude/canon.state.json >/dev/null 2>&1 \
    && ok || fail "canon.state.json не в ветке"

  # 35) идемпотентность: повторный проход не плодит коммиты/worktree
  N1=$(git -C "$TMP/canon/repos/sandbox" rev-list --count canon/v3)
  assert "once(armed): повторный" 0 "$CM" once
  N2=$(git -C "$TMP/canon/repos/sandbox" rev-list --count canon/v3)
  [[ "$N1" == "$N2" ]] && ok || fail "повторный проход добавил коммиты ($N1 -> $N2)"

  # 36) конфликт (mock exit 10): held-conflicts, ветка НЕ создается
  # порядок важен: сначала убрать worktree (он держит ветку), потом ветку;
  # remote-ветку тоже (иначе сработает cursor-CAS remote-продолжения)
  rm -rf "$TMP/canon/worktrees/sandbox"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  git -C "$TMP/canon/repos/sandbox" branch -q -D canon/v3 2>/dev/null
  git -C "$FLEET_BARE" branch -q -D canon/v3 2>/dev/null
  git -C "$TMP/canon/repos/sandbox" fetch -q --prune origin
  rm -f "$TMP/canon/state/sandbox.json"
  CLAUDE_CANON_DELTA="$HERE/mock-canon-delta" MOCK_DELTA_EXIT=10 "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "конфликт уронил проход"
  out_has "once: held-conflicts" 'held-conflicts'
  git -C "$TMP/canon/repos/sandbox" rev-parse --verify -q canon/v3 >/dev/null \
    && fail "ветка создана при конфликте" || ok

  # 37) path-проект (Mac-чекаут) в armed НЕ мутируется (модель B: PR-поток только repo_url)
  cat > "$FLEET" <<EOF
local-git:
  path: $TMP/gitproj
  policy: branch
EOF
  assert "once(armed): path-проект" 0 "$CM" once
  [[ ! -e "$TMP/gitproj/rules/a.md" ]] && ok || fail "armed мутировал path-проект!"

  # --- T11: push + gh pr create + идемпотентность ---

  # свежий цикл: убрать ветку/worktree и локальный след
  rm -rf "$TMP/canon/worktrees/sandbox"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  git -C "$TMP/canon/repos/sandbox" branch -q -D canon/v3 2>/dev/null
  : > "$MOCK_GH_LOG"   # cursor сохраняем: наш последний push = CAS-база
  cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF

  # 38) armed-проход: ветка запушена в origin (bare), PR создан, cursor записан
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T11: проход упал ($(head -c200 "$TMP/err"))"
  out_has "T11: klass=candidate-pr-open" 'candidate-pr-open'
  git -C "$FLEET_BARE" rev-parse --verify -q refs/heads/canon/v3 >/dev/null \
    && ok || fail "T11: ветка не запушена в origin"
  grep -q '"pr", "create"' "$MOCK_GH_LOG" && ok || fail "T11: gh pr create не вызван"
  [[ "$(jq_file "$TMP/canon/state/sandbox.json" 'd["pr_number"]')" == "7" ]] \
    && ok || fail "T11: cursor без pr_number"

  # 39) повторный проход: PR уже открыт (mock list непуст) -> второго create нет
  : > "$MOCK_GH_LOG"
  HEAD_SHA=$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v3)
  MOCK_GH_PR_LIST="[{\"number\": 7, \"state\": \"OPEN\", \"headRefOid\": \"$HEAD_SHA\"}]" \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T11: повторный проход упал"
  out_has "T11: PR переиспользован" 'candidate-pr-open'
  grep -q '"pr", "create"' "$MOCK_GH_LOG" && fail "T11: второй pr create" || ok

  # 40) foreign-коммит в ветке origin -> held-foreign-commits, не затерт
  ( cd "$TMP" && rm -rf foreign && git clone -q "$FLEET_BARE" foreign && cd foreign \
    && git checkout -q canon/v3 \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -q --allow-empty -m "human tweak" && git push -q origin canon/v3 )
  FOREIGN_SHA=$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v3)
  rm -rf "$TMP/canon/worktrees/sandbox"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  git -C "$TMP/canon/repos/sandbox" branch -q -D canon/v3 2>/dev/null
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T11: foreign-проход упал"
  out_has "T11: held-foreign-commits" 'held-foreign-commits'
  [[ "$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v3)" == "$FOREIGN_SHA" ]] \
    && ok || fail "T11: чужой коммит затерт!"

  # --- T12: post-merge scan (T3) -> applied ---

  # чистый цикл: свежая ветка canon/v3 с каноном + PR (эмуляция T11-прохода)
  rm -rf "$TMP/canon/worktrees/sandbox" "$TMP/foreign"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  git -C "$TMP/canon/repos/sandbox" branch -q -D canon/v3 2>/dev/null
  git -C "$FLEET_BARE" branch -q -D canon/v3 2>/dev/null
  rm -f "$TMP/canon/state/sandbox.json"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep -q 'candidate-pr-open' "$TMP/out" || fail "T12-препараты: PR-цикл не собрался"

  # человек мерджит canon/v3 в main (без изменений) и удаляет ветку
  ( cd "$TMP" && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git merge -q --no-edit origin/canon/v3 \
    && git push -q origin main && git push -q origin --delete canon/v3 ) \
    || fail "T12-препараты: merge не прошел"

  # 41) следующий проход: T3 видит канон в main -> applied, ветка/worktree убраны
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T12: applied-проход упал ($(head -c200 "$TMP/err"))"
  out_has "T12: klass=applied" '"klass": "applied"'
  [[ "$(jq_file "$TMP/canon/state/sandbox.json" 'd.get("applied")')" == "True" ]] \
    && ok || fail "T12: cursor не замкнут applied"
  [[ ! -d "$TMP/canon/worktrees/sandbox/canon-v3" ]] && ok || fail "T12: worktree не убран"
  git -C "$TMP/canon/repos/sandbox" rev-parse --verify -q canon/v3 >/dev/null \
    && fail "T12: локальная ветка не убрана" || ok

  # 42) идемпотентность: повторный проход после applied - снова applied, без PR
  : > "$MOCK_GH_LOG"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T12: повторно applied" '"klass": "applied"'
  grep -q '"pr", "create"' "$MOCK_GH_LOG" && fail "T12: PR после applied" || ok

  # 43) merge С ИЗМЕНЕНИЕМ канон-файла -> T3 fail -> held-post-merge-mismatch
  rm -rf "$TMP/merger"
  printf 'rule A v3-content\n' > "$CANON_SRC/rules/a.md"   # канон РЕАЛЬНО двигается
  git -C "$CANON_SRC" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$CANON_SRC" commit -qm "canon v4"
  python3 - "$TMP" <<'PY'
import hashlib, json, sys
tmp = sys.argv[1]
data = open(f"{tmp}/canon-src/rules/a.md", "rb").read()
sha = hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()
lock = {"schema_version": 1, "manifest_digest": "u" * 64,
        "files": {"rules/a.md": {"blob_sha": sha, "mode": "100644"}},
        "membership": {"rules/a.md": ["universal"]},
        "min_cli_version": 1, "plugin_source": None}
json.dump(lock, open(f"{tmp}/canon-src/canon.lock.json", "w"))
PY
  git -C "$CANON_SRC" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$CANON_SRC" commit -qm "lock v4"
  git -C "$CANON_SRC" tag -a canon-v4 -m v4
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1   # открывает PR canon/v4
  grep -q 'candidate-pr-open' "$TMP/out" || fail "T12: v4-цикл не собрался"
  # человек мерджит, НО правит канон-файл при мердже (squash-подмена)
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git merge -q --no-edit origin/canon/v4 \
    && printf 'HUMAN EDIT\n' > rules/a.md && git add rules/a.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "merge tweak" && git push -q origin main && git push -q origin --delete canon/v4 )
  # судьба PR подтверждается через gh (T13): mismatch только при state=MERGED
  MOCK_GH_PR_VIEW_JSON='{"state":"MERGED"}' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T12: mismatch -> held" 'held-post-merge'
  [[ "$(jq_file "$TMP/canon/state/sandbox.json" 'd.get("applied")')" != "True" ]] \
    && ok || fail "T12: applied при подмененном дереве!"

  # --- T13: нештатные PR-исходы (§15.5) ---

  # препараты: человек чинит main обратно к канон-байтам v4 (снимает HUMAN EDIT),
  # издается canon-v5, собирается чистый candidate-PR по нему
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main && printf 'rule A v3-content\n' > rules/a.md \
    && git add rules/a.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "fix back to canon" && git push -q origin main ) \
    || fail "T13-препараты: fix-back не прошел"
  printf 'rule A v5\n' > "$CANON_SRC/rules/a.md"
  git -C "$CANON_SRC" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$CANON_SRC" commit -qm "canon v5"
  python3 - "$TMP" <<'PY'
import hashlib, json, sys
tmp = sys.argv[1]
data = open(f"{tmp}/canon-src/rules/a.md", "rb").read()
sha = hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()
lock = {"schema_version": 1, "manifest_digest": "v" * 64,
        "files": {"rules/a.md": {"blob_sha": sha, "mode": "100644"}},
        "membership": {"rules/a.md": ["universal"]},
        "min_cli_version": 1, "plugin_source": None}
json.dump(lock, open(f"{tmp}/canon-src/canon.lock.json", "w"))
PY
  git -C "$CANON_SRC" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$CANON_SRC" commit -qm "lock v5"
  git -C "$CANON_SRC" tag -a canon-v5 -m v5
  rm -rf "$TMP/canon/worktrees/sandbox"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  git -C "$TMP/canon/repos/sandbox" branch -q -D canon/v4 canon/v5 2>/dev/null
  rm -f "$TMP/canon/state/sandbox.json"
  : > "$MOCK_GH_LOG"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep -q 'candidate-pr-open' "$TMP/out" || fail "T13-препараты: v5-цикл не собрался"
  V5_SHA=$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)

  # 44) PR закрыт без мерджа, ветка ЖИВА -> held-pr-closed, второй PR не создается
  # (судьбу дает gh pr list --state all по имени ветки, cursor не обязателен)
  : > "$MOCK_GH_LOG"
  MOCK_GH_PR_LIST='[{"number": 7, "state": "CLOSED"}]' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T13: closed-проход упал ($(head -c200 "$TMP/err"))"
  out_has "T13: held-pr-closed (ветка жива)" 'held-pr-closed'
  grep -q '"pr", "create"' "$MOCK_GH_LOG" && fail "T13: PR пересоздан после закрытия" || ok

  # 45) PR закрыт, ветку удалили (GitHub-автоснос) -> held-pr-closed, ветка НЕ пересоздана
  git -C "$FLEET_BARE" branch -q -D canon/v5
  : > "$MOCK_GH_LOG"
  MOCK_GH_PR_VIEW_JSON='{"state":"CLOSED"}' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T13: held-pr-closed (ветки нет)" 'held-pr-closed'
  git -C "$FLEET_BARE" rev-parse --verify -q refs/heads/canon/v5 >/dev/null \
    && fail "T13: ветка пересоздана после закрытия PR" || ok

  # 46) судьба PR неизвестна (gh недоступен) -> transient, НЕ held, ветка не пересоздана
  MOCK_GH_PR_VIEW_EXIT=1 CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T13: gh недоступен -> transient" '"klass": "transient"'
  grep -q 'held-pr\|held-post-merge' "$TMP/out" \
    && fail "T13: held при неизвестной судьбе PR" || ok
  git -C "$FLEET_BARE" rev-parse --verify -q refs/heads/canon/v5 >/dev/null \
    && fail "T13: ветка пересоздана при неизвестном PR" || ok

  # 47) ветку снесли руками, PR OPEN -> пересоздание от main, тот же PR
  : > "$MOCK_GH_LOG"
  MOCK_GH_PR_VIEW_JSON='{"state":"OPEN"}' MOCK_GH_PR_LIST='[{"number": 7, "state": "OPEN"}]' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T13: recreate-проход упал ($(head -c200 "$TMP/err"))"
  out_has "T13: ветка пересоздана (PR OPEN)" 'candidate-pr-open'
  git -C "$FLEET_BARE" rev-parse --verify -q refs/heads/canon/v5 >/dev/null \
    && ok || fail "T13: ветка не восстановлена в origin"
  grep -q '"pr", "create"' "$MOCK_GH_LOG" && fail "T13: create при живом OPEN PR" || ok

  # 48) main уехал БЕЗ конфликта -> PR остается как есть, force-push не происходит
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main && printf 'unrelated\n' > unrelated.md && git add unrelated.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "unrelated main move" && git push -q origin main )
  BR_SHA=$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)
  MOCK_GH_PR_LIST='[{"number": 7, "state": "OPEN"}]' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T13: main-move без конфликта -> PR жив" 'candidate-pr-open'
  [[ "$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)" == "$BR_SHA" ]] \
    && ok || fail "T13: ветка перезаписана без причины"

  # 49) main уехал С КОНФЛИКТОМ по канон-файлу -> recreate -> delta-конфликт ->
  #     held-rebase-conflict; remote-ветка НЕ затерта
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main && printf 'HUMAN v5 CONFLICT\n' > rules/a.md && git add rules/a.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "conflicting main move" && git push -q origin main )
  BR_SHA=$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T13: conflict-проход упал ($(head -c200 "$TMP/err"))"
  out_has "T13: held-rebase-conflict" 'held-rebase-conflict'
  [[ "$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)" == "$BR_SHA" ]] \
    && ok || fail "T13: remote-ветка затерта при rebase-конфликте"

  # 50) конфликт main + чужой коммит в PR-ветке -> CAS не сходится -> held-foreign-commits
  ( cd "$TMP" && rm -rf foreign && git clone -q "$FLEET_BARE" foreign && cd foreign \
    && git checkout -q canon/v5 \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -q --allow-empty -m "human tweak in pr" && git push -q origin canon/v5 )
  FOREIGN_SHA=$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T13: конфликт + foreign -> held-foreign-commits" 'held-foreign-commits'
  [[ "$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)" == "$FOREIGN_SHA" ]] \
    && ok || fail "T13: чужой коммит затерт при recreate!"

  # --- T14: фиксы находок codex adversarial (M1) ---

  # 51) юнит: T3-вердикт не проходит "vacuous truth" (items=[]) и мусор
  python3 - "$CM" <<'PY' && ok || fail "T14: T3-вердикт дырявый (items=[]/мусор)"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
cm = importlib.util.module_from_spec(spec)
loader.exec_module(cm)
ok = cm._t3_verdict_applied
good = {"code": 0, "verdict": {"items": [{"klass": "up-to-date"}]}}
assert ok(good) is True
assert ok({"code": 0, "verdict": {"items": []}}) is False          # пусто != applied
assert ok({"code": 0, "verdict": {}}) is False                     # нет items
assert ok({"code": 0, "verdict": {"items": [1]}}) is False         # не-dict item
assert ok({"code": 0, "verdict": {"items": [{"klass": "local-edit"}]}}) is False
assert ok({"code": 1, "verdict": {"items": [{"klass": "up-to-date"}]}}) is False
PY

  # 52) юнит: _pr_state не падает на мусорном JSON (list вместо dict, чужой state)
  python3 - "$CM" "$HERE/mock-gh" <<'PY' && ok || fail "T14: _pr_state падает на мусоре"
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
cm = importlib.util.module_from_spec(spec)
loader.exec_module(cm)
os.environ["CLAUDE_CANON_GH"] = sys.argv[2]
os.environ["MOCK_GH_PR_VIEW_JSON"] = "[1]"
assert cm._pr_state("/tmp", 7) is None
os.environ["MOCK_GH_PR_VIEW_JSON"] = '{"state": "WEIRD"}'
assert cm._pr_state("/tmp", 7) is None
os.environ["MOCK_GH_PR_VIEW_JSON"] = '{"state": "OPEN"}'
assert cm._pr_state("/tmp", 7) == "OPEN"
PY

  # препараты: свежий штатный цикл v5 (после 50: снять foreign-хвост и конфликт main)
  git -C "$FLEET_BARE" branch -q -D canon/v5
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main && printf 'rule A v3-content\n' > rules/a.md && git add rules/a.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "fix main back" && git push -q origin main )
  rm -rf "$TMP/canon/worktrees/sandbox"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  git -C "$TMP/canon/repos/sandbox" branch -q -D canon/v5 2>/dev/null
  rm -f "$TMP/canon/state/sandbox.json"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep -q 'candidate-pr-open' "$TMP/out" || fail "T14-препараты: v5-цикл не собрался"

  # 53) crash-эмуляция: cursor потерян (SIGKILL после pr create), человек закрыл PR
  #     и удалил ветку -> held-pr-closed по gh pr list --state all, БЕЗ create и БЕЗ push
  rm -f "$TMP/canon/state/sandbox.json"
  git -C "$FLEET_BARE" branch -q -D canon/v5
  : > "$MOCK_GH_LOG"
  MOCK_GH_PR_LIST='[{"number": 7, "state": "CLOSED"}]' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T14: closed без cursor -> held-pr-closed" 'held-pr-closed'
  grep -q '"pr", "create"' "$MOCK_GH_LOG" && fail "T14: create поверх закрытого PR (crash)" || ok
  git -C "$FLEET_BARE" rev-parse --verify -q refs/heads/canon/v5 >/dev/null \
    && fail "T14: push восстановил ветку закрытого PR" || ok

  # 54) тот же crash, но PR MERGED (а T3 false) -> held-post-merge-mismatch без create
  : > "$MOCK_GH_LOG"
  MOCK_GH_PR_LIST='[{"number": 7, "state": "MERGED"}]' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T14: merged+T3-false без cursor -> mismatch" 'held-post-merge-mismatch'
  grep -q '"pr", "create"' "$MOCK_GH_LOG" && fail "T14: create поверх merged PR" || ok

  # 55) gh целиком недоступен -> transient ДО каких-либо мутаций remote (push не делается)
  MOCK_GH_EXIT=1 CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T14: gh недоступен -> transient" '"klass": "transient"'
  git -C "$FLEET_BARE" rev-parse --verify -q refs/heads/canon/v5 >/dev/null \
    && fail "T14: push при недоступном gh" || ok

  # 56) cleanup под CAS: человек дописал коммит в PR-ветку, потом смерджил ее в main;
  #     T3 сходится -> applied, но remote-ветку с ЧУЖИМ хвостом НЕ удаляем
  MOCK_GH_PR_LIST='[{"number": 7, "state": "OPEN"}]' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1   # восстановить цикл: push+PR
  grep -q 'candidate-pr-open' "$TMP/out" || fail "T14-препараты(56): цикл не восстановился"
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q canon/v5 \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -q --allow-empty -m "human extra in pr" \
    && git checkout -q main \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git merge -q --no-edit canon/v5 \
    && git push -q origin main canon/v5 ) || fail "T14-препараты(56): merge не прошел"
  HUMAN_TAIL=$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5)
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T14: applied при чужом хвосте" '"klass": "applied"'
  git -C "$FLEET_BARE" rev-parse --verify -q refs/heads/canon/v5 >/dev/null \
    && ok || fail "T14: remote-ветка с чужим коммитом удалена (нет CAS на delete)!"
  [[ "$(git -C "$FLEET_BARE" rev-parse refs/heads/canon/v5 2>/dev/null)" == "$HUMAN_TAIL" ]] \
    && ok || fail "T14: чужой хвост в ветке изменен"

  # препараты v6: новый релиз, чистый цикл (снять артефакты v5)
  git -C "$FLEET_BARE" branch -q -D canon/v5 2>/dev/null
  printf 'rule A v6\n' > "$CANON_SRC/rules/a.md"
  git -C "$CANON_SRC" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$CANON_SRC" commit -qm "canon v6"
  python3 - "$TMP" <<'PY'
import hashlib, json, sys
tmp = sys.argv[1]
data = open(f"{tmp}/canon-src/rules/a.md", "rb").read()
sha = hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest()
lock = {"schema_version": 1, "manifest_digest": "w" * 64,
        "files": {"rules/a.md": {"blob_sha": sha, "mode": "100644"}},
        "membership": {"rules/a.md": ["universal"]},
        "min_cli_version": 1, "plugin_source": None}
json.dump(lock, open(f"{tmp}/canon-src/canon.lock.json", "w"))
PY
  git -C "$CANON_SRC" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$CANON_SRC" commit -qm "lock v6"
  git -C "$CANON_SRC" tag -a canon-v6 -m v6
  rm -rf "$TMP/canon/worktrees/sandbox"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  rm -f "$TMP/canon/state/sandbox.json"
  : > "$MOCK_GH_LOG"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep -q 'candidate-pr-open' "$TMP/out" || fail "T14-препараты: v6-цикл не собрался"

  # 57) застейдженный рантайм-артефакт в durable worktree не едет в PR (git reset до add).
  # артефакт - в пассивном .canon-bak/ (журнал ломал бы sync recovery-путем)
  WT6="$TMP/canon/worktrees/sandbox/canon-v6"
  mkdir -p "$WT6/.claude/.canon-bak"
  printf 'garbage\n' > "$WT6/.claude/.canon-bak/leftover"
  git -C "$WT6" add -f .claude/.canon-bak/leftover
  MOCK_GH_PR_LIST='[{"number": 7, "state": "OPEN"}]' \
    CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T14: проход при staged-артефакте штатный" 'candidate-pr-open'
  git -C "$TMP/canon/repos/sandbox" show canon/v6:.claude/.canon-bak/leftover >/dev/null 2>&1 \
    && fail "T14: staged рантайм-артефакт уехал в ветку" || ok

  # 58) чужой ЛОКАЛЬНЫЙ коммит в нашем worktree + конфликтный main-move ->
  #     recreate НЕ сносит wt (held-foreign-commits), человеческий коммит жив
  ( cd "$WT6" \
    && printf 'human wip\n' > human-wip.md && git add human-wip.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "human local wip" )
  HUMAN_WIP=$(git -C "$WT6" rev-parse HEAD)
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main && printf 'HUMAN v6 CONFLICT\n' > rules/a.md && git add rules/a.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "conflicting move v6" && git push -q origin main )
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  out_has "T14: foreign local wip -> held-foreign-commits" 'held-foreign-commits'
  [[ -d "$WT6" ]] && ok || fail "T14: worktree с чужим коммитом снесен!"
  [[ "$(git -C "$TMP/canon/repos/sandbox" rev-parse canon/v6 2>/dev/null)" == "$HUMAN_WIP" ]] \
    && ok || fail "T14: человеческий локальный коммит потерян"

  # 59) fleet: path и repo_url одновременно -> валидация exit 2 (двусмысленный routing)
  cat > "$FLEET" <<EOF
dual:
  path: $TMP/gitproj
  repo_url: $FLEET_BARE
  policy: branch
EOF
  assert "T14: path+repo_url -> exit 2" 2 "$CM" once

  # 60) изоляция per-project: битый проект не валит проход, второй проект обработан
  cat > "$FLEET" <<EOF
broken:
  repo_url: $TMP/no-such-repo.git
  policy: branch
zzz-sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF
  rm -f "$TMP/canon/state/zzz-sandbox.json"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T14: битый проект уронил проход"
  out_has "T14: broken получил вердикт" '"project": "broken"'
  out_has "T14: второй проект обработан" '"project": "zzz-sandbox"'
  cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF

  # 61) observe по repo_url-проекту читает origin/<default>, а не устаревшее
  #     рабочее дерево клона (fetch не двигает checkout): intent, добавленный
  #     человеком в main ПОСЛЕ создания клона, обязан быть виден
  mkdir -p "$TMP/obs-src"
  git -C "$TMP/obs-src" init -q -b main
  printf 'obs\n' > "$TMP/obs-src/README.md"
  git -C "$TMP/obs-src" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$TMP/obs-src" commit -qm init
  git clone -q --bare "$TMP/obs-src" "$TMP/obs-bare.git"
  cat > "$FLEET" <<EOF
obs:
  repo_url: $TMP/obs-bare.git
  policy: observe
EOF
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1   # клон создан (дерево без intent)
  out_has "T14: до intent - needs-bootstrap" 'needs-bootstrap'
  ( cd "$TMP" && rm -rf obs-merger && git clone -q obs-bare.git obs-merger && cd obs-merger \
    && mkdir -p .claude && printf 'project_type: []\ntrack: stable\n' > .claude/canon.intent.yaml \
    && git add -A \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "human adds intent" && git push -q origin main )
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep -q 'needs-bootstrap' "$TMP/out" \
    && fail "T14: observe видит устаревшее дерево клона (intent из main не виден)" || ok
  cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF

  # 62) юнит (r2-Д3): структурно мусорный gh pr list -> transient ДО мутаций;
  #     нестандартный state -> НЕ held-pr-closed; литеральный CLOSED -> held
  python3 - "$CM" "$HERE/mock-gh" <<'PY' && ok || fail "T14: схема gh pr list дырява"
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
cm = importlib.util.module_from_spec(spec)
loader.exec_module(cm)
os.environ["CLAUDE_CANON_GH"] = sys.argv[2]
def call():
    return cm._push_and_pr("x", {}, "/tmp", "/tmp", "canon/v9", "canon-v9", "c0")
os.environ["MOCK_GH_PR_LIST"] = "[1]"
assert call()["klass"] == "transient", "мусор [1] не transient"
os.environ["MOCK_GH_PR_LIST"] = '[{"number": 7, "state": "WEIRD"}]'
assert call()["klass"] == "transient", "WEIRD state не transient"
os.environ["MOCK_GH_PR_LIST"] = '[{"number": "7", "state": "CLOSED"}]'
assert call()["klass"] == "transient", "не-int number не transient"
os.environ["MOCK_GH_PR_LIST"] = '[{"number": true, "state": "CLOSED"}]'
assert call()["klass"] == "transient", "bool-number не transient (bool - подкласс int!)"
os.environ["MOCK_GH_PR_LIST"] = '[{"number": 0, "state": "CLOSED"}]'
assert call()["klass"] == "transient", "number<=0 не transient"
os.environ["MOCK_GH_PR_LIST"] = '[{"number": 7, "state": "CLOSED"}]'
assert call()["klass"] == "held-pr-closed", "литеральный CLOSED не защелкнул"
PY

  # 63) r2-Д1: усеченный items от classify не дает applied - покрытие сверяется
  #     со state.file_hashes ПРОВЕРЯЕМОГО дерева
  mkdir -p "$TMP/t3cov-src/.claude" "$TMP/t3cov-src/rules"
  git -C "$TMP/t3cov-src" init -q -b main
  printf 'project_type: []\ntrack: stable\n' > "$TMP/t3cov-src/.claude/canon.intent.yaml"
  printf 'A\n' > "$TMP/t3cov-src/rules/a.md"
  printf 'B\n' > "$TMP/t3cov-src/rules/b.md"
  python3 - "$TMP" <<'PY'
import json, sys
tmp = sys.argv[1]
state = {"schema": 2,
         "file_hashes": {"rules/a.md": {"sha": "0" * 40, "mode": "100644"},
                         "rules/b.md": {"sha": "1" * 40, "mode": "100644"}},
         "membership": {}, "desired_release": None, "applied_release": None,
         "rollout_record": [], "resolution_records": [], "decision_records": [],
         "retirement_records": [], "recovery_conflicts": []}
json.dump(state, open(f"{tmp}/t3cov-src/.claude/canon.state.json", "w"))
PY
  git -C "$TMP/t3cov-src" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$TMP/t3cov-src" commit -qm init
  git clone -q --bare "$TMP/t3cov-src" "$TMP/t3cov-bare.git"
  cat > "$FLEET" <<EOF
t3cov:
  repo_url: $TMP/t3cov-bare.git
  policy: branch
EOF
  MOCK_DELTA_EXIT=0 \
    MOCK_DELTA_JSON='{"summary": {"up-to-date": 1}, "items": [{"path": "rules/a.md", "klass": "up-to-date"}]}' \
    CLAUDE_CANON_DELTA="$HERE/mock-canon-delta" "$CM" once >"$TMP/out" 2>&1
  grep -q '"klass": "applied"' "$TMP/out" \
    && fail "T14: applied по усеченному items (state-пути не покрыты)" || ok

  # 64) r2-Д4: битый per-project cursor не валит проход (не die) -> held, exit 0
  cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF
  cp "$TMP/canon/state/sandbox.json" "$TMP/cursor.bak" 2>/dev/null || true
  printf 'garbage{' > "$TMP/canon/state/sandbox.json"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>"$TMP/err"
  [[ "$?" == "0" ]] && ok || fail "T14: битый cursor уронил проход (exit $?)"
  out_has "T14: битый cursor -> held" 'corrupt-cursor'
  cp "$TMP/cursor.bak" "$TMP/canon/state/sandbox.json" 2>/dev/null \
    || rm -f "$TMP/canon/state/sandbox.json"

  # 65) r3: уборка временного worktree сходится и при сбое remove (сирота
  #     вычищается prune, stale-регистрации не копятся между проходами)
  python3 - "$CM" "$TMP" <<'PY' && ok || fail "T14: stale worktree-регистрация не вычищается"
import importlib.machinery, importlib.util, os, shutil, subprocess, sys, tempfile
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
cm = importlib.util.module_from_spec(spec)
loader.exec_module(cm)
tmp = sys.argv[2]
env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
src = tempfile.mkdtemp(dir=tmp)
subprocess.run(["git", "-C", src, "init", "-q", "-b", "main"], check=True)
open(os.path.join(src, "f"), "w").write("x")
subprocess.run(["git", "-C", src, "add", "-A"], check=True)
subprocess.run(["git", "-C", src, "commit", "-qm", "i"], env=env, check=True)
wt_tmp = tempfile.mkdtemp(prefix=".observe-", dir=tmp)
wt = os.path.join(wt_tmp, "head")
subprocess.run(["git", "-C", src, "worktree", "add", "--detach", wt, "main"],
               check=True, capture_output=True)
shutil.rmtree(wt)   # эмуляция: каталог исчез -> worktree remove будет фейлиться
cm._drop_temp_worktree(src, wt, wt_tmp)
out = subprocess.run(["git", "-C", src, "worktree", "list", "--porcelain"],
                     capture_output=True, text=True).stdout
regs = out.count("worktree ")
assert regs == 1, f"осталась stale-регистрация (worktrees={regs})"
assert not os.path.exists(wt_tmp), "временный каталог не убран"
PY

  # --- T15: durable cursor v2 + CAS-переходы + WAL-гейт (§4.5) ---

  # 66) юнит: cursor_transition - CAS-семантика, миграция legacy-формата
  python3 - "$CM" "$TMP" <<'PY' && ok || fail "T15: cursor_transition CAS дыряв"
import importlib.machinery, importlib.util, json, os, sys
tmp = sys.argv[2]
os.environ["CLAUDE_CANON_DIR"] = f"{tmp}/canon-t15"
os.makedirs(f"{tmp}/canon-t15/state", exist_ok=True)
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
cm = importlib.util.module_from_spec(spec)
loader.exec_module(cm)
P = "unit"
path = cm.project_cursor_path(P)
# intent на пустом cursor: idle -> candidate
assert cm.cursor_transition(P, "candidate", desired_commit="c1", release="canon-v1",
                            ring="canary", pass_id="p1") is True
d = json.load(open(path))
assert d["phase"] == "candidate" and d["desired_commit"] == "c1" and d["ring"] == "canary"
# CAS-fail: expect не совпал -> False и файл НЕ изменился
before = open(path).read()
assert cm.cursor_transition(P, "candidate", expect={"desired_commit": "OTHER"},
                            desired_commit="c2") is False
assert open(path).read() == before, "CAS-fail записал файл!"
# pr-recorded: candidate -> candidate под expect
assert cm.cursor_transition(P, "candidate", expect={"desired_commit": "c1"},
                            branch="canon/v1", pr_number=7, pr_head_sha="abc") is True
d = json.load(open(path))
assert d["pr_number"] == 7 and d["phase"] == "candidate"
# applied: candidate -> applied, pr_head_sha вычищен
assert cm.cursor_transition(P, "applied", applied_commit="c1",
                            applied_main_sha="m1", applied=True,
                            drop=("pr_head_sha",)) is True
d = json.load(open(path))
assert d["phase"] == "applied" and d["applied_commit"] == "c1"
assert "pr_head_sha" not in d, "pr_head_sha не вычищен"
# миграция legacy: applied-bool и pr_number без phase
assert cm._cursor_phase({}) == "idle"
assert cm._cursor_phase({"release": "canon-v1", "applied": True}) == "applied"
assert cm._cursor_phase({"release": "canon-v1", "pr_number": 2}) == "candidate"
assert cm._cursor_phase({"phase": "held"}) == "held"
PY

  # 67) gate A (§4.2): намерение durable ДО вызова delta - при упавшем sync
  #     cursor уже несет phase=candidate + desired_commit
  # main после 58 конфликтный - человек возвращает канон-байты v5 (== state)
  ( cd "$TMP" && rm -rf merger && git clone -q "$FLEET_BARE" merger && cd merger \
    && git checkout -q main && printf 'rule A v5\n' > rules/a.md && git add rules/a.md \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git commit -qm "fix main back to v5" && git push -q origin main )
  rm -rf "$TMP/canon/worktrees/sandbox"
  git -C "$TMP/canon/repos/sandbox" worktree prune
  git -C "$TMP/canon/repos/sandbox" branch -q -D canon/v6 2>/dev/null
  git -C "$FLEET_BARE" branch -q -D canon/v6 2>/dev/null
  rm -f "$TMP/canon/state/sandbox.json"
  V6_COMMIT=$(git -C "$TMP/canon/mirror" rev-list -1 canon-v6 2>/dev/null \
    || git -C "$CANON_SRC" rev-list -1 canon-v6)
  MOCK_DELTA_EXIT=1 CLAUDE_CANON_DELTA="$HERE/mock-canon-delta" "$CM" once >"$TMP/out" 2>&1
  out_has "T15: sync-фейл -> transient" '"klass": "transient"'
  [[ "$(jq_file "$TMP/canon/state/sandbox.json" 'd.get("phase")')" == "candidate" ]] \
    && ok || fail "T15: намерение не записано до delta (gate A)"
  [[ "$(jq_file "$TMP/canon/state/sandbox.json" 'd.get("desired_commit")')" == "$V6_COMMIT" ]] \
    && ok || fail "T15: desired_commit не зафиксирован"

  # 68) WAL-гейт (§4.5а): живой journal в worktree -> сперва recover, потом sync;
  #     recover-фейл держит проект и sync не вызывается
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1   # штатный candidate-цикл v6
  grep -q 'candidate-pr-open' "$TMP/out" || fail "T15-препараты: цикл v6 не собрался"
  WT6="$TMP/canon/worktrees/sandbox/canon-v6"
  printf '{"stub": true}\n' > "$WT6/.claude/.canon-journal.json"
  : > "$TMP/delta.log"
  MOCK_DELTA_LOG="$TMP/delta.log" CLAUDE_CANON_DELTA="$HERE/mock-canon-delta" \
    MOCK_DELTA_JSON='{"summary": {}, "items": [{"path": "x", "klass": "outdated"}]}' \
    "$CM" once >"$TMP/out" 2>&1
  R=$(grep -n '"recover"' "$TMP/delta.log" | head -1 | cut -d: -f1)
  S=$(grep -n '"sync"' "$TMP/delta.log" | head -1 | cut -d: -f1)
  [[ -n "$R" && -n "$S" && "$R" -lt "$S" ]] \
    && ok || fail "T15: recover (строка ${R:-нет}) не раньше sync (строка ${S:-нет}) при живом WAL"
  rm -f "$WT6/.claude/.canon-journal.json" 2>/dev/null
  printf '{"stub": true}\n' > "$WT6/.claude/.canon-journal.json"
  : > "$TMP/delta.log"
  MOCK_DELTA_LOG="$TMP/delta.log" MOCK_DELTA_EXIT=3 CLAUDE_CANON_DELTA="$HERE/mock-canon-delta" \
    "$CM" once >"$TMP/out" 2>&1
  out_has "T15: recover-фейл -> held-recovery" 'held-recovery'
  grep -q '"sync"' "$TMP/delta.log" \
    && fail "T15: sync вызван при нетерминализированном WAL" || ok
  rm -f "$WT6/.claude/.canon-journal.json" 2>/dev/null

  # --- T17: harvester-marker триггер (§5.3) ---

  # 69) маркер поглощается проходом (consume под локом), в лог идет trigger
  printf '{"ts": 1}\n' > "$TMP/canon/harvest-trigger.json"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  [[ ! -e "$TMP/canon/harvest-trigger.json" ]] \
    && ok || fail "T17: маркер не поглощен проходом"
  out_has "T17: триггер отмечен в логе" '"trigger": "harvester"'

  # 70) коалесценция: маркер, появившийся ВО ВРЕМЯ прохода, подхватывается
  #     повторным циклом; cap=3 останавливает шторм
  : > "$TMP/delta.log"
  MOCK_DELTA_LOG="$TMP/delta.log" MOCK_DELTA_TOUCH="$TMP/canon/harvest-trigger.json" \
    MOCK_DELTA_JSON='{"summary": {}, "items": [{"path": "x", "klass": "outdated"}]}' \
    CLAUDE_CANON_DELTA="$HERE/mock-canon-delta" "$CM" once >"$TMP/out" 2>&1
  ROUNDS=$(grep -c '"pass-start"' "$TMP/out")
  [[ "$ROUNDS" == "3" ]] && ok || fail "T17: раундов $ROUNDS != 3 (коалесценция/cap)"
  [[ -e "$TMP/canon/harvest-trigger.json" ]] \
    && ok || fail "T17: остаточный маркер потерян (должен ждать следующего прохода)"
  rm -f "$TMP/canon/harvest-trigger.json"

  # --- T18: rollout rings (§6.1) ---

  # три свежих fleet-репо по кольцам + observe-проект в canary
  for R in ringc rings ringr ringo; do
    rm -rf "$TMP/$R-src" "$TMP/$R.git"
    mkdir -p "$TMP/$R-src/.claude"
    git -C "$TMP/$R-src" init -q -b main
    printf 'project_type: []\ntrack: stable\n' > "$TMP/$R-src/.claude/canon.intent.yaml"
    git -C "$TMP/$R-src" add -A
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
      git -C "$TMP/$R-src" commit -qm init
    git clone -q --bare "$TMP/$R-src" "$TMP/$R.git"
  done
  cat > "$FLEET" <<EOF
ringc:
  repo_url: $TMP/ringc.git
  policy: branch
  ring: canary
rings:
  repo_url: $TMP/rings.git
  policy: branch
  ring: snapshot
ringr:
  repo_url: $TMP/ringr.git
  policy: branch
ringo:
  repo_url: $TMP/ringo.git
  policy: observe
  ring: canary
EOF

  # 71) проход 1: мутируется только canary; snapshot/rest ждут; observe не блокирует
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep 'candidate-pr-open' "$TMP/out" | grep -q '"ringc"' \
    && ok || fail "T18: canary не получил candidate"
  grep 'waiting-ring' "$TMP/out" | grep -q '"rings"' && ok || fail "T18: snapshot не ждет"
  grep 'waiting-ring' "$TMP/out" | grep -q '"ringr"' && ok || fail "T18: rest не ждет"
  git -C "$TMP/rings.git" rev-parse --verify -q refs/heads/canon/v6 >/dev/null \
    && fail "T18: snapshot мутирован до applied canary" || ok

  # 72) человек мерджит canary -> проход 2: canary applied, snapshot идет, rest ждет
  ( cd "$TMP" && rm -rf merger && git clone -q ringc.git merger && cd merger \
    && git checkout -q main \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git merge -q --no-edit origin/canon/v6 && git push -q origin main ) \
    || fail "T18-препараты: merge canary не прошел"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep '"klass": "applied"' "$TMP/out" | grep -q '"ringc"' && ok || fail "T18: canary не applied"
  grep 'candidate-pr-open' "$TMP/out" | grep -q '"rings"' && ok || fail "T18: snapshot не пошел после canary"
  grep 'waiting-ring' "$TMP/out" | grep -q '"ringr"' && ok || fail "T18: rest не ждет snapshot"

  # 73) мердж snapshot -> проход 3: rest идет
  ( cd "$TMP" && rm -rf merger && git clone -q rings.git merger && cd merger \
    && git checkout -q main \
    && GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@h GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@h \
       git merge -q --no-edit origin/canon/v6 && git push -q origin main ) \
    || fail "T18-препараты: merge snapshot не прошел"
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep '"klass": "applied"' "$TMP/out" | grep -q '"rings"' && ok || fail "T18: snapshot не applied"
  grep 'candidate-pr-open' "$TMP/out" | grep -q '"ringr"' && ok || fail "T18: rest не пошел"

  cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF

  # --- T19: circuit breaker + latch + ack (§6.2/§6.4) ---

  # свежие кольца: canary x2 + snapshot; cursors T18 стираем
  for R in ringc ringc2 rings; do
    rm -rf "$TMP/$R-src" "$TMP/$R.git" "$TMP/canon/repos/$R" "$TMP/canon/worktrees/$R"
    rm -f "$TMP/canon/state/$R.json"
    mkdir -p "$TMP/$R-src/.claude"
    git -C "$TMP/$R-src" init -q -b main
    printf 'project_type: []\ntrack: stable\n' > "$TMP/$R-src/.claude/canon.intent.yaml"
    git -C "$TMP/$R-src" add -A
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
      git -C "$TMP/$R-src" commit -qm init
    git clone -q --bare "$TMP/$R-src" "$TMP/$R.git"
  done
  cat > "$FLEET" <<EOF
ringc:
  repo_url: $TMP/ringc.git
  policy: branch
  ring: canary
ringc2:
  repo_url: $TMP/ringc2.git
  policy: branch
  ring: canary
rings:
  repo_url: $TMP/rings.git
  policy: branch
  ring: snapshot
EOF

  # 74) apply-error (incompat) на первом canary -> latch(release,canary), fail-fast:
  #     второй canary в том же проходе не мутируется, snapshot стоит
  MOCK_DELTA_EXIT=2 CLAUDE_CANON_DELTA="$HERE/mock-canon-delta" "$CM" once >"$TMP/out" 2>&1
  grep '"klass": "incompat"' "$TMP/out" | grep -q '"ringc"' && ok || fail "T19: нет incompat на ringc"
  grep '"klass": "latched"' "$TMP/out" | grep -q '"ringc2"' \
    && ok || fail "T19: fail-fast не остановил второй canary"
  jq_file "$TMP/canon/latches.json" 'sorted(d.keys())' 2>/dev/null | grep -q 'canon-v6|canary' \
    && ok || fail "T19: latch не durable в latches.json"

  # 75) латч переживает рестарт: новый проход (real delta) не мутирует canary
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep '"klass": "latched"' "$TMP/out" | grep -q '"ringc"' \
    && ok || fail "T19: latch не пережил новый проход"
  git -C "$TMP/ringc.git" rev-parse --verify -q refs/heads/canon/v6 >/dev/null \
    && fail "T19: canary мутирован под латчем" || ok
  grep 'waiting-ring\|latched' "$TMP/out" | grep -q '"rings"' \
    && ok || fail "T19: snapshot не стоит под латчем canary"

  # 76) ack снимает latch(release,ring) -> canary снова идет
  assert "T19: ack" 0 "$CM" ack canon-v6 canary
  CLAUDE_CANON_DELTA="$REAL_DELTA" "$CM" once >"$TMP/out" 2>&1
  grep 'candidate-pr-open' "$TMP/out" | grep -q '"ringc"' \
    && ok || fail "T19: canary не пошел после ack"

  cat > "$FLEET" <<EOF
sandbox:
  repo_url: $FLEET_BARE
  policy: branch
EOF

  "$CM" disarm >/dev/null 2>&1
else
  echo "skip T10: real-delta недоступен"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
