# Runbook: дайджест лимитов LLM (claude-agent-limits-digest)

Каждые 30 минут в Telegram (личка оператора через `claude-agent-tgbot`)
приходит текстовая панель с остатком подписочных лимитов Claude Code и Codex.
Все в одной коробке на llm VM: пробник снимает проценты у провайдеров,
форматтер рендерит панель, отправка - через `claude-agent-tgbot notify`.
Перенесено из webapp (там жили приемник снапшота и PHP-форматтер) -
истории см. git и `docs/dev/done/handoff-limits-digest-to-claude-control.md`.

```
llm VM:  claude-agent-limits-digest.timer (*/30)
           -> once: пробник (Claude oauth/usage, Codex wham/usage; через mihomo 7890)
              -> кэш ~/.claude-control/limits/last.json
              -> панель -> claude-agent-tgbot notify --pre -> личка оператора
/limits в tgbot -> render из кэша (вне расписания)
```

Токены провайдеров НЕ покидают VM и НЕ попадают ни в снапшот, ни в панель -
только проценты остатка и время сброса.

## Env (все опциональны, дефолты под llm VM)

`~/.config/claude-control/env`: `CLAUDE_AGENT_LIMITS_TZ` (Europe/Moscow),
`CLAUDE_AGENT_LIMITS_ENABLED` (рубильник, "0" = не слать),
`CLAUDE_AGENT_LIMITS_STALE_MIN` (45), `LIMITS_PROBE_PROXY`
(http://127.0.0.1:7890), `LIMITS_PROBE_CLAUDE_CREDS`, `LIMITS_PROBE_CODEX_AUTH`,
`LIMITS_PROBE_DATA_MOUNT`, `LIMITS_PROBE_CLAUDE_UA`. Отправка использует
`CLAUDE_AGENT_TG_TOKEN` / `_WHITELIST` / `_PROXY` бота.

## Асимметрия хранения токенов (важно)

- **claude-токен на КОРНЕ** (`~/.claude/.credentials.json`) - виден всегда.
- **codex-auth на LUKS-томе** (`/data/.codex/auth.json`) - только при
  примонтированном `/data` (`ssh -t llm-root /usr/local/sbin/unlock-data`).

Заперт том -> секция Codex показывает `том /data заперт, codex недоступен`,
дайджест продолжает приходить - это и напоминание разлочить. Таймер от
маунта не зависит.

## Статус `stale` ("токен протух, нужен прогон CLI")

Пробник токены НЕ рефрешит (ротация refresh-токена может сбить активную
сессию). Лечение:

- Claude: `ssh -t llm claude` - любой запрос, токен освежится в файле.
- Codex: сначала `unlock-data`, затем прогон codex; при полном протухании -
  `codex login` заново (прокси + `CODEX_HOME=/data/.codex` + туннель
  callback-порта).

## Диагностика

- Панель без отправки: `set -a; . ~/.config/claude-control/env; set +a;
  claude-agent-limits-digest once --dry-run`.
- Из кэша (что покажет /limits): `claude-agent-limits-digest render`.
- Логи: `journalctl --user -u claude-agent-limits-digest.service -n 50`.
- Таймер: `systemctl --user list-timers | grep limits`.
- Оффлайн-тесты форматтера: `tests/test-agent-limits-digest.sh`.
- `ошибка снятия лимитов` (error) - чаще всего лег mihomo (7890) или
  провайдер вернул не-200: смотреть stderr в journalctl.

## Rate-limit

Claude usage-эндпоинт ~1 запрос/180с - таймер */30 с запасом, чаще не делать.
`/limits` в боте читает кэш и провайдеров не дергает.
