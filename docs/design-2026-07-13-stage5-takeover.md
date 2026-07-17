# Этап 5: кросс-машинный handoff Mac -> VM (fresh brief-seeded)

Дизайн-дельта к §9 state machine ([design-2026-07-11-agent-state-machine.md](design-2026-07-11-agent-state-machine.md)).
Спайк этапа 5 - GO ([dev/spike-2026-07-12-stage5-takeover.md](dev/spike-2026-07-12-stage5-takeover.md)).

## История решения (почему НЕ перенос транскрипта)

- **v1** (push-протокол с release-маркером) - codex-adversarial: 10 блокеров.
- **v2** (fence-by-MOVE + nonce + sid-registry + commit-binding) - codex r2 вскрыл
  **фундаментальный предел**: единственный писатель сессии `<sid>` между двумя
  машинами кооперативными ФС-операциями НЕ гарантируется. `rename()` не резервирует
  pathname (живой fd переживает MOVE; процесс пересоздаёт `<sid>.jsonl`); sha
  связывает снимок, но не quiescence. Same-machine §9 спасался тем, что это одна
  машина (physical unlink под контролем `/proc`).
- **Решение dwl (2026-07-13): fresh/brief-seeded.** Транскрипт НЕ переносим. VM
  стартует СВЕЖУЮ mission-сессию (новый session_id) от запушенного git-состояния +
  handoff-брифа. Проблема двойного владения исчезает **by construction**: новый sid
  не коллизится с Mac-сессией, fence не нужен, sid-registry не нужен. Цена -
  теряется дословная память Mac-сессии; замещается брифом (состояние/цель/сделано/
  дальше) - как mission.md уже делает для same-machine /solo.

## Суть

Кросс-машинный handoff = **обычный fresh mission-агент на VM, поднятый от точного
запушенного commit, с mission.md = handoff-бриф**. Транспорт кода - git (push на
origin -> fetch на VM), не scp транскрипта. Никакого нового durable-протокола,
release-маркера, sid-registry, transcript-move, push-ветки в reconciler. Всё
двойное-владение-опасное из v1/v2 удалено.

Что реально нового против существующего create:
1. **Mac-хелпер `claude-rc-takeover`** (тонкий, stateless): git-clean-check + push
   + бриф + scp спека/mission + ssh create на VM.
2. **VM create `--base-commit <sha>`**: worktree агента строится от ТОЧНОГО
   запушенного commit (fetch + verify), а не от произвольного VM HEAD.
   Воспроизводимость дерева, на котором продолжится работа.

## Threat-model

Тот же принцип "ошибки, не злоумышленник". Ключевое отличие от v1/v2: **нет
разделяемого session_id между машинами -> нет инварианта единственного писателя ->
нечего ломать гонками fence**. Mac-сессия и VM-агент - две независимые сессии;
Mac-сессия остаётся у оператора как есть (её судьба - его дело, VM её не трогает).
Единственная общая сущность - git-ветка (переносится push/fetch, git сам атомарен).

## 1. Mac-хелпер `claude-rc-takeover` (новый, тонкий)

Stateless (durable-FSM НЕ нужен - нет fence/маркера, нечего восстанавливать;
падение = перезапуск с нуля, идемпотентно по имени агента на VM). Подкоманда
`start <name> --to <vm> [--spec F] [--mission F]`. Шаги:

1. **git-состояние воспроизводимо**: `git -C <repo> rev-parse HEAD` -> `commit`;
   отказ при dirty/untracked (дерево должно быть восстановимо на VM) - оператор
   коммитит/стешит сам.
2. **push** текущей ветки на origin: `git push`. Нет upstream / не запушено ->
   отказ (VM без запушенного commit не воспроизведёт дерево).
3. **бриф**: `mission.md` - handoff-бриф (состояние/цель/что сделано/что дальше/
   критерий готовности). v1: оператор пишет сам (как для /solo). Автогенерация из
   Mac-сессии (summary транскрипта) - отложена (см. §5).
4. **транспорт спека**: scp `spec.yaml` + `mission.md` на VM в staging проекта
   (или оператор кладёт их там заранее). Транскрипт НЕ переносится.
5. **create на VM**: `ssh <vm> claude-rc agent create <name> --spec <path>
   --mission <path> --base-commit <commit>`. Обычный fresh mission-агент.

Хелпер - удобная обёртка; ничего необратимого не делает (git push идемпотентен,
create отбивает дубль имени). Крах на любом шаге -> повтор с нуля.

## 2. VM create: `--base-commit <sha>` (единственная нетривиальная правка)

Дельта cmd_create (mission-ветка):

- Новый флаг `--base-commit <sha>` (опционален; без него - текущее поведение, HEAD).
- При заданном: `git -C <project> fetch` (обновить объекты с origin) -> проверить
  наличие объекта (`git cat-file -e <sha>^{commit}`); нет -> **fail-closed** отказ
  ("commit не найден после fetch - origin не запушил / force-push"). worktree:
  `git worktree add -b agent/<name> <path> <sha>` от ТОЧНОГО commit. `mission_base
  = <sha>` (а не rev-parse HEAD).
- **Идемпотентность/crash-safety** - как в существующем атомарном create (этап 2,
  worktree в staging -> mv -> repair, trap-rollback). Новый флаг не добавляет
  durable-состояния сверх текущего - только источник commit для worktree.
- Dirty/force-push edge: `cat-file -e` до `worktree add` - чистый отказ до любых
  side-effect'ов (worktree не создаётся при отсутствующем commit).

Всё остальное (spec-валидация, acceptance.kind, incarnation, spec.role,
transient-юниты, reconciler-подъём) - существующий fresh mission-путь без изменений.

## 3. Чем это безопасно (инварианты)

