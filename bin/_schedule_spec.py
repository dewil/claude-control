"""Shared spec.schedule validation (V2.8 §2) + fingerprint (§4).

Одно определение, используемое и bin/claude-rc-agent (create-time, вызов
как скрипт - JSON блока schedule на stdin), и bin/claude-agent-run
(tick-time, импортом) - иначе создание и тик валидируют по-разному, и
именно такой дрейф был блокером аудита V2.8 (спека - обычный файл,
расписание может появиться или измениться в ней уже ПОСЛЕ create, когда
проверка при создании давно отработала).
"""

import hashlib
import json
import re
import sys

_EVERY_RE = re.compile(r"^[1-9][0-9]*(m|h|d)$")
_AT_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
_KNOWN_KEYS = {"every", "at", "text", "json"}


def validate_schedule(d):
    """None, если d - валидный блок schedule (§2); иначе строка-причина."""
    if not isinstance(d, dict):
        return "schedule должен быть map"
    extra = set(d) - _KNOWN_KEYS
    if extra:
        return "schedule: незнакомые ключи %s" % sorted(extra)
    has_every, has_at = "every" in d, "at" in d
    if has_every == has_at:
        return "schedule: нужно ровно одно из every/at"
    if has_every:
        v = d["every"]
        if not isinstance(v, str) or not _EVERY_RE.match(v):
            return "schedule.every: нужен формат <N>m|<N>h|<N>d (N>=1)"
    else:
        v = d["at"]
        if not isinstance(v, str) or not _AT_RE.match(v):
            return "schedule.at: нужен формат HH:MM"
    has_text, has_json = "text" in d, "json" in d
    if has_text == has_json:
        return "schedule: нужно ровно одно из text/json"
    if has_text and not isinstance(d["text"], str):
        return "schedule.text: нужна строка"
    if has_json and not isinstance(d["json"], dict):
        return "schedule.json: нужен объект"
    return None


def fingerprint(d):
    """Хеш нормализованного блока schedule (§4). Смена every/at/text/json
    дает другой fingerprint - schedule-tick считает состояние по старому
    fingerprint чужим и переинициализирует его (без этого смена формата
    every<->at падала бы разбором старого last_slot, а возврат удаленного
    schedule немедленно выстреливал бы наверстыванием)."""
    norm = json.dumps(d, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(norm.encode()).hexdigest()[:16]


if __name__ == "__main__":
    # CLI-обертка для bin/claude-rc-agent (bash): JSON блока schedule на
    # stdin -> текст ошибки на stdout + exit 1, либо тишина + exit 0.
    doc = json.load(sys.stdin)
    err = validate_schedule(doc)
    if err:
        print(err)
        sys.exit(1)
    sys.exit(0)
