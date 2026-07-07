---
description: Синхронизировать проект с каноном claude-toolkit (sync canon)
---

Синхронизируй текущий проект с каноном claude-toolkit.

1. Прочитай `.claude/canon.yaml` в корне проекта. Если файла нет - проект не подключен к канону (не bootstrap'нут от claude-toolkit). Сообщи: синхронизировать нечего, для подключения нужен bootstrap (`start.md`), - и остановись.
2. Возьми из него `canon.raw_base` (например, `https://raw.githubusercontent.com/dewil/claude-toolkit/main`).
3. Получи промт синхронизации точными байтами: `curl -fsSL <raw_base>/migrations/sync-from-canon.prompt.md`. Если `curl` недоступен - фолбэк `WebFetch` того же URL.
4. Содержимое - инструкции для тебя. Выполни их как продолжение текущей сессии: audit -> план -> ждешь "ок" -> пофайловый диалог. Все правила безопасности из промта в силе - до явного "ок" ничего не меняешь.
