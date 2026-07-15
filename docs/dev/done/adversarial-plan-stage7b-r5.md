# Состязательное ревью, раунд 5: РЕАЛИЗАЦИЯ 7b harvester (read-only)

Первой строкой: `session id: <id>`.

Та же сессия. Раунды 1-4 были по ДИЗАЙНУ (ты его принял: "ДА с закрытием
четырёх блокеров-в-модели"). Теперь написан КОД по этому дизайну. Проверь, что
реализация ВЕРНА относительно принятого дизайна и не внесла новых дыр. Не
подтверждай - ломай.

## Threat-model (та же, выровнена под систему)

Защита от ОШИБОК/шума, НЕ от злонамеренного same-UID агента (он всевластен
системно; изоляция отложена для всего claude-control). НЕ репортить как блокер
атаки злонамеренного same-UID (сам approve, прямая запись в canon/role,
эксфильтрация через LLM, TOCTOU-подмена ancestor) - явно вне scope v1.
Репортить дефекты В МОДЕЛИ: крэш / повреждение данных / логическая
некорректность / потеря или ложный сигнал БЕЗ активной атаки; несоответствие
реализации принятому дизайну.

## Что ревьюим (новый/изменённый код)

- `bin/claude-agent-harvest` (НОВЫЙ, ~640 строк) - весь пайплайн:
  collect / propose / digest / approve / dismiss / reject / mark-applied.
- `bin/claude-rc-agent` - enabling-фикс Д0/Д2: `cmd_revise` (~447),
  `cmd_accept_reject` (~467) пишут note/reason в `--detail` события;
  control.json init (~204) получает `incarnation`; валидация `spec.role` (~111).
- `bin/claude-rc` (~55) - dispatch `harvest`.
- `docs/design-2026-07-13-stage7b-harvester.md` - принятый дизайн (эталон).

Смежный существующий код (опора): `bin/claude-agent-io` durable_write (61),
append_event (188, detail), control-cas (288); `bin/claude-agent-review` -
образец §8.7-воркера, на который равнялся propose.

## Ломай прицельно (в рамках модели)

1. **Маскировка (Д5, `mask` + SECRET_PATTERNS).** Есть ли экспортный путь
   (ledger/emitted/digest/brief/canon), где сырьё минует `mask`? Порядок
   применения паттернов - не оставляет ли хвост? correction_id из masked -
   точно необратим в секрет? Многострочный ключ (`-----BEGIN` + тело на
   следующих строках - в ноту попадает как одна строка? событие detail.note -
   одна JSON-строка с `\n`)?
2. **Граница записи (Д11, `assert_write_target` / `_within_project`).** В коде:
   intended_root = КОРЕНЬ ПРОЕКТА, проверка commonpath (в проекте И не в
   agents), O_EXCL+rename. Есть ли путь записи (brief/canon/meta/ledger/
   emitted), параметризованный ledger-содержимым/LLM-выводом, выходящий за
   allowlist? `os.makedirs(brief_root)` ДО assert корня - assert ловит симлинк
   upstream-pending до записи контента? meta.json пишется БЕЗ key-lock (коммент
   "атомарен, идемпотентен") - реальна ли гонка порчи meta двумя ролями?
3. **Валидатор вывода (Д7, `validate_clusters`).** membership (id ⊆ pool),
   disjoint (пересечение -> `return []` весь вывод), >=2 distinct incarnation/
   agent механически, поля bounded. Пробивается ли: кластер из валидных, но
   НЕсвязанных ids (семантика - на human gate, это ОК)? Может ли инъекция в
   тексте ноты заставить эмитнуть кандидата, который пройдёт валидацию и
   навредит на approve (запись куда-то)? `_scan_top_objects` + "ровно один с
   ключом clusters" - обходится вторым объектом/вложенностью?
4. **candidate_id / IMMUTABLE (Д8).** `sha16([sorted ids, essence, why, how])`.
   Immutable-подавление: `if cid in existing` где existing = ВСЕ candidate_id
   любого статуса. После upstream-rejected идентичная essence -> тот же id ->
   подавлен (это корректно?). approve fail-closed сверяет cid с записью?
5. **Lifecycle/coverage (Д8).** `COVERING={proposed,pending-upstream,applied,
   dismissed}`; только upstream-rejected возвращает ids. FSM-гварды:
   approve только из {proposed,pending-upstream}; dismiss из proposed;
   mark-applied из pending-upstream; reject из pending-upstream. Есть ли
   переход, ведущий в неконсистентность, или id, застревающий/двоящийся?
   Свёртка `load_candidates` (append-only, candidate immutable, status
   последний) - верна при рваном хвосте / дублях?
6. **canon RMW (Д9, `_canon_edit` через yq strenv + durable_write).** yq читает
   yaml (комментарии), правит `.upstream_pending` add-if-absent (`| unique`) /
   remove (`- [strenv]`), durable-пишу stdout. Инъекция через entry в yq-
   выражение (entry = `toolkit-log/upstream-pending/harvest-<role>-<cid>.md`,
   role∈NAME_RE, cid∈hex16 - есть ли путь недоверенного в entry)? Повреждённый
   старый canon (не map) -> отказ ДО записи? Крэш между brief / canon / status
   - re-run approve из pending-upstream доводит идемпотентно, без дублей?
   `_canon_type` через `yq . | type` - надёжно ли ловит порчу?
7. **collect идемпотентность/incarnation (Д2/Д4).** correction_id из
   `[project_key, role, incarnation, event_seq, masked_note]`. incarnation:
   control.json или legacy fallback `legacy:<at первого agent_created>`.
   Пересозданный одноимённый: новый events.jsonl (mv в create) -> новый
   agent_created -> различает? dedup по correction_id при повторном collect.
   Гонка collect с живым агентом, дописывающим events.jsonl (рваный хвост)?
   Пропуск seq=None / detail.note отсутствует (события до Д0) - молчит верно?
8. **§8.7-воркер (`run_llm` + `make_empty_cwd`).** Пустой cwd no-follow,
   `--disallowedTools` полный список, strict-mcp пустой, timeout+killpg по
   pgroup (start_new_session). input-кап `LEDGER_INPUT_MAX` - явный отказ, не
   молчаливая обрезка? `--output-format json` парс: `{"result": ...}` -> текст;
   если result не строка? Таймаут -> None -> 0 кандидатов (не крэш)?
9. **Д0 enabling-фикс.** `--detail '{"note": ...}'` в control-cas - не ломает
   контракт события/CAS; append_event идёт под тем же flock после
   durable_write (best-effort, крэш между = событие без ноты - принято)?
   `incarnation` в control.json - не ломает validate_control в io (лишнее поле
   отвергается)? Проверь, что control-cas/state-read терпят новое поле.

## Формат

По каждому пункту 1-9: СООТВЕТСТВУЕТ дизайну / ДЕФЕКТ-в-модели (крэш/порча/
некорректность/потеря сигнала) / несоответствие дизайну. "Проблем нет" - только
с перечнем проверенного. Итог одной строкой: можно ли коммитить и катить на VM
(да / да с закрытием списка дефектов / нет).

READ-ONLY: только отчёт, файлы не менять.
