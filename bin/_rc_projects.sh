#!/usr/bin/env bash
# _rc_projects.sh: единственный резолвер схемы projects.yaml.
#
# Форма A (сегодняшняя, плоская): `<name>: <path>`.
# Форма B (объектная): `<name>: {path: ..., integrate: merge|pr|none}`.
# Обе валидны одновременно - см.
# docs/design-2026-07-26-v2.7b-acceptance-integration.md §1.
#
# Sourced-хелпер для bash (`. bin/_rc_projects.sh`). Питоновская сторона
# (фаза integrate) зовёт его тем же выражением подпроцессом, не заводя
# вторую копию: `sh -c '. bin/_rc_projects.sh; project_path "$1"' _ <name>`.
#
# Каждая функция принимает <name> и, вторым (опциональным) аргументом, путь
# к projects.yaml; без него берёт дефолт, общий с claude-rc/claude-rc-agent.
_rc_projects_default_file() {
  printf '%s' "${CLAUDE_RC_PROJECTS_FILE:-$HOME/.claude-control/projects.yaml}"
}

# project_path <name> [file]
# Путь проекта: форма A - как есть; форма B - .path (пусто, если поля нет).
# Незарегистрированное имя - тоже пусто.
# mikefarah yq не знает jq-style if/then/else (см. claude-rc:164) -
# форма различается через select(tag == "!!map") и фолбэки через //.
project_path() {
  local name="$1" file="${2:-$(_rc_projects_default_file)}"
  # shellcheck disable=SC2016
  name="$name" yq -r \
    '.[strenv(name)] as $v | ($v | select(tag == "!!map") | .path // "") // ($v // "")' \
    "$file"
}

# project_integrate <name> [file]
# Режим интеграции: форма B - .integrate; форма A - пусто (дефолт "none"
# решает вызывающий, см. §1 п.4). Код возврата: 0 - имя есть в реестре
# (значение может быть пустым для формы A/без .integrate); 1 - имени нет в
# реестре вовсе. "Нет в реестре" и "есть, режим не задан" - разные исходы
# (§1 п.3): пропавший ключ (переименовали, снесли файл) обязан отличаться от
# формы A кодом возврата, а не сливаться в одну и ту же пустую строку.
# Форма B без .path - ТОЖЕ "нет в реестре" (аудит блокер 5): мапа без path
# не идентифицирует проект, и вызывающий не должен принять ее за валидную
# регистрацию только потому, что ключ присутствует.
project_integrate() {
  local name="$1" file="${2:-$(_rc_projects_default_file)}"
  # shellcheck disable=SC2016
  local present
  present=$(name="$name" yq -r '.[strenv(name)] != null' "$file")
  [ "$present" = "true" ] || return 1
  # shellcheck disable=SC2016
  local is_map
  is_map=$(name="$name" yq -r '.[strenv(name)] | tag == "!!map"' "$file")
  if [ "$is_map" = "true" ]; then
    [ -n "$(project_path "$name" "$file")" ] || return 1
  fi
  # shellcheck disable=SC2016
  name="$name" yq -r \
    '.[strenv(name)] as $v | ($v | select(tag == "!!map") | .integrate // "") // ""' \
    "$file"
}

# project_names [file]
# Список имён проектов (верхнеуровневые ключи) - одинаков для обеих форм.
project_names() {
  local file="${1:-$(_rc_projects_default_file)}"
  yq -r 'keys | .[]' "$file"
}

# project_lessons_path <name> [file]
# АБСОЛЮТНЫЙ путь к файлу уроков проекта (V2.9 §6, аудит блокер 4): форма B -
# .lessons (дефолт ".claude/rules/lessons.md", если поле пусто/отсутствует),
# склеенный с project_path и провалидированный на вложенность в корень
# проекта ПОСЛЕ РАЗРЕШЕНИЯ СИМЛИНКОВ; форма A - всегда дефолт (нет
# отдельного поля для лишних свойств). Возвращается уже готовый абсолютный
# путь - вызывающий не склеивает его с project_path сам (склейка на стороне
# вызывающего была бы вторым резолвером схемы через черный ход, §6). Код
# возврата: 0 - путь резолвится и лежит внутри проекта; 1 - имени нет в
# реестре, форма B без .path (не идентифицирует проект - та же граница, что
# у project_integrate), .lessons - абсолютное значение в реестре, либо
# резолвенный путь (после realpath -m) уходит ЗА пределы корня проекта
# (traversal ../, симлинк-каталог наружу) - отказ, а не запись куда попало.
project_lessons_path() {
  local name="$1" file="${2:-$(_rc_projects_default_file)}"
  local proj
  proj=$(project_path "$name" "$file")
  [ -n "$proj" ] || return 1
  local raw
  # shellcheck disable=SC2016
  raw=$(name="$name" yq -r \
    '.[strenv(name)] as $v | ($v | select(tag == "!!map") | .lessons // "") // ""' \
    "$file")
  raw="${raw:-.claude/rules/lessons.md}"
  case "$raw" in
    /*) return 1 ;;  # абсолютное значение в реестре - отказ, не подмена корня
  esac
  local proj_real abs
  proj_real=$(realpath -m -- "$proj") || return 1
  abs=$(realpath -m -- "$proj_real/$raw") || return 1
  case "$abs" in
    "$proj_real"/*) : ;;
    *) return 1 ;;  # ../ или симлинк увели путь за пределы корня проекта
  esac
  printf '%s' "$abs"
}

# project_lessons_relpath <name> [file]
# ОБЪЯВЛЕННЫЙ в реестре путь зеркала уроков ОТНОСИТЕЛЬНО корня проекта, без
# канонизации (V2.10 §3.2, аудит серьезная 6). Отдельная функция, а не
# производная от project_lessons_path: та отдает путь после `realpath -m`, и
# если зеркало окажется симлинком на файл внутри того же проекта, вернет путь
# ЦЕЛИ - исключение из грязи вычло бы посторонний файл, который правил человек.
# Потребителю исключения нужен именно лексический путь, а симлинки он обязан
# отвергнуть сам (проверкой компонентов), поэтому здесь только разбор схемы
# реестра плюс лексическая валидация.
# Коды: 0 - путь на stdout; 1 - имени нет в реестре, форма B без .path, либо
# значение непригодно (абсолютное, пустое, уходит за корень через ../).
project_lessons_relpath() {
  local name="$1" file="${2:-$(_rc_projects_default_file)}"
  local proj
  proj=$(project_path "$name" "$file")
  [ -n "$proj" ] || return 1
  local raw
  # shellcheck disable=SC2016
  raw=$(name="$name" yq -r \
    '.[strenv(name)] as $v | ($v | select(tag == "!!map") | .lessons // "") // ""' \
    "$file")
  raw="${raw:-.claude/rules/lessons.md}"
  case "$raw" in
    /*) return 1 ;;   # абсолютное значение в реестре - отказ, как и выше
  esac
  # лексическая нормализация без обращения к ФС: `realpath -m` тут нельзя -
  # он же и канонизирует симлинки, ради чего вся функция и заведена.
  local norm
  norm=$(printf '%s' "$raw" | python3 -c '
import posixpath, sys
p = posixpath.normpath(sys.stdin.read().strip())
sys.stdout.write("" if p in (".", "") or p.startswith("../") or p == ".." else p)
') || return 1
  [ -n "$norm" ] || return 1
  printf '%s' "$norm"
}
