# Состязательное ревью: КОД этапа 5 (fresh brief-seeded takeover, read-only)

Первой строкой: `session id: <id>`.

Та же сессия. Дизайн v3 ты одобрил ("ДА с закрытием остатка"): fresh-seeded
снимает фундаментальный блокер, остаток - контрактные границы (r3 п.1-6). Я
реализовал. Проверь КОД: закрыт ли остаток r3, нет ли новых дефектов. Ломай.

## Что ревьюим (изменения)

- `bin/claude-rc-agent` cmd_create - новый `--base-commit <sha>` (mission-ветка,
  ~139-165): fetch origin + `cat-file -e <sha>^{commit}` + `worktree add ... <sha>`
  + пост-проверка `HEAD==sha`; `.gitmodules` -> fail-closed; event -> отказ.
- `bin/claude-rc-takeover` (новый, Mac-сторона): stateless; `start <name> --to
  <vm> --spec --mission [--repo]`; clean-check + submodule-check + upstream-check
  + push + scp spec/mission + ssh create --base-commit.
- `bin/claude-rc` - dispatch `takeover`.
- `docs/design-2026-07-13-stage5-takeover.md` §4.1 - контракт остатка r3.

Атомарная машинерия create (staging $tmp/work -> mv -> repair -> trap-rollback)
- этап 2, НЕ менялась; `--base-commit` меняет только startpoint worktree add.

## Проверь закрытие остатка r3 в КОДЕ

1. **Честная граница (r3-1)**: контракт "не продолжай ту же миссию на Mac после
   запуска VM" - только в тексте (шапка хелпера, вывод). Достаточно ли для
   модели "ошибки", или код обязан что-то форсить?
2. **materialization (r3-2)**: `fetch origin || true` (мягкий) + `cat-file -e` +
   пост-проверка `git -C $tmp/work rev-parse HEAD == mission_base`. Дыры: fetch
   упал (нет сети) но commit локально есть - ок? commit есть как объект, но
   worktree add даёт detached/пустое дерево - ловит ли пост-проверка? `^{commit}`
   на tag/tree - отказ? force-push после fetch - берём immutable sha, ок?
3. **crash-safety (r3-3)**: `--base-commit` реально НЕ добавляет durable-состояния
   сверх атомарного create? Пост-проверка HEAD падает ПОСЛЕ worktree add, но ДО
   mv (worktree в $tmp/work) - trap чистит staging? Ветка agent/<name> при этом
   не повисает (worktree add -b создал её в $s_project)?
4. **reproducibility (r3-4)**: хелпер clean-check (`status --porcelain`) +
   submodule (`.gitmodules`). Дыры: ignored-но-нужное состояние? LFS? push без
   upstream отбит, но push в НЕ тот origin (несколько remote)?
5. **порядок хелпера (r3-4)**: scp spec/mission ДО ssh create. Крах между scp и
   create - staging на VM есть, агента нет (повтор ок)? create до scp невозможен
   по порядку кода?

## Прицельно (новые дефекты)

- `--base-commit` regex `^[0-9a-f]{7,40}$` - короткий префикс (7) неоднозначен?
  `rev-parse ${base_commit}^{commit}` резолвит префикс - коллизия/ambiguous?
- fail-closed exit-коды: несуществующий commit=4, submodule=4, event=2, bad-sha=2
  - согласованы?
- хелпер: `ssh "$vm" "claude-rc agent create '$name' ... '$commit'"` - инъекция
  через $name/$commit/$stage в удалённую команду? ($name валидируется regex,
  commit - rev-parse HEAD, stage - фикс путь; но кавычки/экранирование?)
- `merge-base --is-ancestor $commit origin/$branch` после push - надёжно
  доказывает, что commit на origin? branch с слэшами?
- `yq_project` grep-фолбэк (Mac без yq) - корректно достаёт .project из spec?

НЕ репортить: стиль; отсутствие переноса памяти (принято); автогенерацию брифа
(v2); submodule/LFS (явный scope-out v1 - критикуй обоснование, не факт).

## Итог одной строкой

Можно ли коммитить и катить на VM: ДА / ДА с закрытием списка / НЕТ.

READ-ONLY: только отчёт.
