# Runbook: canon-maintainer (fleet-reconciler канона)

Оперативная инструкция "что делать сейчас". Как устроено и почему - explainer:
[design-2026-07-14-stage8-canon-sync.md](design-2026-07-14-stage8-canon-sync.md)
(читать первым при незнакомстве с системой).

`claude-agent-canon-maintainer` раскатывает ревизии канона (репо
claude-toolkit, теги `canon-vN`) по парку git-проектов через PR: строит
candidate-ветку `canon/<vN>` в клоне проекта, применяет канон детерминированной
дельтой (toolkit `canon-delta.py`), пушит и открывает PR; `applied` фиксируется
только по факту присутствия байт канона в post-merge default-ветке (T3).
Path-проекты (например Mac-чекауты) и не-git vault'ы не мутируются никогда -
только observe-вердикт.

## Установка на VM с нуля

1. Клоны репо:
   ```sh
   git clone git@github.com:dewil/claude-control.git ~/Work/claude-control
   git clone <SSH-алиас-канона>:dewil/claude-toolkit.git ~/Work/claude-toolkit
   ```
2. Креды:
   - deploy-ключи per-repo в `~/.ssh/config` (алиасы `github-<repo>`;
     ключи на зашифрованном томе, если он есть);
   - `gh` CLI в `~/.local/bin` + fine-grained PAT с правами PR на fleet-репо -
     токен кладется ТОЛЬКО в env-файл (ниже), не в чат/заметки;
   - git identity: `git config --global user.name/user.email`.
3. Env-файл `~/.config/claude-control/env` (переменные, значения не документируем):
   - `CLAUDE_CANON_REPO_URL` - URL канон-репо (источник зеркала);
   - `CLAUDE_CANON_DELTA` - путь к `~/Work/claude-toolkit/scripts/canon-delta.py`;
   - `GH_TOKEN` - PAT для gh;
   - `CLAUDE_AGENT_ALERT_CMD` - хук уведомлений (обычно `claude-agent-tgbot send`);
   - опционально `CLAUDE_CANON_SMOKE_CMD` - глобальная smoke-проверка кандидата
     (например `claude -p ok --max-turns 1`: грузит `.claude`; помни - это
     LLM-вызов на каждый новый кандидат каждого проекта, решение о стоимости
     за оператором), `CLAUDE_CANON_BUDGET`, `CLAUDE_CANON_SMOKE_TIMEOUT`;
   - рекомендуется `CLAUDE_CANON_LOCK` - АБСОЛЮТНЫЙ путь singleton-замка
     (без него путь зависит от `XDG_RUNTIME_DIR` окружения; cron/ssh-сессия
     без XDG взяла бы другой путь и не исключала бы таймерный проход);
     `CLAUDE_CANON_LOCK_WAIT` - таймаут ожидания лока админ-командами
     (arm/disarm/ack; дефолт 60с, по истечении exit 5).
4. `cd ~/Work/claude-control && ./install.sh` - идемпотентен; рендерит юниты,
   кладет бинари, включает `claude-agent-canon-maintainer.timer` (12 ч +
   jitter, Persistent=false).
5. Инвентарь `~/.claude-control/canon/fleet.yaml` - по
   [examples/fleet.yaml.example](../examples/fleet.yaml.example):
   `{имя: {repo_url|path, policy, ring?, smoke_cmd?, target_cmd?}}`.
   `path` и `repo_url` взаимоисключающие; не-git path - только observe.
6. Проверка: `systemctl --user list-timers | grep canon` и ручной проход
   (обязательно с env-файлом - без него maintainer увидит дефолтные URL/пути):
   ```sh
   set -a; . ~/.config/claude-control/env; set +a
   claude-agent-canon-maintainer once
   ```

## Observe-first и arm

Свежая установка disarmed: проходы только наблюдают (plan + digest), никаких
мутаций. Включение боевого режима:

```sh
claude-agent-canon-maintainer arm      # первые 3 прохода observe-first, потом armed
claude-agent-canon-maintainer disarm   # kill switch: мгновенно обратно в observe
claude-agent-canon-maintainer status   # armed/mode, latches, per-project phase
```

## Повседневность

- **Digest** - источник истины прохода: `~/.claude-control/canon/digest/<pass>.md`.
  Шапка `projects/ok/held/escalations`, per-project вердикты; для конфликтов -
  готовые resolve-команды. Алерт в TG шлется только при не-нейтральных вердиктах
  и только при смене картины (повторные проходы не флудят).
- **Релиз канона**: в claude-toolkit собрать `canon.lock.json`
  (`scripts/build-lock.py`), закоммитить В ДЕРЕВО, повесить annotated-тег
  `canon-vN`, запушить с тегом. CI-gate сверит lock; maintainer подхватит
  релиз следующим проходом.
