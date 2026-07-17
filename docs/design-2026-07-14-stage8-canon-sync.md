# Этап 8: редизайн canon-sync - v5 (release-descriptor + транзакционная FSM + контракт реализации)

Дизайн-дельта к механике canon-sync. План: [plan-2026-07-10](plan-2026-07-10-autonomous-agents.md) строка 197 (этап 8), граница слоев - строки 199-203. Кормится от harvester этапа 7b ([design-2026-07-13-stage7b-harvester.md](design-2026-07-13-stage7b-harvester.md)) через `toolkit-log/upstream-pending`.

**Дата:** 2026-07-14 - **Статус:** v5 - GO (codex verify-adversarial, session 019f60ce, 2026-07-14): 3 модельные темы закрыты, дизайн зафиксирован, готов к коду. Транзакционные свойства (§10) доказываются fault-injection тестами (crash-матрица, как этапы 1b/2/4/7). - **Слои:** claude-toolkit (a,b) + claude-control (c)

История: v1 (lockfile + дельта + гибрид-плагин + LLM-mission) прошел внутренний состязательный проход и codex second-opinion. v2 (release-descriptor центричный) собрал 20 adversarial-находок codex (12 blocker + 8 risk), v3 их закрыл. v3 прошел 2-й codex adversarial (NO-GO: 8/20 закрыто чисто, 8 частично + 12 новых blocker). v4 закрывает дизайн-дыры Группы 1 (П1-П4) и уточнения Группы 3 (П5-П8) в теле §2-§6, а транзакционный протокол Группы 2 фиксирует КОНТРАКТОМ инвариантов (§10), доказываемым fault-injection тестами в коде, НЕ полным протоколом на бумаге. v4 прошел финальный codex adversarial (NO-GO, но близко: 5/8 правок закрыто чисто); остались 3 модельные темы, которые закрывает v5: T1 (retired-from-scope lifecycle, §3/§6), T2 (терминальность recovery + WAL machine-state scope, §10/§5), T3 (post-merge truth - applied по присутствию правила в merged-дереве, §4/§5/§6). Реализационный слой (§10 fault-тесты) v5 не трогает, кроме добавления scope в WAL-header и инварианта терминальности recovery. §0 (принятые решения) сохранен дословно.

## 0. Решения (приняты dwl 2026-07-14, НЕ менять)

- **4 сдвига:** (1) единый **release-descriptor** вместо "тег одного имени в двух каналах"; (2) **расщепление `canon.yaml`** на intent/state/ledger; (3) maintenance = **детерминированный fleet-reconciler**, LLM только on-demand на разрешение конфликтов; (4) **rollout rings + circuit breaker**.
- **RU-транспорт:** 1) SSH-зеркало на host (maintainer), 2) shallow/partial SSH-fetch через github:443, 3) jsDelivr@sha - только аварийный fallback для блобов. identity = commit SHA (не tag).
- **Граница (c) = вариант B:** PR-упаковка, интерпретация pending, сборка release, очистка marker - в toolkit CLI; control - только schedule/inventory/budgets/уведомления/запуск.
- **Плагин: v1 all-delta.** marketplace-плагин - отдельным этапом после capability-спайка; в correctness-модель v1 не входит; гейт - capability-spike.

## 1. Суть решения

canon-sync = **детерминированный дельта-скрипт поверх immutable release-descriptor** с транзакционным (WAL) apply и durable per-project FSM. LLM полностью вне data-plane; поднимается ТОЛЬКО on-demand, когда человек садится разрешать конфликт. Проект пинит одну release-identity = **commit SHA** annotated-тега. Метрика этапа: **0 вызовов LLM на no-op** (это и есть цель). Отдельно: strictly-pinned standalone CLI на no-op делает **0 сетевых обращений** (локальное перехеширование); fleet-путь такого обещания НЕ дает - зеркало обновляется раз на проход (см. §5, снимает находку 19). maintenance = детерминированный fleet-reconciler (systemd-timer -> scan/apply/branch/report). v1 - все компоненты канона через дельту; marketplace-плагин отложен.

## 2. Release-descriptor (ядро версионирования)

Единый immutable объект на ревизию канона. **Identity ревизии = git commit_sha**, на который указывает annotated tag `canon-vN`. commit_sha - **ambient** (внешний по отношению к содержимому lock), НЕ встроен внутрь lock -> снимает самоссылочность (находка 1).

- **Descriptor** (`canon.lock.json` на теге, генерит `scripts/build-lock.py` в CI):
  `{ schema_version, manifest_digest, files{path:{blob_sha, mode}}, membership{path:[секции]}, min_cli_version, plugin_source? (v1 = null) }`.
  **commit_sha в файл НЕ пишется** - его сообщает git-транспорт как объект-identity (tag -> commit). `rev`/`built` - волатильные, в digest не входят.
- **mode на путь (находка 7, дыра B):** git-blob НЕ несет режим (mode живет в git-tree), поэтому источник правды по биту исполнения - явное поле `files[path].mode` (напр. `100644`/`100755`), заполняется из tree при сборке lock. Классификатор и материализация +x берут mode ОТСЮДА, а не из blob. Без mode fail-closed по +x недоказуем.
- **manifest_digest** = sha256 канонического sorted-JSON `files`(включая mode)+`membership`. Это **оптимизация fast-path, НЕ release-identity** (находка 8): равный состав -> равный digest, поэтому identity держит commit_sha, а metadata (`applied_release`, `min_cli_version`, pin) обновляется ВСЕГДА при смене commit_sha, даже если digest равен.
- **Транспорт identity - ПОЛНОЕ зеркало (П5, находка N6):** lock/descriptor тянется ТОЛЬКО доверенным git-транспортом. Primary-транспорт = **host-side SSH-зеркало ПОЛНЫМ клоном** (НЕ shallow), с ретеншном >= N ревизий (дефолт N = глубина `rollout_record`, R4). Прошлый descriptor/lock для отката тянется git-объектом (tag->commit->tree) прямо из этого зеркала - shallow тут не годится, иначе прошлый lock не восстановить (см. §5 rollback). `rollout_record` хранит **commit_sha**, а сам прошлый lock материализуется из полного зеркала по этому SHA. **shallow/partial SSH-fetch - только опциональный secondary** для добора отдельных блобов, НЕ носитель истории descriptor. CDN (jsDelivr) - только для блобов, сверяемых по blob_sha из уже-доверенного lock; НИКОГДА для самого lock (находка 9).
- **schema_version + min_cli_version - fail-closed:** несовместимость -> отдельный **exit-код 2 (incompat)**, не занятый transport(1). schema-version dispatch в CLI: неизвестная старшая версия -> отказ, не "молча проигнорить поля" (находка 18).
- **Discovery vs pin:** `track` (stable / release-index) -> доступная ревизия; **`desired_release` живет в `canon.state.json` (machine-owned)**, не в intent (см. §3, находка 2). Новая ревизия сперва candidate, после apply -> `applied_release`. rollback = смена `desired_release` на прошлый descriptor из durable `rollout_record` (commit_sha -> lock из полного зеркала).

