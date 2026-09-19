Общие поведенческие правила (применяются всегда):

@.claude/rules/typography-ru.md
@.claude/rules/subagents-usage.md
@.claude/rules/docs-maintenance.md
@.claude/rules/compact-results.md
@.claude/rules/addressing.md
@.claude/rules/secrets-handling.md

Правила для кодовых проектов:

@.claude/rules/karpathy-guidelines.md
@.claude/rules/tests-coverage.md
@.claude/rules/error-exposure.md
@.claude/rules/sdd-pipeline.md
@.claude/rules/requirements-traceability.md

Проект принял SDD-конвейер как планку (решение dwl 19.09.2026): изменение, меняющее наблюдаемое поведение, идет через спеку, без градации по размеру. Доменные спеки - `docs/specs/<домен>.md`, спеки фич - `docs/dev/<дата>-spec-<фича>.md`, инварианты - `INV-<ДОМЕН>-NN`.

Архитектура и структура проекта (справка, держи актуальной):

@docs/architecture.md
