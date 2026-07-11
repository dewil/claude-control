# State machine control-plane агентного слоя

Дата: 2026-07-11. Статус: **v6 - ПРИНЯТ** (вердикт codex в раунде 6: "ГОДЕН" как основание этапа 1b, must-fix нет). Итог 6 adversarial-раундов (gpt-5.6-sol, одна resume-сессия): 59 атак (r1: 31, r2: +11 N*, r3: +11 V*, r4: +6 A*, r5: +1); заметки ревьюера для 1b перенесены в план (строки этапов 1b и 2). История и остаточные риски - разд. 18. Маппинг на чек-лист - разд. 15. Схемы - разд. 19.

Это документ-до-кода: он фиксирует контракты, по которым пишутся reconciler (этап 1b), /solo (этап 2) и claude-agent-run (этап 4). Расхождение кода с документом - баг кода или осознанная правка документа, третьего нет.

## 1. Словарь и акторы

| Актор | Что пишет | Что не пишет никогда |
|---|---|---|
| **Оператор** (человек: `claude-rc agent ...` с Mac/VM или TG-бот) | `desired`, вердикты accept/reject, resolve/revise | `state.*.json` |
| **/solo** (скилл в живой сессии) | создание реестра через `claude-rc agent create` (desired=paused) + handoff-блок | ничего напрямую - только через CLI |
| **Reconciler** (systemd --user, singleton, 6.1) | `control.json` (lease, generation, acceptance, attention), машинные переходы desired из 4.3 | `spec.yaml`, `mission.md`, `state.*.json` |
| **Агент** (claude-сессия/прогон) | `state.<gen>.json` (атомарно tmp+mv), append в `events.jsonl` | `control.json`, `spec.yaml` |
| **claude-agent-run** (intake+executor событийного агента) | inbox (pending/inflight/done/deadletter), курсор, дедуп-леджер, `state.<gen>.json` | `control.json` |
| **project-watchdog** (легаси) | ничего в реестре; обязан ПРОПУСКАТЬ агентов (5.5) | - |

### 1.1 Durable-write примитив

Все критичные записи (control.json, курсор, файлы inbox, леджеры) - через один helper **на python3** (bash/coreutils не дают переносимого fsync(2)): `open tmp -> write -> fsync(tmp) -> rename -> fsync(родительского каталога)`; для rename МЕЖДУ каталогами - fsync обоих. ENOSPC/EIO - различимый exit code, вызывающий обязан обрабатывать. Fault-injection-тесты в 1b. Порядок именно такой: fsync каталога ДО rename не защищает новую directory entry.

### 1.2 Запись в control.json - CAS + seq + аудит

Каждая запись - через helper под `flock agents/<name>/.lock` в форме **conditional read-modify-write**: сверка ожидаемых значений (`desired`, `generation`, `lease.state`, `lease.start_attempt_id` - какие релевантны операции); несовпадение = конфликт, операция отменяется. Каждая запись инкрементирует монотонный **`seq`**. Аудит-событие в `events.jsonl` пишется ПОСЛЕ control-записи с ее seq; **control.json - источник истины, events.jsonl - best-effort аудит, который может отставать и никогда не опережает**: обнаружив на проходе `последний seq в events < control.seq`, reconciler идемпотентно дописывает backfill-событие "state now X (recovered, seq N)". Crash между control-записью и событием безопасен по построению.

**Имя агента**: `^[a-z][a-z0-9-]{0,30}[a-z0-9]$`, совпадает с именем каталога; все входы CLI/бота валидируются до обращения к ФС.

## 2. Файлы реестра и валидация при чтении

```text
agents/<name>/
├── spec.yaml            # плоскость spec: неизменяемо после create
├── mission.md           # плоскость spec: неизменяемо после create
├── role/                # снапшот контента роли + manifest.yaml (пути + sha256 + role_rev + источник)
├── state.<gen>.json     # плоскость reported: пишет только агент поколения <gen>
├── control.json         # плоскость control: пишет только helper (CAS, 1.2)
├── events.jsonl         # append-only аудит (seq, generation в каждой строке)
├── .lock                # flock helper'а
├── inbox/               # только event-агенты (11)
└── session.debug.log    # --debug-file рантайма (heartbeat, 5.2)
```

**Пер-поколенческий state** - write-side fencing: агент поколения N пишет ТОЛЬКО `state.<N>.json` (имя из env), затереть файл поколения N+1 физически не может. Reconciler читает файл текущего поколения, старые удаляет сам.

### 2.1 control.json (схема; полные схемы остальных файлов - разд. 19)

```json
{
  "schema": 1, "seq": 152,
  "desired": "running",                  // running | paused | stopped
  "generation": 4,                       // растит только helper
  "session_id": "uuid",                  // персистентно; resume любого поколения берет отсюда
  "started_at": "...",                   // ОДИН раз при ПЕРВОМ lease.state=active (часы max_hours)
  "deadline_extension_h": 0,             // продление max_hours оператором (resolve --extend-hours)
  "mission_base": "d34db33f",            // фиксируется при CREATE вместе с созданием ветки agent/<name>
  "lease": {
    "state": "active",                   // none | acquiring | active | stopping
    "start_attempt_id": "uuid",          // токен попытки; env рантайма, эхо в state.<gen>.json
    "gen_base": "beefcafe",              // tip ветки agent/<name>, фиксируется на ГЕЙТЕ A ЭТОГО поколения (V4; provenance 8.2)
    "socket": "agent-faq-updater.g4",    // tmux-сокет, уникальный per-generation (V9)
    "unit": "agent-faq-updater.service",
    "main_pid": 12345, "pid_start": 987654321,
    "granted_at": "...", "renewed_at": "...", "ttl_s": 300
  },
  "acceptance": {
    "status": "pending",                 // pending | needs-human | revise | accepted | rejected (needs-human ТОЛЬКО здесь)
    "artifact": null, "verdict_by": null, "checked_at": null, "note": null,
    "check_job": null,                   // {job_id, generation, artifact, started_at} - fencing async-воркера (8.2)
    "check_runs": []                     // история запусков acceptance.check
  },
  "attention": { "reason": "...", "subject": null, "since": "...", "episode": "uuid", "count": 1 },  // null, если штатно; subject - адресат reason (напр. event key для crash_loop - V6)
  "hold": null,                          // null | luks_locked | budget_exhausted | admission_queue
  "handoff": { "phase": "prepared",              // prepared | adopting | adopted (+ expired/aborted)
               "origin_pid": 1, "origin_pid_start": 2, "expires_at": "...",
               "origin_cwd": "/path/to/project",  // cwd origin-сессии -> namespace-каталог транскрипта-источника
               "transcript_digest": null }        // sha256 транскрипта, зафиксированный при входе в adopting (A1/A4)
}
```