## 3. Часть (a): дельта-скрипт + расщепление состояния и ownership

Монолит `canon.yaml` расщепляется на три файла с РАЗНЫМИ владельцами. Кластер A (модель состояния/ownership) вводит machine-owned поля состояния, чтобы у перехода candidate->pin был легальный писатель-транзакция (закрывает находки 2, 5, 14, 20).

- **`canon.intent.yaml`** (владелец - человек): `project_type`, `track`, `skip_sync`, `local_only`, `overrides`. **БЕЗ `resolved_release`** - политика, не состояние.
- **`canon.state.json`** (владелец - дельта-скрипт, ЕДИНСТВЕННЫЙ писатель machine-полей): `file_hashes` (applied base по путям), снимок `membership`, **`desired_release`** (куда движемся), **`applied_release`** (где сейчас), **`rollout_record`** (durable список N последних applied commit_sha - **ЕДИНСТВЕННЫЙ авторитет** per-project истории отката, П2/c), `resolution_records` (durable решения "resolved-local"). **Указателя на WAL-журнал в state НЕТ** (журнал - фикс-путь, см. §6; дыра C).
- **harvester-ledger** (владелец - harvester): очередь `upstream_pending` + lifecycle по candidate-id (см. §5/§6/F). Реальный формат записи - **путь брифа + candidate-id**, не текст и не blob-SHA (П2/a).

**Атомарность записи state (оговорка находки 2, дыра C).** `canon.state.json` мутируется на двух шагах (сначала `desired_release`, затем в commit-фазе `applied_release`+`file_hashes`). ОБА раза - только через `temp -> fsync -> rename` на том же ФС. Рваная запись в общий state запрещена конструктивно: state никогда не пишется in-place. Атомарность durable-полей - контракт §10.

**Легальный писатель pin.** Переход candidate->pin = дельта пишет `desired_release` (намерение, atomic-rename) и по успешному commit-фазе WAL - `applied_release`+base (второй atomic-rename). resolved_release больше не в human-owned intent (находка 2). Crash между pin и apply детерминирован: `desired_release != applied_release` при отсутствии/`prepare`-журнале -> reconcile доигрывает apply (см. §6/B).

**Явный resolution-API для 4 conflict-исходов** (каждый ЗАМЫКАЕТ FSM; находка 20). Ключевое разделение per-path и release-wide (П3, находка N13):
- **accept-upstream (per-path, П3):** обновляет **ТОЛЬКО** `file_hashes[path]` + durable **decision-record** для этого пути, атомарно в commit-фазе WAL. Release-wide `applied_release` от одного per-path accept **НЕ двигается**. Иначе applied_release=target при нерешенных конфликтах = грязная rollout-история и ложный predecessor при откате.
- **release-wide gate (П3):** `applied_release` продвигается к target ТОЛЬКО когда **все пути релиза classified как не-conflict** (полное разрешение релиза: каждый путь либо up-to-date/outdated-applied, либо замкнут решением accept/keep-local/skip/pending). Пока хоть один путь в `conflict`/`untracked-collision`/`removed-upstream` - релиз НЕ считается applied, `applied_release` держит прошлый commit_sha.
- **keep-local:** durable **resolution_record** класса "resolved-local" `{path, base_sha, local_sha, upstream_sha, release}`. Классификатор при следующем проходе, увидев тот же `(upstream_sha, local_sha)`, выдает `resolved-local`, а не `conflict`. base НЕ обновляем (иначе теряем факт расхождения) - повтор гасит именно record. **Инвалидация (R6):** если `descriptor.files[path].blob_sha != record.upstream_sha` (канон сдвинул путь), record больше НЕ матчит -> путь корректно всплывает как НОВЫЙ `conflict`; stale-record не подавляет уже неактуальное расхождение.
- **skip_sync:** запись в intent через **ЯВНУЮ человеческую команду** (`/canon skip <path>`), дельта intent не трогает (ownership).
- **upstream_pending:** запись в ledger через **harvester-API с candidate-id**, не дельтой (§5/§6/F).

