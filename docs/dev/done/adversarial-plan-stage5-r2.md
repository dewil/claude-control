# Состязательное ревью, раунд 2: дизайн этапа 5 takeover v2 (read-only)

Первой строкой: `session id: <id>`.

Та же сессия. В раунде 1 ты нашёл 10 дизайн-блокеров + 4 доработки: дизайн не
гарантировал единственного владельца (copy без fence, replay маркера, неатомарный
дедуп sid, транскрипт не связан с commit, у Mac-хелпера нет FSM, §9 stray-scan в
коде не сплошной). Я переписал в v2. Проверь, что блокеры РЕАЛЬНО закрыты и v2 не
внёс новых дыр. Не подтверждай на слово - ломай.

## Как сведены блокеры r1

`docs/design-2026-07-13-stage5-takeover.md` (v2, прочитай целиком). Правки:

1. **Нет fence (r1-1,2,3)** -> **fence-by-MOVE**: Mac-хелпер атомарным `rename()`
   изымает транскрипт из `$cfg/projects/<slug>` в приватный outbox ДО release
   (I1). После rename `claude --resume <sid>` на Mac не находит файл - второй
   писатель невозможен физически (как §9 unlink), не по проверке. Триада -
   best-effort пред-условие, гарант - rename.
2. **Неатомарная публикация scp (r1-4)** -> durable-transfer: scp во временное
   имя `.part` -> ssh fsync+rename -> маркер публикуется ПОСЛЕДНИМ (его наличие =
   готовность). Уникальный inbox по takeover-id.
3. **Replay маркера (r1-5)** -> `takeover_id` nonce + consumed-ledger на VM;
   повторный/старый маркер отбивается (I2).
4. **Неатомарный дедуп sid (r1-6)** -> атомарная claim sid+takeover-id в
   `sid-registry.json` под `fcntl.flock` при create; два параллельных create
   разных имён -> второй отказ.
5. **§9 stray-scan заявлен, но в коде не сплошной (r1-8)** -> раздел 7: этап 5
   ОБЯЗАН реализовать verified stray-scan + обязательную проверку наличия `lsof`
   (нет -> fail-closed, не тихий пропуск).
6. **Git не связан с транскриптом (r1-9)** -> I4: маркер несёт repo_id/branch/
   commit; VM `fetch` + `cat-file -e` проверяет объект, `worktree add ... <commit>`
   от ТОЧНОГО commit; dirty-tree на Mac -> отказ.
7. **Нет FSM хелпера (r1-11)** -> раздел 2: durable FSM prepared->locally-fenced->
   transferred->registered->consumed, status/retry/abort/gc, идемпотентность по id.
8. **pgrep не fence, вечное ожидание (r1-7)** -> VM-дедуп с ТЕРМИНАЛЬНЫМ окном
   (busy>dedup_expires -> attention, не вечно); дедуп - защита от двойного импорта
   на VM, не origin-liveness.
9. **Recovery FS-предпосылки (r1-10)** -> st_dev-инвариант (inbox и projects на
   одной ФС, иначе handoff_exdev); H_SRC неизменяем (durable-publish финализировал).
10. **Expiry (r1-12)** -> готовность = наличие release.json (последний); rearm
    через `retry`; терминальный исход busy.
11. **Hostname не независим (r1-13)** -> enrolled стабильный `origin_host_id`
    (не сырой hostname); hostname - диагностика.
12. **Тест-план зелен при double-owner (r1-15)** -> добавлен ключевой контрпример:
    Mac `--resume <sid>` ПОСЛЕ locally-fenced -> не находит файл (I1); + concurrent
    create, replay, partial scp, crash-boundaries, wrong commit, EXDEV.

## Задача раунда 2 (ломай прицельно)

По КАЖДОМУ блокеру r1 - вердикт: закрыт / закрыт частично / не закрыт. Затем -
осталось ли что-то, что ломает ЕДИНСТВЕННОГО ВЛАДЕЛЬЦА или корректность В МОДЕЛИ
"ошибки, не злоумышленник" (крэш/гонка/потеря/двойное владение БЕЗ активной атаки):

- **fence-by-MOVE**: атомарный `rename()` реально изымает? Сценарий, где после
  rename на Mac всё же появляется discoverable писатель того же sid (напр. claude
  пишет НЕ по slug-namespace, а иначе; или second `--resume` создаёт НОВЫЙ файл
  под тем же sid в namespace)? P4 (открытый fd дописывает изъятый inode) - точно
  ловится sha-расхождением, или есть окно, где VM берёт sha ПОСЛЕ дозаписи?
- **consumed-ledger/claim**: атомарность claim под flock - между чтением реестра
  и записью нет TOCTOU? crash между claim и adopted - claim висит, повторный
  create того же sid отбивается ложно (никогда не адоптируется)?
- **commit-binding**: `worktree add <commit>` от commit, которого нет локально
  после fetch (origin push не долетел/ветка force-pushed) - отказ чистый или
  worktree в мусорном состоянии? mission_base=commit, а транскрипт помнит другой
  base - разъезд?
- **durable-transfer**: маркер последний, но scp транскрипта и ssh-rename -
  отдельные шаги; crash между rename транскрипта и публикацией маркера - inbox с
  транскриптом без маркера, следующий retry - дубль или доводит?
- **st_dev**: inbox на той же ФС, что projects - кто это гарантирует на VM? create
  кладёт inbox куда? если оператор задал inbox на другой ФС - поймано до adopting?

НЕ репортить: стиль; отложенные v2 (VM->Mac); "добавьте тест" (критикуй
достаточность). НЕ переоткрывай r1-14 (preseed - принят).

## Итог одной строкой

Можно ли начинать код: ДА / ДА с закрытием остатка списком / НЕТ.

READ-ONLY: только отчёт.