### 2.2 Валидация при каждом чтении

Обязательные поля, типы, enum, timestamp'ы, `generation` - целое, имя = каталогу. Исходы по плоскости:

- **spec/mission/role-manifest** невалиден или sha256 не сходится -> `attention: invalid_registry`, никаких действий.
- **state.<gen>.json** невалиден -> "нет отчета" + warn.
- **control.json** невалиден -> скип агента в проходе; алерт через независимый леджер (16.2).

**Bulkhead**: сбой одного агента не прерывает проход по остальным.

## 3. Generation, fencing, единственность живого поколения

- `generation` инкрементируется helper'ом при каждой попытке старта (6.2) и на фазе revise (8.4).
- **Write-side fence** - пер-поколенческий `state.<gen>.json` (разд. 2).
- `start_attempt_id` - env рантайма, эхо в каждом state. Отчет с чужим attempt_id = FOREIGN_WRITER.
- **Инвариант единственного живого поколения**: новый рантайм стартует только после доказанно пустого cgroup предыдущего (6.2 шаг 3), а `kill_failed` НЕ освобождает lease и блокирует захват (6.2/6.3) - значит, два поколения не живут одновременно, и side-effect-fence обеспечен исключением, а не проверками downstream (атаки [3], N1).
- **Stray-scan**: каждый проход reconciler делает `pgrep -f <session_id>` по каждому агенту; кандидаты вне cgroup юнита-владельца **верифицируются** (uid, exe = claude, держит открытым транскрипт агента или cwd в его worktree - V8): верифицирован -> FOREIGN_WRITER (kill + attention: double_owner); нет -> attention: stray_suspect БЕЗ kill (диагностический `tail`/редактор с uuid в argv не расстреливается). Скан - второй эшелон после структурной эксклюзивности namespace (9.4); ловит ручные `claude --resume <uuid>` и уцелевших потомков.

## 4. Плоскость desired и команды оператора

### 4.1 Значения

`running` - reconciler сводит факт к "жив и здоров". `paused` - рантайм гасится, не поднимается. `stopped` - завершен, resume запрещен.

### 4.2 CLI-семантика (`claude-rc agent ...`)

Существующий `claude-rc` не меняется; агентный слой - namespace `agent`.

| Команда | Действие | Отказ (exit code) |
|---|---|---|
| `create <name> --spec f --mission f --role r` | валидация; создание ветки `agent/<name>` и фиксация `mission_base` СЕЙЧАС; каталог атомарно; desired=paused | имя занято (4); спец невалиден (2) |
| `start <name>` | CAS: desired=running | acceptance терминален (4); attention блокирующего типа (4) |
| `pause <name>` / `stop <name>` | CAS: desired=paused/stopped; гашение - 6.3 | - |
| `status <name>` / `list` | derived-состояние, read-only | - |
| `resolve <name> --resume\|--stop [--extend-hours N]` | снять attention; для reason=mission_timeout `--resume` требует `--extend-hours` (пишет deadline_extension_h; иначе отказ - см. N10) | attention нет (4) |
| `revise <name> --note "..."` | CAS из acceptance=needs-human -> `revise` (промежуточный статус; дальше 8.4) | acceptance не needs-human (4) |
| `accept <name>` / `reject <name> --reason` | вердикт человека; терминальный поток 8.3 | claim не выставлен (4) |
| `attach <name>` | `tmux -L agent-<name> attach` (mission) | event-агент (4) |
| `dlq <name> [--requeue id\|--drop id]` | разбор dead-letter; requeue снимает и quarantine-флаг конверта | - |
| `inbox-restore <name>` | ЕДИНСТВЕННЫЙ регламентный путь restore inbox из бэкапа: сам пере-инициализирует курсор и дедуп-леджер от живого источника (не памятка, а команда - V-r3) | - |
| `pause --role <role>` | экстренный отзыв роли: pause всем агентам роли | - |

Exit codes: 0 ok, 2 валидация, 3 не найден, 4 недопустимый переход, 5 lease/lock busy.

### 4.3 Кто меняет desired

Оператор; машинных переходов два, оба reconciler'ом через helper:

1. Терминальный вердикт acceptance -> desired=stopped **той же RMW-записью, что и вердикт** (атомарно по построению).
2. Handoff-commit: paused -> running (разд. 9).

Завершенный агент не воскресает; повтор миссии = новый агент.

## 5. Наблюдаемое состояние

### 5.1 Источники

1. **Юнит**: ActiveState, MainPID, листинг cgroup (пустота, посторонние).
2. **state.<gen>.json**: свежесть, phase, iteration_started_at, next_wakeup_at, agent_claim, эхо attempt_id.
3. **Relay-heartbeat** (mission): `session.debug.log` - `Heartbeat sent` новее H (120с; штатно ~20с).
4. **Транскрипт JSONL**: инкрементальный парс usage (кэш оффсетов; потеря кэша безвредна).
5. **Stray-scan** (разд. 3).

**Живость event-агента** - без relay: юнит active + state свежее собственного `next_wakeup_at`.

### 5.2 Живость mission = коннект к relay

Урок теста-ребута 2026-07-11: процесс жив, но сессия на модальном экране отключена от relay - с телефона невидима, миссия стоит. Здоровье = процесс жив И state свежий И heartbeat свежее H.

### 5.3 Классификация (derived)

| Класс | Условие |
|---|---|
| `ABSENT` | юнит inactive/отсутствует и lease.state=none |
| `ORPHANED_LEASE` | lease.state != none, но юнит inactive; или acquiring старше start-grace (180с) без state |
| `ACQUIRING_READY` | lease.state=acquiring + юнит active + state текущего поколения с моим attempt_id (crash до Gate B - N2) |
| `STARTING` | юнит active, state текущего поколения нет, в пределах start-grace |
| `HEALTHY_WORKING` | phase=working, виток короче max_iteration_minutes, heartbeat свежий |
| `HEALTHY_SLEEPING` | phase=sleeping, `now < next_wakeup_at + grace(120с)`, heartbeat свежий |
| `CLAIMED` | agent_claim=done\|blocked |
| `OVERRUN` | phase=working, виток дольше max_iteration_minutes |
| `OVERSLEPT` | phase=sleeping, `now >= next_wakeup_at + grace` |
| `MODAL_OR_DISCONNECTED` | юнит active, heartbeat старше H, state молчит дольше H (вкл. STARTING после grace) |
| `FOREIGN_WRITER` | чужой attempt_id в state / посторонние в cgroup / stray-scan нашел процессы вне юнита |