**Скрипт** `scripts/canon-delta.py` (python stdlib, работает в чужом репо без зависимостей):
1. **fast-path (metadata-aware):** если `applied_release.commit_sha == desired_release.commit_sha` И локальное перехеширование type-set совпадает с `file_hashes` (включая mode) -> `up to date`, exit 0. Если commit_sha различаются, но `manifest_digest` равен -> **все равно обновить metadata**, НЕ выходить 0 молча (находка 8). Локальный проход обязателен всегда (ловит `missing-local`/побитый файл/потерю +x).
2. type-set = секции manifest по `project_type` (из membership) **минус `local_only` минус `skip_sync` минус `overrides`** (находка 5); `new` = пути type-set вне state.
3. на путь: `base=file_hashes[path]`, `local` (lstat+open, п.4), `upstream=descriptor.files[path]` (blob_sha+mode).
4. **классификатор по UNION-множеству путей (П1, находка N7):** итерируется по **UNION = (type-set descriptor) ∪ (пути из `state.file_hashes`)**, НЕ только по type-set нового descriptor. Иначе удаленный в каноне путь не всплывает и GC осиротил бы `file_hashes` молча. `local` вычисляется через **lstat + open** без слепого следования symlink - symlink на месте канонического файла -> `conflict` (не `up-to-date` по байтам чужой цели; находка 7). Для путей с `mode=100755` проверяется **бит +x из дескриптора**: потеря бита -> `outdated`/`conflict`, не green. Классы: `up-to-date`; `outdated`(ff); `local-edit`(оставить); `resolved-local`(по record); `conflict`(эскалация); **`untracked-collision`** = upstream `new`, НО файл СУЩЕСТВУЕТ на диске -> `conflict`, не auto-apply (находка 4); **`removed-upstream`** = путь ЕСТЬ в `state.file_hashes`, но **глобально ОТСУТСТВУЕТ в `descriptor.files`** (исчез из канона для ВСЕХ типов) -> **эскалация человеку, НЕ молчаливый GC/удаление** (П1); **`retired-from-scope` (T1)** = путь ЕСТЬ в `state.file_hashes`, но НЕ входит в применимый type-set проекта (выпал из-за смены `membership`/`project_type` в descriptor), ХОТЯ **может оставаться в `descriptor.files` для ДРУГОГО типа** -> перестать управлять путем (retire-lifecycle, §6), НЕ conflict, НЕ удаление файла с диска; **`managed-but-excluded` (T1)** = путь вычтен из применимого type-set **intent-исключением** (`overrides`/`skip_sync`/`local_only`) -> остается под учетом, upstream его НЕ заменяет, но и НЕ retire; `missing-local`(восстановить).
   **Порядок проверки scope-исключений (T1, разграничение intent vs membership):** для пути из UNION, отсутствующего в применимом type-set, классификатор идет строго по цепочке: (1) путь вычтен `overrides`/`skip_sync`/`local_only` -> `managed-but-excluded` (НАМЕРЕННОЕ исключение, остается под учетом); иначе (2) путь выпал из type-set из-за смены `membership`/`project_type` при ЖИВОМ descriptor (путь еще есть в `descriptor.files`, но не для типа проекта) -> `retired-from-scope`; иначе (3) путь глобально исчез из `descriptor.files` -> `removed-upstream`. intent-исключение НИКОГДА не дает retire; retire - только выпадение из scope по membership/project_type.
5. **RE-VERIFY под project-flock:** непосредственно перед каждым rename повторно хешируем `local` под захваченным project-lock и сверяем `local==base`; расхождение -> abort пути в `conflict`, не ff (закрывает TOCTOU, находки 6, 13). Байты тянутся по blob_sha, проверка `sha(fetched)==upstream`, запись через **WAL-журнал** (§6). Остаточное окно: flock advisory - человек/Obsidian его не соблюдают; для не-git vault путь RE-VERIFY->rename в авто-режиме НЕ исполняется (policy принудительно `observe`, R2), для git-проектов окно между RE-VERIFY и rename микроскопично.
6. пишет только machine-поля `canon.state.json` (atomic-rename; не intent, не ledger); итог - машинный JSON; коды `0`/`10`(конфликты)/`1`(транспорт)/`2`(incompat)/`3`(recovery-required).
7. **Детерминированный conflict-digest** (path/class/options + candidate-id для upstream_pending) - LLM не нужен.

`/canon` standalone: сначала дельта; `exit 0` - строка статуса; `exit 10` - LLM тянет тонкий conflict-промт (4 исхода на файл через resolution-API); `exit 2` - fail-closed по schema/min_cli_version. **Инвариант standalone vs fleet (П6, находка N4):** standalone `/canon` **НЕ гоняется по fleet-managed проектам** - проекты под fleet помечены в inventory; standalone на таком проекте отказывает (или переводится в read-only report), чтобы не устроить гонку stale-desired с reconciler.

## 4. Часть (b): marketplace-плагин - отдельный этап (v1 all-delta)

**v1 = все на дельте:** skills/agents/rules/scripts материализуются дельта-скриптом. marketplace-плагин в correctness-модель v1 НЕ входит; `plugin_source` в descriptor = null.

**Гейт плагин-этапа - capability-spike:** (1) поддерживает ли плагин per-project pin на тег/SHA; (2) виден ли plugin `bin/` в PATH под **systemd** (иначе delta-бинарь нельзя гонять только из плагина в фоновом reconciler); (3) семантика version-bump и precedence version>marketplace>SHA. Спайк как на этапах 0/2/5.

**Когда спайк GO:** плагин - только для стабильных namespaced skills (`/canon:<skill>`); delta-бинарь остается доступен и вне плагина (systemd-контекст); rules (нет @-импорта у плагинов), scripts (в корень), персонализация - на дельте. `plugin_source` SHA войдет в release-descriptor - оба канала производны от одной release-identity. Форк как отдельный **release producer** - позже, не runtime-слоение.

**Harvester-lifecycle - привязка к реальному коду (П2, находки нах.16/N14/N5):** завершение записи ledger происходит по **candidate-id**, а не byte-match. Реальный `bin/claude-agent-harvest` кладет в `upstream_pending` **путь брифа** (не текст, не blob-SHA) и знает только ручной `mark-applied` (авто-перехода merge->close в реальном коде НЕТ, durable mapping candidate-id -> target тоже нет). Поэтому lifecycle замыкается **через явный хук `mark-applied` по candidate-id**, который часть (c) СТРОИТ поверх реального harvester. **Единая семантика триггера (T3): хук срабатывает ТОЛЬКО по ПРИСУТСТВИЮ байт правила в фактическом post-merge main-tree** (проверка присутствия в дереве основной ветки после merge), НЕ по СОБЫТИЮ PR-merge. Т.к. applied у harvester терминален (необратим), ложное закрытие по событию merge необратимо, а merge мог дать дерево != засмоканному candidate. Это явное **расширение** harvester-lifecycle, а не опора на несуществующий авто-переход.

## 5. Часть (c): maintenance = детерминированный fleet-reconciler

**НЕ живая LLM-mission.** systemd-timer (12ч + jitter/coalescing; spool-marker от harvester = второй триггер того же job) -> детерминированный reconciler с durable FSM; LLM зовется on-demand только когда человек садится разрешать конфликт. Кластер D закрывает находки 10, 11, 12, 17, 19.