- **Нет разделяемого sid** -> нет двойного владения сессией. VM-агент = новый
  session_id, Mac-сессия независима.
- **git - источник истины кода**: worktree от запушенного immutable commit;
  отсутствие commit -> fail-closed (не молчаливый HEAD). `fetch` идемпотентен.
- **Никаких новых durable-инвариантов** сверх существующего create -> нет новой
  crash-матрицы, нет sid-registry/consumed-ledger/маркеров.

## 4. Crash-матрица (минимальная - нового протокола нет)

| # | Ситуация | Исход |
|---|----------|-------|
| Q1 | Mac push не долетел, create с --base-commit | fetch не находит commit -> fail-closed отказ до worktree; оператор пушит, повторяет |
| Q2 | крах Mac-хелпера на любом шаге | stateless, повтор с нуля; git push/create идемпотентны |
| Q3 | дубль create того же имени | существующий create отбивает (реестр занят) |
| Q4 | force-push сдвинул ветку после fetch | worktree от заданного sha (immutable), не от ветки; если sha недостижим - Q1 |
| Q5 | крах VM между fetch и worktree add | существующий атомарный create (staging->mv->rollback), не пол-агента |

## 4.1. Контракт реализации (остаток codex r3 - закрыть в коде)

Фундаментальный блокер r1/r2 codex подтвердил закрытым. Остаток - обычные границы:

1. **Честная граница гарантии (не "только git").** fresh снимает session-ownership,
   но НЕ task-level exactly-once: Mac-сессия и VM-агент - две независимые сессии,
   могут параллельно воздействовать на ВНЕШНЕЕ состояние (deploy, API, issue,
   БД). Контракт v1: **гарантируется единственность на уровне git-состояния и
   session_id; после запуска VM-агента оператор НЕ продолжает ту же миссию на Mac**
   (Mac-сессию можно закрыть/переключить на другое). Это рабочая дисциплина
   оператора (модель "ошибки"), задокументировать в /solo-хелпере и mission-бриф.
2. **`--base-commit` materialization**: fetch ПИНОВАННОГО ref (`git fetch origin
   <sha>` или `<branch>` c последующей SHA-сверкой), `cat-file -e <sha>^{commit}`,
   после `worktree add` - **пост-проверка `git -C <wt> rev-parse HEAD == <sha>`**
   (дерево реально выписано). submodules/LFS - **v1 scope-out**: используемые
   проекты (claude-control и прикладные) их не используют; хелпер fail-closed при
   наличии `.gitmodules` ("submodule-проекты в кросс-машинном v1 не поддержаны").
3. **Crash-safety worktree/branch**: `--base-commit` меняет ТОЛЬКО startpoint
   `worktree add` (добавляет `<sha>` в конец), вся атомарная машинерия create
   этапа 2 (staging `$tmp/work` -> mv -> `worktree repair` -> trap-rollback:
   `worktree prune` + `branch -D agent/<name>`) переиспользуется без изменений.
   Новой crash-поверхности нет; подтвердить тестом (SIGKILL посреди create с
   --base-commit -> rollback, реестр и git чисты).
4. **Порядок хелпера (идемпотентность)**: push -> scp spec+mission -> create.
   spec/mission на VM ДО create (существующий create fail-closed без файлов ->
   агент без миссии не появляется). push случился, create нет -> безвредно
   (повтор). Cleanup хелпера консервативный: ничего необратимого не удаляет.

## 4.2. Принятые residual'ы v1 (codex code-review, модель "ошибки")

- **Offline-reuse локального объекта (code-6)**: `fetch origin || true` мягкий -
  если commit уже в object db VM (обычный случай: origin запушил, VM fetch'нул),
  worktree корректен; offline-reuse без сети допустим (helper всё равно пушит, VM
  всё равно fetch'ит). Не претендуем на pinned refspec в v1.
- **Полнота дерева (code-7)**: `HEAD==sha` ловит startpoint; sparse/partial-clone
  могут дать неполное дерево при верном HEAD. Используемые VM-клоны полные,
  не-sparse. Sparse/partial - scope-out v1 (как submodule/LFS).
- **Идентичность repo (code-11)**: `spec.project` - доверенный оператору путь; VM
  не сверяет, что local repo и origin проекта на VM - один. Ошибка в spec.project
  = operator-error, не защищаемся (модель "ошибки, доверенный оператор").
- **Branch ownership (code-r2-1, r3-1)**: EXIT-trap гейтится отсутствием
  финального `$AGENTS_DIR/<name>` - успешный `mv` = структурная граница ownership,
  catchable-сигнал в окне mv..(trap-clear) больше НЕ трогает опубликованного
  агента. Остаток: SIGKILL (trap не ловится) и гонка двух одновременных `create`
  ОДНОГО имени ДО любого mv - оба pre-existing, fail-closed, ручное восстановление
  по сообщению. Полный lock/CAS на ref - будущее ужесточение create, вне scope 5.
- **Staging bundle при разном контенте одного commit (code-r3-5)**: `.part.<pid>`
  уникален на вызов -> нет частичного файла. Если оператор МЕНЯЕТ spec/mission
  между retry ОДНОГО commit, теоретически возможна пара "новый spec + старый
  mission"; на практике один commit = один контент. Digest-bundle - v2.

## 5. Отложено / открытые

- **Автогенерация брифа** из Mac-сессии (summary транскрипта в mission.md) - v2.
  v1: оператор пишет mission.md сам. Это не безопасностный, а UX-вопрос.
- Дословная память Mac-сессии на VM - сознательно НЕ переносим (источник
  неразрешимых проблем v1/v2). Если позже понадобится - только как read-only
  reference-артефакт (не как активный транскрипт агента), отдельным решением.
- Автовыбор VM, VM->Mac, VM->VM - вне scope.
