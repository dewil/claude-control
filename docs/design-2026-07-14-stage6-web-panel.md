# Этап 6: веб-панель управления парком (высокоуровневый план)

Этап "по желанию" из [plan-2026-07-10](plan-2026-07-10-autonomous-agents.md) (строка 194). Высокоуровневый план и ключевые решения приняты dwl 2026-07-14; реализация отложена (не активный этап). Документ - чтобы решения не потерялись.

## Решение по каналу: вариант D - локальная морда прямо на llm

llm имеет **прямой публичный IP `161.104.35.228`, NAT нет** (см. memory `project_llm_vm_selectel`). Панель живёт целиком на llm, **ни от кого не зависит**: без Cloudflare Tunnel, без reverse-tunnel на хост метрик.

Отвергнутые варианты (судейская панель + разбор прецедента хост метрик):
- **Cloudflare Tunnel + Access** - изолирует поверхность, но зависимость от CF как канала И identity. dwl выбрал независимость.
- **хост метрик reverse/forward-tunnel** (паттерн bot-sm2-adm: `ssh -L` на alp2 -> nginx+LE+basic) - переиспользует готовое, но тащит shared-хост метрик (50+ сайтов) в цепь доверия control-plane; для управления парком неприемлемо.

**Сеть:** сейчас на llm `ufw deny incoming` кроме `22` и `22000` (Syncthing) - бокс держится "без веба". Веб-морда = первый inbound веб-сервис; **порт открыть в ufw явно** (напр. высокий порт, не :443, чтобы не палиться сканерам). fail2ban на llm уже стоит.

## Решение по auth: app-логин + TOTP (2FA)

Свой экран входа: пароль + одноразовый TOTP-код (любой authenticator), cookie-сессия. Self-contained.

Отвергнутые:
- **mTLS (клиентский серт)** - строго сильнее по поверхности (без серта TLS-handshake отклоняется, порт невидим), но dwl выбрал против из-за UX установки серта на телефон.
- **Basic Auth** (как хост метрик) - слабее, один фактор.

**Следствие выбора:** TOTP не прячет порт (в отличие от mTLS) - сервис отвечает на коннекты, виден сканерам. Компенсация: fail2ban (есть) + app-rate-limit на логин + высокий нестандартный порт + PIN/повторный TOTP на деструктивные мутации.

## Архитектура (общая для всех фаз)

- **Стек лёгкий:** один python-процесс уровня tgbot (FastAPI+uvicorn single-worker, ~40-80 MB) в бюджет ~1.3 GB свободной RAM. 2 vCPU делятся с агентами - без тяжёлого рендера.
- **Непривилегированный юзер** `claude-panel` **без read-доступа к OAuth-токену парка** (`~/.claude`, 0600, owner - token-user). Web-RCE в панели даёт максимум мутации через claude-rc (контейнится autonomy-капами в spec + append-only events.jsonl), не эксфильтрацию токена. systemd-sandbox на юните (`ProtectSystem`, `NoNewPrivileges`, `MemoryMax`).
- **На корневой ФС** - панель поднимается ДО разлочки LUKS, отдаёт реестр (список парка, control.json, spec, mission.md), работают pause/stop (только control.json). Вьюхи по /data (diff, claim_artifact, worktree) - под баннером "LUKS заперт". Пассфразу панель НЕ хранит.
- **Чтение парка:** реестр `~/.claude-control/agents/<name>/*` + `claude-rc agent list/status`. Health-классификация от reconciler. `status_line` от агента - **недоверенные данные, HTML-эскейп всегда**.
- **Мутации:** только через `claude-rc agent <verb>` (start/pause/stop/accept/reject/...) - CAS в control.json, не переизобретать flock-инвариант. PIN/повторный TOTP на деструктив (stop/reject/revoke-role), confirm-диалог, аудит в events.jsonl.

## Фазы

- **MVP read-only (~6-10 ч):** ufw-порт + `claude-panel.service` (FastAPI+Jinja, read-only дашборд: парк, health, phase, cost, attention, heartbeat, эскейпленный status_line) + app-логин с TOTP. Готово: с телефона из РФ открывается URL, вход по паролю+TOTP, виден живой парк.
- **v1 мутации (~6-10 ч):** POST-обёртки над `claude-rc agent <verb>`, PIN/TOTP на деструктив, confirm, аудит, LUKS-баннеры и гейт /data-вьюх, диплинк на remote-control сессию по session_id.
- **v2 полировка (~10-16 ч):** SSE/inotify вместо polling, PWA-манифест + service worker (иконка на телефоне), web-push через `CLAUDE_AGENT_ALERT_CMD`, rate-limit.

## Что панель НЕ делает

- **Не переизобретает наставление в живую миссию** - это обычное сообщение в remote-control сессию через claude.ai/code relay (телефон уже достаёт); максимум диплинк на сессию.
- **Не пишет control.json сама** - только через claude-rc (иначе рушится CAS/flock).
- **Не хранит LUKS-пассфразу** - разлочка /data остаётся ручной `ssh llm`.
- **Не заводит БД** - состояние это файлы реестра.

## Связано

- Прецедент паттерна ssh-tunnel+панель: хост метрик `bot-sm2-adm.alp.dewil.ru` (forward `-L` на alp2, nginx+LE+basic-auth).
- [design-2026-07-11-agent-state-machine.md](design-2026-07-11-agent-state-machine.md) - реестр агента, поля для дашборда.
- Мутационный API - `claude-rc agent <verb>` (тот же путь, что у CLI и tgbot).