- **Singleton-lock (находка 10, дыра E):** stage-8 job берет **СВОЙ глобальный flock по ФИКСИРОВАННОМУ пути** (напр. `/run/lock/claude-stage8.lock`), который agent-reconciler НЕ наследует. Оба триггера (таймер и harvester-marker) обязаны брать **ОДИН И ТОТ ЖЕ** lock-путь - иначе они разъедутся на два замка; путь зашит в общий job-launcher, не дублируется в unit-файлах. Второй запуск, не взяв lock, выходит немедленно.
- **Durable-состояние на файлах** (crash не сбрасывает): per-project **cursor** (позиция FSM), **breaker-latch**, **budget-учет** - в файлах под spool-каталогом control. `rollout_record` - **НЕ дублируется в control-spool**: единственный авторитет = `canon.state.json` (П2/c), control-spool его только **читает**, не пишет второй копией. In-memory stop/лимит запрещены как единственный носитель. Breaker-latch снимается **только ручным ack**, новый проход его НЕ сбрасывает (находка 10). Атомарность durable cursor/latch/budget - контракт §10.
- **Зеркало - раз на проход, host-side, ПОЛНЫЙ клон** (находка 19+N6, снимает раздвоение находки 17): reconciler в начале прохода ОДИН раз обновляет общее SSH-зеркало канона (`git fetch` по ssh) - зеркало держится **полным клоном** с ретеншном >= N ревизий (см. §2), чтобы прошлый lock/descriptor для отката доставался git-объектом. Метрика "0 сети на no-op" относится к standalone strictly-pinned CLI, НЕ к fleet data-plane.
- **Граница B - кто исполняет transport/SHA/cat-file (находка 17):** transport-selection и обновление зеркала - **host-side шаг toolkit CLI**, вызванный один раз до project-loop. Материализация блобов из зеркала (`git cat-file blob <blob_sha>`, НЕ `<sha>:<path>` - см. §10) исполняет **toolkit-дельта** (в prepare-фазе, §6), а НЕ control: control лишь запускает дельту как непрозрачный CLI и потребляет вердикт+exit-код, сам git не трогает и транспорт не выбирает. Сравнение/ревизия/release-сборка/PR-упаковка/marker-очистка - в toolkit; control - schedule/inventory/budgets/запуск/уведомления.
- **Per-project FSM с durable cursor (находка 12, П8):** `idle -> candidate -> smoking -> applied` (или `held` при conflict/incompat/timeout, `rolled-back` при smoke-fail). Переходы фиксируются в cursor до/после действия -> crash доигрывается детерминированно. "applied" зависит от policy: `observe` = отчет без записи; `branch` = **candidate становится `applied` ТОЛЬКО по ПРИСУТСТВИЮ в фактическом post-merge main-tree** (T3/П8, находка N15/нах.12), НЕ при создании candidate-ветки и НЕ по СОБЫТИЮ merge; `auto-merge` = WAL commit прошел. **post-merge predicate (T3):** applied привязан к ФАКТИЧЕСКОМУ main-tree ПОСЛЕ merge - reconciler **перечитывает дерево основной ветки** (опц. re-smoke на main), т.к. интеграционное разрешение при merge могло дать дерево != засмоканному candidate. Только **совпадение фактического дерева с ожидаемым (присутствие байт правила в дереве) -> `applied`**; расхождение -> `held`/эскалация, applied НЕ фиксируется. То же и для ledger-закрытия harvester (branch-applied и ledger-close - единая семантика по merged-дереву, T3).
- **Bounded workers + per-project timeout + изоляция (находка 12):** пул ограниченного размера, у каждого project-loop свой timeout; зависший smoke -> `held(timeout)`, проход остальных не падает.
- **Rollout rings + circuit breaker - определенная семантика (П4, находка N11):** canary -> snapshot-проекты -> остальные; лимит проектов/ревизию; cursor идет по одной ревизии (запрет перепрыгивать несколько неприменённых). Явная семантика breaker:
  - **failure-predicate** = `smoke-fail` ИЛИ `apply-error` (ошибка WAL-apply).
  - **threshold** = стоп текущего ring **после первого fail** (fail-fast на кольце, blast-radius минимален).
  - **latch** привязан к паре **(release, ring)**: durable, переживает рестарт, снимается только ручным ack; новый проход его не сбрасывает.
  - **budget** = durable **pass-id + счетчик**; счетчик переживает рестарт, при старте нового прохода делается **атомарный reset** (по смене pass-id). Единица budget - применений/ревизий на проход (R13), явный cap; исчерпание -> стоп-ring.
  - Детали атомарности durable latch/cursor/budget/pass-id - контракт §10.
- **Semantic smoke - определенный контракт (П7, находка нах.11/N11):** smoke = **"claude успешно грузит `.claude` на candidate-revision без ошибок"** ПЛЮС проверка **exit-code целевой команды проекта**, если она задана в inventory (иначе только load-чек). **Fencing по revision:** запуск ТОЛЬКО в candidate **worktree/branch** (не на main), cwd = candidate. Результат помечается candidate commit_sha; **устаревший результат отвергается по revision-mismatch** (smoke на main или CI-результат с чужим SHA не принимается). **Для не-git vault smoke неприменим** (нет worktree) -> vault всегда `observe`, fleet его не мутирует (R2).
- **Применение:** `safe-update` -> candidate branch/worktree (git) или WAL-журнал (не-git vault, но fleet его не авто-применяет); auto-merge ТОЛЬКО по policy git-проектов; `conflict`/`untracked-collision`/`removed-upstream`/`new-canon`/`incompat` -> durable report без применения.
- **Дайджест:** детерминированный (path/class/options), через alert-hook -> TG + durable файл (источник истины). Список решений, не диффы; шапка N/M/K/P; copy-paste на исход. LLM - только когда человек начал разрешать.
- **Rollback (находка 14, П5):** reconciliation к **предыдущему descriptor из per-project `rollout_record`** (не глобальный N-1 - mixed fleet). `rollout_record` хранит commit_sha; сам прошлый lock материализуется git-объектом из **полного host-side зеркала** (§2). smoke-fail после применения -> авто-откат к `rollout_record[-2]` + алерт. Откат = смена `desired_release` + повторный apply через WAL (легальный писатель, не `git revert`).
- **Recovery терминален, затем CAS по expected-state (П6/T2, находка N4):** возобновление прохода после crash СНАЧАЛА терминализует незавершенную транзакцию - **roll-forward** (доиграть до конца, включая state.json по scope записи, §10) ИЛИ **roll-back** (компенсировать по backup) - и только ПОСЛЕ этого сверяет `desired_release` (CAS по expected-state в cursor). **live-WAL блокирует смену `desired_release`**: пока транзакция не терминальна, desired не двигается (§10). Если после терминализации desired сдвинулся - re-scan под новое намерение, НЕ слепая перезапись. Совместно с инвариантом "standalone не гоняется по fleet-managed" (§3) это закрывает гонку stale-desired. Механику см. §10.
- **Harvester-вход (находка 15/П2/F):** ledger как allowlist -> класс `pending-upstream` (защищен от перезаписи старым каноном). Запись = **путь брифа + candidate-id** (реальный формат `bin/claude-agent-harvest`, П2/a). toolkit CLI при упаковке присваивает target-path и пакует PR (gh) с candidate-id; закрытие записи - **явным хуком `mark-applied` по candidate-id** (§4), триггеримым ТОЛЬКО присутствием правила в фактическом post-merge main-tree (T3), а не событием PR-merge и не авто-переходом.

