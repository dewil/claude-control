# Состязательное ревью, раунд 2: проверка фиксов твоих же находок (read-only)

Первой строкой отчета напиши: `session id: <id>`.

Продолжаем ту же adversarial-сессию. В раунде 1 ты нашел 2 блокера и 4
дефекта cross-incarnation по фиксам живого прогона агентов. Я применил
правки (коммит `bf40835`, поверх раунда 1). Твоя задача - проверить, что
блокеры РЕАЛЬНО закрыты, фиксы не внесли новых дыр, и поискать то, что
осталось. Не подтверждай на слово - ломай заново.

## Что изменено против раунда 1 (git show bf40835)

**Блокер 1 (изоляция permissions):** настройки больше НЕ в worktree.
`bin/claude-rc-agent` cmd_create пишет `agents/<name>/agent-settings.json`
(в реестре) с `{"permissions":{"allow":[...]}}` (act/release -> +Bash;
suggest -> только Read реестра). `bin/claude-agent-session` (flag-форма,
~строки 68-85) добавляет к запуску claude:
`--settings <реестр>/agent-settings.json --setting-sources user,local
--permission-mode <acceptEdits|default>` (autonomy читается из spec.yaml
через yq). Замысел: `--setting-sources` без `project` -> проектный
`.claude/settings.json` целевого репо НЕ грузится и не расширяет права.

**Блокер 2 (shell-exec из агентского текста):** во ВСЕХ eval-сайтах
`bin/claude-agent-reconciler` функция `sh` теперь использует
`shlex.quote` вместо `json.dumps` (строки ~185, 200-202, 605, 767, 886).
Плюс раньше run_review_criterion перевели с `eval` на две отдельные
командные подстановки `$(python3 ...)` для rverdict/rsummary.

**Находка 3 (recreate):** worktree add fail -> `rm -rf registry` + `fail
... 4` (не warning+успех). `bin/claude-rc-agent` ~строки 254-265.

**Находки 4,6 (stale scratch):** cmd_create перед публикацией registry
чистит `cache/<name>.flags`, `rm -rf $SPOOL_BASE/<name>`, и удаляет
ключи `<name>/*` из `cache/alerts-state.json`. ~строки 246-268.

**Находка 5 (git-exclude):** удалено полностью (настройки вне worktree,
`.claude/` там больше не создается).

## Вопросы-направления (ломай, не ограничивайся)

- **Блокер 1 не долечен?** Реально ли `--setting-sources user,local`
  исключает проектный settings? `local` source = что именно грузит в cwd
  агента (worktree целевого репо) - не подтянет ли он `.claude/settings.local.json`
  ИЗ самого целевого репо, если тот его закоммитил/оставил, снова
  расширяя права? user-source: preseed `.claude.json` (trust) - не
  ломает ли `--setting-sources user,local` его загрузку и trust-диалог?
  Совместимость `--settings`+`--setting-sources`+`--permission-mode` с
  `--remote-control` и `--resume` (handoff-путь /solo кейс A: адоптируется
  операторская сессия - применяются ли к ней эти флаги, и надо ли)?
  yq в env юнита claude-agent-session гарантирован?
- **Блокер 2 добит?** Остались ли ЛЮБЫЕ пути, где агентский/LLM-текст
  доходит до bash-eval, `sh -c`, backticks, небезопасной интерполяции в
  обоих бинарях (grep eval / `\$(` / backtick по reconciler, rc-agent,
  agent-run, agent-review, tgbot)? shlex.quote корректен для всех значений
  (перевод строки, NUL невозможен в JSON, очень длинные)? classify output
  сам по себе - доверенный (io classify), или туда тоже течет агентский
  текст помимо claim_artifact (status_line, note)?
- **Находка 3:** `rm -rf registry` при fail - гонка с уже стартовавшим
  reconciler-проходом (успел увидеть полу-registry)? Что если worktree
  add провалился НЕ из-за ветки (нет места, битый git) - `rm -rf` уносит
  чужое? fail-код 4 везде корректно трактуется вызывающими?
- **Находки 4,6:** `rm -rf $SPOOL_BASE/<name>` - если SPOOL_BASE пуст/не
  задан, не сносит ли лишнее; гонка с живым продюсером (spool-put в
  момент create); alerts-state RMW под конкурентным reconciler-писателем
  (там свой lock?); create по-прежнему НЕ атомарен (находка 7 раунда 1) -
  усугубилось ли добавленными шагами до/после mv?
- Регрессии: сломал ли вынос settings обычный (не-recreate) старт;
  переживает ли suggest-агент отсутствие Bash (виснет ли на нужном ему
  git-коммите claim'а - suggest без Bash не сможет `git commit`, значит не
  сможет заявить done?); тест S30/S21 - ловят ли реальную регрессию.

НЕ репортить: стиль/нейминг/докстринги; спекулятивные улучшения; то, что
уже принято моделью угроз v1 (same-UID, агент с Bash дотягивается до
чужих файлов).

## Формат

Список атак: что атаковал, чем ломается (или почему устояло), серьезность.
Для каждого блокера раунда 1 - явный вердикт: закрыт / не закрыт / закрыт
частично. "Проблем нет" - только с перечнем проверенного.

READ-ONLY: только отчет, файлы не менять.
