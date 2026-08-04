#!/usr/bin/env python3
"""Занятость контекстного окна сессии по ее транскрипту.

Печатает по строке на файл: <путь>\t<токены>\t<процент>. Неизвестное - пустым
полем, а не нулем: "не смогли посчитать" и "контекст пуст" - разные вещи.

Токены берутся из usage ПОСЛЕДНЕГО ответа модели: там лежит ровно то, что ушло
в запрос (свежий ввод + прочитанный кеш + записанный кеш), то есть текущий
размер контекста. Сумма по всей переписке не годится - она растет вечно и после
сжатия не падает.

Файл читается С ХВОСТА (последние TAIL_BYTES): транскрипты доходят до десятков
мегабайт, а список сессий рисуется на каждый тап в боте.

Размер окна берем из настроек CLI: суффикс "[1m]" в имени модели - миллион,
иначе 200k. Гадать по наблюдаемому максимуму нельзя: сессия на миллионе, дошедшая
до 150k, показала бы 75% и погнала бы сжимать там, где занято 15%.
"""

import json
import os
import re
import sys

TAIL_BYTES = 512 * 1024
WINDOW_1M = 1_000_000
WINDOW_DEFAULT = 200_000
_USAGE_KEYS = ("input_tokens", "cache_read_input_tokens",
               "cache_creation_input_tokens")


def window_tokens(config_dir=None, project_dir=None):
    env = os.environ.get("CLAUDE_RC_CTX_WINDOW")
    if env and env.isdigit() and int(env) > 0:
        return int(env)
    cfg = config_dir or os.environ.get("CLAUDE_CONFIG_DIR") or \
        os.path.expanduser("~/.claude")
    paths = []
    if project_dir:
        paths += [os.path.join(project_dir, ".claude", "settings.local.json"),
                  os.path.join(project_dir, ".claude", "settings.json")]
    paths.append(os.path.join(cfg, "settings.json"))
    for p in paths:
        try:
            with open(p, encoding="utf-8") as fh:
                model = (json.load(fh) or {}).get("model")
        except (OSError, ValueError):
            continue
        if isinstance(model, str) and model:
            return WINDOW_1M if "[1m]" in model.lower() else WINDOW_DEFAULT
    return WINDOW_DEFAULT


def last_context_tokens(path):
    """Токены в контексте на последний ответ модели. None - если не нашли."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()  # обрезок строки на границе seek - выбросить
            chunk = fh.read()
    except OSError:
        return None
    for raw in reversed(chunk.splitlines()):
        if b'"usage"' not in raw:
            continue
        try:
            rec = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        usage = (rec.get("message") or {}).get("usage")
        if not isinstance(usage, dict):
            continue
        total = 0
        for k in _USAGE_KEYS:
            v = usage.get(k)
            if isinstance(v, (int, float)):
                total += int(v)
        # Нулевую запись пропускаем и ищем дальше: запросом она не была. Такую
        # дописывает CLI после сжатия, и если принять ее за последний ответ, то
        # сессия на 74% окна показывается как пустая.
        if total > 0:
            return total
    return None


def main(argv):
    win = window_tokens()
    for path in argv:
        tok = last_context_tokens(path)
        if tok is None:
            print("%s\t\t" % path)
        else:
            print("%s\t%d\t%d" % (path, tok, round(100.0 * tok / win)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