SIGSTOP накрывается OVERRUN/OVERSLEPT/MODAL по отсутствию прогресса.

### 5.4 Порядок разрешения (тотальность)

Действие по агенту определяется **первым сверху истинным правилом** (это делает исход определенным для ЛЮБОЙ комбинации слоев - таблица 7 не перечисляет декартово произведение, а задает порядок):

1. control.json невалиден -> скип + алерт (2.2).
2. FOREIGN_WRITER -> T13.
3. **Recovery незавершенных протоколов - ВЫШЕ hold и attention** (доведение начатого, не новая работа - V1): `lease.state=stopping` -> довести гашение 6.3; ACQUIRING_READY -> R2; ORPHANED_LEASE при desired=paused|stopped -> T15; `handoff.phase=adopting` -> довести адопцию (9.4, A2).
4. Терминальный acceptance + живой рантайм -> T12.
5. acceptance=revise -> R1 (8.4).
6. CLAIMED: done-заявка -> T7 при любом desired кроме stopped (приемка от desired не зависит); blocked-заявка -> T8 только при running, при paused -> T10 (гашение, claim остается в state - V2).
7. desired=stopped/paused -> T9-T12, T15.
8. attention с блокировкой захвата по матрице 16.1 (**неизвестный reason = блокирует, fail-closed** - V11) -> только наблюдение/гашение.
9. hold -> T14.
10. desired=running -> T1-T6 по классификации.

### 5.5 Watchdog и надзор за reconciler

project-watchdog пропускает tmux-сокеты/сессии/юниты `agent-*`; источник истины - `agents/*/`. Надзор за reconciler'ом: unit Restart=always + `OnFailure=` юнит с TG-алертом; watchdog хоста в 1b проверяет активность юнита reconciler'а.

## 6. Lease

### 6.1 Singleton reconciler

Один systemd-юнит; глобальный `flock ~/.claude-control/reconciler/.lock` на весь проход; второй экземпляр выходит. CAS-гейты ниже - защита в глубину.

### 6.2 Протокол захвата (start/resume)

```text
1. PRE-FLIGHT (без side effects): валидация реестра; hold-условия (/data
   смонтирован - findmnt, fail-closed; предохранитель); admission (10.1);
   auth/relay probe; пресид (12). Отказ -> hold / retry / attention.
2. CAS-ГЕЙТ A (flock): desired=running; attention=null ИЛИ reason
   разрешает захват по матрице 16.1 (неизвестный reason - блокирует);
   lease.state=none (или reclaim ORPHANED_LEASE) -> записать
   lease.state=acquiring, generation+1, новый start_attempt_id, unit,
   socket=agent-<name>.g<gen> (уникален per-generation - V9),
   gen_base = текущий tip ветки агента (ДО старта рантайма - V4).
   Конфликт -> отмена.
3. KILL остатков (если reclaim): systemctl --user stop -> проверка
   ПУСТОТЫ CGROUP (KillMode=control-group: MCP, panes, дети - все там).
   Не опустел за 15с + SIGKILL -> attention: kill_failed, lease.state
   ОСТАЕТСЯ КАК ЕСТЬ (никогда не none при непустом cgroup - N1), СТОП.
   Плюс ассерт: на НОВОМ сокете lease.socket нет живого tmux-сервера,
   stale-файл сокета удаляется. Сокет занят живым сервером ->
   FAIL-CLOSED: не стартовать, attention: socket_busy (fault-тест в 1b)
   (V9/A5: подключение к серверу вне cgroup исключено уникальностью
   имени + fail-closed ассертом).
4. СТАРТ юнита (6.4) с env: CLAUDE_AGENT_GENERATION, CLAUDE_AGENT_ATTEMPT,
   session_id, имя state-файла, socket.
5. CAS-ГЕЙТ B (flock): desired все еще running, generation и attempt мои
   -> записать main_pid+pid_start, lease.state=active; при ПЕРВОМ
   active - started_at.
   Конфликт (успели stop/pause) -> погасить свежезапущенный юнит по 6.3.
```

Классификация ACQUIRING_READY (crash между 4 и 5) ведет прямо к повторению гейта B - переход R2 в таблице 7 (N2).

### 6.3 Гашение (единый порядок)

```text
1. CAS: lease.state=stopping (durable, до kill).
2. systemctl --user stop; graceful (T10): sleeping - сразу; working -
   ждать конца витка, максимум max_iteration_minutes, затем stop.
3. Проверка пустоты cgroup. Не пуст после SIGKILL+15с ->
   attention: kill_failed, lease.state ОСТАЕТСЯ stopping, СТОП (N1).
4. CAS: lease.state=none, owner-поля очищены - одной записью, только
   ПОСЛЕ доказанной пустоты.
```

Инвариант: **не бывает "lease=none, процесс жив"**. Crash между шагами: stopping+мертвый -> шаг 4; stopping+живой -> шаг 2 (C21).

### 6.4 Форма рантайма

- **mission**: транзиентный `agent-<name>.service`, **Type=exec**, `KillMode=control-group`, `MemoryMax=<spec, дефолт 700M>`. MainPID = **pty-обертка** (`script -qec ...` - паттерн уже обкатан в `bin/claude-control-session`), которая держит tmux-клиент форграундом; tmux-сервер на сокете **`-L <lease.socket>` (уникален per-generation - V9)** и claude - дети в том же cgroup. Смерть сервера роняет клиента -> юнит fail -> видно systemd. Никакого GuessMainPID (N8). **Имя юнита = mutual exclusion**: systemd откажет второму `agent-<name>.service`. **CWD рантайма = приватный worktree агента** (git worktree ветки `agent/<name>`; принцип плана "act = worktree"): у транскриптов агента собственный namespace-каталог, которым не пользуется никто, кроме claude-rc (основа адопции 9). Attach - `claude-rc agent attach` (читает socket из lease).
- **event**: тот же транзиентный юнит, Type=exec (claude-agent-run - foreground MainPID); headless-дети в том же cgroup.

