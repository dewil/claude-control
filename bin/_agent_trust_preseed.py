#!/usr/bin/env python3
"""Trust preseed (V2.1 §4): идемпотентный RMW hasTrustDialogAccepted=true в
$CLAUDE_CONFIG_DIR/.claude.json для заданного cwd. Headless `-p` не может
пройти trust-диалог интерактивно.

Общий код: claude-agent-session (mission, tmux-обертка) вызывает как CLI
(bash не импортирует python-модули), claude-agent-run (event, workspace!=
none) - импортом функции напрямую.
"""

import json
import os
import sys


def preseed_trust(config_path, cwd):
    doc = {}
    if os.path.exists(config_path):
        try:
            doc = json.load(open(config_path))
        except ValueError:
            return  # сломанный конфиг не чиним - пусть ловится как MODAL (T6)
    doc.setdefault("hasCompletedOnboarding", True)
    doc.setdefault("theme", "dark")
    proj = doc.setdefault("projects", {}).setdefault(cwd, {})
    proj["hasTrustDialogAccepted"] = True
    os.makedirs(os.path.dirname(config_path) or ".", exist_ok=True)
    tmp = config_path + ".preseed.tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, config_path)


if __name__ == "__main__":
    preseed_trust(sys.argv[1], sys.argv[2])