## 6. Инварианты безопасности

**Транзакционность (кластер B, находки 3, 6, 13; дыра A).** WAL-журнал по **фиксированному пути** `.canon-journal.json` (указателя в state нет, дыра C). Единая модель apply - **stage + atomic rename** (не in-place-backup). Полный транзакционный протокол и его атомарность - **контракт §10** (доказывается fault-тестами); здесь - инварианты-скелет:
- **header:** `{ release_identity: commit_sha, phase: prepare|committed, scope: per-path|release }` (scope задает, какие поля state.json фиксирует recovery, T2/§10).
- **на файл:** `{ path, action, base_sha, target_sha, new_sha, mode, staging_path, backup_path }`.
- **Протокол:**
  - `prepare`: дельта **полностью материализует ВСЕ target-байты** (fetch по blob_sha из зеркала, при недоступе - jsDelivr@sha, проверка `sha==target`) в стейдж `.canon-stage/<pass-id>/<path>`, снимает versioned-пре-имидж модифицируемых в `.canon-bak/<pass-id>/<path>`, `fsync` стейджа+бэкапов+журнала, затем ставит `phase=committed`. После этой точки сеть НЕ нужна на no-op пути, но допустима на recovery (re-fetch по target_sha, §10).
  - `commit`: только локальные **атомарные rename** из стейджа на финальные пути + atomic-rename `state.json` (`applied_release`+`file_hashes`), каждый под RE-VERIFY (§10 CAS).
  - `clear`: удалить журнал+стейдж.
- **Crash-recovery детерминирован** (добивает находку 3):
  - `phase=prepare`: ни один rename не финализирован как валидный. Для каждого файла: если on-disk `== base_sha` - ничего; если `== new_sha` (частично применился) - восстановить из `backup_path` (modified) или удалить (created, но только если on-disk `== new_sha`; при `!= new_sha` - файл кто-то правил -> НЕ трогать, эскалация, находка 13). Удалить стейдж, очистить журнал.
  - `phase=committed`: **терминальный roll-forward** (T2) - для каждого файла с on-disk `!= new_sha` сделать rename из `staging_path` (байты локальны) ИЛИ re-fetch по `target_sha` при потребленном стейдже (§10), затем финализировать atomic-rename `state.json` **по `header.scope`**: `scope=per-path` фиксирует ТОЛЬКО `file_hashes[path]`+decision-record (`applied_release` НЕ двигать), `scope=release` двигает `applied_release`+`file_hashes`+`rollout_record` атомарно (§10). Committed-recovery сверяет **base_sha** перед rename, не только new_sha (§10 CAS). Recovery ВСЕГДА доигрывает committed до конца (и файлы, и state.json) - не оставляет частичный post-image со старым state. Очистить.
  - На вход recovery-необходимости standalone-CLI возвращает `exit 3`; reconciler доигрывает молча.
- **Project-level flock на весь проход** + **RE-VERIFY `local==base` под lock прямо перед каждым rename** (§3 п.5) - закрывает TOCTOU и параллельные проходы (находка 6). Остаточное advisory-окно - см. §3 п.5.
- **Versioned pre-image** `backup_path = .canon-bak/<pass-id>/<path>` (namespace по **pass-id/transaction-id**, НЕ по commit_sha - §10: переживает повторный apply/rollback к тому же target): последовательные N->N+1->N+2 откатываются каждый к своему предшественнику (находка 13). Источник НОВЫХ байт при доигрывании - `staging_path`, источник ОТКАТА - `backup_path`; две роли разведены (дыра A).

**Ownership и не-затирание.** `conflict`/`local-edit`/`untracked-collision`/`resolved-local`/`removed-upstream` НИКОГДА не авто-применяются. **`removed-upstream` НЕ удаляется молча** (П1): путь, исчезнувший из descriptor, но живой в `state.file_hashes`, всплывает эскалацией человеку, а не тихим GC. `local_only`/`skip_sync`/`overrides`/`upstream_pending` - вне apply. Один писатель на файл: intent(человек) / state(дельта, machine-поля, atomic-rename) / ledger(harvester).

**Scope-retirement (T1).** Класс `retired-from-scope` (§3 п.4) - путь выпал из применимого type-set проекта из-за смены `membership`/`project_type`, при том что в `descriptor.files` он может жить для другого типа. Lifecycle: **перестать управлять путем** - снять запись из `state.file_hashes` с durable **retirement-decision-record** (atomic-rename state), НЕ молчаливый GC, НЕ удаление файла с диска (файл остается у проекта как local), НЕ блокировка релиза. Эскалация - **информативно в дайджест**, не `conflict`. Разграничение с `managed-but-excluded`: путь, вычтенный из type-set intent-исключением (`overrides`/`skip_sync`/`local_only`), - НАМЕРЕННОЕ исключение, остается под учетом и НЕ retire; retire срабатывает ТОЛЬКО при выпадении из scope по membership/project_type (порядок проверки - §3 п.4). Отличие от `removed-upstream`: тот - глобальное исчезновение пути из канона (эскалация человеку), retire - живой descriptor, но путь не для этого типа. **Повторный вход (re-entry).** Путь, ранее retired (снят из `state.file_hashes`), при ПОВТОРНОМ появлении в применимом type-set классифицируется штатно, без спец-состояния: если файл существует на диске - это `untracked-collision` (`conflict`, не молчаливая замена); если файла нет - `new`. Retirement НЕ создает скрытого состояния для повторного входа: путь просто снова "вне state".

**Descriptor identity и транспорт (кластер E).** identity = commit_sha (ambient git-объект), lock тянется только git-транспортом из **полного host-side зеркала** (П5); CDN только для блобов по SHA; shallow - лишь secondary для блобов. schema_version/min_cli_version fail-closed -> **exit 2**. `git archive --remote` исключен. Логировать доставщика.

