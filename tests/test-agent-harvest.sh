#!/usr/bin/env bash
# Детерминированные тесты bin/claude-agent-harvest (этап 7b). Без сети:
# propose гоняется через мок tests/mock-harvest-claude (CLAUDE_BIN).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HARV="$HERE/../bin/claude-agent-harvest"
MOCK="$HERE/mock-harvest-claude"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_AGENTS_DIR="$TMP/agents"
export CLAUDE_HARVEST_DIR="$TMP/harvest"
export CLAUDE_BIN="$MOCK"
# T17: canon-trigger в изолированный каталог, пинок systemd мокается штампом
export CLAUDE_CANON_DIR="$TMP/canon"
export CLAUDE_CANON_KICK_CMD="touch '$TMP/kick.stamp'"
AGENTS="$CLAUDE_AGENTS_DIR"
HARVEST="$CLAUDE_HARVEST_DIR"
mkdir -p "$AGENTS"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
chk()  { if [[ "$2" == "$3" ]]; then ok; else bad "$1: '$2' != '$3'"; fi; }

pkey() { python3 -c 'import hashlib,os,sys
print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:16])' "$1"; }

# mk_agent <name> <role> <project> <incarnation|-> <note>...
mk_agent() {
  local name="$1" role="$2" proj="$3" inc="$4"; shift 4
  local d="$AGENTS/$name"; mkdir -p "$d"
  cat > "$d/spec.yaml" <<EOF
schema: 1
name: $name
type: mission
role: $role
project: $proj
goal: "g"
autonomy: act
EOF
  if [[ "$inc" == "-" ]]; then
    echo '{"schema":1}' > "$d/control.json"
  else
    # incarnation обязан быть hex32 (token_hex(16)); метку хэшируем детерминированно
    local inchex; inchex=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:32])' "$inc")
    printf '{"schema":1,"incarnation":"%s"}\n' "$inchex" > "$d/control.json"
  fi
  : > "$d/events.jsonl"
  printf '{"at":"2026-07-13T00:00:00Z","event":"agent_created","actor":"operator"}\n' >> "$d/events.jsonl"
  local seq=5
  for note in "$@"; do
    python3 -c 'import json,sys
print(json.dumps({"at":"2026-07-13T00:00:%02dZ"%int(sys.argv[2]),
"event":"acceptance_revise","actor":"operator","seq":int(sys.argv[2]),
"detail":{"note":sys.argv[1]}},ensure_ascii=False))' "$note" "$seq" >> "$d/events.jsonl"
    seq=$((seq+1))
  done
}

ledger_n() { local f="$HARVEST/$1/$2/ledger.jsonl"; [[ -f "$f" ]] && grep -c . "$f" || echo 0; }
cand_status() { # <pkey> <role> <cid> -> текущий статус из свёртки emitted
  python3 -c 'import json,sys
p=sys.argv[1]; cid=sys.argv[2]; st="proposed"; seen=False
try:
    for ln in open(p):
        ln=ln.strip()
        if not ln: continue
        r=json.loads(ln)
        if r.get("candidate_id")!=cid: continue
        if r.get("kind")=="candidate": seen=True
        elif r.get("kind")=="status": st=r.get("status",st)
    print(st if seen else "MISSING")
except FileNotFoundError: print("NOFILE")' "$HARVEST/$1/$2/emitted.jsonl" "$3"
}
first_cid() { # <pkey> <role> -> candidate_id первой candidate-строки
  python3 -c 'import json,sys
for ln in open(sys.argv[1]):
    ln=ln.strip()
    if not ln: continue
    r=json.loads(ln)
    if r.get("kind")=="candidate": print(r["candidate_id"]); break' \
    "$HARVEST/$1/$2/emitted.jsonl"
}

# --- проекты-фикстуры (два разных пути -> два разных project_key) ---
PA="$TMP/projA"; PB="$TMP/projB"; mkdir -p "$PA/.claude" "$PB/.claude"
printf 'project_type: [coding]\nupstream_pending: []\n' > "$PA/.claude/canon.yaml"
KA="$(pkey "$PA")"; KB="$(pkey "$PB")"

# ============================================================ collect ========
# 3 агента одной (проект,роль), у каждого 1 revise -> ledger 3 записи
mk_agent coder-a coder "$PA" inc-aaa "поправь: пиши тесты сразу"
mk_agent coder-b coder "$PA" inc-bbb "нужны тесты в той же задаче"
mk_agent coder-c coder "$PA" inc-ccc "добавляй тесты, не откладывай"
"$HARV" collect >/dev/null
chk "collect: ledger 3 записи" "$(ledger_n "$KA" coder)" "3"

