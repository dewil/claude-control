Повторный adversarial-раунд, свежая сессия (read-only).

Ты adversarial-ревьюер. Ранее по дизайну этапа 8 (v2) был выдан список из 20 находок (12 blocker + 8 risk) - он приведён ниже дословно. Дизайн переработан до v3. Твоя задача - проверить, что v3 реально закрыл эти находки, и найти НОВЫЕ дефекты от переработки. Исходи из того, что дефекты остались - ломай, а не подтверждай.

## Что ревьюим

Дизайн v3: `docs/design-2026-07-14-stage8-canon-sync.md` (в этом репо, прочитай ЦЕЛИКОМ, включая §9 "Закрытие adversarial-находок"). НЕ верь §9 на слово - сверяй заявленное закрытие с реальным механизмом в теле (§2-§6).

## Контекст системы

`claude-control` - слой автономных агентов на Selectel VM (Linux/systemd; RU-сеть режет raw.githubusercontent). `claude-toolkit` - канон правил/агентов/скиллов, снапшотится побайтово в `.claude/` проектов. Этап 8: детерминированный дельта-скрипт поверх immutable release-descriptor (identity=git commit_sha annotated-тега), LLM только on-demand на конфликтах. Расщепление `canon.yaml` на intent(человек)/state(дельта)/ledger(harvester). maintenance = детерминированный fleet-reconciler (systemd-timer, rollout rings, durable circuit-breaker). Транспорт: SSH-зеркало -> shallow-fetch github:443 -> jsDelivr@sha (только блобы). Граница B: canon-механика в toolkit CLI, control только schedule/inventory/budgets. Плагин отложен (v1 all-delta). Harvester (этап 7b, реализован) - писатель upstream_pending, кладёт brief с ТЕКСТОМ кандидата+ссылку (не blob-SHA). Целевые проекты: cactus-adm/sub/doc/order (git), vault (НЕ git), hiddify-faq, сам claude-control. У agent-reconciler свой flock, stage-8 job его НЕ наследует.

## 20 находок v2 (проверить закрытие каждой в v3)

1 [blk] Release-descriptor самоссылочен: lock в tagged commit обязан нести commit_sha того же коммита - невозможно.
2 [blk] Переход candidate->pin без легального писателя/транзакции: resolved_release в human-intent, дельте писать нельзя; crash -> рассинхрон desired/файлы.
3 [blk] Batch-journal не транзакционен: нет target-SHA/release/phase/backup-locator; crash после rename до state -> классификатор примет за local-edit/conflict.
4 [blk] `new` затирает существующий локальный файл: new="нет в state", наличие на диске не учтено -> перезапись без conflict.
5 [risk] overrides защищён (§6), но формула type-set его не вычитает -> outdated -> молча заменён.
6 [blk] TOCTOU хеш<->rename: нет project-lock/CAS; ручная правка после классификации local==base (vault) затрётся; 2 прохода.
7 [risk] fast-path false green: sha по symlink; потеря +x не ловится.
8 [risk] manifest_digest как identity: две ревизии с равным составом -> равный digest -> exit 0 без обновления metadata/min_cli_version.
9 [risk] jsDelivr@SHA не доказывает identity САМОГО lock: descriptor через CDN без git-proof; commit_sha самодекларирован.
10 [blk] Circuit breaker обходится рестартом/2-м проходом: нет singleton-lock/durable cursor/latch/budget; crash сбрасывает in-memory.
11 [blk] Semantic smoke false green: не определены команда/cwd/revision-binding/fencing; smoke на main при branch-candidate; устаревший CI-результат.
12 [risk] Multi-rev/multi-proj fan-out без сходящейся FSM: нет очереди/cursor/applied-определения для observe/branch; нет bounded-worker/timeout/изоляции.
13 [blk] Единственная .bak ломает 2-й rollout vault: N->N+1->N+2 rollback вернёт N; created-откат без new_sha сверки.
14 [blk] Auto-rollback не знает предыдущий descriptor: state только applied_release; mixed fleet нужен per-project predecessor.
15 [risk] Harvester lifecycle byte-match нереализуем: 7b кладёт текст+ссылку, не path/blob-SHA; сравнение с mutable HEAD -> сирота.
16 [risk] Миграция split теряет pending: pending в canon.yaml.upstream_pending И внешний lifecycle; миграция двух источников не задана.
17 [risk] Граница B противоречива: кто обновляет зеркало+cat-file (control или toolkit CLI) - transport-selection/SHA-validation раздваивается.
18 [risk] min_cli_version/lock_schema fail-closed не исполним: descriptor-структура без явных files/membership; нет schema-dispatch; exit 1 занят transport.
19 [risk] "0 сети strictly-pinned" не выполняется fleet: каждый project-loop git pull зеркала.
20 [blk] 4 conflict-исхода без durable write-path: accept/keep-local/skip_sync/upstream_pending - API не определён; keep-local воспроизведёт conflict; skip_sync нарушит ownership.

## Задача

1. **Статус 20 находок:** по каждому номеру - ЗАКРЫТА / ЧАСТИЧНО / НЕ ЗАКРЫТА + чем именно недостаточно (проверяя по телу v3, не §9).
2. **Новые дефекты v3** от переработки. Особо: WAL prepare/commit/recovery (детерминизм при crash в любой точке; хватает ли полей журнала); ownership desired/applied (новая гонка?); resolution_records keep-local (GC, инвалидация, не подавляет ли реальное расхождение); per-project rollout_record (атомарность, predecessor при mixed fleet); durable circuit-breaker/cursor/budget (singleton-lock реально?); identity ambient commit_sha (не всплыла ли самоссылочность иначе; lock только git, CDN только блобы); harvester lifecycle по candidate-id (замыкается?); mode-поле (+x-дрейф, lstat/symlink); versioned backup в vault (последовательные rollout + ручной edit).
3. **Итоговый вердикт: GO / NO-GO** (GO - если все blocker закрыты и критичных новых нет; NO-GO - с перечнем оставшихся/новых blocker).

НЕ репортить стиль/нейминг/спекулятивные улучшения/предложения тестов. Только реальные поломки/рассинхрон/потерю данных.

Формат: раздел "Статус 20 находок", раздел "Новые дефекты v3" (с серьёзностью), итоговый вердикт.
READ-ONLY: только отчёт, файлы не менять. Первой строкой отчёта: session id: <id>.
