#!/usr/bin/env python3
"""Trust preseed (V2.1 §4): идемпотентный RMW hasTrustDialogAccepted=true в
$CLAUDE_CONFIG_DIR/.claude.json для заданного cwd. Headless `-p` не может
пройти trust-диалог интерактивно.

Общий код: claude-agent-session (mission, tmux-обертка) вызывает как CLI
(bash не импортирует python-модули), claude-agent-run (event, workspace!=
none) - импортом функции напрямую.

RMW под локом (аудит V2.1, major 5): .claude.json - глобальный файл, его пишут
mission-старты, event-прогоны и интерактивный claude одновременно; без лока и
уникального tmp два вызова рвут файл/теряют чужие правки.

Лок берется ПО ПРОТОКОЛУ САМОГО CLI: директория <config>.lock, mkdir на захват,
rmdir на отпускание. Совпадение обязательно - иначе мьютекс односторонний.
Раньше здесь был flock по файлу с тем же именем: имя занималось навсегда, mkdir
у CLI не проходил никогда, и CLI писал конфиг вообще без взаимного исключения,
сыпля "Failed to save config with lock: ENOTDIR ... rmdir" (151 раз за неделю).
"""

import json
import os
import sys
import tempfile
import time

LOCK_STALE_S = 10.0   # старше - считаем брошенным и отбираем
LOCK_WAIT_S = 10.0    # дольше не ждем: сорванный preseed = сессия в trust-диалоге
LOCK_POLL_S = 0.05


def _acquire(lock_path):
    """Захватить лок CLI. True - лок наш, снимать нам.

    False - взять не удалось; пишем без него, как поступает и сам CLI. Потерять
    чужую правку в редком случае лучше, чем не проставить доверие и подвесить
    сессию на диалоге, который в headless некому нажать.
    """
    deadline = time.monotonic() + LOCK_WAIT_S
    while True:
        try:
            os.mkdir(lock_path, 0o700)
            return True
        except FileExistsError:
            pass
        except OSError:
            return False
        try:
            age = time.time() - os.lstat(lock_path).st_mtime
        except OSError:
            continue  # исчез между попытками - пробуем снова
        if age > LOCK_STALE_S:
            # Брошенный лок. Заодно самолечение машин, где от прошлой версии
            # остался ФАЙЛ с этим именем: он тут навсегда и глушит мьютекс CLI.
            try:
                if os.path.isdir(lock_path):
                    os.rmdir(lock_path)
                else:
                    os.unlink(lock_path)
            except OSError:
                pass
            continue
        if time.monotonic() >= deadline:
            return False
        time.sleep(LOCK_POLL_S)


def preseed_trust(config_path, cwd):
    d = os.path.dirname(config_path) or "."
    os.makedirs(d, exist_ok=True)
    lock_path = config_path + ".lock"
    held = _acquire(lock_path)
    try:
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
        if held:
            try:
                os.rmdir(lock_path)
            except OSError:
                pass


if __name__ == "__main__":
    preseed_trust(sys.argv[1], sys.argv[2])
