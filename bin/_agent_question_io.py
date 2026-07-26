"""_agent_question_io: общий код создания вопроса под questions/.lock -
единственный вопрос-creation путь для claude-agent-ask (kind=info, V2.3
§2) и claude-agent-permit (kind=permission, V2.4 §2). Singleton (не больше
одного status=open) и fail-closed на битом состоянии (аудит V2.3 major 7)
реализованы здесь ровно один раз.

durable_write/durable_json/fsync_dir - тот же протокол tmp+fsync+rename+
fsync(dir), что в claude-agent-run.
"""

import fcntl
import json
import os
import uuid
from datetime import datetime, timezone


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def durable_write(path, data):
    d = os.path.dirname(os.path.abspath(path)) or "."
    tmp = os.path.join(d, ".%s.tmp.%d" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        mv = memoryview(data.encode() if isinstance(data, str) else data)
        while mv:
            mv = mv[os.write(fd, mv):]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    fsync_dir(d)


def durable_json(path, doc):
    durable_write(path, json.dumps(doc, ensure_ascii=False) + "\n")


def envelope_in_inflight(agent_dir, envelope_key):
    """True - envelope_key реально лежит в inbox/inflight/ этого агента
    сейчас (V2.3 major 6 / V2.4 major 6: произвольный/устаревший ключ не
    должен создавать вопрос, не привязанный ни к одному живому прогону, но
    безусловно морозящий очередь). Общая проверка для claude-agent-ask и
    claude-agent-permit."""
    # containment ДО вывода "да" (тот же протокол, что qid_safe_path в
    # V2.3): без него ключ вида "../../tmp/x" проходил бы проверку при
    # существовании любого чужого .json - то есть создавал бы ровно тот
    # осиротевший вопрос, ради которого проверка и заводилась. Форму ключа
    # тут НЕ фиксируем: она задана продюсером конвертов, а не этим слоем.
    if not envelope_key:
        return False
    inflight = os.path.realpath(os.path.join(agent_dir, "inbox", "inflight"))
    path = os.path.realpath(os.path.join(inflight, envelope_key + ".json"))
    if os.path.dirname(path) != inflight:
        return False
    return os.path.isfile(path)


class QuestionError(Exception):
    """Отказ создания вопроса: message + exit code (по умолчанию 2 - как
    остальные валидационные отказы CLI в этом репо)."""

    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def create_question(agent_dir, envelope_key, kind, question, options=None,
                    context=None, extra=None):
    """Singleton-создание вопроса под questions/.lock (V2.3 §1-3, §3.1;
    аудит major 7 - fail-closed на битом файле). Возвращает qid.
    QuestionError - открытый вопрос уже есть, либо questions/ повреждена."""
    qdir = os.path.join(agent_dir, "questions")
    os.makedirs(qdir, mode=0o700, exist_ok=True)
    lk = os.open(os.path.join(qdir, ".lock"), os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lk, fcntl.LOCK_EX)
        for fn in os.listdir(qdir):
            if not fn.endswith(".json"):
                continue
            try:
                d = json.load(open(os.path.join(qdir, fn)))
            except (OSError, ValueError):
                raise QuestionError(
                    "состояние вопросов повреждено (нечитаемый файл %s) - "
                    "разберись вручную перед новым вопросом" % fn)
            if isinstance(d, dict) and d.get("status") == "open":
                raise QuestionError(
                    "уже есть открытый вопрос, объедини формулировки")
        qid = str(uuid.uuid4())
        asked_at = now_iso()
        doc = {
            "qid": qid, "envelope_key": envelope_key, "asked_at": asked_at,
            "kind": kind, "question": question, "options": options,
            "context": context, "status": "open", "answer": None,
            "decision": None, "answered_at": None, "answered_by": None,
            "closed_by_envelope": None,
            "reminder": {"step": 0, "next_push_at": asked_at,
                        "snoozed_until": None}}
        if extra:
            doc.update(extra)
        durable_json(os.path.join(qdir, qid + ".json"), doc)
        return qid
    finally:
        fcntl.flock(lk, fcntl.LOCK_UN)
        os.close(lk)
