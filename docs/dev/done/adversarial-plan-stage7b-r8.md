# Ревью, раунд 8: закрытие 2 edge-case r7 (read-only, тугая рамка)

Первой строкой: `session id: <id>`.

Та же сессия. r7 дал НЕТ из-за ДВУХ edge-case. Я их закрыл. Проверь ТОЛЬКО эти
два + отсутствие регрессии. НЕ переоткрывай закрытое в r5/r6/r7, НЕ ищи атаки
вне модели (ошибки, не злоумышленник).

## Два закрытия (`bin/claude-agent-harvest`)

1. **reject self-heal fsync (r7 п.1)** - `_remove_brief` переписан: unlink (если
   файл есть) + `fsync каталога ВСЕГДА`, в т.ч. когда brief УЖЕ отсутствует (был
   ранний return без fsync). Теперь при сценарии: (1) unlink ok, (2) fsync падает
   -> die(7), (3) re-run: brief уже нет, но fsync каталога ВЫПОЛНЯЕТСЯ снова ->
   недолговечный unlink становится durable, и только тогда canon-очистка +
   статус. Проверь: повторный reject после сбоя fsync доводит durability; нет
   пути, где статус upstream-rejected при неdurable unlink; `os.path.isdir(d)`
   guard не глушит нужный fsync (каталог брифа существует после approve).

2. **incarnation unreadable control (r7 п.2)** - `agent_incarnation`
   переструктурирован: `if isinstance(ctrl, dict):` -> ключ есть: hex32/None;
   ключа нет: legacy `agent_created`. Если `ctrl` НЕ dict (control.json
   отсутствует/непарсибелен, `read_json_file` вернул None) -> `return None`
   (агент ПРОПУСКАЕТСЯ, НЕ legacy). Проверь: непарсибельный/отсутствующий
   control.json больше НЕ даёт legacy fallback (не переключает идентичность);
   legacy-агент 1-7 (parseable dict БЕЗ ключа) всё ещё -> agent_created;
   валидный hex32 -> он.

## Итог одной строкой

Оба закрыты, регрессии нет - коммитить и катить на VM: ДА / НЕТ (с файл:строкой
незакрытого). Если остаточный риск объективно приемлем в модели "ошибки, не
злоумышленник" - назови ПРИЕМЛЕМО-v1, не блокер.

READ-ONLY: только отчёт, файлы не менять.