# повторный collect - без дублей
"$HARV" collect >/dev/null
chk "collect идемпотентен" "$(ledger_n "$KA" coder)" "3"

# два разных project-пути -> два разных project_key (без коллизии)
if [[ "$KA" != "$KB" ]]; then ok; else bad "project_key коллизия KA==KB"; fi

# два revise в ОДНУ секунду у одного агента -> разные id (seq различает)
mk_agent dblsec coder "$PB" inc-d "первая в ту же секунду" "вторая в ту же секунду"
# перебьём at обоих на одинаковый timestamp, seq оставим разным
python3 - "$AGENTS/dblsec/events.jsonl" <<'PY'
import json,sys
p=sys.argv[1]; out=[]
for ln in open(p):
    ln=ln.strip()
    if not ln: continue
    r=json.loads(ln)
    if r.get("event")=="acceptance_revise": r["at"]="2026-07-13T00:00:09Z"
    out.append(json.dumps(r,ensure_ascii=False))
open(p,"w").write("\n".join(out)+"\n")
PY
"$HARV" collect >/dev/null
chk "два revise в секунду -> 2 записи" "$(ledger_n "$KB" coder)" "2"

# пересозданный одноимённый (новый incarnation) -> НЕ коллизится со старым id
INC_NEW=$(python3 -c 'import hashlib;print(hashlib.sha256(b"inc-aaa-NEW").hexdigest()[:32])')
printf '{"schema":1,"incarnation":"%s"}\n' "$INC_NEW" > "$AGENTS/coder-a/control.json"
"$HARV" collect >/dev/null
chk "пересоздание -> новая запись (incarnation различает)" "$(ledger_n "$KA" coder)" "4"

# битый incarnation (КЛЮЧ есть, значение невалидно) -> агент ПРОПУСКАЕТСЯ,
# НЕ legacy-fallback (иначе старые события переэмитились бы; codex-r6 п.7а)
mk_agent garbinc coder "$PA" - "garbage-incarnation-поправка"
printf '{"schema":1,"incarnation":"NOT-HEX32-GARBAGE"}\n' > "$AGENTS/garbinc/control.json"
"$HARV" collect >/dev/null 2>&1 && ok || bad "битый incarnation уронил collect"
python3 -c 'import json,sys
present=any(json.loads(l).get("agent")=="garbinc" for l in open(sys.argv[1]) if l.strip())
sys.exit(0 if not present else 1)' "$HARVEST/$KA/coder/ledger.jsonl" \
  && ok || bad "агент с битым incarnation не пропущен (попал в ledger)"

# непарсибельный control.json -> агент ПРОПУСКАЕТСЯ, НЕ legacy (codex-r7 п.2:
# неидентифицируемый агент не должен переключать идентичность)
mk_agent brokenctl coder "$PA" - "broken-control-поправка"
printf 'не json {{{' > "$AGENTS/brokenctl/control.json"
"$HARV" collect >/dev/null 2>&1 && ok || bad "непарсибельный control уронил collect"
python3 -c 'import json,sys
present=any(json.loads(l).get("agent")=="brokenctl" for l in open(sys.argv[1]) if l.strip())
sys.exit(0 if not present else 1)' "$HARVEST/$KA/coder/ledger.jsonl" \
  && ok || bad "агент с непарсибельным control не пропущен"

# каталог агента с невалидным именем (NAME_RE) -> пропуск (не утечёт в ledger)
mkdir -p "$AGENTS/token=SECRET/"
cat > "$AGENTS/token=SECRET/spec.yaml" <<EOF
schema: 1
name: bad
type: mission
role: coder
project: $PA
goal: g
autonomy: act
EOF
printf '{"schema":1,"incarnation":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' > "$AGENTS/token=SECRET/control.json"
printf '{"at":"2026-07-13T00:00:00Z","event":"agent_created","actor":"operator"}\n{"at":"2026-07-13T00:00:05Z","event":"acceptance_revise","actor":"operator","seq":5,"detail":{"note":"n"}}\n' > "$AGENTS/token=SECRET/events.jsonl"
"$HARV" collect >/dev/null 2>&1
grep -rq 'token=SECRET' "$HARVEST" && bad "невалидное имя каталога утекло в harvest" || ok

