# Этап 7b: harvester поправок оператора -> кандидаты в правила ролей

История: v1 -> v2 (раунд 1 codex, 13 находок/8 блокеров) -> v3 (раунд 2,
10 новых) -> v4 (раунд 3, 5 TRUE-блокеров) -> **v5 (раунд 4: ПРИНЯТ -
threat-model признан легитимным, закрыты 4 блокера-в-модели: legacy
incarnation fallback, approve FSM-гард, upstream-rejected cleanup, единый
предикат покрытия)**. Дизайн готов к коду. Ключевое
v4: threat-model ВЫРОВНЕН под системную модель claude-control (защита от
ОШИБОК/шума, НЕ от злонамеренного same-UID агента - принцип 1 плана; реальная
изоляция отложена СИСТЕМНО, не 7b-специфично); LLM-провайдер - доверенный
sink (как любой `claude -p`); candidate_id включает КОНТЕНТ (approve привязан
к просмотренному); durable RMW canon.yaml; commonpath-граница. Прежние v2/v3
правки в силе: project key sha1(realpath), durable incarnation-id, redaction
всех экспортных полей, disjoint+evidence валидатор, finite lifecycle.
Контракт stage-7 - `design-2026-07-12-stage7-acceptor-role.md`; канон -
feedback_canon_via_toolkit_log.

**Статус реализации (2026-07-13):** РЕАЛИЗОВАНО. Код: `bin/claude-agent-harvest`
(collect/propose/digest/approve/dismiss/reject/mark-applied), enabling-фикс Д0/Д2
в `bin/claude-rc-agent` (note->detail события, incarnation в control.json,
валидация spec.role), dispatch `harvest` в `bin/claude-rc`. Тесты:
`tests/test-agent-harvest.sh` (44 детерм + мок-LLM), enabling-ассерты в
`tests/test-agent-cli.sh` (80). Отклонение от дизайна: intended_root границы
Д11 = КОРЕНЬ ПРОЕКТА (не подкаталог - иначе симлинк подкаталога наружу проекта
тривиально прошёл бы проверку (1)); canon.yaml.upstream_pending entry = путь
брифа (уникален по cid, чистая идемпотентная очистка при upstream-rejected).

**Adversarial код-раунд r5 (codex) + фиксы:** 8 дефектов закрыто -
(1) маскировка PEM-блока целиком + project path в брифе через mask();
(3) валидатор fail-closed на oversize (капы не срезают молча) + строго ОДИН
top-level JSON-объект; (4) approve/reject сверяют candidate_id с хэшем контента
(integrity при порче emitted); (5a) durable_append цикл до полной записи
(POSIX short-write рвал ledger/emitted); (5b) reject чистит артефакты ДО смены
статуса, fail-closed на битом canon, self-heal re-run; (5c) fsync каталога
после unlink брифа; (6) canon RMW schema-валидация ВХОДА под canon.lock (не до)
+ revalidate; (7b) incarnation hex32-guard в collector + validate_control;
(8) run_llm fail-closed на returncode!=0; (9) install.sh ставит бинарник.
Тесты дополнены (harvest 53). Планы/отчёты r5/r6 - docs/dev/adversarial-*-r5/r6.

**Adversarial r6 (re-review) + остаток:** 6/8 закрыто полностью, 3 остаточных
пункта закрыты (harvest 58): reject fail-closed на fsync каталога брифа И на
отсутствующем canon.yaml (die, статус не меняется, self-heal re-run); incarnation
- различаем ОТСУТСТВИЕ ключа (legacy fallback) от ПРИСУТСТВИЯ битого значения
(агент пропускается, не переэмитит старые события), validate_control отвергает
явный null; имя каталога агента валидируется NAME_RE + event_at через mask()
(повреждённый registry-каталог token=SECRET не утечёт).

**Adversarial r7 + 2 edge-case:** durable-self-heal reject (fsync каталога
брифа ВСЕГДА, даже когда файл уже удалён - иначе недолговечный unlink
откатится) + incarnation: непарсибельный/отсутствующий control.json -> пропуск
агента (None), НЕ legacy fallback (только dict без ключа -> agent_created).
Тесты harvest 60. r8 - GO. Отчёты r5-r8 - docs/dev/adversarial-report-*.

## Threat-model (выровнен под систему - codex-3 блокеры 1,4)