Admission считает бюджет RAM в МБ, не штуки.

### 6.5 Продление и истечение

`renewed_at` обновляет reconciler, подтвердив владельца (юнит active + MainPID/pid_start + эхо attempt_id). TTL = 5x интервал прохода. Истек + мертв -> reclaim. Истек + жив (reconciler лежал) -> владение сохраняется, warn. Передачи по TTL нет.

## 7. Таблица переходов

Порядок применения - 5.4 (первое истинное правило). `attention` блокирует захват lease только для reasons, помеченных в 16.1.

| # | desired | Классификация | Действие |
|---|---|---|---|
| T1 | running | ABSENT / ORPHANED_LEASE | захват 6.2 (admission/stagger); неудачи -> backoff 1/2/5/15 мин, 4 подряд -> attention: resume_failed |
| R2 | running | ACQUIRING_READY | довершить Gate B (CAS: main_pid, active, started_at при первом). **Recovery-переход: выполняется поверх hold/attention** (5.4 п.3 - V1) |
| T2 | running | STARTING | ждать grace |
| T3 | running | HEALTHY_* | продлить lease; context hygiene (13); учет (14) |
| T4 | running | OVERRUN | interrupt (13.1) -> 60с -> гашение 6.3 + attention: overrun_quarantine; ветка не трогается |
| T5 | running | OVERSLEPT | 1 пинок (13.1) -> не проснулся -> гашение + захват (gen++); 2 рецидива -> attention: wakeup_loop |
| T6 | running | MODAL_OR_DISCONNECTED | гашение + захват с пресидом (12); 2 неудачи -> attention: modal_screen (хинт trust/onboarding) |
| T7 | не stopped | CLAIMED (done) | приемка 8.2; рантайм гасится 6.3 (слот освобождается, транскрипт остается) |
| T8 | ТОЛЬКО running | CLAIMED (blocked) | по spec.on_blocker (notify-and-sleep: пуш + спит); при paused -> T10 (V2) |
| R1 | не stopped | acceptance=revise | гашение живого рантайма 6.3 -> CAS: acceptance=pending + generation++ (note остается в acceptance.note) -> далее T1 (8.4) |
| T9 | paused | ABSENT | ничего (цель) |
| T10 | paused | живой | graceful гашение 6.3 |
| T11 | stopped | ABSENT | ничего; терминально |
| T12 | stopped / acceptance терминален | живой | гашение 6.3 |
| T13 | * | FOREIGN_WRITER | верификация кандидата (uid + exe=claude + держит транскрипт/cwd агента - V8) -> kill; не верифицирован -> attention: stray_suspect БЕЗ kill (невиновный `tail`/редактор с uuid в argv не убивается) |
| T14 | running | hold | не стартовать новое; живой рантайм не убивать; алерт 1 раз на вход (кроме admission_queue), автоснятие; retry не растут |
| T15 | paused/stopped | ORPHANED_LEASE | довести гашение 6.3 с шага 2 (kill остатков -> пустота cgroup -> lease=none). Recovery-переход поверх hold/attention (V2) |

`max_hours + deadline_extension_h` (по started_at) - поверх любой строки с живым рантаймом: гашение + attention: mission_timeout.

### 7.1 Crash-матрица

| # | Падение | Обнаружение | Исход |
|---|---|---|---|
| C1 | Агент умер посреди витка | юнит inactive | T1: захват, gen++; ветка цела. Сходится |
| C2 | Агент умер во сне | то же | T1. Сходится |
| C3 | tmux-сервер убит | клиент-обертка падает -> юнит fail | T1. Сходится |
| C4 | Crash reconciler после гейта A, до kill | acquiring, юнита нет | ORPHANED_LEASE -> T1. Сходится |
| C5 | Crash после kill, до старта | acquiring, cgroup пуст | ORPHANED_LEASE -> T1. Сходится |
| C6 | Crash после старта, до гейта B | acquiring + юнит active + state с моим attempt | ACQUIRING_READY -> R2 (довершение гейта B). State не появился за grace -> гашение + T1. Сходится (N2) |
| C7 | Двойной запуск | systemd откажет второму юниту; обход (ручной запуск) -> FOREIGN_WRITER (attempt_id/cgroup/stray-scan) | T13. Сходится с алертом |
| C8 | Ребут VM | все юниты мертвы | control-plane (корень) стартует сам; T1 по одному за проход. Сходится |
| C9 | Ребут + LUKS заперт | pre-flight fail-closed | hold: luks_locked, ОДИН алерт; после unlock staggered resume. Сходится после unlock |
| C10 | Reconciler мертв | Restart=always; сломан юнит -> OnFailure-алерт + watchdog-проверка (5.5) | агенты доживают витки автономно; передачи по TTL нет - деградация безопасна |
| C11 | SIGSTOP агента | нет прогресса | T4/T5/T6 (SIGKILL добивает). Сходится |
| C12 | Штормовой рестарт всех | много ABSENT | 1 захват/проход, FIFO. Сходится растянуто |
| C13 | /solo: origin умер после create(prepared) | prepared, origin мертв | штатный сигнал -> commit по 9. Prepared ограничен expires_at - "сироты" нет |
| C14 | /solo: origin жив к expires_at | expires в прошлом | attention: handoff_expired + пуш; paused; решает оператор |
| C15 | Crash между adopted-CAS и стартом | running, phase=adopted, lease none | T1; session_id персистентен (2.1). Сходится |
| C26 | Crash посреди адопции (вкл. между link и unlink) | phase=adopting | recovery 9.4 (выше T1) разбирает ВСЕ состояния пары origin/dest, включая "оба существуют" (один inode -> довершить unlink; разные -> attention); любой CAS в adopted - только после свежих digest+lsof. desired еще paused - T1 не стартует раньше adopted. Сходится |
| C16 | Crash посреди приемки | acceptance=pending, claim=done | read-only проверки + ОДНА RMW -> повтор идемпотентен. Сходится |
| C17 | Порча файла реестра | валидация 2.2 | по плоскости; control -> скип + алерт через леджер (16.2). Не сходится машинно - и не должно |
| C18 | Executor kill -9 посреди события | inflight с мертвым runner | recovery 11.2 (probe-гейт, recoveries-счетчик). Событие не потеряно. Сходится |
| C19 | Intake crash между персистом и курсором | событие в pending, курсор старый | перечитка + дедуп. Сходится |
| C20 | Диск полон | ENOSPC от helper | intake стоп; executor стоп; алерт через tmpfs (16.2); control не портится (упавший rename не трогает старый файл). Сходится после освобождения |
| C21 | Crash посреди гашения | lease.state=stopping | stopping+мертвый -> шаг 4; stopping+живой -> шаг 2. Сходится |
| C22 | Crash между вердиктом и desired | - | не существует: одна запись (4.3) |
| C23 | Crash посреди revise (R1) | acceptance=revise | каждый шаг R1 идемпотентен от статуса revise: гашение повторяемо, CAS-довершение повторяемо. Сходится |
| C24 | kill_failed (cgroup не пустеет) | 6.2/6.3 шаг 3 | lease НЕ освобождается, захват заблокирован, attention; новый владелец не стартует - двух поколений не бывает (N1). Сходится после ручного разбора |
| C25 | hold возник между стартом и гейтом B | ACQUIRING_READY + hold | R2 - recovery-переход выше hold (5.4 п.3): гейт B довершается, lease не зависает в acquiring (V1). Сходится |

