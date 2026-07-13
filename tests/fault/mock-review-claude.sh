#!/usr/bin/env bash
# Мок claude ДЛЯ приёмщика (этап 7 fault-suite): подменяет только CLAUDE_BIN,
# НАСТОЯЩИЙ claude-agent-review вокруг него работает (git diff, mission gate,
# role verification, пустой cwd, строгий парсер, no-clobber). Эмулирует
# `claude -p --output-format json`: читает промпт со stdin, печатает
# result-JSON с вердиктом из $MOCK_REVIEW_VERDICT (accept|reject|uncertain).
#
# MOCK_REVIEW_MODE: verdict (по умолчанию) | fail (exit 1 - мёртвый прогон
# для retry) | badjson (сломать парс -> uncertain).
set -u
cat >/dev/null   # съесть промпт (mission+diff)
case "${MOCK_REVIEW_MODE:-verdict}" in
  fail) echo "mock infra error" >&2; exit 1 ;;
  badjson) inner='это не json, приёмщик даст uncertain' ;;
  *)
    V="${MOCK_REVIEW_VERDICT:-accept}"
    # summary с кириллицей и $()-зондом: note обязана дойти читаемой
    # (не \uXXXX-эскейпами) и НЕ исполниться шеллом реконсилера (S21)
    if [[ "$V" == "reject" ]]; then
      inner='{"verdict":"reject","findings":[{"severity":"blocker","file":"x","issue":"mock"}],"summary":"mock reject"}'
    else
      inner="{\"verdict\":\"$V\",\"findings\":[],\"summary\":\"mock $V кириллица \$(touch /tmp/agent-review-pwned)\"}"
    fi ;;
esac
# claude -p --output-format json оборачивает ответ модели в result
python3 - "$inner" <<'PY'
import json, sys
print(json.dumps({"type": "result", "subtype": "success",
                  "is_error": False, "result": sys.argv[1],
                  "total_cost_usd": 0.0}))
PY
