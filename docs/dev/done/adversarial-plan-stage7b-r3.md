# Состязательное ревью, раунд 3: дизайн 7b harvester v3 (read-only)

Первой строкой: `session id: <id>`.

Та же сессия. Раунд 2 дал 10 находок; я переписал в v3. Ключевое v3 -
явный **threat-model**: harvest это advisory-пайплайн, агентная плоскость
НЕДОВЕРЕННА, граница безопасности = human review перед canon-export, `actor`
= advisory (не аутентифицируем). Это осознанное решение, не недосмотр.

## Что изменено против раунда 2

`docs/design-2026-07-13-stage7b-harvester.md` (v3, прочитай целиком).
Правки по твоим находкам раунда 2:

1. Д0 "атомарно" -> убрано слово; честный best-effort.
2. project key -> `sha1(realpath)` (не lossy slug); incarnation-id ->
   durable random hex в control.json; correction-id из `json.dumps([...])`
   (не `|`-склейка) от MASKED note.
3. legacy-роли -> collector валидирует роль при чтении, невалидную
   пропускает.
4. `actor=operator` -> НЕ аутентифицируем; threat-model честно объявляет
   агентную плоскость недоверенной, security-граница = human gate.
5. redaction -> ВСЕ экспортные поля (note, reject/dismiss reason, brief);
   correction-id из masked (не сырой sha1(note)).
6. валидатор -> disjoint-кластеры + механическая проверка >=2 разных
   incarnation + evidence (сырые masked-тексты) в дайджесте для human gate.
7. lifecycle -> КОНЕЧНЫЙ: applied/dismissed терминальны; pending-upstream
   имеет выходы applied/upstream-rejected; upstream-rejected возвращает ids
   с essence-memory.
8. approve -> идемпотентный self-healing (re-run = recovery), canon.lock
   flock; НЕ ACID (явно принято).
9. граница role/ -> no-follow: realpath assert (в намеренном корне И НЕ в
   agents/), O_NOFOLLOW запись; symlink upstream-pending->role не даёт записи.
10. delivery-критерий -> усилен (2 disjoint-кластера, перефразировка,
    стабильность candidate_id, инъекция).

## Задача раунда 3 (форсируем сходимость)

По КАЖДОМУ блокеру раунда 2 - вердикт: закрыт / закрыт частично / не закрыт.
Затем главное: раздели ВСЁ оставшееся на две группы -
- **TRUE-БЛОКЕР**: делает дизайн некорректным/небезопасным ДАЖЕ в заявленной
  threat-model (advisory + human gate). Нельзя начинать код.
- **ПРИЕМЛЕМО-v1**: реальный, но при human-gate + принятых остаточных
  рисках не мешает начать код (можно закрыть в коде/тестах или отложить).

Не засчитывай как блокер то, что дизайн УЖЕ явно принял как остаточный риск
с обоснованием (раздел "Остаточные риски") - если обоснование НЕверно,
объясни почему; если верно - это ПРИЕМЛЕМО-v1, не блокер.

## Ломай прицельно

- Threat-model: реально ли human gate + LLM-без-рук + no-follow закрывают
  недоверенный вход, или остаётся путь, где враждебный агент добивается
  БОЛЬШЕГО, чем шум в дайджесте (запись в canon/role/исполнение без
  человека)?
- Incarnation-id: durable random hex в control.json - collector точно его
  читает из ТЕКУЩЕГО control.json, а не из событий; пересоздание фиксит
  коллизию?
- no-follow assert Д11: realpath(target) в намеренном корне И не в agents/
  - есть ли TOCTOU между assert и записью, дающий побег в role/?
- Lifecycle Д8: точно конечен, или есть цикл proposed->upstream-rejected->
  proposed бесконечно (essence-memory реально гасит переэмиссию)?
- approve self-healing Д9: re-run после крэша - есть ли состояние, из
  которого re-run НЕ сходится (canon.yaml повреждён частичной записью)?

НЕ репортить: стиль; отложенные (b)/(c); "добавьте тест" (критикуй
достаточность).

## Формат

Вердикты по блокерам р2 + разделение оставшегося на TRUE-БЛОКЕР /
ПРИЕМЛЕМО-v1. Итог одной строкой: можно ли начинать код (да / да с
закрытием TRUE-блокеров списком / нет).

READ-ONLY: только отчёт.
