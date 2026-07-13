#!/usr/bin/env bash
# Tests for bin/claude-rc-takeover (этап 5, Mac-сторона кросс-машинного handoff).
# Пред-проверки - локально; happy-path - real git push в bare-origin + shim ssh/scp.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RC="$HERE/../bin/claude-rc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
assert() { # <desc> <expected-exit> <cmd...>
  local desc="$1" want="$2"; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err"; local got=$?
  if [[ "$got" == "$want" ]]; then ok; else
    fail "$desc: exit $got != $want ($(head -c150 "$TMP/err"))"; fi
}

GIT="git -c user.email=t@t -c user.name=t"

# --- fixtures: bare origin + рабочий clone с upstream ---
ORIGIN="$TMP/origin.git"; git init -q --bare "$ORIGIN"
REPO="$TMP/repo"
git clone -q "$ORIGIN" "$REPO"
( cd "$REPO" && echo hi > f.txt && $GIT add . && $GIT commit -qm init \
  && git push -q -u origin main 2>/dev/null || git push -q -u origin master 2>/dev/null )

SPEC="$TMP/spec.yaml"
cat > "$SPEC" <<EOF
schema: 1
name: taover
type: mission
role: coder
project: /remote/proj/on/vm
goal: g
autonomy: act
EOF
echo "# handoff бриф" > "$TMP/mission.md"

# --- негативные пред-проверки (без shim - падают до ssh/scp) ---
assert "нет --to -> отказ" 1 "$RC" takeover start taover --spec "$SPEC" --mission "$TMP/mission.md" --repo "$REPO"
assert "нет spec -> отказ"  1 "$RC" takeover start taover --to fakevm --spec "$TMP/nope.yaml" --mission "$TMP/mission.md" --repo "$REPO"
assert "плохое имя -> отказ" 1 "$RC" takeover start Bad_Name --to fakevm --spec "$SPEC" --mission "$TMP/mission.md" --repo "$REPO"
# пустой mission
: > "$TMP/empty.md"
assert "пустой mission -> отказ" 1 "$RC" takeover start taover --to fakevm --spec "$SPEC" --mission "$TMP/empty.md" --repo "$REPO"

# dirty tree -> отказ
echo dirty >> "$REPO/f.txt"
assert "dirty tree -> отказ" 1 "$RC" takeover start taover --to fakevm --spec "$SPEC" --mission "$TMP/mission.md" --repo "$REPO"
( cd "$REPO" && git checkout -q -- f.txt )

# .gitmodules в дереве HEAD -> submodule-проект отбит (проверка по git-объекту)
( cd "$REPO" && echo '[submodule "x"]' > .gitmodules && $GIT add .gitmodules && $GIT commit -qm submod )
assert "submodule-проект -> отказ" 1 "$RC" takeover start taover --to fakevm --spec "$SPEC" --mission "$TMP/mission.md" --repo "$REPO"
( cd "$REPO" && $GIT rm -q .gitmodules && $GIT commit -qm rmsubmod )

# ветка без upstream -> отказ
( cd "$REPO" && git checkout -q -b orphan )
assert "ветка без upstream -> отказ" 1 "$RC" takeover start taover --to fakevm --spec "$SPEC" --mission "$TMP/mission.md" --repo "$REPO"
( cd "$REPO" && git checkout -q - )

# --- happy-path: shim ssh/scp (логируют), real git push ---
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/ssh" <<SH
#!/usr/bin/env bash
echo "ssh \$*" >> "$TMP/sshlog"
# запрос remote-home (printf %s \$HOME) -> отдать фейковый home в stdout
case "\$*" in
  *printf*HOME*) printf '/remote/home' ;;
esac
exit 0
SH
cat > "$BIN/scp" <<SH
#!/usr/bin/env bash
echo "scp \$*" >> "$TMP/scplog"
exit 0
SH
chmod +x "$BIN/ssh" "$BIN/scp"

HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
PATH="$BIN:$PATH" assert "happy-path (shim ssh/scp) -> ok" 0 \
  "$RC" takeover start taover --to fakevm --spec "$SPEC" --mission "$TMP/mission.md" --repo "$REPO"
# ssh create вызван с --base-commit = HEAD
grep -q -- "--base-commit '$HEAD_SHA'" "$TMP/sshlog" \
  && ok "create вызван с --base-commit=HEAD" || fail "нет --base-commit=HEAD в ssh create"
grep -q "agent create 'taover'" "$TMP/sshlog" \
  && ok "create вызван с именем агента" || fail "нет agent create в ssh"
# spec+mission scp'нуты ДО create (2 scp-вызова)
[[ "$(wc -l < "$TMP/scplog")" -ge 2 ]] \
  && ok "spec+mission скопированы (>=2 scp)" || fail "spec/mission не scp'нуты"
grep -q "spec.yaml" "$TMP/scplog" && grep -q "mission.md" "$TMP/scplog" \
  && ok "scp включает spec.yaml и mission.md" || fail "scp без spec/mission"

echo "---"
echo "agent-takeover: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
