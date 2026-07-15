# Состязательное ревью, раунд 6: закрытие дефектов r5 (read-only)

Первой строкой: `session id: <id>`.

Та же сессия. В раунде 5 ты дал вердикт "ДА С ЗАКРЫТИЕМ дефектов пунктов 1,
3-9". Я применил фиксы. Проверь, что КАЖДЫЙ дефект РЕАЛЬНО закрыт и фикс не
внёс новой дыры. Не подтверждай на слово - перечитай изменённый код.

## Threat-model - та же (ошибки, не злоумышленник; изоляция отложена системно).

## Как сведены дефекты r5 (проверь по коду `bin/claude-agent-harvest`, кроме 7b-io)

1. **Маскировка Д5** -> `SECRET_PATTERNS` получил PEM-БЛОК
   `-----BEGIN[\s\S]*?-----END[^\n]*?-----` + отдельные BEGIN/END строки;
   `render_brief` прогоняет `project` path через `mask()`. Проверь: тело PEM и
   END теперь маскируются; путь с секретом в brief замаскирован.
2. (п.2 был чист - не трогал.)
3. **Валидатор Д7** -> `validate_clusters`: убраны срезы `[:CLUSTERS_MAX]`/
   `[:IDS_PER_CLUSTER_MAX]`; `len(clusters) > CLUSTERS_MAX -> return []`
   (весь вывод); `len(ids) > IDS_PER_CLUSTER_MAX -> отброс кластера`.
   `extract_clusters`: теперь РОВНО один top-level объект (`len(objs)!=1 ->
   []`), и он несёт clusters. Проверь: oversize не обрезается молча; второй
   объект (инъекция) отбивается.
4. **candidate_id integrity** -> `candidate_id_of(c)` = sha16([sorted ids,
   essence, why, how]); `cmd_approve` И `cmd_reject` fail-closed сверяют
   `candidate_id_of(c) == cid` (die 6 при рассинхроне). Проверь: порча essence
   в emitted при том же id -> approve/reject отказ.
5. **Lifecycle/coverage Д8** -> (а) `durable_append` цикл `while mv:` до полной
   записи (short-write закрыт, ledger И emitted); (б) `cmd_reject`
   переструктурирован: чистка (`_remove_brief` fail-closed + fsync каталога;
   `_canon_rmw remove`) ДО смены статуса; битый canon -> `_canon_rmw` die ->
   статус НЕ меняется -> re-run лечит; `already`-ветка перечищает идемпотентно;
   (в) `_remove_brief` fsync каталога после unlink. Плюс `build_prompt` теперь
   получает essence+reason отклонённых. Проверь: reject на битом/отсутствующем
   canon не возвращает ids в пул с висящими артефактами; self-heal re-run.
6. **canon RMW Д9** -> `_canon_rmw` под `CanonLock`: schema-валидация ВХОДА
   (`_canon_type == !!map` И `_canon_field_type(.upstream_pending) in
   {!!seq,!!null}`) ВНУТРИ лока (не до), затем `_canon_edit` (yq strenv +
   durable_write + revalidate map). Проверь: precheck больше не вне лока;
   битая схема map / нелистовой upstream_pending -> die до записи.
7. **collect/incarnation Д2/Д4** -> (а) тот же `durable_append`-fix (ledger);
   (б) `agent_incarnation`: `isinstance(inc,str) and INC_RE.match(inc)` (hex32),
   иначе fallback на legacy `agent_created`. Плюс `bin/claude-agent-io`
   `validate_control`: `incarnation` опционально, но если есть - строго hex32
   (`INCARNATION_RE`). Проверь: битое incarnation в control.json -> collector
   игнорит (не переключает идентичность); control-cas отвергнет запись мусорного
   incarnation; legacy-агенты БЕЗ поля не ломаются (опционально).
8. **§8.7 worker** -> `run_llm`: `if proc.returncode != 0: return None`
   (fail-closed на non-zero exit claude). Проверь: аварийный claude -> None ->
   0 кандидатов, не парсит частичный stdout.
9. **rollout** -> `install.sh` список скриптов дополнен `claude-agent-harvest`.
   Проверь: бинарник теперь ставится; `claude-rc harvest` на VM не упадёт.

## Задача раунда 6

По КАЖДОМУ дефекту 1,3-9: ЗАКРЫТ / закрыт частично (чем) / НЕ закрыт (чем
ломается в модели). Отдельно: не внесли ли фиксы НОВЫЙ дефект-в-модели (крэш/
порча/некорректность/потеря сигнала)? Особое внимание:
- `durable_append` цикл - корректен на пустой строке / коротком буфере?
- `cmd_reject` новый порядок - есть ли путь, где статус меняется, а артефакт
  остался (или наоборот - артефакт убран, а ids НЕ вернулись)?
- `_canon_rmw` под локом - `_canon_type`/`_canon_field_type` открывают файл вне
  CanonLock для чтения типа - гонка с параллельным canon-sync значима в модели?
- integrity-сверка - не ломает ли легитимный re-run approve из pending-upstream
  (контент тот же -> id совпадает -> ок)?
- incarnation-guard - legacy fallback всё ещё различает пересозданных?

## Итог одной строкой

Можно ли коммитить и катить на VM: ДА / ДА с закрытием остатка списком / НЕТ.

READ-ONLY: только отчёт, файлы не менять.