- **Кольца**: canary -> snapshot -> rest; следующее кольцо мутируется только
  после applied предыдущего. PR мерджит человек - applied зафиксируется сам.
- **Harvester**: `approve` кандидата пинает maintainer сам (durable-маркер +
  systemctl). При упаковке правила в PR к канон-репо зарегистрировать путь
  И эталонные байты (в чекауте упаковщика):
  ```sh
  claude-agent-canon-maintainer cid-map <cid16> rules/<путь>.md \
    "$(git hash-object rules/<путь>.md)"
  ```
  После мерджа в канон скан (каждый проход once) замкнет pending, когда
  regular-файл по пути в HEAD совпадет с эталоном байт-в-байт. Правка правила
  до мерджа = перерегистрация (удалить запись из canon/cid-map.json руками);
  несовпадение/лишний тип объекта - только ручной `claude-agent-harvest
  mark-applied`.

## Разбор held-причин

| klass | Что случилось | Что делать |
|---|---|---|
| held-conflicts / held-rebase-conflict | delta не может применить (локальная правка против канона) | resolve-команды из digest (worktree живой); следующий проход увезет решение в PR |
| held-pr-closed | человек закрыл PR без мерджа | осознанно: оставить (канон не нужен проекту) либо удалить cursor `canon/state/<name>.json` для пересоздания |
| held-post-merge-mismatch | PR смерджен, но дерево != канону (правили при мердже) | разобрать руками: вернуть байты канона в main или ждать следующего релиза |
| held-foreign-commits | чужие коммиты в candidate-ветке/worktree | забрать работу человека (ветка/worktree целы), потом убрать ветку - проход пересоздаст |
| held-smoke | красный smoke кандидата; кольцо защелкнуто | чинить канон/проект; форс-перегон - удалить `canon/smoke/<name>.json`; снять защелку `ack` |
| held-smoke-timeout | smoke не уложился в таймаут | поднять `CLAUDE_CANON_SMOKE_TIMEOUT` или чинить команду; защелки нет |
| held-corrupt-cursor | битый `canon/state/<name>.json` | удалить/починить файл |
| held-dirty-clone | кто-то работал руками в `canon/repos/<name>` | убрать/закоммитить чужое, вернуть клон в чистое состояние |
| held-recovery | незавершенный WAL delta не терминализировался | `canon-delta.py --root <worktree> recover`, затем проход |
| held-migrate / needs-bootstrap | миграция canon.yaml упала / проект не подключен | смотреть stderr в detail; для needs-bootstrap - завести intent или canon.yaml |
| latched | breaker-защелка кольца (incompat/error/smoke) | причина в latches у `status`; после починки `ack <release> <ring>` |
| waiting-ring | штатно: ждет applied предыдущего кольца | мерджить PR предыдущего кольца |
| budget-exhausted | cap применений за проход | штатно рассосется следующими проходами; поднять `CLAUDE_CANON_BUDGET` при нужде |
| transient | сеть/gh/зеркало; повторится следующим проходом | ничего; если повторяется - смотреть detail |
| error | неожиданное исключение (изолировано per-project) | смотреть detail, лог journalctl |

## Break-glass

```sh
claude-agent-canon-maintainer rollback <project>   # откат на rollout_record[-2] PR-ом; ставит latch
claude-agent-canon-maintainer ack <release> <ring> # снять breaker-защелку
claude-agent-canon-maintainer disarm               # полный стоп мутаций
systemctl --user stop claude-agent-canon-maintainer.timer   # остановить и таймер
```

Принятые остаточные риски (codex-циклы T14/T31):

- (r2-Д2) гард чужой работы в worktree не атомарен с его сносом - не работать
  руками в `~/.claude-control/canon/worktrees/`; легальный ввод человека там -
  только `canon-delta resolve` по командам digest (в candidate- И
  rollback-worktree; свежий worktree переживает следующий проход).
- (r6) `rolled_back_from` в cursor снимает mismatch-гейт merged-истории для
  уже-откатанного релиза: повторная подмена дерева при мердже после отката
  деградирует в НОВЫЙ human-gated PR, а не в held (мутаций мимо PR нет).
- Зависший проход: `disarm` ждет лок `CLAUDE_CANON_LOCK_WAIT` (60с) и умирает
  exit 5 - тогда `systemctl --user stop claude-agent-canon-maintainer.service`
  и ПОВТОРИТЬ `disarm` (stop не пишет armed.json).
- Смена default-ветки канон-репо не двигает HEAD зеркала - при таком переезде
  пересоздать зеркало (`rm -rf ~/.claude-control/canon/mirror`, следующий
  проход клонирует заново).

## Логи

`journalctl --user -u claude-agent-canon-maintainer.service -n 100` -
JSON-строки: pass-start/release/project-verdict/pass-end, latch-set, cursor-cas-fail.