# --- legacy-агент без incarnation: fallback на agent_created.at ---
mk_agent legacy1 coder "$PA" - "legacy-поправка"
"$HARV" collect >/dev/null
python3 -c 'import json,sys
ok=any(json.loads(l).get("agent")=="legacy1" for l in open(sys.argv[1]) if l.strip())
sys.exit(0 if ok else 1)' "$HARVEST/$KA/coder/ledger.jsonl" \
  && ok || bad "legacy-агент (fallback incarnation) не попал в ledger"

# --- legacy-агент с НЕВАЛИДНОЙ ролью -> collector пропускает ---
mk_agent badrole_a Coder_X "$PA" inc-x "поправка невалидной роли"
"$HARV" collect 2>/dev/null >/dev/null
[[ ! -d "$HARVEST/$KA/Coder_X" ]] && ok || bad "агент с невалидной ролью не пропущен"

# --- рваный хвост events.jsonl -> строка пропускается, collect не падает ---
mk_agent ragged coder "$PB" inc-r "валидная поправка ragged"
printf '{"broken json no close' >> "$AGENTS/ragged/events.jsonl"
"$HARV" collect >/dev/null 2>&1 && ok || bad "рваный хвост уронил collect"
python3 -c 'import json,sys
ok=any(json.loads(l).get("agent")=="ragged" for l in open(sys.argv[1]) if l.strip())
sys.exit(0 if ok else 1)' "$HARVEST/$KB/coder/ledger.jsonl" \
  && ok || bad "валидная строка ragged-агента не собрана"

# ============================================================ секреты ========
mk_agent seca sekret "$PA" inc-s1 "ключ sk-ABCDEF0123456789 в ноте"
mk_agent secb sekret "$PA" inc-s2 "token=SUPERSECRETVALUE утёк"
"$HARV" collect >/dev/null
LEDGER_SEC="$HARVEST/$KA/sekret/ledger.jsonl"
grep -q 'sk-ABCDEF' "$LEDGER_SEC" && bad "секрет sk- не замаскирован в ledger" || ok
grep -q 'SUPERSECRETVALUE' "$LEDGER_SEC" && bad "token= не замаскирован в ledger" || ok
grep -q '\*\*\*' "$LEDGER_SEC" && ok || bad "маска *** отсутствует в ledger"

# ============================================================ propose ========
# 3 непокрытых поправки coder@PA -> один кластер (мок MOCK_MODE=one)
MOCK_MODE=one "$HARV" propose "$KA" coder >/dev/null
CID=$(first_cid "$KA" coder)
[[ -n "$CID" ]] && ok || bad "propose не эмитировал кандидата"
chk "новый кандидат в proposed" "$(cand_status "$KA" coder "$CID")" "proposed"

# digest: показывает proposed-кандидата с evidence и командами approve/dismiss
DIG="$("$HARV" digest "$KA" coder)"
echo "$DIG" | grep -q "$CID" && ok || bad "digest не показал candidate_id"
echo "$DIG" | grep -q "EVIDENCE" && ok || bad "digest без EVIDENCE"
echo "$DIG" | grep -q "approve $KA coder $CID" && ok || bad "digest без готовой команды approve"

# повторный propose с тем же кандидатом -> IMMUTABLE no-op (кандидат не дублится)
N_BEFORE=$(grep -c '"kind": "candidate"' "$HARVEST/$KA/coder/emitted.jsonl")
MOCK_MODE=one "$HARV" propose "$KA" coder >/dev/null
N_AFTER=$(grep -c '"kind": "candidate"' "$HARVEST/$KA/coder/emitted.jsonl")
chk "propose идемпотентен (candidate immutable)" "$N_AFTER" "$N_BEFORE"

