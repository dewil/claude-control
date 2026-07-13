#!/usr/bin/env bash
# LLM-корпус приёмщика (этап 7, критерий этапа). Гоняет НАСТОЯЩИЙ
# claude-agent-review по фикстурам build-corpus R раз каждую и проверяет
# пороги (§корпус design): ошибочная фикстура - count_accept==0; корректная
# - count_accept >= R-1; глобально доля uncertain <= 40%. Требует сети/API,
# в обычный unit-прогон НЕ входит.
#
# usage: [R=3] [MODEL=<id>] run-corpus.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
REVIEW="$REPO/bin/claude-agent-review"
R="${R:-3}"
MODEL="${MODEL:-}"
ROLE="$REPO/roles/acceptor"
CORPUS="$(mktemp -d)/corpus"
trap 'rm -rf "$(dirname "$CORPUS")"' EXIT

# точный model ID обязателен (ревью-4/5): плавающий alias/пустой -
# невоспроизводимый прогон. Требуем pin: не голый alias + содержит версию
[[ -n "$MODEL" ]] || { echo "ОШИБКА: задай MODEL=<точный id, напр claude-haiku-4-5-20251001>"; exit 2; }
case "$MODEL" in
  sonnet|opus|haiku|fable|default)
    echo "ОШИБКА: MODEL='$MODEL' - плавающий alias, нужен точный id"; exit 2 ;;
esac
[[ "$MODEL" =~ [0-9] ]] \
  || { echo "ОШИБКА: MODEL='$MODEL' без версии - нужен точный pinned id"; exit 2; }
# R >= 2 (при R<2 порог count_accept>=R-1 вырождается - ревью-5 п.7)
[[ "$R" =~ ^[0-9]+$ && "$R" -ge 2 ]] \
  || { echo "ОШИБКА: R='$R' - нужно целое >= 2 (рекомендуется 3)"; exit 2; }

bash "$HERE/build-corpus.sh" "$CORPUS" >/dev/null
ROLE_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$ROLE/prompt.md")
echo "corpus: R=$R model=$MODEL"
echo "role_prompt_sha256=$ROLE_SHA"
echo

FAIL=0
# confusion matrix пишем парами "<expect> <verdict>" в лог, сводим python'ом
# в конце (переносимо, без bash-4 ассоциативных массивов)
PAIRS="$(mktemp)"
total=0; uncertain=0; errors=0

for d in "$CORPUS"/*/; do
  name=$(basename "$d")
  expect=$(cat "$d/expect.txt")
  mission=$(cat "$d/.mission")
  # фикстура = git-репо с gen_base..artifact (HEAD)
  gen_base=$(git -C "$d" rev-parse HEAD~1)
  artifact=$(git -C "$d" rev-parse HEAD)
  # приёмщику нужен agent-layout: work/ = чекаут, mission.md, reviewer-role/
  ad="$d/.agent"; mkdir -p "$ad"
  ln -s "$d" "$ad/work" 2>/dev/null || cp -R "$d" "$ad/work"
  printf '%s\n' "$mission" > "$ad/mission.md"
  cp -R "$ROLE" "$ad/reviewer-role"
  accepts=0; rejects=0; uncs=0; errs=0
  for run in $(seq 1 "$R"); do
    rm -rf "$ad/.reviews"
    "$REVIEW" "$ad" "job$run" 1 "$artifact" "$gen_base" 120 "$MODEL" \
      >/dev/null 2>&1 || true
    v=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["verdict"])
except Exception: print("ERROR")' "$ad/.reviews/job$run.json" 2>/dev/null)
    case "$v" in
      accept) accepts=$((accepts+1)) ;;
      reject) rejects=$((rejects+1)) ;;
      uncertain) uncs=$((uncs+1)); uncertain=$((uncertain+1)) ;;
      *) errs=$((errs+1)); errors=$((errors+1)) ;;  # ERROR = сбой воркера
    esac
    total=$((total+1))
    echo "$expect $v" >> "$PAIRS"
  done
  printf '  %-14s expect=%-7s accept=%d reject=%d uncertain=%d error=%d  ' \
    "$name" "$expect" "$accepts" "$rejects" "$uncs" "$errs"
  # ERROR (упавший воркер) - это НЕ валидный вердикт: фикстура падает
  if [[ "$errs" -gt 0 ]]; then
    echo "FAIL (worker error=$errs)"; FAIL=$((FAIL+1))
  elif [[ "$expect" == "accept" ]]; then
    if [[ "$accepts" -ge $((R-1)) ]]; then echo "OK"; else echo "FAIL (accept<R-1)"; FAIL=$((FAIL+1)); fi
  else  # reject-фикстура: false-accept недопустим
    if [[ "$accepts" -eq 0 ]]; then echo "OK"; else echo "FAIL (false-accept=$accepts)"; FAIL=$((FAIL+1)); fi
  fi
done

echo
python3 - "$PAIRS" <<'PY'
import sys, collections
cm = collections.Counter()
for ln in open(sys.argv[1]):
    p = ln.split()
    if len(p) == 2:
        v = p[1] if p[1] in ("accept", "reject", "uncertain") else "error"
        cm[(p[0], v)] += 1
print("confusion matrix (expect \\ verdict):")
print("  %-8s %6s %6s %9s %6s" % ("expect", "accept", "reject",
                                  "uncertain", "error"))
for e in ("accept", "reject"):
    print("  %-8s %6d %6d %9d %6d" % (
        e, cm[(e, "accept")], cm[(e, "reject")],
        cm[(e, "uncertain")], cm[(e, "error")]))
PY
rm -f "$PAIRS"
echo
if [[ "$total" -gt 0 ]]; then
  urate=$(python3 -c "print(round(100*$uncertain/$total))")
  echo "uncertain-rate: ${urate}% (лимит 40%), worker-errors: $errors"
  [[ "$urate" -le 40 ]] || { echo "FAIL: вырожденный приёмщик (uncertain > 40%)"; FAIL=$((FAIL+1)); }
fi
echo
echo "corpus: $([ "$FAIL" -eq 0 ] && echo PASS || echo "FAIL ($FAIL)")"
[[ "$FAIL" -eq 0 ]]