## 8. Acceptance

### 8.1 Заявка

`agent_claim: done` + `claim_artifact: <commit>` в state.<gen>.json; артефакт - commit в ветке `agent/<name>`.

### 8.2 Проверка (T7)

1. **Provenance** (закрытие "старого зеленого" - [26]): (a) artifact - потомок `mission_base`; (b) artifact - потомок **`gen_base` поколения, подавшего claim** (tip ветки, зафиксированный на гейте A ДО старта рантайма - V4: работа обязана быть сделана В ЭТОМ поколении); (c) `artifact != gen_base` И **дерево artifact отличается от дерева gen_base** (`git diff --quiet` обязан показать изменения - пустой/tree-identical коммит поверх старого зеленого не проходит, V3); (d) artifact == текущий tip ветки. Случайный reset/выбор старого hash проваливает (b)/(c) механически. Edge: работа реально завершена прошлым поколением до crash (tip уже = результат) -> artifact == gen_base -> needs-human (безопасная сторона, не ложный вердикт).
2. **Критерий**: `acceptance.check` выполняется ТОЛЬКО при явном `acceptance.deterministic: true` в spec (нет декларации - сразу needs-human). Запуск - **отдельным bounded-воркером** (транзиентный юнит с таймаутом); проход не блокируется (V10). **Fencing воркера** (A-r4): при старте reconciler пишет в control `acceptance.check_job = {job_id, generation, artifact, started_at}`; воркер кладет результат в файл, именованный job_id; reconciler принимает результат ТОЛЬКО если {job_id, generation, artifact} джоба совпадают с текущим claim - результат устаревшего джоба (агент успел revise/новый claim) молча отбрасывается. Прогонов **два**: оба 0 -> `accepted`; расхождение -> needs-human + flaky_check; оба != 0 -> needs-human с выводами (НЕ авто-reject). Таймаут/инфра-ошибка -> НЕ вердикт: retry (probe-гейт). Запуски - в `check_runs`. Остаточный риск: коррелированный флак - принят (см. 18).
3. Вердикт: ОДНА RMW - acceptance.status + (терминальные) desired=stopped. Идемпотентно (C16).

### 8.3 Терминальность

`accepted`/`rejected` (reject - только человек или приемщик этапа 7 через reconciler) терминальны: desired=stopped той же записью, пуш, `start` - отказ навсегда. Повтор = новый агент.

### 8.4 needs-human и revise

`needs-human` живет ТОЛЬКО в `acceptance.status`. Выходы: `accept`/`reject` (терминал) или `revise --note` - **двухфазно** (N3):

1. CLI: CAS `needs-human -> revise` + note. Другие исходные статусы - отказ.
2. Reconciler (R1): гашение живого рантайма 6.3 -> CAS: `revise -> pending` + generation++ (старый claim в state.<gen-1>.json инвалидирован фенсингом) -> T1 стартует новое поколение, агент читает note из acceptance.note и продолжает миссию.

Crash-safe: оба шага идемпотентны от статуса `revise` (C23). Никакого зацикливания CLAIMED ([24]) и никакого gen++ при живом старом рантайме (N3).

## 9. /solo handoff (кейс A, контракт этапа 2)

Handoff - персистентная FSM: `phase: prepared -> adopting -> adopted` (+ expired/aborted).

1. /solo: mission.md с проверяемым критерием (иначе отказ) -> подтверждение пользователя -> `create`: desired=paused, session_id (верхний уровень), handoff{prepared, origin_pid, origin_pid_start, expires_at=+10m}.
2. Origin завершает ход и выходит. Больше от нее ничего не требуется.
3. Reconciler видит prepared. **Commit-триада** (все три обязательны): (a) origin_pid+pid_start мертв; (b) `pgrep -f <session_id>` пуст; (c) `lsof` транскрипта пуст. Выполнены -> вход в адопцию (п.4). Origin жив, expires не истек -> ждать; истек -> C14.
4. **Транскрипт-адопция = durable-фаза FSM + атомарный MOVE** (структурное закрытие V7; A1-A4):
   - CAS: `phase=adopting` + `transcript_digest` = sha256 текущего origin-файла (desired ОСТАЕТСЯ paused).
   - **MOVE, не copy**: `link(origin, dest)` в namespace приватного worktree агента (no-clobber: link падает EEXIST, если dest уже есть) -> `fsync(dest-каталога)` -> `unlink(origin)` -> `fsync(origin-каталога)`. Rename-семантика с защитой от затирания. Origin-файла БОЛЬШЕ НЕТ: юзерский `claude --continue` в cwd проекта его не найдет (A3 - двух файлов с одним session_id не существует), повторная адопция поверх живого транскрипта невозможна физически (A1 - источник исчез).
   - Пост-move проверки: digest dest == transcript_digest (источник не менялся во время адопции - A4; расхождение -> attention: adoption_dirty, БЕЗ отката); `lsof` dest пуст (уцелевший писатель следует за inode при rename - ловится здесь).
   - CAS: `phase=adopted` + `desired=running` (одна запись) -> обычный T1 из worktree агента. **Инвариант: ЛЮБОЙ CAS в adopted (штатный и recovery) выполняется только после свежих digest-проверки И пустого `lsof` dest в том же проходе** (A4-r5: уцелевший писатель открытого inode ловится всегда, не только на штатном пути).
   - **Recovery (выше T1 - правило 5.4 п.3)**, полный разбор состояний adopting:
     - origin есть, dest нет -> повторить move с шага link.
     - **origin И dest оба есть** (crash между link и unlink - A2-r5): `stat` обоих - **один inode** -> довершить move (`unlink(origin)` + fsync origin-каталога), дальше штатно; **разные inode** (чужой dest - EEXIST-случай) -> attention: adoption_failed, ничего не удалять.
     - dest есть, origin нет -> digest + lsof (инвариант выше) -> CAS в adopted.
     - обоих нет или digest расходится -> attention: adoption_failed (не гадать).
     - `EXDEV` (namespace-каталоги на разных ФС - не наша конфигурация) -> fail-closed: attention, copy-fallback ЗАПРЕЩЕН (copy возвращает атаку A3).
   После adopted move не повторяется никогда. Crash между adopted-CAS и стартом - обычный C15.