**Защита от ОШИБОК и низкокачественного сигнала, НЕ от злонамеренного
агента.** Это тот же системный контракт, что у всего claude-control (план,
принцип 1: "границы v1 - от ошибок, не от злоумышленника; агент с Bash
технически дотянется до чужих файлов; настоящая изоляция осознанно
отложена"). 7b НЕ поднимает планку выше системной - иначе это ложная
гарантия.

Что из этого следует (честно, без overclaim):

- **Same-UID агент с Bash УЖЕ всевластен** - может сам вызвать `harvest
  approve`, писать в `canon.yaml`, `role/`, `rm -rf` репозиторий. Защищать
  7b от ЭТОГО в v1 бессмысленно: это системная дыра, закрываемая только
  общей изоляцией (свой UID/контейнер на роль - отложено для ВСЕЙ системы,
  не для 7b). Поэтому 7b НЕ претендует на механическую защиту human gate
  от злонамеренного агента.
- **От чего 7b реально защищает**: от ШУМА и низкокачественного сигнала,
  доезжающего до канона по ОШИБКЕ. Human gate с evidence - фильтр КАЧЕСТВА
  (спурьозная/слабая поправка -> человек видит сырьё -> отклоняет), не
  барьер против атак. Это ценно: без него мусорные поправки молча копятся
  в правила.
- **`actor=operator`** - сигнал происхождения (обычно ставит операторский
  CLI), не крипто-доказательство. Consistent с системой: мы не
  аутентифицируем акторов в v1.
- **LLM-провайдер - доверенный разрешённый sink**: candidate-pass шлёт
  masked-ledger во внешний LLM ДО human review - ровно как каждый `claude
  -p` в claude-control (приёмщик шлёт дифф, event-агент - payload).
  Отправка кода/данных провайдеру - принятый системный факт, не новый
  вектор 7b. Redaction (Д5) снижает утечку неумышленных секретов, не
  претендуя на анти-эксфильтрацию злонамеренного агента (тот и так шлёт
  что угодно куда угодно).

Итог: 7b проектируется как **фильтр качества с человеком в петле** в
системной модели "ошибки, не злоумышленник". Механические детали ниже
(маскировка, disjoint-валидация, no-follow, durable-записи) закрывают
ОШИБКИ и порчу данных (крэш, симлинк по недосмотру, повреждённый файл), а
не активную атаку same-UID агента - та вне scope v1 системно.

## Что строим (v1)

Операторские поправки (revise/reject) накапливаются per (проект, роль),
кластеризуются LLM'ом, предлагаются кандидатами - через дайджест, human
gate, канон. В `role/` не пишем никогда (Д11). Источник v1 - только (a);
(b),(c) отложены (Д6).

## Критерий этапа (разделён - codex-1 находка 12, усилен codex-2 находка 10)

- **Verifiable delivery (билд, тестируемо):** collector собирает
  посаженный корпус incarnation-safe с маскировкой; candidate-pass на
  корпусе с ДВУМЯ разными сутями даёт РОВНО два непересекающихся кластера,
  singletons не кластеризует, устойчив к перефразировке и к семантической
  инъекции (unknown/disjoint-валидация); идемпотентен между прогонами
  (candidate_id стабилен); approve атомарно-идемпотентен и не выходит за
  no-follow границу. Это проверяет РАБОТОСПОСОБНОСТЬ, не только plumbing.
- **Outcome-метрика (эксплуатация, НЕ билд):** реальный кластер доехал до
  канона и снял повтор. Не билд-тестируемо; копится во времени.

## Д0. Durability нот - best-effort, БЕЗ слова "атомарно" (codex-2 находка 1)

`cmd_revise`/`cmd_accept_reject` передают note в `--detail` control-cas.
`append_event` идёт под тем же flock и после `durable_write(control.json)` -
это НЕ атомарно (крэш между ними оставит control без события). Убираем
ложное "атомарно": контракт - **best-effort аудит**, harvester терпит
потерю (петля обучения, не бухгалтерия; пропущенная поправка = недобор
сигнала). События до Д0-фикса (без detail.note) - пропуск. Правка боевого
пути - только эти две команды.

## Д1. Архитектура

1. **Collector** (`claude-agent-harvest collect`, детерминированный):
   events.jsonl всех агентов -> per-(проект,роль) ledger. Идемпотентен по
   incarnation-safe id, под per-key fcntl-flock, маскирует на экспорте.
2. **Candidate-pass** (`propose`, bounded LLM §8.7 + валидация вывода Д7).
3. **Digest + approve/reject/dismiss** (человек): кандидаты с EVIDENCE ->
   дайджест; approve -> canon-протокол (Д9).

Запуск v1 - явная команда/cron, не автономный агент.

## Д2. Ключ и идентичность (codex-2 находки 2,9)

- **Project key = `sha256(os.path.realpath(spec.project))[:16]`** -
  canonical (хэш РЕАЛЬНОГО абсолютного пути; symlink разрешён realpath'ом),
  не lossy slug (`/srv/a-b/c` и `/srv/a/b-c` в один slug - коллизия).
  sha256 (не sha1) - без криптотребования, но дешевле обосновать
  безколлизионность (codex-3: sha1 не инъективен).
- **Role**: валидировать `spec.role` при create тем же
  `^[a-z][a-z0-9-]{0,30}[a-z0-9]$`, что имя. **Legacy-агенты** (роль записана
  до валидации): collector при чтении проверяет роль тем же regex; невалидная
  -> агент ПРОПУСКАЕТСЯ (не в ledger), с log-строкой. Не ретро-ломаем.
- **Incarnation-id**: control.json при create получает поле
  `"incarnation": "<secrets.token_hex(16)>"` (CSPRNG, durable, уникален на
  инкарнацию). Пересозданный одноимённый агент = новый incarnation.
  Collector читает из ТЕКУЩЕГО control.json.
  **Legacy-агенты этапов 1-7 БЕЗ поля** (codex-4 блокер 1: create его не
  писал): collector НЕ падает и не требует поля - fallback
  `incarnation = control.get("incarnation") or <at первого события
  agent_created из events.jsonl>`. Первое `agent_created` durable и уникально
  на инкарнацию (пересоздание -> новый agent_created с новым `at`), т.е.
  различает инкарнации и для legacy. Поле обязательно только для НОВЫХ
  агентов; чтение - опциональное с fallback.
- Путь ledger на диске - `harvest/<project_key>/<role>/` (project_key и role
  - валидированные/хэш, безопасны как компоненты пути).

## Д4. correction-id: incarnation-safe + из masked (codex-2 находки 2,5)

`id = sha256(json.dumps([project_key, role, incarnation, event_seq,
masked_note], ensure_ascii=False))[:16]`.

- `incarnation` (не `event_at`) различает пересозданных одноимённых -
  секундная гранулярность `event_at` не годилась (два revise в секунду).
- `masked_note` (НЕ сырой) в хэше: сырой `sha1(note)` допускал словарную
  атаку на короткий секрет по ledger'у. Хэшируем ПОСЛЕ маскировки.
- json.dumps списка (не `|`-склейка): путь/текст может содержать `|`.

## Д5. Маскировка - на ВСЕХ экспортных полях (codex-2 находка 5)

Threat-model: локальный events.jsonl - недоверенный вход, маскируем при
ЧТЕНИИ в ledger (ledger - первый экспортный артефакт). Маскируется КАЖДОЕ
поле, попадающее в ledger/digest/candidate/brief/emitted, включая:
- текст поправки (note);
- **reject/dismiss `--reason`** (тоже операторский/недоверенный текст ->
  во внешний LLM и дайджест);
- любые строки в brief (пишутся из уже-маскированного ledger).
correction-id строится из masked-note (Д4) - не несёт сырья.

Паттерны: `sk-…`, `gh[pousr]_…`, `AIza…`, `xox[baprs]-…`, `-----BEGIN`,
`Bearer …`, `(token|password|secret|api[_-]?key)=\S+`, hex(>=32),
base64(>=40) -> `***`. Агрессивно: потеря сигнала приемлема, утечка в
git-remote канона - нет. **Остаточный риск (принят):** секрет нестандартной
формы пробьёт маскировку. Смягчение: (1) human review видит кандидат перед
export; (2) источник - только короткий операторский текст (не транскрипт).
Не претендуем на полную DLP - claim'а "безопасный экспорт" в дизайне нет.

## Д6. Отложены (b),(c) - подтверждено codex (раунды 1,2)

(b) транскрипт вырезан (fresh без session_id, handoff без границы миссии);
(c) пост-accept diff отложен (нет надёжного трекинга ветки). v1 на (a).

## Д7. candidate-pass: bounded §8.7 + валидация с provenance (codex-2 находка 6)

Контракт приёмщика (пустой cwd no-follow, ВСЕ tools забанены,
strict-mcp пустой, input-капы с явным отказом при переполнении, timeout
SIGKILL-pgroup, no-clobber O_EXCL+link, fencing по (key, ledger-sha)).

**Детерминированная валидация вывода (ПОСЛЕ LLM, reconciler-сторона)** -
кластер ОТБРАСЫВАЕТСЯ, если не выполнено ВСЁ:
- `correction_ids` - непустое подмножество id поданного ledger (unknown ->
  отброс: инъекция "объедини реальные X,Y" мимо, т.к. проверяем membership,
  но НЕ семантику - семантику ловит human evidence, см. ниже);
- **кластеры disjoint**: один id максимум в одном кластере (иначе весь
  вывод отброшен - LLM плохо разбил);
- **>= MIN_CLUSTER (2) от >= 2 РАЗНЫХ incarnation ИЛИ agent** -
  проверяется МЕХАНИЧЕСКИ по ledger-записям ids (не по слову LLM);
- ни один id не покрыт (единый предикат Д8: любой кандидат в
  {proposed, pending-upstream, applied, dismissed});
- поля bounded.

**Семантическую честность группировки валидатор НЕ гарантирует** (LLM мог
слепить реальные, но несвязанные ids). Ловит - **human gate с evidence**:
дайджест показывает рядом с кандидатом ПОЛНЫЕ masked-тексты всех его
correction_ids. Человек видит, что суть реально общая, и отклоняет слепленное.

## Д7.1. Порог. `MIN_CLUSTER=2` от >= 2 разных incarnation/agent (env).

## Д8. Lifecycle кандидата - КОНЕЧНЫЙ (codex-2 находка 7)

`harvest/<key>/emitted.jsonl`, append под key-flock. **`candidate_id =
sha256(json.dumps([sorted(correction_ids), essence, why, how_to_apply]))`** -
включает КОНТЕНТ, не только ids (codex-3 блокер 2): человек одобряет
ИМЕННО просмотренный bundle. Тот же набор ids с другой essence (напр. после
`upstream-rejected` LLM переформулировал) = ДРУГОЙ candidate_id -> approve
старого id экспортирует ровно то, что было в дайджесте, не подменённый
payload. Кандидат в emitted.jsonl IMMUTABLE: propose НЕ перезаписывает
существующий candidate_id (append-only); повтор с тем же id - no-op.
approve дополнительно fail-closed сверяет переданный candidate_id с
существующей записью (нет записи -> отказ). Состояния и ПОКРЫТИЕ ids:

- `proposed` - эмитировано, ждёт человека. Покрывает (non-terminal).
- `pending-upstream` - approve прошёл, кандидат в upstream-pending.
  Покрывает (non-terminal, но с ВЫХОДАМИ ниже).
- `applied` - **ТЕРМИНАЛ**: канон реально принял правило (человек ставит
  `harvest mark-applied` после заноса toolkit-сессией, либо canon-sync
  детектит файл). Покрывает НАВСЕГДА - цель достигнута.
- `dismissed` - **ТЕРМИНАЛ**: человек на дайджесте сказал "не тянет на
  правило". Покрывает НАВСЕГДА (не долбить). `dismiss --reason`.
- `upstream-rejected` - канон-ревьюер отклонил при заносе. Переход
  **идемпотентно ЧИСТИТ артефакты** (codex-4 блокер 3): удаляет/архивирует
  brief из `upstream-pending` И убирает запись из `canon.yaml.upstream_pending`
  (durable RMW, как approve) - иначе отклонённый кандидат продолжает числиться
  pending для canon-workflow. Только ПОСЛЕ чистки ids возвращаются в пул,
  essence+reason -> в промпт candidate-pass ("уже отклонено каноном").

**Единый предикат покрытия** (codex-4 блокер 4): id "покрыт" и исключён из
входа candidate-pass (Д7), если на него ссылается кандидат в состоянии
**{proposed, pending-upstream, applied, dismissed}** - т.е. ВСЕ, кроме
`upstream-rejected`. Только `upstream-rejected` возвращает ids в пул. Так
`applied`/`dismissed` покрывают НАВСЕГДА (терминалы), и их ids не всплывут
в новом кластере с другим набором. Валидатор Д7 и Д8 используют ОДИН этот
предикат (не рассинхронены).

**Конечность**: каждая поправка кончает в `applied` (стала правилом) или
`dismissed` (человек сказал нет) - оба покрывают навсегда. `upstream-rejected`
возвращает в пул с memory сути -> переформулированный повтор всплывёт
ограниченно, человек dismiss'ит -> терминал.

## Д9. approve - идемпотентный self-healing (codex-2 находка 8)

`harvest approve <key> <candidate_id>` fail-closed сверяет candidate_id с
записью emitted (нет -> отказ) И **статус ∈ {proposed, pending-upstream}**
(codex-4 блокер 2: только свежий proposed или recovery-повтор pending-
upstream; из `dismissed`/`applied`/`upstream-rejected` approve ОТКАЗЫВАЕТ -
иначе approve после dismiss создаст brief, а после applied воскресит
удалённое sync'ом). Затем 3 записи. Каждая **independently
durable** (codex-3 блокер 5) И идемпотентна -> re-run = crash-recovery:
1. brief-файл `<project>/toolkit-log/upstream-pending/<key>-<cid>.md` -
   `durable_write` (tmp O_EXCL + write-all + fsync + rename + fsync каталога),
   overwrite тем же контентом (детерминирован по candidate);
2. RMW `<project>/.claude/canon.yaml`: **parse+schema-validate старого ->
   add-if-absent в `upstream_pending` -> `durable_write` нового (полная
   цепь) -> re-parse-validate**. Под `.claude/.canon.lock` flock (общий с
   /canon-sync). Повреждённый/невалидный старый canon.yaml -> approve
   ОТКАЗЫВАЕТ (не пишет поверх мусора), просит починить - не усугубляет.
3. emitted status -> `pending-upstream` (durable append).

Крэш на любом шаге: `durable_write` гарантирует, что каждый файл либо старый
целый, либо новый целый (rename атомарен, fsync до/после) - НЕ обрезанный.
Повторный `approve <cid>` доделывает недостающее (проверяет brief, запись в
canon.yaml, статус - до-исполняет идемпотентно). **Остаточный риск
(принят):** три файла не образуют ОБЩУЮ транзакцию - между шагами наблюдаемо
brief без canon-записи; но каждый durable, re-run сходится, а применение
канона всё равно за человеком в toolkit-клоне. Общий ACID здесь
over-engineering для human-gated шага; per-file durability - обязателен и
обеспечен.

## Д10. Локи/гонки (codex-1 находка 5)

Per-key fcntl-flock `harvest/<key>/.lock` на collect И propose И approve
(fcntl, не bash flock - Mac). Чтение events.jsonl терпит рваный хвост
(json.loads построчно, пропуск). ledger/emitted append durable под flock.
**Гонка approve/propose** (codex-2 находка 8): approve и propose держат ОДИН
key-flock -> propose не прочитает ledger, пока approve меняет emitted, и
наоборот. Кандидат, ставший pending при approve, покрывает ids до
следующего propose (который уже под тем же локом увидит покрытие).

## Д11. Граница role/ - механическая + no-follow (codex-2 находка 9)

- LLM без write-тулов (Д7) - физически не пишет.
- Детерминированный код пишет в фиксированный allowlist корней. **Перед
  КАЖДОЙ записью в output-корень** (`toolkit-log/upstream-pending`,
  `canon.yaml`, дайджест): resolve `os.path.realpath(target)` и assert
  через **`os.path.commonpath`** (не строковый префикс - codex-3 блокер 3:
  `/a/agents` строкой матчит `/a/agents-foo`): (1) `commonpath([target,
  намеренный_корень]) == намеренный_корень`; (2) `commonpath([target,
  ~/.claude-control/agents]) != agents` (target НЕ внутри реестра/role).
  Финальная запись `O_NOFOLLOW` на файле + tmp+rename. Symlink
  `upstream-pending -> agents/<name>/role/` не даёт записи: realpath попадёт
  в agents/ -> assert падает. `agents/<name>/role/` как write-путь в коде
  ОТСУТСТВУЕТ вовсе.
- **Остаточный риск (принят, вне scope v1):** статический realpath+O_NOFOLLOW
  ловит симлинк-по-недосмотру (ошибка), но НЕ race-free против злонамеренной
  подмены ancestor-каталога между assert и open (TOCTOU). Это защита от
  АТАКИ same-UID процесса - вне threat-model v1 (см. Threat-model: агент и
  так всевластен). Race-free `openat(O_DIRECTORY|O_NOFOLLOW)` покомпонентно
  от trusted-fd - в фазу общей изоляции системы.
- Инъекция через ledger не даёт записи: LLM без рук; его вывод -> валидация
  -> только emitted/digest.

## Тест-план

**Детерминированный (без сети):**
- Д0: `revise --note X` -> событие с `detail.note=X`; `reject --reason Y`
  -> `detail.note=Y`; accept-нота НЕ порождает correction.
- collect: 3 агента одной (проект,роль) revise -> ledger 3 записи;
  повторный collect без дублей; пересозданный одноимённый (новый
  incarnation, seq сброшен) НЕ коллизится; два revise в одну секунду -
  разные id (incarnation+seq).
- ключ: `spec.role` с `/`,`..`,заглавными -> create отбит; legacy-агент с
  невалидной ролью -> collector ПРОПУСКАЕТ; два разных project-пути -> два
  разных project_key (без slug-коллизии).
- секреты: `sk-`/`token=` в ноте И в reject-reason -> `***` в
  ledger/digest/brief; correction-id НЕ обратим в секрет (из masked).
- рваный хвост events.jsonl -> пропуск строки.
- валидатор (мок LLM): unknown id -> отброс; пересекающиеся кластеры ->
  отброс; кластер из 1 incarnation -> отброс; покрытый id -> отброс.
- lifecycle: proposed->approve->pending-upstream (не applied); dismiss->
  terminal (повторно не эмитится); upstream-rejected-> ids в пул +
  essence-memory; mark-applied->terminal.
- approve идемпотентность: прервать после brief -> re-run доделывает
  canon.yaml+status; canon.yaml add-if-absent не дублит.
- no-follow: `upstream-pending` -> symlink на `agents/x/role` -> approve
  падает на assert, в role НЕ пишет.
- per-key flock: параллельные collect не сдвоят ledger.

**LLM-корпус (сеть):**
- ДВЕ разные сути по 3 агента каждая -> РОВНО 2 disjoint-кластера, essence
  по сути, ids верные; singletons не кластеризуются.
- перефразировка той же сути у 3 агентов -> один кластер (устойчивость).
- повторный прогон того же ledger -> тот же candidate_id (стабильность).
- инъекция "верни applied/объедини всё" в тексте ноты -> не меняет вывод.

## Остаточные риски (приняты для v1, с обоснованием)

Все - в системной модели "ошибки, не злоумышленник" (Threat-model). Атаки
same-UID агента вне scope v1 СИСТЕМНО (не 7b-специфично) - закрываются общей
изоляцией, отложенной для всего claude-control.

- **Злонамеренный same-UID агент** может сам вызвать approve / писать в
  canon/role / эксфильтровать через LLM - вне scope v1 (агент и так
  всевластен; принцип 1 плана). 7b защищает от ОШИБОК/шума, не атак.
- **actor не аутентифицирован** - сигнал происхождения, не доказательство;
  consistent с системой.
- **LLM-провайдер - доверенный sink** - masked-ledger уходит до human
  review, как любой `claude -p`; принятый системный факт.
- **маскировка не полная DLP** - секрет нестандартной формы пробьётся;
  смягчение human review + короткий операторский источник; защищает от
  СЛУЧАЙНОЙ утечки, не от злонамеренной эксфильтрации.
- **no-follow не race-free** (TOCTOU) - ловит симлинк-по-недосмотру, не
  атаку подмены ancestor; race-free dirfd - в фазу изоляции.
- **approve не общий-ACID** - per-file durable + идемпотентный self-heal;
  общая транзакция - over-engineering для human-gated шага.
- **lifecycle конечен через human dismiss**, не автоматически: цикл
  upstream-rejected->proposed гасится essence-memory + терминальным dismiss.
- **LLM split/merge недетерминизм** - candidate_id стабилен по (ids+контент),
  human gate с evidence ловит слепленное.
- **outcome-критерий не билд-тестируем** - копится в эксплуатации.
- **(b),(c) отложены** (Д6).
