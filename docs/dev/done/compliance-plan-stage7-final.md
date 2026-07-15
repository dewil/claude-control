# Сверка реализации этапа 7 с design-doc (read-only)

Первой строкой отчета напиши: `session id: <id>`.

## Использование субагентов

По возможности делегируй вспомогательную работу собственным субагентам на более дешевых моделях:
- поиск файлов/символов, grep по репо;
- чтение больших файлов и выборка релевантных фрагментов;
- сбор фактов (версии, конфиги, наличие/отсутствие чего-либо);
- проверка тривиальных условий ("есть ли тест на X", "используется ли функция Y").

Что НЕ делегировать дешевым моделям:
- финальные вердикты (реализовано / частично / пропущено / отклонено);
- рассуждения о безопасности, корректности логики, инвариантах;
- сводное заключение в конце отчета.

## Контекст

claude-control - оркестрация автономных claude-агентов (bash + systemd --user +
tmux + yq v4 + python3). Этап 7 плана `docs/plan-2026-07-10-autonomous-agents.md` -
ролевой LLM-приемщик артефактов: воркер `claude-agent-review` делает diff-only
ревью артефакта агента из пустого cwd от имени замороженной роли-ревьюера,
реконсилер оркестрирует acceptance.kind = deterministic | role-review | both.
Реализация завершена одним коммитом `82b6ff3` (HEAD), прошла 6 раундов
adversarial-ревью на этапе дизайна/имплементации. Сейчас нужна ФИНАЛЬНАЯ
сверка: закоммиченный код vs итоговый design-doc.

## Исходный план (источник истины)

`docs/design-2026-07-12-stage7-acceptor-role.md` - прочитай целиком. Это
итоговая версия дизайна после всех раундов ревью. Дополнительно: строка
этапа 7 в `docs/plan-2026-07-10-autonomous-agents.md` (критерий этапа).

## Что реализовано (дифф для сверки)

Коммит `82b6ff3` (= HEAD), смотри `git show 82b6ff3` или `git diff 82b6ff3~1..82b6ff3`.
Файлы:

- `bin/claude-agent-review` (новый, ~330 строк) - воркер-приемщик: строгий
  парсер вердикта extract_verdict, проверка sha роли, безопасный cwd,
  запрет всех тулов + пустой mcp-config, no-clobber результата (O_EXCL+link).
- `bin/claude-agent-reconciler` (+222) - ветки run_acceptance / run_check_criterion
  / run_review_criterion / start_review_unit, verdict_needs_human, tuple-fencing,
  revoke-gate, phase-FSM для kind=both.
- `bin/claude-rc-agent` (+67) - валидация acceptance.kind, --reviewer-role
  (заморозка снапшота, sha256), init acceptance с review_job/phase/reviewer_revoked,
  cmd_revoke_role.
- `roles/acceptor/prompt.md` + `manifest.yaml` - рубрика приемщика + sha.
- Тесты: `tests/test-agent-review.sh` (парсер + no-clobber),
  `tests/fault/run-fault-tests.sh` S20-S27, `tests/fault/mock-review-claude.sh`,
  `tests/corpus/build-corpus.sh` + `run-corpus.sh` (LLM-корпус, критерий этапа),
  `tests/test-agent-cli.sh` (+54).
- `install.sh`, `docs/architecture.md`, строка плана - обвязка.

Хот-споты для сверки инвариантов:
- `bin/claude-agent-review`: extract_verdict (ровно один валидный JSON-объект,
  accept+blocker -> uncertain до усечения), reviewer_role_ok (fail-closed),
  emit (первый результат побеждает).
- `bin/claude-agent-reconciler`: run_review_criterion (retry >=3 -> needs-human,
  auto_accept opt-in, вердикт-асимметрия), run_check_criterion (gate-режим
  через CAS phase), tuple-fencing {job_id, generation, artifact}.

## Задание

По каждому пункту/разделу design-doc определи статус:
**реализовано / частично / пропущено / отклонено** (с пояснением, в чем
отклонение). Особо проверь разделы про: схему acceptance в state.yaml,
жизненный цикл ревью-джоба (FSM фаз для kind=both), fail-closed поведение
(отсутствие роли, битый вердикт, git-ошибки), вердикт-асимметрию,
revoke-механику, изоляцию ревьюера (тулы, cwd, mcp), тесты из раздела
тест-плана (все ли заявленные сценарии есть в коде тестов).

Дополнительно перечисли, что есть в диффе СВЕРХ design-doc (появилось, но
не было заявлено) - отдельным блоком.

## Формат ответа

Таблица "пункт плана -> статус -> комментарий" (группируй по разделам
design-doc) + отдельный блок "сверх плана". Без оценок качества кода
(это не аудит) - только сверка факта реализации.

READ-ONLY: только отчет, файлы не менять.
