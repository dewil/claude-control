# Ревью: закрытие must-fix кода этапа 5 (read-only, тугая рамка)

Первой строкой: `session id: <id>`.

Та же сессия. В code-review ты дал "ДА с закрытием списка" (17 находок). Я закрыл
must-fix. Проверь ТОЛЬКО закрытия + отсутствие регрессии. НЕ ищи вне модели
"ошибки". НЕ переоткрывай принятые residual'ы (code-6 offline-reuse, code-7
sparse/partial, code-11 spec.project - в дизайне §4.2 как принятые).

## Закрытия (`bin/claude-rc-agent` cmd_create, `bin/claude-rc-takeover`)

1. **Trap/ветка (code-1)**: пред-проверка `show-ref refs/heads/agent/<name>` ДО
   создания - если ветка есть, fail 4 БЕЗ её удаления (recreate fail-closed цел).
   Иначе - ветку создали мы: `_wt_cleanup` (rm tmp + worktree prune + `branch -D
   agent/<name>`) на провале worktree-add И на провале пост-проверки HEAD==sha.
   Проверь: recreate с живой веткой всё ещё отбит и НЕ удаляет чужую ветку;
   провал пост-проверки чистит нашу ветку (не оставляет).
2. **Взаимоисключение (code-15)**: `--base-commit` + любой `--handoff-*` -> fail 2
   до регистрации. Проверь: нельзя адоптировать транскрипт в worktree чужого commit.
3. **Submodule по дереву commit (code-8)**: `cat-file -e "${base_commit}:.gitmodules"`
   (не `-f` VM HEAD). helper: `cat-file -e "HEAD:.gitmodules"`. Проверь: проверяется
   дерево запрошенного commit, не рабочий checkout.
4. **Полный OID + тип commit (code-5)**: `^[0-9a-f]{40}$` + `cat-file -t == commit`
   (tag/tree -> отказ 2). Проверь: короткий префикс отбит; annotated-tag отбит.
5. **Helper remote-home (code-4)**: `rhome=$(ssh "$vm" 'printf "%s" "$HOME"')`,
   staging = `$rhome/.claude-control/takeover-staging/<name>-<commit>` (абсолютный,
   не буквальный `$HOME` в кавычках; уникален по commit - code-2). Проверь: нет
   зависимости от scp shell-expansion; retry другого commit не затирает.
6. **Helper clean fail-closed (code-9)**: `st=$(git status --porcelain) || die`;
   `[[ -z "$st" ]] || die`. Проверь: ошибка status не выглядит как clean.
7. **Helper upstream==origin/branch (code-10)**: upstream сверяется точно с
   `origin/<branch>`; иначе die (push и проверка на одном remote).
8. **Helper $vm (code-14)**: die если `$vm` начинается с `-` (опция-инъекция).
9. **Helper yq_project удалён (code-12)**; overclaim идемпотентности смягчён
   (code-3,16): docstring честно "create paused, ограниченная идемпотентность".
10. **exit-коды (code-17)**: submodule/bad-type/mutual-excl -> 2; missing-commit -> 4.

## Задача

По каждому пункту 1-10: ЗАКРЫТ / частично / не закрыт. Новый дефект-в-модели от
самих фиксов (особенно: `_wt_cleanup` не удаляет чужую ветку в recreate? пред-check
show-ref не гонка? `cat-file ${base_commit}:.gitmodules` синтаксис верен?
staging-per-commit не ломает scp путь с `-`? mutual-excl не ломает штатный
handoff §9 без base-commit?).

## Итог одной строкой

Коммитить и катить на VM: ДА / НЕТ (с файл:строкой).

READ-ONLY: только отчёт.