**Схема-совместимость.** schema-version dispatch; неизвестная старшая версия lock или `cli_version < min_cli_version` -> exit 2, отказ применять (находка 18).

**Harvester lifecycle (кластер F, находки 15, 16, П2).** Завершение pending - по **candidate-id через явный хук `mark-applied`** (§4), не byte-match и не авто-переход. harvester кладет **путь брифа + candidate-id** (реальный формат, target-path/blob-SHA harvester НЕ знает); toolkit CLI при упаковке присваивает target-path и пакует PR с candidate-id; хук `mark-applied` (триггеримый ТОЛЬКО присутствием байт правила в фактическом post-merge main-tree, T3/П8, не событием merge) закрывает запись по id. **Миграция split (находка 16):** явный шаг сводит ДВА источника в единый ledger - (1) `.claude/canon.yaml.upstream_pending` (старый, записи **без candidate-id**) и (2) внешний harvester-lifecycle. Дедуп: записям из (1) присваивается синтетический `candidate-id = sha256(<содержимое брифа по пути>)`; при совпадении с записью из (2) берется id из (2), дубль из (1) отбрасывается; несопоставленные из (1) въезжают как самостоятельные. Отдельный migration-шаг, не только bootstrap R12.

**Авторитет descriptor** = CI single-writer + server-side gate (отбраковка коммитов с расходящимся lock-vs-дерево, включая mode); pre-commit - удобство. **Секреты** в дайджест не попадают: пути+классы, не содержимое.

**GC durable-состояния (дыра D, П1).** `rollout_record` bound = 3 (R4, кольцевой). `resolution_records` инвалидируются при движении `upstream_sha` пути (§3 keep-local): stale-record при перехешировании не матчит и удаляется как tombstone-cleanup. Сироты `file_hashes` вне активного type-set проходят через классификатор UNION-множества (§3 п.4) и разводятся по трем классам (T1): путь, глобально отсутствующий в descriptor, - `removed-upstream` (эскалация человеку); путь, живой в descriptor, но выпавший из type-set по membership/project_type, - `retired-from-scope` (retire с durable record, снятие из state, **не** тихий GC-drop); путь, вычтенный intent-исключением, - `managed-but-excluded` (остается под учетом). Прочий GC-хлам (стейдж/бэкап завершенных pass-id) чистится по завершении транзакции.

## 7. Отложено в v1

- marketplace-плагин целиком (отдельный этап после capability-спайка).
- личный форк как release producer + fork-merge precedence (single upstream в v1).
- @-импорт правил через плагин (остается дельта-фетчем).
- identity agent/skill при сосуществовании local+plugin (появляется с плагин-этапом).
- полный rollback-DAG по всей цепочке ревизий (v1 - rollout_record на N последних, откат на одну назад).
- автоматический ack/snooze-UI конфликтов (v1 - ручной snooze-файл с TTL).

## 8. Открытые вопросы / риски в код

- **[R1] server-side gate CI** (lock-vs-дерево, включая mode) - блокер издания descriptor: иначе up-to-date-файлы не тянутся и изменение не доезжает молча.
- **[R2] vault не git:** WAL-журнал + versioned backup - единственный атомарный слой; branch/worktree/smoke для vault нет -> **fleet НИКОГДА не мутирует не-git vault**, policy принудительно `observe`, канон в vault - только отчет + ручной standalone `/canon`.
- **[R3] транспорт:** SSH-зеркало ПОЛНЫМ клоном primary, shallow-fetch secondary (только блобы), jsDelivr@sha fallback ТОЛЬКО для блобов (в prepare-фазе, до commit); логировать доставщика.
- **[R4] размер rollout_record:** глубина отката vs рост state; задает и ретеншн полного зеркала. Дефолт - 3; **на решение dwl**, если нужен глубже rollback-горизонт.
- **[R5] deferred/ack-set (snooze TTL):** заигноренный `conflict`/`removed-upstream`/`untracked-collision` не должен поднимать дайджест каждый цикл бессрочно; resolved-local уже не поднимает (record).
- **[R6] resolution_record staleness:** дефолт - авто-инвалидация record при смене `upstream_sha` пути. Явный tombstone-подавитель, если dwl захочет гасить и на новом base, - **на решение dwl**.
- **[R7] локальный дрейф:** fast-path обязан перехешировать локальные файлы (иначе `missing-local`/потеря +x не чинятся).
- **[R8] semantic smoke:** контракт зафиксирован в §5 (claude грузит .claude + exit-code целевой команды из inventory + revision-fencing); per-project команда - параметр inventory.
- **[R9] descriptor schema + min_cli_version:** зафиксировать schema_version=1, exit 2 fail-closed, dispatch по старшей версии; `files[path]` = `{blob_sha, mode}`.
- **[R10] capability-spike плагина** - гейт (per-project pin, plugin bin/ в systemd PATH, version-bump).
- **[R11] сироты `file_hashes`/state при сбросе типа** - через UNION-классификатор (§3 п.4): путь без descriptor -> `removed-upstream` (эскалация), не тихий drop.
- **[R12] bootstrap + миграция split:** первая раскатка дельты + расщепление canon.yaml - через старый LLM-синк (в vault вручную); плюс явный migration-шаг сведения двух источников pending в ledger с дедупом по candidate-id (§6/F).
- **[R13] budget единица (на решение dwl):** cap в применениях/ревизиях на проход ИЛИ в проектах на ревизию. Дефолт - применений на проход; влияет на скорость раскатки fleet.

## 9. Закрытие adversarial-находок

### 9.1. Раунд 1 (v2 -> v3): 20 находок, закрыты в v3

