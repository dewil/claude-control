#!/usr/bin/env python3
"""Пакетное чтение транскриптов для страницы сессий.

Два режима:

  rows --limit N --offset M <файлы...>
      <sid>\t<mtime>\t<origin>\t<cwd>\t<preview>\t<путь> - по строке на сессию,
      в порядке поданных файлов. Файл без человеческой реплики (только служебные
      записи) строки не дает вовсе, и offset считается ПОСЛЕ такого отсева -
      иначе страницы разъезжаются.

  titles <файлы...>
      <путь>\t<имя-сессии> - по строке на КАЖДЫЙ поданный файл, имя пустое, если
      сессия безымянная. Путь первым полем: по нему вызывающий сопоставляет
      строку с сессией.

Зачем питон. Раньше то же самое собирал bash: yq на КАЖДУЮ строку транскрипта в
поисках первой реплики плюс grep по всему файлу за именем. На страницу из восьми
сессий уходило под сто двадцать процессов и почти секунда - при том, что тап в
боте ждет человек. Здесь тот же разбор идет одним проходом.

Транскрипты доходят до десятков мегабайт, поэтому читаем ровно столько, сколько
нужно: превью и cwd лежат у головы (выходим, как только нашли оба), имя ищем с
хвоста и разворачиваемся на полный проход, только если в хвосте его нет.
"""

import json
import os
import re
import sys

TAIL_BYTES = 512 * 1024
PREVIEW_MAX = 120

# Чем подписана сессия, в которой человек еще ничего не сказал. Поле обязано
# быть непустым: пустое схлопнется с соседним при разборе TSV в bash.
EMPTY_PREVIEW = "(без реплик)"

# Компактный JSON от CLI ("type":"custom-title") плюс пробелы после двоеточия -
# ровно та же терпимость, что была у grep в claude-rc.
_TITLE_RE = re.compile(rb'"type":\s*"custom-title"')
_CWD_RE = re.compile(rb'"cwd":"([^"]*)"')
_USER_RE = re.compile(rb'"type":\s*"user"')

# Управляющие символы, которые вычищались из превью и имени. Диапазоны взяты
# один в один из прежней реализации (tr -d '\000-\010\013\014\016-\037'):
# табуляция и перевод строки к этому моменту уже заменены пробелом, а возврат
# каретки (\r) в список не входил и здесь тоже остается.
_CTRL = dict.fromkeys(
    list(range(0x00, 0x09)) + [0x0B, 0x0C] + list(range(0x0E, 0x20)))


def sanitize(text):
    """Одна печатная строка: текст идет в аргумент процесса и в поле TSV."""
    return text.replace("\n", " ").replace("\t", " ").translate(_CTRL)


def _decode(raw):
    return raw.decode("utf-8", "replace")


def _preview_from(rec):
    """Текст человеческой реплики или "" - форма content бывает двух видов."""
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, list):
        parts = [b.get("text") for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
        return " ".join(p for p in parts if isinstance(p, str))
    if isinstance(content, str):
        return content
    return ""


def head_meta(path):
    """(cwd, preview) из головы файла. preview None - реплики человека нет."""
    cwd = None
    preview = None
    try:
        with open(path, "rb") as fh:
            for raw in fh:
                if cwd is None:
                    m = _CWD_RE.search(raw)
                    if m:
                        cwd = _decode(m.group(1))
                if preview is None and _USER_RE.search(raw):
                    try:
                        rec = json.loads(_decode(raw))
                    except ValueError:
                        rec = None
                    if isinstance(rec, dict) and rec.get("type") == "user":
                        txt = sanitize(_preview_from(rec)).lstrip()
                        if txt:
                            preview = txt[:PREVIEW_MAX]
                # Обе величины лежат в первых строках, поэтому обычный файл
                # дочитывать незачем; служебный без реплики прочитается целиком.
                if cwd is not None and preview is not None:
                    break
    except OSError:
        return None, None
    return cwd, preview


def _title_from_lines(lines):
    """Имя из ПОСЛЕДНЕЙ записи custom-title среди строк, иначе None."""
    for raw in reversed(lines):
        if not _TITLE_RE.search(raw):
            continue
        try:
            rec = json.loads(_decode(raw))
        except ValueError:
            continue
        title = rec.get("customTitle")
        if not isinstance(title, str):
            return ""
        return sanitize(title)
    return None


def session_title(path):
    """Имя сессии или "" - то, что в транскрипт пишет /rename и флаг --name."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()  # обрезок строки на границе seek - выбросить
                title = _title_from_lines(fh.read().splitlines())
                if title is not None:
                    return title
                # В хвосте записи нет: сессия, переименованная на старте и с тех
                # пор долго работавшая, держит ее у головы. Без этого отката она
                # молча стала бы безымянной, то есть неотличимой в меню от новой.
                fh.seek(0)
            title = _title_from_lines(fh.read().splitlines())
    except OSError:
        return ""
    return title or ""


def cmd_rows(argv):
    limit, offset = 8, 0
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--limit" and i + 1 < len(argv):
            i += 1
            if argv[i].isdigit() and int(argv[i]) > 0:
                limit = int(argv[i])
        elif a == "--offset" and i + 1 < len(argv):
            i += 1
            if argv[i].isdigit():
                offset = int(argv[i])
        else:
            files.append(a)
        i += 1

    out = sys.stdout.buffer
    shown = skipped = 0
    for path in files:
        if shown >= limit:
            break
        cwd, preview = head_meta(path)
        if preview is None:
            # Реплик нет - но это не обязательно мусор: `new` с телефона
            # поднимает именно такую сессию, и раньше она пропадала из меню
            # целиком. Отличаем по имени: --name пишет custom-title при
            # создании, а брошенный служебный файл имени не несет.
            if not session_title(path):
                continue
            preview = EMPTY_PREVIEW
        if skipped < offset:
            skipped += 1
            continue
        cwd = cwd or ""
        origin = "worktree" if "/.claude/worktrees/" in cwd else "project"
        try:
            mtime = int(os.path.getmtime(path))
        except OSError:
            mtime = 0
        sid = os.path.basename(path)
        if sid.endswith(".jsonl"):
            sid = sid[:-len(".jsonl")]
        row = "\t".join((sid, str(mtime), origin, cwd, preview, path))
        out.write(row.encode("utf-8", "surrogateescape") + b"\n")
        shown += 1
    return 0


def cmd_titles(argv):
    out = sys.stdout.buffer
    for path in argv:
        row = "%s\t%s" % (path, session_title(path))
        out.write(row.encode("utf-8", "surrogateescape") + b"\n")
    return 0


def main(argv):
    mode = argv[0] if argv else ""
    if mode == "rows":
        return cmd_rows(argv[1:])
    if mode == "titles":
        return cmd_titles(argv[1:])
    sys.stderr.write("usage: _rc_meta.py rows|titles ...\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