# --- валидатор (мок): негативные режимы не эмитят кандидатов ---
# отдельный ключ, чтобы не пересекаться с уже покрытыми
mk_agent va1 valrole "$PB" inc-v1 "суть один"
mk_agent va2 valrole "$PB" inc-v2 "суть два"
mk_agent va3 valrole "$PB" inc-v3 "суть три"
"$HARV" collect >/dev/null
prop_cnt() { grep -c '"kind": "candidate"' "$HARVEST/$KB/valrole/emitted.jsonl" 2>/dev/null || echo 0; }
MOCK_MODE=unknown  "$HARV" propose "$KB" valrole >/dev/null; chk "unknown id -> отброс" "$(prop_cnt)" "0"
MOCK_MODE=overlap  "$HARV" propose "$KB" valrole >/dev/null; chk "пересечение -> отброс всего" "$(prop_cnt)" "0"
MOCK_MODE=injection "$HARV" propose "$KB" valrole >/dev/null; chk "инъекция 2 блока -> отброс" "$(prop_cnt)" "0"
MOCK_MODE=oversize_clusters "$HARV" propose "$KB" valrole >/dev/null; chk "oversize кластеров -> отброс всего" "$(prop_cnt)" "0"
MOCK_MODE=oversize_ids "$HARV" propose "$KB" valrole >/dev/null; chk "oversize id в кластере -> отброс" "$(prop_cnt)" "0"
MOCK_MODE=empty    "$HARV" propose "$KB" valrole >/dev/null; chk "пустой clusters -> 0" "$(prop_cnt)" "0"
MOCK_MODE=one      "$HARV" propose "$KB" valrole >/dev/null; chk "валидный кластер -> 1" "$(prop_cnt)" "1"

# --- кластер из ОДНОЙ инкарнации/агента -> отброс (>=2 distinct нужно) ---
mk_agent solo sololrole "$PA" inc-solo "одна суть A" "одна суть B"
"$HARV" collect >/dev/null
MOCK_MODE=one "$HARV" propose "$KA" sololrole >/dev/null
chk "1 инкарнация -> кластер отброшен" \
  "$(grep -c '"kind": "candidate"' "$HARVEST/$KA/sololrole/emitted.jsonl" 2>/dev/null || echo 0)" "0"

