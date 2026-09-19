# CANON - fleet-reconciler канона и обратный поток кандидатов

Домен покрывает раскатку правил/скиллов/агентов из claude-toolkit по парку
git-проектов (`bin/claude-agent-canon-maintainer`), реестр раскатанного per
проект, и обратный поток: сбор кандидатов в канон из операторских правок
(`bin/claude-agent-harvest`) и ролевая приемка артефактов в независимом
контексте (acceptor).

## Границы

**Входит:** fleet.yaml-инвентарь, детерминированная дельта поверх
release-descriptor (canon.lock.json), транзакционный WAL-apply, per-project
FSM и durable-cursor, rollout rings + circuit breaker, PR-раскатка и
post-merge подтверждение applied, harvester (collect/propose/digest/approve/
reject/dismiss/mark-applied), acceptor (deterministic/role-review/both).

**Не входит:**

- живучесть самого процесса reconciler'а (systemd-юниты, сторожа, спул
  событий) - `RECON/reconciler.md`;
- контур задач агента (FSM задачи, пояса прав, worktree) - `TASK/tasks.md`,
  даже там, где acceptor использует тот же приемочный механизм, что и задачи;
- телеграм-уведомления как канал доставки алертов (сам факт "дайджест ушел
  в TG") - механика бота в `BOT/tgbot.md`, здесь только факт, что канон
  шлет алерт через тот же хук;
- доставка находок текущей рабочей сессии в канон через
  `~/.claude/canon-inbox/` (скилл `harvest-canon`, скрипт `canon-brief.py`) -
  это процесс работы НАД claude-control как проектом-потребителем канона, а
  не функциональность самого claude-control; в этом репозитории скрипта нет.

## Инварианты

- **INV-CANON-01.** Identity ревизии канона - git commit_sha annotated-тега
  `canon-vN`, а не встроенное поле файла и не `manifest_digest`. Digest -
  fast-path оптимизация; при равном digest, но разном commit_sha metadata
  все равно обновляется. Довод: самоссылочный identity внутри файла ломает
  сравнение "что применено", а digest без commit_sha скрывает не меняющие
  состав правки (переименование внутри той же ревизии).
- **INV-CANON-02.** `canon.intent.yaml` (человек), `canon.state.json`
  (единственный писатель - дельта, machine-поля atomic-rename), ledger
  harvester'а (владелец - harvester) - три файла, три разных владельца;
  дельта не пишет intent, harvester не пишет state. Довод: без разделения
  ownership переход candidate->pin не имеет легального писателя и
  превращается в гонку между человеком и скриптом.
- **INV-CANON-03.** Классификатор путей идет по UNION(type-set дескриптора,
  путей `state.file_hashes`), не только по новому дескриптору. Путь,
  исчезнувший из канона глобально, эскалируется человеку
  (`removed-upstream`), а не удаляется молча. Довод: классификация только по
  новому дескриптору осиротила бы `file_hashes` и потеряла бы сигнал об
  удалении.
- **INV-CANON-04.** Путь, выпавший из применимого type-set проекта из-за
  смены `membership`/`project_type` при живом дескрипторе, получает класс
  `retired-from-scope`: снимается из `state.file_hashes` durable-записью, но
  файл на диске не трогается и релиз не блокируется. Путь, исключенный
  намеренно (`overrides`/`skip_sync`/`local_only`), получает
  `managed-but-excluded` и остается под учетом. Довод: смешение "канон
  больше не предлагает путь для этого типа" и "человек намеренно исключил
  путь" привело бы либо к порче намеренных исключений, либо к тихой потере
  учета мигрировавших путей.
- **INV-CANON-05.** Apply идет транзакционно: WAL по фиксированному пути
  `.canon-journal.json`, стадирование в `.canon-stage/<pass-id>/`,
  versioned pre-image в `.canon-bak/<pass-id>/`, commit только через atomic
  rename, recovery терминален (roll-forward до конца или roll-back по
  backup) до любой смены `desired_release`. Довод: частично примененный
  канон, оставленный "как есть" при крэше, оставляет проект в
  неопределенном состоянии, из которого нет детерминированного выхода.
- **INV-CANON-06.** Перед каждым rename - re-verify `on-disk == base_sha`
  под project-flock (CAS), включая при committed-recovery. Довод: без
  повторной проверки в момент rename окно между чтением локального файла и
  записью - открытая гонка с ручной правкой человека или Obsidian-клиентом.
- **INV-CANON-07.** `applied_release` продвигается только когда все пути
  релиза классифицированы как не-conflict (гейт release-wide); per-path
  accept-upstream двигает только `file_hashes[path]` конкретного пути и
  decision-record. Довод: иначе один принятый конфликт продвинул бы
  identity релиза при остальных нерешенных путях, и rollback-история
  стала бы грязной.
- **INV-CANON-08.** Полный transport канона (мастер-зеркало и материализация
  прошлых дескрипторов для отката) идет только доверенным git-транспортом
  (SSH-зеркало полным клоном); CDN (jsDelivr) допустим только для отдельных
  блобов по уже проверенному `blob_sha`, никогда для самого lock-файла.
  Довод: lock, полученный не-git транспортом, не имеет доказуемой цепочки
  происхождения - подмена дескриптора равносильна подмене канона целиком.
- **INV-CANON-09.** Fleet-проход берет один и тот же singleton-flock по
  фиксированному пути независимо от триггера (таймер или маркер от
  harvester). Durable-состояние прохода (cursor, breaker-latch,
  budget-счетчик) живет в файлах под spool-каталогом, не только в памяти.
  Довод: два триггера с разными локами разъезжаются на параллельные
  проходы того же парка; in-memory состояние теряется при крэше без следа.
- **INV-CANON-10.** Circuit breaker - latch на пару `(release, ring)`,
  снимается только ручным `ack`; следующий проход его не сбрасывает.
  Порог срабатывания - первый `smoke-fail` или `apply-error` на кольце
  (fail-fast). Довод: автосброс latch превращает защелку в отчет "мы вчера
  падали", а не в реальный стоп раскатки на неисправном релизе.
- **INV-CANON-11.** `applied` для policy `branch` фиксируется только по
  фактическому присутствию байт правила в post-merge дереве основной
  ветки, а не по событию merge PR. Расхождение (merge дал дерево, не
  совпадающее с candidate) - `held`/эскалация, не `applied`. Довод:
  ручное разрешение конфликтов при мерже может дать дерево, отличное от
  засмоканного кандидата; `applied` терминален и необратим, поэтому ложное
  закрытие непоправимо.
- **INV-CANON-12.** Проект под fleet-управлением не обслуживается
  одновременно standalone `/canon`. Довод: два независимых писателя
  `desired_release`/state одного проекта устраивают гонку stale-desired
  между ручным прогоном и ревайлером.
- **INV-CANON-13.** Harvester кладет в `upstream_pending` путь брифа и
  candidate-id (не текст правки, не blob-SHA); завершение записи (переход
  в терминал) идет только через явный хук `mark-applied` по candidate-id,
  вызываемый по присутствию правила в post-merge дереве, а не по событию
  merge и не по авто-переходу. Довод: у реального `bin/claude-agent-harvest`
  нет durable mapping candidate-id -> целевой путь на момент создания брифа,
  авто-переход при таком контракте недостижим честно.
- **INV-CANON-14.** Кандидат в `emitted.jsonl` неизменяем после первой
  записи (append-only, `candidate_id` включает контент кластера, не только
  список id). `approve` сверяет переданный `candidate_id` с записью и
  отказывает при расхождении. Довод: человек одобряет ровно тот bundle,
  что видел в дайджесте; изменение сути под тем же id подменило бы то, что
  было одобрено.
- **INV-CANON-15.** Кластер кандидатов проходит валидацию: id -
  непустое подмножество поданного ledger; кластеры дизъюнктны (один id
  максимум в одном кластере); минимум 2 correction от минимум 2 разных
  incarnation/агентов; ни один id уже не покрыт активным кандидатом. Любое
  нарушение отбрасывает весь вывод LLM. Довод: LLM без этих проверок может
  склеить несвязанные события в один "кластер" или сослаться на
  несуществующий id - механическая валидация ловит это без доверия к
  содержанию ответа.
- **INV-CANON-16.** Id "покрыт" (исключен из входа следующего candidate-pass)
  для состояний `{proposed, pending-upstream, applied, dismissed}`; только
  `upstream-rejected` возвращает id в пул. `applied` и `dismissed` -
  терминальные состояния и покрывают навсегда. Довод: без единого предиката
  покрытия один и тот же id мог бы попасть в два конкурирующих кандидата
  или бесконечно предлагаться заново после явного отказа человека.
- **INV-CANON-17.** LLM-приемщик (acceptor) не получает рабочее дерево
  проекта - только текст диффа в промпте, из пустого приватного cwd, без
  единого write/read-инструмента (`--disallowedTools` включает файловые и
  сетевые тулы, `--strict-mcp-config` пуст). Довод: рабочее дерево - канал
  подхвата чужого `CLAUDE.md`/hooks/настроек и утечки за пределы диффа;
  инструменты дают приемщику возможность действовать, а не только судить.
- **INV-CANON-18.** Вердикт `accepted` ставится автоматически только при
  `auto_accept: true`; по умолчанию положительный вердикт приемщика уходит
  в `needs-human`. `rejected` ставит только оператор командой `reject` -
  LLM-приемщик такой статус не проставляет никогда. Довод: асимметрия
  цены ошибки - ложный автоматический reject убивает годную работу
  необратимо (по контракту terminal-статусов), ложный auto-accept без
  опта был бы тихим ослаблением human gate.

## Внешние контракты

- **Читает:** `canon.lock.json` (release-descriptor) с тега `canon-vN` в
  репозитории claude-toolkit; `~/.claude-control/canon/fleet.yaml`
  (инвентарь проектов: `repo_url`/`path`, `policy`, `ring`, `smoke_cmd`,
  `target_cmd`); per-project `canon.intent.yaml`, `canon.state.json`;
  env-файл `~/.config/claude-control/env`
  (`CLAUDE_CANON_REPO_URL`, `CLAUDE_CANON_DELTA`, `GH_TOKEN`,
  `CLAUDE_AGENT_ALERT_CMD`, опционально `CLAUDE_CANON_SMOKE_CMD`,
  `CLAUDE_CANON_BUDGET`, `CLAUDE_CANON_SMOKE_TIMEOUT`, `CLAUDE_CANON_LOCK`,
  `CLAUDE_CANON_LOCK_WAIT`).
- **Пишет:** candidate-ветку `canon/<vN>` и PR в fleet-репозиториях (через
  `gh`); `canon.state.json` per проект (atomic-rename); durable
  cursor/latch/budget-файлы под `~/.claude-control/canon/`; дайджест прохода
  `~/.claude-control/canon/digest/<pass>.md`; алерт через
  `CLAUDE_AGENT_ALERT_CMD` (обычно `claude-agent-tgbot notify`) при
  не-нейтральном вердикте и смене картины.
- **Harvester читает/пишет:** `events.jsonl` агентов (вход, недоверенный);
  `harvest/<project_key>/<role>/ledger.jsonl`, `emitted.jsonl` (per-key
  fcntl-flock); брифы в `<project>/toolkit-log/upstream-pending/<key>-<cid>.md`;
  `<project>/.claude/canon.yaml` (RMW под `.claude/.canon.lock`, add-if-absent
  в `upstream_pending`).
- **systemd:** `claude-agent-canon-maintainer.timer` (12ч + до 1ч jitter,
  `OnActiveSec=15min` после enable, `Persistent=false` - пропуски не
  наверстываются, следующий тик покрывает); harvester запускается явной
  командой/cron, не автономным агентом.
- **CLI:** `claude-agent-canon-maintainer {once,status,arm,disarm,ack,
  mirror,recover,cid-map,mark-applied-scan,rollback}`;
  `claude-agent-harvest {collect,propose,digest,approve,reject,dismiss,
  mark-applied,pending,list}`.

## Решения

- **2026-07-14.** Maintenance - детерминированный fleet-reconciler, не живая
  LLM-миссия; LLM зовется on-demand только на разрешение конфликта
  человеком (design-2026-07-14-stage8-canon-sync.md, §0).
  Граница (b)/(c): PR-упаковка, интерпретация pending и сборка release -
  в toolkit CLI; claude-control - только schedule/inventory/budgets/
  уведомления/запуск.
- **2026-07-13.** Threat-model harvester'а выровнена под системную модель
  claude-control: защита от ошибок и шума, не от злонамеренного same-UID
  агента (design-2026-07-13-stage7b-harvester.md, "Threat-model"). Реальная
  изоляция отложена системно, не per-домену.
- **2026-07-12 (v5).** Acceptor: авто-accept строго опт-ин (`auto_accept`),
  для обоих режимов `role-review` и `both`; reject LLM-приемщика никогда не
  терминален (design-2026-07-12-stage7-acceptor-role.md, §8.6).
- **2026-07-18.** Роль acceptor rev >= 2 несет два механических гейта в
  парсере вердикта: quote-gate (reject без цитаты из диффа демотируется в
  uncertain) и zero-findings (accept без непустого `checks` демотируется в
  uncertain). Старые снапшоты роли (`role_rev < 2`) сохраняют прежнюю
  семантику.
- **v1, отложено (design-2026-07-14-stage8-canon-sync.md, §7).**
  Marketplace-плагин целиком; личный форк как release producer; полный
  rollback-DAG по всей цепочке ревизий (только на одну ревизию назад,
  `rollout_record` bound=3); автоматический ack/snooze-UI конфликтов.

## Известные дыры

- Marketplace-плагин, форк-как-producer и полный rollback-DAG сознательно
  не реализованы в v1 (design §7) - это не расхождение с замыслом, а
  явно отложенная область; фиксирую здесь, чтобы не путать с недосмотром.
- Не-git vault (Obsidian) никогда не мутируется fleet-реконсилером
  (policy принудительно `observe`) - для таких целей WAL/branch/smoke не
  применимы вовсе; ручной standalone `/canon` - единственный путь
  изменения. Разрыв между "канон для git-проектов" и "канон для vault"
  держится по конструкции, не как долг.
- Redaction секретов в harvester (Д5) не претендует на полный DLP: секрет
  нестандартной формы (не подпадающий под известные паттерны) пройдет
  маскировку и попадет во внешний LLM и в дайджест. Принятый остаточный
  риск design-2026-07-13-stage7b-harvester.md, смягчение - только human
  review перед экспортом.
- `approve` harvester'а не образует общую ACID-транзакцию между тремя
  файлами (brief, `canon.yaml`, статус emitted) - каждый durable по
  отдельности, но между шагами возможно наблюдаемое промежуточное
  состояние "brief есть, записи в canon.yaml еще нет". Принято как
  разумный размен для human-gated шага (design, Д9).
- Acceptor: собственный приватный cwd защищен `lstat` + отказом на
  symlink, но не race-free против TOCTOU-подмены ancestor-каталога тем же
  UID между `mkdir` и стартом процесса - вне threat-model v1
  (design-2026-07-12-stage7-acceptor-role.md, "Остаточные риски").
- Тесты домена (`tests/test-agent-canon-maintainer.sh`,
  `tests/test-agent-harvest.sh`, `tests/test-agent-harvest-corpus.sh`)
  существуют и структурно покрывают большинство инвариантов выше (T01-T10
  у maintainer, секции collector/validator/lifecycle у harvest), но ни один
  не несет тег `INV-CANON-NN` в комментарии или тексте `fail` - формальная
  трассируемость по схеме `requirements-traceability.md` для этого домена
  еще не проведена.

## Трассируемость

Схема тегов `INV-CANON-NN` в тестах на момент написания спеки не введена
(домен получил доменную спеку раньше, чем прошел разметку тестов). Для
каждого инварианта - фактическое покрытие без формального тега:

| Инвариант | Покрытие |
|---|---|
| INV-CANON-01 identity=commit_sha | нет тега; косвенно `tests/test-agent-canon-maintainer.sh` T02/T05 |
| INV-CANON-02 три владельца state/intent/ledger | нет тега; нет отдельного теста |
| INV-CANON-03 UNION-классификатор, removed-upstream | нет тега; нет отдельного теста в этом репозитории (логика в toolkit canon-delta.py) |
| INV-CANON-04 retired-from-scope / managed-but-excluded | нет тега; нет теста в этом репозитории |
| INV-CANON-05 WAL/recovery терминален | нет тега; `cmd_recover`/T-серии в test-agent-canon-maintainer.sh косвенно |
| INV-CANON-06 CAS re-verify перед rename | нет тега; логика в toolkit, не в этом репозитории |
| INV-CANON-07 release-wide гейт applied_release | нет тега; нет теста в этом репозитории |
| INV-CANON-08 транспорт только git, CDN только блобы | нет тега; T03 (host-side зеркало) косвенно |
| INV-CANON-09 singleton-flock + durable-состояние | нет тега; T08 (observe-first + kill switch) косвенно |
| INV-CANON-10 circuit breaker latch(release,ring) | нет тега; `set_latch`/`clear_latch`/`ack` без выделенного теста |
| INV-CANON-11 applied по post-merge дереву | нет тега; `held-post-merge-mismatch` косвенно в коде, без явного теста |
| INV-CANON-12 fleet-managed исключает standalone | нет тега; нет теста в этом репозитории |
| INV-CANON-13 upstream_pending = путь+candidate-id, mark-applied | нет тега; `cmd_mark_applied` в test-agent-harvest.sh секция lifecycle |
| INV-CANON-14 candidate_id включает контент, immutable | нет тега; секция lifecycle в test-agent-harvest.sh |
| INV-CANON-15 валидация кластера (disjoint, >=2 incarnation, membership) | нет тега; секция "валидатор (мок)" в test-agent-harvest.sh |
| INV-CANON-16 единый предикат покрытия | нет тега; секции dismiss/upstream-rejected в test-agent-harvest.sh |
| INV-CANON-17 acceptor без рук, diff-only | нет тега; fault-suite S20-S27 (design упоминает, файлы вне зоны поиска этой спеки) |
| INV-CANON-18 auto_accept опт-ин, reject не терминален | нет тега; test-agent-harvest-corpus.sh (confusion matrix) косвенно |

## Вопросы к пользователю

1. Формально размечать тесты тегами `INV-CANON-NN` сейчас отдельной задачей
   или откладывать до первого аудита домена (`codex-audit adversarial`),
   который и найдет расхождения, требующие новых тестов?
2. `retired-from-scope`/`removed-upstream`/CAS-классификатор живут в
   `canon-delta.py` (репозиторий claude-toolkit), а не в этом репозитории -
   считать ли их частью домена CANON здесь (спека описывает контракт,
   которому доверяет claude-control) или это чужой домен, и здесь достаточно
   ссылки?
3. `rollout_record` bound=3 и глубина ретеншна зеркала (R4 design) - решение
   оператора отложено в design. Зафиксировать сейчас конкретное число как
   инвариант или оставить параметром `fleet.yaml`/env без дефолтного
   значения в спеке?
4. Нужен ли отдельный инвариант на env-переменную `CLAUDE_CANON_LOCK`
   (абсолютный путь обязателен для cron/ssh без XDG) - или это деталь
   эксплуатации, достаточно runbook'а?
5. Acceptor (design этап 7) физически не входит в `bin/claude-agent-harvest`
   и не найден отдельным бинарем при поверхностном осмотре (`claude-agent-review`
   упоминается в design, но не проверялся построчно) - подтвердить, что
   `bin/claude-agent-review` существует и актуален, или это тоже
   отложенная/устаревшая часть design?
6. Снапшот роли acceptor (`role_rev`) - есть ли способ узнать текущий
   `role_rev` в проде одной командой, чтобы включить это в runbook, или
   решение о ревизии роли принимается вручную при каждом обновлении промпта?
7. `harvest mark-applied` вызывается вручную человеком либо
   `canon-sync`-детектом (design формулирует "либо-либо") - для этого
   домена зафиксировать как два равноправных пути, или один из них
   фактически не реализован и должен уйти в "известные дыры"?
8. MIN_CLUSTER=2 и порог `count_accept >= R-1` (corpus) - считать
   инвариантами домена (INV-CANON-NN) или параметрами калибровки, не
   заслуживающими отдельного номера?
