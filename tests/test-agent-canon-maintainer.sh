#!/usr/bin/env bash
# Tests for bin/claude-agent-canon-maintainer: fleet-reconciler canon-sync (этап 8c).
# Контракт: docs/design-2026-07-14-stage8-canon-sync.md §5; план docs/dev/plan-2026-07-14-stage8-part-c.md.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CM="$HERE/../bin/claude-agent-canon-maintainer"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CANON_DIR="$TMP/canon"

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
cactus-adm:
  repo_url: git@github.com:dewil/cactus-adm.git
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
[[ "$(jq_out 'sorted(d["projects"].keys())')" == "['cactus-adm', 'local-git', 'local-vault']" ]] \
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
  MOCK_GH_PR_LIST="[{\"number\": 7, \"headRefOid\": \"$HEAD_SHA\"}]" \
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

  "$CM" disarm >/dev/null 2>&1
else
  echo "skip T10: real-delta недоступен"
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