# ============================================================ lifecycle ======
# proposed -> approve -> pending-upstream (не applied); бриф + canon-запись
"$HARV" approve "$KA" coder "$CID" >/dev/null
chk "approve -> pending-upstream" "$(cand_status "$KA" coder "$CID")" "pending-upstream"
BRIEF="$PA/toolkit-log/upstream-pending/harvest-coder-$CID.md"
[[ -f "$BRIEF" ]] && ok || bad "бриф не создан approve"
# T17 (§5.3): approve эмитит durable canon-trigger + пинок maintainer-юнита
[[ -f "$TMP/canon/harvest-trigger.json" ]] && ok || bad "T17: canon-trigger маркер не записан"
[[ -f "$TMP/kick.stamp" ]] && ok || bad "T17: пинок maintainer не выполнен"
# T25 (§10.3): pending - машиночитаемый список pending-upstream для maintainer
"$HARV" pending > "$TMP/pending.out" 2>/dev/null
grep -q "\"cid\": \"$CID\"" "$TMP/pending.out" && ok || bad "T25: pending не выдал кандидата"
python3 -c 'import json,sys
[json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$TMP/pending.out" \
  && ok || bad "T25: pending не JSON-lines"
grep -q "harvest-coder-$CID.md" "$PA/.claude/canon.yaml" && ok || bad "canon-запись не добавлена"
grep -q '\*\*\*' "$BRIEF" || grep -q 'Evidence' "$BRIEF" && ok || bad "бриф без evidence"

# approve идемпотентен: повтор не дублит canon-запись, статус тот же
"$HARV" approve "$KA" coder "$CID" >/dev/null
chk "approve x2: одна canon-запись" \
  "$(HARVEST_ENTRY= yq '.upstream_pending | length' "$PA/.claude/canon.yaml")" "1"

# recovery: убрали canon-запись вручную, re-approve из pending-upstream доводит
HARVEST_ENTRY="toolkit-log/upstream-pending/harvest-coder-$CID.md" \
  yq -i '.upstream_pending = ((.upstream_pending // []) - [strenv(HARVEST_ENTRY)])' "$PA/.claude/canon.yaml"
"$HARV" approve "$KA" coder "$CID" >/dev/null
grep -q "harvest-coder-$CID.md" "$PA/.claude/canon.yaml" && ok || bad "re-approve не восстановил canon-запись"

# mark-applied -> терминал
"$HARV" mark-applied "$KA" coder "$CID" >/dev/null
chk "mark-applied -> applied" "$(cand_status "$KA" coder "$CID")" "applied"
# approve из applied -> отказ (FSM guard Д9)
"$HARV" approve "$KA" coder "$CID" >/dev/null 2>&1; chk "approve из applied отбит" "$?" "4"

# --- dismiss терминал + не переэмитится ---
CID_VAL=$(first_cid "$KB" valrole)
"$HARV" dismiss "$KB" valrole "$CID_VAL" --reason "не тянет на правило" >/dev/null
chk "dismiss -> dismissed" "$(cand_status "$KB" valrole "$CID_VAL")" "dismissed"
MOCK_MODE=one "$HARV" propose "$KB" valrole >/dev/null
chk "dismissed покрывает: propose не эмитит заново" "$(prop_cnt)" "1"

# --- upstream-rejected: ids в пул + чистка артефактов ---
# новый ключ под reject-цикл
mk_agent ra1 rejrole "$PA" inc-ra1 "reject-суть один"
mk_agent ra2 rejrole "$PA" inc-ra2 "reject-суть два"
"$HARV" collect >/dev/null
MOCK_MODE=one "$HARV" propose "$KA" rejrole >/dev/null
CID_R=$(first_cid "$KA" rejrole)
"$HARV" approve "$KA" rejrole "$CID_R" >/dev/null
BRIEF_R="$PA/toolkit-log/upstream-pending/harvest-rejrole-$CID_R.md"
[[ -f "$BRIEF_R" ]] && ok || bad "reject-цикл: бриф не создан"
"$HARV" reject "$KA" rejrole "$CID_R" --reason "канон отклонил" >/dev/null
chk "reject -> upstream-rejected" "$(cand_status "$KA" rejrole "$CID_R")" "upstream-rejected"
[[ ! -f "$BRIEF_R" ]] && ok || bad "reject не убрал бриф"
grep -q "harvest-rejrole-$CID_R.md" "$PA/.claude/canon.yaml" && bad "reject не убрал canon-запись" || ok
# ids вернулись в пул: идентичная essence -> тот же candidate_id -> подавлен
# (immutable, корректно); переформулированная (essence-memory) -> новый кандидат
MOCK_MODE=one "$HARV" propose "$KA" rejrole >/dev/null
chk "reject+идентичная essence -> тот же id подавлен" \
  "$(grep -c '"kind": "candidate"' "$HARVEST/$KA/rejrole/emitted.jsonl")" "1"
MOCK_MODE=one MOCK_ESSENCE="переформулированная суть роли" \
  "$HARV" propose "$KA" rejrole >/dev/null
python3 -c 'import json,sys
cands=[json.loads(l) for l in open(sys.argv[1]) if l.strip() and json.loads(l).get("kind")=="candidate"]
sys.exit(0 if len(cands)>=2 else 1)' "$HARVEST/$KA/rejrole/emitted.jsonl" \
  && ok || bad "upstream-rejected не вернул ids в пул (переформулировка не всплыла)"

# ============================================================ no-follow ======
# upstream-pending -> симлинк на agents/<victim>/role -> approve падает на assert
mk_agent victim coder "$PB" inc-vic "victim-поправка"
mkdir -p "$AGENTS/victim/role"
PC="$TMP/projC"; mkdir -p "$PC/.claude" "$PC/toolkit-log"
printf 'project_type: [coding]\nupstream_pending: []\n' > "$PC/.claude/canon.yaml"
ln -s "$AGENTS/victim/role" "$PC/toolkit-log/upstream-pending"
mk_agent nfa nfrole "$PC" inc-nf1 "nf суть один"
mk_agent nfb nfrole "$PC" inc-nf2 "nf суть два"
"$HARV" collect >/dev/null
KC="$(pkey "$PC")"
MOCK_MODE=one "$HARV" propose "$KC" nfrole >/dev/null
CID_NF=$(first_cid "$KC" nfrole)
"$HARV" approve "$KC" nfrole "$CID_NF" >/dev/null 2>&1
RC=$?
chk "no-follow: approve отбит (exit 6)" "$RC" "6"
ls "$AGENTS/victim/role/"*.md >/dev/null 2>&1 && bad "no-follow: запись просочилась в role/" || ok

# симлинк upstream-pending НАРУЖУ проекта (не в agents) -> тоже отбит (in_root)
PD="$TMP/projD"; OUT="$TMP/outside-evil"; mkdir -p "$PD/.claude" "$PD/toolkit-log" "$OUT"
printf 'project_type: [coding]\nupstream_pending: []\n' > "$PD/.claude/canon.yaml"
ln -s "$OUT" "$PD/toolkit-log/upstream-pending"
mk_agent nda ndrole "$PD" inc-nd1 "nd суть один"
mk_agent ndb ndrole "$PD" inc-nd2 "nd суть два"
"$HARV" collect >/dev/null
KD="$(pkey "$PD")"
MOCK_MODE=one "$HARV" propose "$KD" ndrole >/dev/null
CID_ND=$(first_cid "$KD" ndrole)
"$HARV" approve "$KD" ndrole "$CID_ND" >/dev/null 2>&1
chk "симлинк наружу проекта: approve отбит (exit 6)" "$?" "6"
ls "$OUT/"*.md >/dev/null 2>&1 && bad "запись просочилась наружу проекта" || ok

# ================================================ candidate_id integrity =====
# порча emitted.jsonl (essence изменён, id тот же) -> approve отказ (Д8 п.4)
PE="$TMP/projE"; mkdir -p "$PE/.claude"
printf 'project_type: [coding]\nupstream_pending: []\n' > "$PE/.claude/canon.yaml"
KE="$(pkey "$PE")"
mk_agent ie1 introle "$PE" inc-ie1 "integrity суть один"
mk_agent ie2 introle "$PE" inc-ie2 "integrity суть два"
"$HARV" collect >/dev/null
MOCK_MODE=one "$HARV" propose "$KE" introle >/dev/null
CID_IE=$(first_cid "$KE" introle)
# подменяем essence в candidate-строке, id оставляем
python3 - "$HARVEST/$KE/introle/emitted.jsonl" "$CID_IE" <<'PY'
import json,sys
p,cid=sys.argv[1],sys.argv[2]; out=[]
for ln in open(p):
    ln=ln.strip()
    if not ln: continue
    r=json.loads(ln)
    if r.get("kind")=="candidate" and r.get("candidate_id")==cid:
        r["essence"]="ПОДМЕНЕННАЯ суть (не та, что одобряли)"
    out.append(json.dumps(r,ensure_ascii=False))
open(p,"w").write("\n".join(out)+"\n")
PY
"$HARV" approve "$KE" introle "$CID_IE" >/dev/null 2>&1
chk "approve на повреждённом emitted (id!=контент) отбит (exit 6)" "$?" "6"

# reject fail-closed на битом canon: статус НЕ меняется, ids не в пуле
mk_agent bc1 bcrole "$PE" inc-bc1 "bc суть один"
mk_agent bc2 bcrole "$PE" inc-bc2 "bc суть два"
"$HARV" collect >/dev/null
MOCK_MODE=one "$HARV" propose "$KE" bcrole >/dev/null
CID_BC=$(first_cid "$KE" bcrole)
"$HARV" approve "$KE" bcrole "$CID_BC" >/dev/null
printf 'просто строка, не map\n' > "$PE/.claude/canon.yaml"   # порча canon
"$HARV" reject "$KE" bcrole "$CID_BC" --reason "канон отклонил" >/dev/null 2>&1
chk "reject на битом canon отбит (exit 6)" "$?" "6"
chk "reject на битом canon: статус остался pending-upstream" \
  "$(cand_status "$KE" bcrole "$CID_BC")" "pending-upstream"

# reject на ОТСУТСТВУЮЩЕМ canon -> fail-closed (codex-r6 п.5b): статус не менять
rm -f "$PE/.claude/canon.yaml"
"$HARV" reject "$KE" bcrole "$CID_BC" --reason "x" >/dev/null 2>&1
chk "reject на отсутствующем canon отбит (exit 3)" "$?" "3"
chk "reject без canon: статус остался pending-upstream" \
  "$(cand_status "$KE" bcrole "$CID_BC")" "pending-upstream"
# восстановили canon с записью -> reject доводит (self-heal), статус меняется
printf 'project_type: [coding]\nupstream_pending: [toolkit-log/upstream-pending/harvest-bcrole-%s.md]\n' "$CID_BC" > "$PE/.claude/canon.yaml"
"$HARV" reject "$KE" bcrole "$CID_BC" --reason "канон отклонил" >/dev/null 2>&1
chk "reject после восстановления canon -> upstream-rejected" \
  "$(cand_status "$KE" bcrole "$CID_BC")" "upstream-rejected"
grep -q "harvest-bcrole-$CID_BC.md" "$PE/.claude/canon.yaml" && bad "запись не убрана" || ok

# ======================================================= traversal guard =====
# ../ в project_key/role отбивается ДО join (защита пути реестра)
"$HARV" dismiss '../../etc' coder deadbeefdeadbeef --reason x >/dev/null 2>&1
chk "traversal в project_key отбит (exit 2)" "$?" "2"
"$HARV" approve "$KA" 'bad/role' deadbeefdeadbeef >/dev/null 2>&1
chk "traversal в role отбит (exit 2)" "$?" "2"

# ============================================================ итог ===========
echo "---"
echo "agent-harvest: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
