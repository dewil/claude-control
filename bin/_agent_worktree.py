"""_agent_worktree: единственное место, где считаются факты о worktree
задачи (commit_sha/base/branch/empty), общее для claude-agent-done
(создание заявки о готовности, V2.7a §3) и claude-agent-run
(commit_worktree/finalize_worktree_done - коммит рантайма и перечитка HEAD
в терминальной ветке прогона, V2.10 §3a/§3d.1). Второй реализации этой
проверки заводить нельзя - расхождение между "что видит claude-agent-done"
и "что видит раннер" было бы дырой в фенсинге само по себе.

git_run() здесь - ЕДИНАЯ точка вызова git там, где может присутствовать
агентский worktree (V2.10 §3d.2, третий круг аудита): вычищает окружение и
конфигурационные callback'и (хуки, fsmonitor, pager, editor), а ДО любого
действия fail-closed проверяет, что <work>/.git - штатный указатель на
gitdir проекта (не подмена агентом, §3d.2) и что ни один индексируемый путь
не объявляет git-фильтр (`git check-attr`, а не grep по .gitattributes -
учитывает $GIT_DIR/info/attributes и внешние attributesFile, которые
grep-проверка не видела, аудит r3 блокер 1).
"""

import os
import re
import subprocess

BASE_SHA_RE = re.compile(r'^[0-9a-f]{40}$')


class GitGuardError(Exception):
    """Fail-closed отказ ЕДИНОГО git-хелпера (V2.10 §3d.2): подмененный
    .git-указатель worktree либо объявленный где-либо filter-атрибут."""


