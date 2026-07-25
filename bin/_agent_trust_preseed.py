#!/usr/bin/env python3
"""Trust preseed (V2.1 §4): идемпотентный RMW hasTrustDialogAccepted=true в
$CLAUDE_CONFIG_DIR/.claude.json для заданного cwd. Headless `-p` не может
пройти trust-диалог интерактивно.

Общий код: claude-agent-session (mission, tmux-обертка) вызывает как CLI
(bash не импортирует python-модули), claude-agent-run (event, workspace!=
none) - импортом функции напрямую.

RMW под flock (аудит V2.1, major 5): .claude.json - глобальный файл, его
пишут mission-старты, event-прогоны и интерактивный claude одновременно;
без лока и уникального tmp два вызова рвут файл/теряют чужие правки.
"""

import fcntl
import json
import os
import sys
import tempfile


def preseed_trust(config_path, cwd):
    d = os.path.dirname(config_path) or "."
    os.makedirs(d, exist_ok=True)
    lk = os.open(config_path + ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lk, fcntl.LOCK_EX)
        doc = {}
        if os.path.exists(config_path):
            try:
                doc = json.load(open(config_path))
            except ValueError:
                # сломанный конфиг: как раньше (mission inline-код до выноса,
                # аудит minor 6) - НЕ бросаем правку, пишем минимальный
                # валидный документ с trust, а не молча выходим
                doc = {}
        doc.setdefault("hasCompletedOnboarding", True)
        doc.setdefault("theme", "dark")
        proj = doc.setdefault("projects", {}).setdefault(cwd, {})
        proj["hasTrustDialogAccepted"] = True
        fd, tmp = tempfile.mkstemp(prefix=".claude.json.", dir=d)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(doc, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, config_path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    finally:
        fcntl.flock(lk, fcntl.LOCK_UN)
        os.close(lk)


if __name__ == "__main__":
    preseed_trust(sys.argv[1], sys.argv[2])