5. Пост-commit защита - непрерывный stray-scan (разд. 3) как второй эшелон. **Обязательство этапа 2**: спайк-подтверждение, что resume перенесенного в другой namespace транскрипта сохраняет session_id и связь с relay (если нет - fresh-режим остается единственным, handoff-режим блокируется до решения).

/solo не может определить session_id -> честный отказ handoff-режима, fallback: fresh-режим (агент с mission.md без наследования транскрипта).

## 10. Admission, бюджет, backpressure

### 10.1 RAM-admission

`ram_budget_mb` (стартово 2500). Сумма MemoryMax допущенных + резерв headless <= бюджета. Очередь desired=running без слота -> hold: admission_queue, FIFO по started_at (нет - по create). Один захват за проход. CLAIMED слот не держит.

### 10.2 Бюджет-предохранитель

Капы (прогонов/сутки, недельный расход). Срабатывание -> hold: budget_exhausted + алерт: прогоны и захваты стоп, **intake продолжает**. Учет - инкрементально из транскриптов (14).

### 10.3 Backpressure и ретеншн источника

`inbox_max_events` (1000) / `inbox_max_bytes` (50M). 80% -> warn. 100% -> intake останавливает продвижение курсора, attention: inbox_wedged; **executor продолжает drain, и lease для event-агента при этом reason ЗАХВАТЫВАЕТСЯ** (16.1 - лекарство должно запускаться, N6). **Потеря событий возможна только наблюдаемо**: для каждого источника в spec - `replay_window` (TG getUpdates ~24ч); intake алертит при возрасте старейшего невыбранного > 50% окна; hold дольше окна = потеря С АЛЕРТОМ - тихого дропа нет, но и предотвратить потерю за пределами окна источника нельзя (честный контракт, [21]).

## 11. Event-контракт

```text
agents/<name>/inbox/
├── cursor.json          # per-item contiguous курсор (durable-helper)
├── dedup.jsonl          # леджер обработанных ключей (протокол 11.3)
├── .executor.lock       # flock singleton executor'а
├── pending/<key>.json   # key = sha256(source_ns + native_id) (32 hex)
├── inflight/<key>.json  # ЕДИНЫЙ ФАЙЛ-КОНВЕРТ: {meta:{attempts,recoveries,next_attempt_at,history}, payload:{...}}
├── done/<key>.json      # терминальный tombstone (payload чистится, имя живет в dedup)
└── deadletter/<key>.json
```

**Конверт** (N4): meta и payload - один файл; переход состояния = rename между каталогами; изменение meta (attempts++, next_attempt_at) = durable-rewrite в текущем каталоге (tmp+fsync+rename) ДО перехода. Никакого сайдкара - split-brain "meta без payload" не существует.

### 11.1 Intake FSM

Состояния: RUNNING <-> DEGRADED (источник недоступен, backoff); WEDGED (10.3/C20); stopped только по desired=stopped (paused intake НЕ останавливает).

Строго по одному элементу: элемент -> key -> есть в pending|inflight|done|deadletter или dedup -> скип -> durable-запись `pending/<key>.json` (конверт с meta {attempts:0}) -> **после** durable-коммит курсора на ЭТОТ элемент (contiguous: курсор не обгоняет последний персистованный). Нативный id - в payload, имя файла - только hash.

### 11.2 Executor FSM

Singleton: flock на `.executor.lock` + cgroup-юнит.

`PICK` (старейший pending с next_attempt_at <= now, `quarantined != true`) -> `CLAIM` = rename pending -> inflight (атомарно; проигравший получает ENOENT) -> `RUN` (`claude -p`, таймаут, key в промпте) -> исходы:

- **OK** -> durable-append в dedup (11.3) -> rename inflight -> done. Crash между: recovery видит inflight+мертвый runner+key в dedup -> доводит в done (идемпотентно).
- **Наблюдаемый FAIL (ненулевой exit)** -> **инфра-гейт**: независимый probe (relay/API, auth, диск). Инфра больна -> attempt НЕ засчитан, конверт обратно в pending, executor-пауза с backoff, карантин > 30 мин -> attention: infra_down. Здорова -> meta.attempts++ (durable-rewrite) + next_attempt_at (1/5/15 мин) -> rename в pending; **другие ready-события обрабатываются** - head-of-line нет.
- **attempts >= 3** (только наблюдаемые фейлы при здоровой инфре) -> rename в deadletter + алерт.
- **Recovery inflight с мертвым runner** (kill -9, ребут - N5): key в dedup -> done. Нет -> **probe-гейт**: инфра больна или причина неизвестна -> meta.recoveries++ (НЕ attempts), в pending; `recoveries > 5` -> `meta.quarantined=true` в конверте + attention: crash_loop c `subject=<key>` (V6: attention адресует конкретное событие, PICK пропускает quarantined-конверты, остальная очередь живет; снимает `dlq --requeue`).

FIFO гарантируется до первого retry. Concurrency v1: один прогон на агента. DLQ разбирает человек.

### 11.3 Дедуп-леджер и ретеншн