| # | серьезность | как закрыто |
|---|---|---|
| 1 | blk | Identity = ambient git commit_sha annotated-тега; commit_sha в lock НЕ пишется. §2, §6/E |
| 2 | blk | `desired/applied_release` - machine-owned в state; дельта - легальный писатель через WAL; обе записи atomic-rename. §3(A), §6/B |
| 3 | blk | WAL stage+rename; committed-recovery доигрывает rename из стейджа. §6/B, §10 |
| 4 | blk | `new` + файл на диске -> `untracked-collision` = conflict. §3 п.4 |
| 5 | risk | type-set вычитает и `overrides`. §3 п.2 |
| 6 | blk | Project-flock + RE-VERIFY `local==base` перед rename; singleton. §3 п.5, §6, §10 |
| 7 | risk | lstat вместо open (symlink->conflict); mode per-path в дескрипторе. §2, §3 п.4 |
| 8 | risk | manifest_digest - fast-path; identity = commit_sha; metadata обновляется всегда. §2, §3 п.1 |
| 9 | risk | lock - только git-транспортом; CDN только блобы. §2, §6/E |
| 10 | blk | Singleton-flock; durable cursor/latch/budget; latch снимается ручным ack. §5, §10 |
| 11 | blk | Semantic smoke (см. П7/9.2); revision-fencing. §5, R8 |
| 12 | risk | Per-project FSM + bounded workers + timeout + budget. §5 |
| 13 | blk | Versioned pre-image + отдельный staging_path; created-откат сверяет new_sha. §6/B, §10 |
| 14 | blk | Per-project rollout_record (bound=3); rollback к предшественнику из record. §3(A), §5 |
| 15 | risk | Завершение pending по candidate-id (см. П2/9.2), не byte-match. §5, §6/F |
| 16 | risk | Migration-шаг двух источников pending; дедуп по candidate-id. §6/F, R12 |
| 17 | risk | transport/зеркало - host-side toolkit; cat-file исполняет toolkit-дельта. §5, §6/B |
| 18 | risk | exit 2 (incompat); schema-version dispatch; fail-closed. §2, §3 п.7, §6 |
| 19 | risk | Зеркало раз на проход host-side; "0 сети" = свойство standalone CLI. §1, §5 |
| 20 | blk | Resolution-API на 4 исхода, каждый замыкает FSM (уточнен П3). §3(A) |

### 9.2. Раунд 2 (v3 -> v4): 8 частичных + 12 новых. Закрытие в v4

Дизайн-дыры (Группа 1) и уточнения (Группа 3) закрыты в теле §2-§6 правками П1-П8. Транзакционный протокол (Группа 2) вынесен в контракт §10, доказывается fault-injection тестами.

| правка | находки раунда 2 | суть закрытия | разделы |
|---|---|---|---|
| П1 | N7 | removed-upstream достижим: классификатор по UNION (descriptor ∪ file_hashes); удаленный путь -> эскалация, НЕ тихий GC. | §3 п.4, §6 (ownership, GC) |
| П2 | нах.16, N14, N5 | harvester приведен к реальному коду: `upstream_pending` = путь брифа + candidate-id; lifecycle через явный хук mark-applied; ОДИН авторитет rollout_record (state.json). | §3, §4, §5, §6/F |
| П3 | N13, нах.20 | per-path accept двигает только file_hashes[path]+record; applied_release - только по гейту "все пути релиза не-conflict". | §3 (resolution-API) |
| П4 | N11 | circuit-breaker определен: predicate=smoke-fail∨apply-error; threshold=стоп ring после 1-го fail; latch=(release,ring); budget=pass-id+счетчик, atomic reset. | §5, детали -> §10 |
| П5 | N6 | primary-транспорт = полный host-side клон, ретеншн>=N; прошлый lock из зеркала по commit_sha; shallow только secondary для блобов. | §2, §5, §6/E |
| П6 | N4 | инвариант standalone НЕ по fleet-managed + recovery CAS по expected-state (desired не сдвинулся, иначе abort+re-scan). | §3, §5, §10 |
| П7 | нах.11 | smoke = claude грузит .claude + exit-code целевой команды из inventory; fencing по revision (только candidate worktree); stale отвергается. | §5, R8 |
| П8 | N15, нах.12 | policy=branch: applied ТОЛЬКО после merge в основную ветку; ledger-close по присутствию правила в merged-состоянии, не по событию merge. | §5 (FSM) |

Группа 2 (транзакционный протокол) - контракт §10: WAL-самодостаточность, atomic durability журнала, CAS перед rename, backup namespace по pass-id, identity=(blob_sha,mode), материализация `git cat-file blob <sha>`. Каждый инвариант доказывается crash-матрицей fault-тестов в коде, НЕ бумажным протоколом.

### 9.3. Раунд 3 (v4 -> v5, финальный): 3 модельные темы. Закрытие в v5

v4 прошел финальный codex adversarial: NO-GO, но близко - 5/8 правок (П1-П8, из них 5) закрыты чисто, остались 3 модельные темы. v5 закрывает их точечными модельными правками (реализационный §10 не переписывается, кроме scope в WAL-header и инварианта терминальности recovery).

| тема | серьезность | суть закрытия | разделы |
|---|---|---|---|
| T1 scope-retirement | blocker | Введен класс `retired-from-scope` (путь выпал из применимого type-set по membership/project_type при живом descriptor) с lifecycle "снять из state + durable retirement-record, не GC, не удаление файла, не блок релиза, эскалация информативно"; разграничен с `managed-but-excluded` (intent-исключение - под учетом, не retire) и `removed-upstream` (глобальное исчезновение). Порядок проверки: intent-исключение -> managed-but-excluded; выпал из type-set при живом descriptor -> retired-from-scope; исчез из descriptor -> removed-upstream. | §3 п.4, §6 (scope-retirement, GC) |
| T2 recovery-терминальность + WAL machine-state | blocker | Recovery ВСЕГДА терминален - roll-forward (доиграть, включая state.json) ИЛИ roll-back (компенсировать по backup) ДО смены desired/re-scan; live-WAL блокирует смену `desired_release`; "abort+re-scan" как исход активной транзакции убран. WAL-header несет `scope ∈ {per-path, release}`: per-path фиксирует только file_hashes[path]+decision (applied_release не двигать), release - applied_release+file_hashes+rollout_record атомарно. | §10 (WAL, терминальность, CAS), §5 (recovery), §6 (header, committed-recovery) |
| T3 post-merge truth | 2×high | Единая семантика ВЕЗДЕ: branch-applied и ledger-close - ТОЛЬКО по присутствию байт правила в фактическом post-merge main-tree, НЕ по событию PR-merge. Добавлен post-merge predicate: перечитать main-tree после merge (опц. re-smoke), applied только при совпадении с ожидаемым деревом, иначе held/эскалация (merge мог дать дерево != засмоканному candidate; applied терминален -> ложное закрытие необратимо). | §4, §5 (FSM), §6/F |

## 10. Контракт реализации (проверяется fault-injection тестами, не бумагой)