def _clean_git_env():
    """Окружение для дочернего git (V2.10 §3d.2): без GIT_* вызывающего
    (могли прийти из прогона claude) плюс переменные, гарантирующие, что
    git не читает пользовательский/системный конфиг вовсе - агент мог бы
    подложить его там же, где подкладывает .gitattributes."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    return env


# Конфигурационные callback'и, глушащие произвольный код агента ДО
# человеческой приемки (V2.10 §3d.2): core.hooksPath - хуки репозитория;
# core.fsmonitor - бинарь, который git запускает на каждом status/add
# (третий круг аудита - именно этот механизм не глушился прежним
# core.hooksPath=/dev/null); core.pager/core.editor - интерактив, которому
# неоткуда прийти в headless-прогоне, но безопаснее исключить как класс;
# --no-optional-locks - не создает посторонних lock-файлов при read-only
# командах статуса.
_CLEAN_GIT_FLAGS = [
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=",
    "-c", "core.pager=cat",
    "-c", "core.editor=true",
    "--no-optional-locks",
]


def _raw_git(args, cwd, timeout=30, text=True, input=None):
    """Хардened, но БЕЗ fail-closed предпроверки - только для внутреннего
    использования guard'ом (иначе его собственный `check-attr` рекурсивно
    требовал бы сам себя). Не экспортируется как публичный API модуля -
    вызывающие обязаны идти через git_run()."""
    return subprocess.run(
        ["git", "-C", cwd] + _CLEAN_GIT_FLAGS + args,
        cwd=cwd, env=_clean_git_env(), capture_output=True,
        text=text, timeout=timeout, input=input)


def _common_gitdir(project_path):
    """Общий gitdir проекта, либо None. Чистая файловая проверка, без
    вызова git - той же дисциплины, что и весь сторож.

    Проект может быть зарегистрирован НЕ основным чекаутом, а вторичным
    worktree (аудит V2.10 r4, серьезная 6): тогда `<project>/.git` - файл
    `gitdir: <common>/worktrees/<id>`, каталога `<project>/.git/worktrees`
    не существует вовсе, и привязка к нему браковала бы КАЖДЫЙ прогон -
    рантайм-коммит всегда отказывал бы, а заявка инвалидировалась.
    Раскладка git тут фиксированная, поэтому общий каталог - на два уровня
    выше `<id>`."""
    dotgit = os.path.join(project_path, ".git")
    if os.path.isdir(dotgit):
        return os.path.realpath(dotgit)
    if not os.path.isfile(dotgit):
        return None
    try:
        with open(dotgit, "rb") as f:
            text = f.read().decode("utf-8", "replace").strip()
    except OSError:
        return None
    if not text.startswith("gitdir: "):
        return None
    p = text[len("gitdir: "):].strip()
    if not os.path.isabs(p):
        p = os.path.normpath(os.path.join(project_path, p))
    p = os.path.realpath(p)
    parent = os.path.dirname(p)
    if os.path.basename(parent) == "worktrees":
        # проект сам - вторичный worktree: общий каталог на два уровня выше
        return os.path.dirname(parent)
    # primary checkout с --separate-git-dir (аудит V2.10 r5, серьезная 4):
    # .git-файл указывает ПРЯМО на общий gitdir, без .../worktrees/<id>.
    # Принимаем только то, что похоже на сам git-каталог (HEAD внутри).
    # Вход здесь - project_path из РЕЕСТРА (доверенный путь оператора), а
    # не agent-writable worktree; границу для worktree задачи держит
    # _worktree_gitdir_ok (префикс common/worktrees + обратный указатель),
    # и это послабление ее не трогает.
    if os.path.isdir(p) and os.path.isfile(os.path.join(p, "HEAD")):
        return p
    return None


def _worktree_gitdir_ok(work, project_path):
    """(ok, reason) - <work>/.git явлется штатным git-worktree указателем,
    заведенным `git worktree add` из project_path, а не файлом/каталогом,
    которым агент подменил бы git собственный конфиг (V2.10 §3d.2, аудит
    r3 блокер 2). Чистая файловая проверка - БЕЗ вызова git, чтобы не
    доверять команде до того, как убедились, что она смотрит куда нужно.

    Требуется ДВУСТОРОННЯЯ связь: work/.git -> .../.git/worktrees/<id>
    (gitdir-файл в work) И .../.git/worktrees/<id>/gitdir -> work/.git
    обратно - ровно то, что поддерживает сам git при `worktree add`. Агент,
    которому Write/Edit ограничены work/** (§1.1), не может подделать ОБЕ
    стороны разом: .git/worktrees/<id>/ проекта лежит вне work/**."""
    dotgit = os.path.join(work, ".git")
    if os.path.islink(dotgit) or not os.path.isfile(dotgit):
        return False, "<worktree>/.git не является обычным файлом-указателем"
    try:
        with open(dotgit, "rb") as f:
            raw = f.read()
    except OSError as e:
        return False, "не удалось прочитать .git: %s" % e
    text = raw.decode("utf-8", "replace").strip()
    if not text.startswith("gitdir: "):
        return False, "содержимое .git не в форме 'gitdir: <path>'"
    gitdir = text[len("gitdir: "):].strip()
    if not os.path.isabs(gitdir):
        gitdir = os.path.normpath(os.path.join(work, gitdir))
    real_gitdir = os.path.realpath(gitdir)
    common = _common_gitdir(project_path)
    if common is None:
        return False, "у проекта нет распознаваемого gitdir"
    expect_prefix = os.path.join(common, "worktrees") + os.sep
    if not (real_gitdir + os.sep).startswith(expect_prefix):
        return False, "gitdir указывает мимо .git/worktrees проекта"
    back_path = os.path.join(real_gitdir, "gitdir")
    try:
        with open(back_path, "rb") as f:
            back_raw = f.read()
    except OSError as e:
        return False, "обратный указатель gitdir/gitdir нечитаем: %s" % e
    back_target = os.path.realpath(
        back_raw.decode("utf-8", "replace").strip())
    if back_target != os.path.realpath(dotgit):
        return False, "обратный указатель не совпадает с work/.git"
    return True, None


def _worktree_filter_clean(work):
    """(ok, reason) - ни один индексируемый путь рабочего дерева НЕ
    объявляет атрибут filter (V2.10 §3d.2, аудит r3 блокер 1). Через `git
    check-attr -z --stdin filter`, а не grep по .gitattributes: check-attr -
    единственный источник ИТОГОВОГО значения атрибута, учитывающий
    $GIT_DIR/info/attributes и внешний core.attributesFile, которые
    grep-проверка прежней обертки (claude-agent-commit, §1.2) не видела.
    Отсутствие узлов в дереве (кроме .git) - нечего проверять, ok."""
    paths = []
    for root, dirs, files in os.walk(work):
        if ".git" in dirs:
            dirs.remove(".git")
        for fn in files:
            rel = os.path.relpath(os.path.join(root, fn), work)
            paths.append(rel)
    if not paths:
        return True, None
    stdin_blob = b"\x00".join(os.fsencode(p) for p in paths) + b"\x00"
    try:
        r = _raw_git(["check-attr", "-z", "--stdin", "filter"], work,
                     text=False, input=stdin_blob)
    except (OSError, subprocess.SubprocessError) as e:
        return False, "git check-attr не удался: %s" % e
    if r.returncode != 0:
        return False, ("git check-attr вернул код %d: %s"
                       % (r.returncode,
                          r.stderr.decode("utf-8", "replace").strip()))
    tokens = [t for t in r.stdout.split(b"\x00") if t != b""]
    for i in range(0, len(tokens) - 2, 3):
        path_b, _attr_b, value_b = tokens[i], tokens[i + 1], tokens[i + 2]
        value = value_b.decode("utf-8", "replace")
        if value not in ("unspecified", "unset"):
            return False, (
                "%s объявляет filter=%s - git add исполнил бы "
                "filter.%s.clean с правами пользователя ДО человеческого "
                "гейта" % (os.fsdecode(path_b), value, value))
    return True, None


def _guard(cwd, project_path):
    """Fail-closed предпроверка ДО любого действия (V2.10 §3d.2) -
    поднимает GitGuardError при первом нарушении."""
    if not project_path:
        raise GitGuardError("project_path не задан - fail-closed")
    ok, reason = _worktree_gitdir_ok(cwd, project_path)
    if not ok:
        raise GitGuardError(reason)
    ok, reason = _worktree_filter_clean(cwd)
    if not ok:
        raise GitGuardError(reason)


def git_run(args, cwd, project_path, timeout=30, text=True, input=None):
    """ЕДИНАЯ точка вызова git в присутствии агентского worktree (V2.10
    §3d.2): коммит рантайма, факты ветки (worktree_facts ниже), статус для
    фазы интеграции (_branch_worktree_status в claude-agent-run). project_path
    - путь ПРОЕКТА (не worktree), из которого worktree заведен - обязателен,
    без него отказ (fail-closed, а не "пропустить проверку").

    Поднимает GitGuardError при провале fail-closed предпроверки -
    вызывающий обязан трактовать это как отказ (та же семантика, что любой
    другой git-сбой на этом пути: комментарий не выполняется, дерево
    остается как есть)."""
    _guard(cwd, project_path)
    return _raw_git(args, cwd, timeout=timeout, text=text, input=input)


def worktree_facts(work, base, name, project_path):
    """(commit_sha, base, branch, empty) чистого дерева на СВОЕЙ ветке
    задачи, либо None - грязное дерево, git-ошибка, detached/чужая ветка,
    HEAD не потомок base, либо fail-closed отказ guard'а (§3d.2) (вызывающий
    решает про исход). base приходит от вызывающего (control.json,
    зафиксирован при create). project_path - путь проекта, из которого
    заведен worktree (для guard'а git_run - §3d.2).

    Проверяется не только родство, но и идентичность ветки (аудит V2.7a,
    major 4): HEAD обязан быть на ветке task/<name>-* этой задачи - иначе
    под "потомок базы" подходит любой коммит любой ветки, выросшей из
    того же корня (в т.ч. detached HEAD или чужая ветка)."""
    if os.path.islink(work):
        return None  # симлинк вместо work - отказ (fail-closed)
    try:
        st = git_run(["status", "--porcelain"], work, project_path)
        if st.returncode != 0 or st.stdout.strip():
            return None
        br = git_run(["symbolic-ref", "--short", "HEAD"], work, project_path)
        if br.returncode != 0:
            return None  # detached HEAD - нет символической ветки
        branch = br.stdout.strip()
        if not branch.startswith("task/%s-" % name):
            return None  # чужая ветка - не ветка этой задачи
        head = git_run(["rev-parse", "HEAD"], work, project_path)
        if head.returncode != 0:
            return None
        commit_sha = head.stdout.strip()
        # base приходит от вызывающего (control.json, зафиксирован при
        # create), а НЕ выводится merge-base от самого commit_sha:
        # merge-base по определению предок HEAD, поэтому проверка "HEAD -
        # потомок базы" оказывалась невыполнимой - она не могла провалиться
        # ни при какой истории.
        if not base:
            return None
        mb = git_run(["merge-base", "--is-ancestor", base, commit_sha],
                     work, project_path)
        if mb.returncode != 0:
            return None
    except GitGuardError:
        return None  # fail-closed (§3d.2): предъявлять нечего
    return commit_sha, base, branch, (commit_sha == base)


def commit_worktree(work, project_path, message):
    """Коммитит ВСЕ изменения агентского worktree (V2.10 §3d.1): рантайм
    индексирует содержимое (`git add -A`) и создает коммит с текстом
    message - агенту это делать больше не дано, единственный путь к git
    закрыт вовсе (обертка claude-agent-commit упразднена). Хуки/fsmonitor/
    pager/editor глушит и fail-closed проверяет ЕДИНЫЙ git_run() (§3d.2).

    (ok, reason): ok=True - коммит создан ЛИБО индексировать было нечего
    (пустой diff после add -A - не ошибка рантайма, тред мог не тронуть
    ничего); ok=False - reason объясняет отказ (guard, git add/commit
    упал, пустое сообщение) - вызывающий (commit_worktree_done) НЕ считает
    это ошибкой прогона: worktree остается как есть, и finalize_worktree_
    done инвалидирует заявку по уже существующему гейту "грязное дерево"
    (§3a) - отдельной обработки отказа здесь не требуется."""
    if not message:
        return False, "пустое summary - коммитить нечем"
    try:
        add = git_run(["add", "-A"], work, project_path)
    except GitGuardError as e:
        return False, "guard: %s" % e
    if add.returncode != 0:
        return False, ("git add не удался: %s"
                       % (add.stderr.strip() or "exit %d" % add.returncode))
    try:
        staged = git_run(["diff", "--cached", "--quiet"], work, project_path)
    except GitGuardError as e:
        return False, "guard: %s" % e
    if staged.returncode == 0:
        return True, "нечего коммитить - индекс пуст после git add -A"
    try:
        # identity явно, а не из конфига (V2.10 §3d.2 сама вычищает
        # GIT_CONFIG_GLOBAL/SYSTEM - без явного -c коммит рантайма упал бы
        # "unable to auto-detect email address" на машине без user.name/
        # email в ЛОКАЛЬНОМ конфиге проекта; проверено опытом).
        commit = git_run(
            ["-c", "user.name=claude-control",
             "-c", "user.email=claude-control@localhost",
             "commit", "--no-verify", "--no-gpg-sign", "-m", message],
            work, project_path)
    except GitGuardError as e:
        return False, "guard: %s" % e
    if commit.returncode != 0:
        return False, ("git commit не удался: %s"
                       % (commit.stderr.strip()
                          or "exit %d" % commit.returncode))
    return True, None