Протокол dedup.jsonl (N11): все операции под `flock dedup.lock`. **Открытие на запись: если последняя строка без завершающего `\n` - сначала truncate до последнего полного `\n` + fsync, потом append** (V5: оборванный хвост не отравляет следующие записи; усеченный key безопасен - его событие в этот момент еще в inflight, recovery дозапишет). Append одной строки + fsync ДО rename inflight->done; читатель толерантен к дублям строк (set-семантика). Ротация - durable-rewrite под тем же lock, окно >= `replay_window x 3`. Restore из бэкапа - только командой `claude-rc agent inbox-restore` (4.2), которая сама пере-инициализирует курсор и леджер от живого источника.

Ретеншн: `done/` payload - 14 дней (имя живет в dedup); `deadletter/` до разбора (>100 -> attention); `pending/`, `inflight/`, курсор - не трогает никогда. Транскрипты headless - чистка старше N дней.

## 12. Хрупкий старт: preseed (риск 11 плана)

Обертка рантайма перед exec claude идемпотентно пресидит в `$CLAUDE_CONFIG_DIR/.claude.json`: onboarding, theme, `projects["<cwd>"].hasTrustDialogAccepted=true` (python3 RMW, чужие поля сохраняются). Несработавший пресид -> MODAL_OR_DISCONNECTED -> T6.

## 13. Канал управления сессией

### 13.1 send-keys - честно хрупкий канал, fail-closed

`tmux send-keys` - UI-RPC без ack. Дисциплина: перед отправкой `capture-pane` + проверка fingerprint idle-промпта claude; **несовпадение = НЕ отправлять + attention: pane_unrecognized** (fail-closed - клавиши в неопознанный consumer не уходят); отправка литералом (`-l`) + отдельный Enter; подтверждение эффекта - по транскрипту следующим проходом; 2 неудачи -> attention. Машинный канал - открытый вопрос (17).

### 13.2 Внешний compact

Заполнение окна - по инкрементальному парсу транскрипта. При >= 90% и phase=sleeping - `/compact` через 13.1. Проверка падения заполнения следующим проходом; 2 несработавших -> attention: compact_failed. Посреди working-витка - никогда.

## 14. Учет расхода

Транскрипт-JSONL (пишется по ходу; kill не теряет), парс инкрементальный. Использование: дашборд, предохранитель 10.2, context-fill 13.2. Финальный JSON headless - сверка, не первоисточник.

## 15. Соответствие чек-листу этапа 1a

| Пункт | Раздел |
|---|---|
| Терминальность acceptance | 4.3, 8.3 |
| max_hours от первого lease | 6.2 (гейт B), 2.1 |
| Порядок захвата lease | 6.2 |
| Durability критичных записей | 1.1, 1.2 |
| MemoryMax + admission по RAM | 6.4, 10.1 |
| Предохранитель стопит прогоны, не intake | 10.2 |
| Dead-letter после health-check инфры | 11.2 |
| Provenance claim_artifact (старый зеленый не проходит) | 8.2 (gen_base) |
| Снапшот роли; отзыв = pause роли | 2, 2.2, 4.2 |
| Учет расхода при kill | 14 |
| Ретеншн не трогает pending | 11.3 |
| Таблица переходов + crash-матрица (вкл. /solo и двойного владельца) | 5.4, 7, 7.1, 9 |
| needs-attention/needs-human + lease renewal | 16, 8.4, 6.5 |
| Event-контракт | 11, 10.3 |
| Schema-валидация при чтении | 2.2, 19 |
| Роль как opaque bundle | 2, 19 |
| Живость = коннект к relay | 5.2, T6 |
| Context hygiene >= 90% на границе витка | 13.2 |

## 16. Attention и алертинг

### 16.1 Матрица reason x действия (управляет и гейтом A)

CAS-гейт A (6.2) сверяется с этой матрицей: блокирует захват только reason, у которого в колонке "Заблокировано" стоит захват lease (N6).

| reason | Заблокировано | Разрешено (в т.ч. лечит) |
|---|---|---|
| resume_failed, modal_screen, wakeup_loop, mission_timeout, overrun_quarantine, handoff_expired | захват lease | гашение, приемка, status |
| invalid_registry, double_owner, kill_failed | все кроме гашения (kill_failed: и гашение доводится повторно) | гашение |
| inbox_wedged | продвижение курсора intake | **захват lease event-агента, executor drain** (лечение), гашение |
| dlq_overflow | ничего из основной очереди | все, включая захват |
| infra_down | прогоны executor | intake, захват, гашение |
| crash_loop | прогон события из `attention.subject` (quarantined-флаг в конверте) | остальная очередь, захват |
| compact_failed, pane_unrecognized | повторные send-keys | все остальное |
| disk_full | записи на диск | алерт через tmpfs (16.2) |
| **неизвестный reason** (schema-дрейф, порча) | захват lease и все авто-действия (fail-closed - V11) | status, гашение |

`resolve` для `mission_timeout --resume` требует `--extend-hours N` (deadline_extension_h; иначе следующий проход немедленно вернет тот же attention - N10). Самоснятие средовых: inbox_wedged - при заполнении < 60%; infra_down - при здоровом probe. Остальные снимает только оператор.

### 16.2 Alert-леджер

Дедуп пушей - НЕ в control.json: `~/.claude-control/reconciler/alerts.jsonl`, ключ `{agent, reason, episode}`; fallback при недоступном корневом диске - `/run/user/<uid>/claude-control-alerts/` (tmpfs). 1 пуш на эпизод + повтор каждые 6ч, пока открыт. Общий rate-limit (антишторм).

### 16.3 hold != attention

luks_locked, budget_exhausted, admission_queue - ожидаемые состояния: алерт 1 раз на вход (кроме очереди), автоснятие, retry не растут, живой рантайм не трогается.

## 17. Открытые вопросы (за пределами 1a)

- Машинный канал управления интерактивной сессией вместо send-keys.
- Частота прохода: v1 = таймер 60с; событийный пинок - после 1b.
- Механизм определения /solo своего session_id - этап 2 (fallback в 9).
- Модель event-агентов (haiku с эскалацией) - этап 4. TG-диплинк - этап 3.
- Изоляция per-UID/контейнер - после этапа 4.

## 18. История ревью и остаточные риски