Рамка: транзакционный протокол canon-sync **доказывается crash-матрицей тестов в коде** (kill в каждой точке протокола), как транзакционные слои этапов 1b/2/4/7 проекта. Дизайн фиксирует ИНВАРИАНТЫ-контракты, а не полный протокол на бумаге. Каждый пункт - контракт, реализуемый в коде (a)/(c) и проверяемый fault-тестом.

- **WAL-запись самодостаточна для файлов И machine-state (T2).** Журнал несет `header{release-id, phase, scope}` + per-file `{path, base_sha, target_sha, new_sha, mode, backup_path}`. **`scope ∈ {per-path, release}`** делает WAL самодостаточным и по state.json, не только по файлам: для **`scope=per-path`** (accept одного пути, §3) recovery фиксирует **ТОЛЬКО `file_hashes[path]` + decision-record**, `applied_release` НЕ двигает (release-identity двигать нельзя при нерешенных путях); для **`scope=release`** (полное применение релиза по гейту "все пути не-conflict", §3) recovery двигает **`applied_release` + `file_hashes` + `rollout_record` атомарно**. Recovery доигрывает из staging (roll-forward без сети) ИЛИ **re-fetch по `target_sha`** при потребленном стейдже (сеть на recovery ДОПУСТИМА - это не no-op путь, а восстановление). Из одной записи журнала детерминированно определимо, что доиграть, откуда взять байты И какие поля state.json зафиксировать.
- **Atomic durability журнала.** Переход `prepare->committed` пишется `temp -> fsync -> rename`; `fsync` **родительских каталогов**. Torn journal исключен конструктивно (не бывает частично записанного header/phase).
- **CAS перед каждым rename.** Непосредственно перед rename - **re-verify on-disk == `base_sha`** под project-flock (не только new_sha). Закрывает TOCTOU и ручную правку в crash-окне. **committed-recovery тоже сверяет `base_sha`**, а не только `new_sha`, - иначе доигрывание затрет чужую правку, появившуюся в окне.
- **Backup namespace по pass-id/transaction-id** (НЕ по commit_sha). `.canon-bak/<pass-id>/<path>` переживает повторный apply/rollback к ТОМУ ЖЕ target: два прохода к одному commit_sha не сталкиваются в общем бэкап-namespace.
- **Identity файла = (blob_sha, mode).** mode сверяется ВЕЗДЕ: классификатор (§3), keep-local инвалидация, WAL-recovery. Неверный `+x` при верных байтах = транзакция НЕ завершена (fail-closed), а не green.
- **Материализация блоба = `git cat-file blob <sha>`** (НЕ `<sha>:<path>` - это tree-ish синтаксис, требующий commit/tree-контекста). Байты берутся по чистому blob_sha из доверенного зеркала.
- **Терминальность recovery (T2).** Восстановление ВСЕГДА терминально: **roll-forward** (доиграть транзакцию до конца, ВКЛЮЧАЯ финальный atomic-rename state.json по scope записи) ИЛИ **roll-back** (полностью компенсировать по `backup_path`) - ДО любой смены `desired_release` или re-scan. **live-WAL (phase != committed-clear) БЛОКИРУЕТ смену `desired_release`:** пока незавершенная транзакция не доиграна/не откачена, `desired_release` не двигается. Формулировка "abort + re-scan как исход при АКТИВНОЙ транзакции" убрана - активная committed-транзакция замыкается терминальным recovery, а не оставляется как частичный post-image со старым state.
- **CAS возобновления (П6, после терминализации).** Когда live-WAL нет (транзакция уже терминальна), resume сверяет `desired_release` cursor'а с ожидаемым (expected-state): совпал -> продолжает проход; сдвинулся -> re-scan под новое намерение (не слепая перезапись). CAS применяется к УЖЕ терминальному состоянию, а не поверх активной транзакции.
- **Атомарность durable-полей reconciler (П4).** cursor/breaker-latch/budget-счетчик/pass-id пишутся `temp->fsync->rename`; reset budget на новый pass-id - атомарный; latch(release,ring) durable, снимается только ручным ack.

Каждый инвариант проверяется fault-тестом: kill процесса в точке (после fetch до fsync стейджа; после fsync стейджа до phase=committed; после committed до первого rename; между rename файлов; после файловых rename до rename state.json; в окне между RE-VERIFY и rename) - и recovery должен привести систему в консистентное состояние без потери/затирания данных.

## Дополнение 2026-07-17: fs_rel path-mapping (пост-GO фикс)

Обнаружено на первой боевой раскатке (api-service PR #1, закрыт): движок применял
канонические пути (дерево toolkit) в проект буквально - канон высыпался в корень
репо. Конвенция реальных проектов (канон под `.claude/`, `scripts/` в корне) жила
в LLM-промпте `/canon` и потерялась в rewrite; canon-sandbox повторял допущение
движка и потому дыру не ловил. Фикс (toolkit 57529bb): `fs_rel`/`fs_path` -
маппинг применяется только на ФС-границе (`read_local`, final rename, backup
snapshot/restore, recovery unlink, GC), идентичность (WAL-журнал,
state.file_hashes, membership, резолюции, lock) остается канонической.
canon-migrate чинится автоматически через общий `read_local`. Sandbox пересобран
под реальную раскладку. Урок: e2e-стенд обязан моделировать раскладку боевых
проектов, а не допущения движка.

## Связано

- [plan-2026-07-10-autonomous-agents.md](plan-2026-07-10-autonomous-agents.md) - мастер-план, этап 8 и граница с claude-toolkit.
- [design-2026-07-13-stage7b-harvester.md](design-2026-07-13-stage7b-harvester.md) - harvester, поставщик входа для (c); реальный формат upstream_pending (путь брифа + candidate-id) - основа П2.
- [design-2026-07-12-stage4-event-spool.md](design-2026-07-12-stage4-event-spool.md) - event-spool/reconciler, образец для детерминированного fleet-reconciler (c).
- [design-2026-07-11-agent-state-machine.md](design-2026-07-11-agent-state-machine.md) - модель агента (spec/control/reconciler).

Новых крупных развилок v5 не вводит (3 модельные правки T1-T3 - уточнения существующей модели, не новые развилки). Неизбежные на решение dwl: R4 (глубина rollout_record + ретеншн зеркала), R6 (tombstone-подавитель resolution_record), R13 (единица budget). Остальные §8 - параметры реализации, доказываемые контрактом §10, не развилки курса.
