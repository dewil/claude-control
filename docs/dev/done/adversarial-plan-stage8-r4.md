Verify-adversarial (read-only). Финальная проверка 3 модельных тем.

Дизайн этапа 8 (canon-sync) прошёл 4 раунда. v5 закрыл последние 3 модельные темы (T1/T2/T3). Транзакционная реализация вынесена в §10-контракт (доказывается fault-injection тестами в коде, как этапы 1b/2/4/7). Твоя задача - проверить ТОЛЬКО, что 3 темы закрыты на уровне МОДЕЛИ и правки v5 не внесли новых дизайн-дыр.

## Рамка (жёстко)

НЕ репортить: детали формата/протокола §10 (это реализация, доказывается fault-тестами); стиль; wording без модельного impact; реализационные однострочники; предложения тестов. Репортить ТОЛЬКО реальные МОДЕЛЬНЫЕ дыры в 3 темах ниже или НОВЫЕ дизайн-дефекты от правок v5.

## Файл

`docs/design-2026-07-14-stage8-canon-sync.md` (v5). Смотри §3 (классификатор), §4/§5 (reconciler/FSM/harvester), §6 (инварианты), §9.3 (статус тем), §10 (контракт).

## Контекст

claude-control - агенты над claude remote-control на Selectel VM. claude-toolkit - канон, снапшотится в .claude/ проектов. Этап 8: детерминированный дельта-скрипт поверх immutable release-descriptor, LLM только on-demand. Расщепление на intent(человек)/state(дельта)/ledger(harvester). Harvester (7b, реализован) - реальный писатель upstream_pending (путь брифа + candidate-id, ручной mark-applied). Проекты: git (cactus-*) + не-git (vault).

## Проверь 3 темы (закрыты ли модельно + новые дыры)

**T1 - scope-retirement (§3, §6):** классы `retired-from-scope` (путь выпал из применимого type-set из-за смены membership/project_type, но жив в descriptor для другого типа) vs `managed-but-excluded` (путь вычтен intent-исключением overrides/skip_sync/local_only - намеренно, не retire) vs `removed-upstream` (путь глобально исчез из descriptor). Порядок проверки intent -> membership -> descriptor. ПРОВЕРЬ: нет ли пути, который снова проходит в обход без класса; корректно ли разграничение intent-исключение vs membership-выпадение; завершается ли lifecycle retired (снятие из file_hashes без удаления файла, без блокировки релиза).

**T2 - committed-recovery терминальность + WAL scope (§5, §6, §10):** recovery ВСЕГДА терминален (roll-forward доиграть / roll-back компенсировать полностью) ДО смены desired_release/re-scan; live-WAL (phase != committed-clear) блокирует смену desired; WAL header scope ∈ {per-path, release} - per-path accept НЕ двигает applied_release (фиксирует только file_hashes[path]+decision), release двигает атомарно по гейту. ПРОВЕРЬ на уровне ИНВАРИАНТА (не формата): закрыт ли частичный post-image после kill между file-rename; однозначен ли исход machine-state (applied_release/file_hashes/rollout_record) после kill в любой принципиальной точке; нет ли остаточного "abort+re-scan" без терминализации.

**T3 - post-merge truth (§4, §5, §6):** единая семантика ВЕЗДЕ - branch-applied и harvester ledger-close ТОЛЬКО по ПРИСУТСТВИЮ правила в фактическом post-merge main-tree, НЕ по событию merge; post-merge predicate перечитывает фактическое дерево (merge мог дать дерево != candidate), held при расхождении. ПРОВЕРЬ: согласованы ли формулировки §4/§5/§6 (нет остатка "по событию merge"); закрыт ли ложный необратимый applied; привязан ли applied к фактическому дереву.

## Формат

- T1/T2/T3: закрыта (модельно) / частично / не закрыта + причина.
- Новые дизайн-дефекты от v5: серьёзность.
- Итоговый вердикт: **GO** (3 темы закрыты, новых дизайн-blocker нет - дизайн готов к коду, транзакц. реализация через fault-тесты) / **NO-GO** (оставшиеся модельные blocker).

READ-ONLY. Первой строкой отчёта: session id: <id>.