- **Раунд 1** (codex gpt-5.6-sol, adversarial): 31 атака -> v2 (CAS-гейты, пер-поколенческий state, systemd-юнит как singleton/kill-domain, rename-FSM inbox, унификация needs-human, alert-леджер, durable-примитив и др.).
- **Раунд 2** (re-review + 11 новых атак N1-N11) -> v3: kill_failed не освобождает lease + инвариант единственного живого поколения (N1, закрыл и [3]); ACQUIRING_READY/R2 (N2); двухфазный revise (N3); конверт вместо сайдкара (N4); recovery через probe + recoveries (N5); гейт A по матрице (N6, [22]); commit-триада + stray-scan (N7); Type=exec + pty-обертка (N8, [29]); seq + backfill (N9, [10]); --extend-hours (N10); протокол леджера (N11); gen_base provenance ([26]); check-политика ([28]); fail-closed fingerprint ([30]); порядок 5.4 + схемы ([31]).
- **Раунд 3** (re-review + 11 новых атак V1-V11) -> v4: recovery-переходы (R2, доведение stopping, T15) подняты ВЫШЕ hold/attention в порядке 5.4 (V1); orphan/paused-комбинации доопределены (V2); tree-diff-проверка против пустого коммита поверх старого зеленого (V3); gen_base фиксируется на гейте A до старта (V4); truncate оборванного хвоста леджера перед append (V5); attention.subject + quarantined-флаг конверта (V6); **транскрипт-адопция: живой транскрипт агента живет только в namespace его приватного worktree - blind spot `--continue` закрыт структурно** (V7); верификация кандидатов stray-scan перед kill, невиновные не расстреливаются (V8); per-generation tmux-сокет + ассерт отсутствия чужого сервера (V9); acceptance-check в bounded-воркере, проход не блокируется (V10); неизвестный attention reason = fail-closed (V11); авто-accept только при deterministic: true; inbox-restore как команда, не памятка.
- **Раунд 4** (атаки A1-A6 на адопцию/сокеты) -> v5: адопция - durable-фаза FSM `prepared -> adopting -> adopted` с digest, desired=running только на adopted, recovery выше T1 (A1, A2); **MOVE вместо copy** (link no-clobber + unlink): origin-файл исчезает - двух файлов с одним session_id не существует, юзерский `--continue` не находит сессию агента, повторная адопция поверх живого невозможна физически (A1, A3); пост-move digest + lsof (писатель следует за inode - A4); socket_busy = fail-closed + fault-тест (A5); fencing async-воркера приемки по {job_id, generation, artifact} (V10-остаток); спайк-обязательство этапа 2: resume перенесенного транскрипта сохраняет session_id, иначе handoff-режим блокируется (A3-верификация).
- **Раунд 5** -> v6: recovery адопции разбирает все состояния пары origin/dest, включая crash-окно "оба существуют после link" (один inode -> довершить unlink; разные -> attention); инвариант "CAS в adopted только после свежих digest+lsof в том же проходе"; EXDEV = fail-closed без copy-fallback; интро 9 исправлено на prepared->adopting->adopted. Заметки в 1b: fault-injection на каждой границе link->fsync->unlink->fsync; EEXIST/inode-mismatch тесты; cleanup stale-результатов acceptance-воркера.
- **Остаточные риски (принято осознанно)**: (a) send-keys - UI-RPC без ack: fail-closed fingerprint, не используется для необратимых команд, машинный канал в 17; (b) коррелированный флак check, дважды давший ложный 0 - при обязательной декларации deterministic: true принят; (c) верифицируемый kill в stray-scan может пропустить экзотического самозванца (не claude-бинарь, пишущий в транскрипт) - вне модели угроз v1; (d) TOCTOU занятия сокета между ассертом и стартом юнита - вне модели угроз v1 (штатные акторы исключены уникальностью имени; fault-тест 1b подтверждает fail-closed).

## 19. Приложение: схемы файлов

```yaml
# spec.yaml (неизменяемо после create)
schema: 1
name: faq-updater            # ^[a-z][a-z0-9-]{0,30}[a-z0-9]$, = каталогу
type: mission                # mission | event
role: coder                  # имя роли; контент заморожен в role/
role_rev: 17                 # ревизия роли на момент снапшота
project: проект 1-faq         # чекаут на /data
goal: "одно предложение"
autonomy: act                # suggest | act | release
memory_max_mb: 700
limits:
  max_iterations: 50
  max_hours: 8
  max_iteration_minutes: 20
  runs_per_day: 50           # event: кап прогонов
  on_blocker: notify-and-sleep
acceptance:                  # опционально; нет -> needs-human
  check: "make test"
  deterministic: true        # ОБЯЗАТЕЛЬНО true для авто-accept; иначе сразу needs-human (V-r3)
  timeout_s: 600
source:                      # только event
  kind: telegram             # идентификатор источника (source_ns для key)
  replay_window_h: 24
```

```json
// state.<gen>.json (пишет только агент поколения <gen>)
{ "schema": 1, "generation": 4, "attempt_id": "uuid",
  "phase": "sleeping",            // working | sleeping | waiting_input | blocked
  "status_line": "виток 7: ...",
  "agent_claim": "running",       // running | done | blocked
  "claim_artifact": null,          // commit hash при done
  "session_id": "uuid",
  "iteration_started_at": "...", "last_progress_at": "...",
  "next_wakeup_at": "...", "iterations": 7, "cost_usd": 1.42 }
```

```yaml
# role/manifest.yaml
schema: 1
role: coder
role_rev: 17
source: "claude-toolkit@<commit>"
created_at: 2026-07-11T12:00:00Z
files:
  - { path: prompt.md, sha256: "..." }
  - { path: settings.json, sha256: "..." }
```

```json
// inbox: конверт события (pending/inflight/done/deadletter/<key>.json)
{ "schema": 1, "key": "sha256-32hex", "source_ns": "telegram",
  "native_id": "update_12345", "received_at": "...",
  "meta": { "attempts": 0, "recoveries": 0, "quarantined": false, "next_attempt_at": null,
            "history": [ { "at": "...", "outcome": "fail", "exit": 1 } ] },
  "payload": { } }

// cursor.json
{ "schema": 1, "source_ns": "telegram", "position": "12345", "committed_at": "..." }

// dedup.jsonl - по строке на ключ: {"key":"...","done_at":"..."}
// alerts.jsonl - {"agent":"...","reason":"...","episode":"uuid","pushed_at":"...","count":2}
// events.jsonl - {"seq":152,"generation":4,"at":"...","actor":"reconciler","event":"lease_active","detail":{}}
```
