"""_agent_worktree: единственное место, где считаются факты о worktree
задачи (commit_sha/base/branch/empty), общее для claude-agent-done
(создание заявки о готовности, V2.7a §3) и claude-agent-run
(finalize_worktree_done - перечитка HEAD в терминальной ветке прогона,
V2.10 §3a). Второй реализации этой проверки заводить нельзя - расхождение
между "что видит claude-agent-done" и "что видит раннер" было бы дырой в
фенсинге само по себе.
"""

import os
import re
import subprocess

BASE_SHA_RE = re.compile(r'^[0-9a-f]{40}$')


def git_run(args, cwd):
    return subprocess.run(["git", "-C", cwd] + args,
                          capture_output=True, text=True, timeout=30)


def worktree_facts(work, base, name):
    """(commit_sha, base, branch, empty) чистого дерева на СВОЕЙ ветке
    задачи, либо None - грязное дерево, git-ошибка, detached/чужая ветка
    или HEAD не потомок base (вызывающий решает про исход). base
    приходит от вызывающего (control.json, зафиксирован при create).

    Проверяется не только родство, но и идентичность ветки (аудит V2.7a,
    major 4): HEAD обязан быть на ветке task/<name>-* этой задачи - иначе
    под "потомок базы" подходит любой коммит любой ветки, выросшей из
    того же корня (в т.ч. detached HEAD или чужая ветка)."""
    if os.path.islink(work):
        return None  # симлинк вместо work - отказ (fail-closed)
    st = git_run(["status", "--porcelain"], work)
    if st.returncode != 0 or st.stdout.strip():
        return None
    br = git_run(["symbolic-ref", "--short", "HEAD"], work)
    if br.returncode != 0:
        return None  # detached HEAD - нет символической ветки
    branch = br.stdout.strip()
    if not branch.startswith("task/%s-" % name):
        return None  # чужая ветка - не ветка этой задачи
    head = git_run(["rev-parse", "HEAD"], work)
    if head.returncode != 0:
        return None
    commit_sha = head.stdout.strip()
    # base приходит от вызывающего (control.json, зафиксирован при create),
    # а НЕ выводится merge-base от самого commit_sha: merge-base по
    # определению предок HEAD, поэтому проверка "HEAD - потомок базы"
    # оказывалась невыполнимой - она не могла провалиться ни при какой
    # истории.
    if not base:
        return None
    if git_run(["merge-base", "--is-ancestor", base, commit_sha],
               work).returncode != 0:
        return None
    return commit_sha, base, branch, (commit_sha == base)
