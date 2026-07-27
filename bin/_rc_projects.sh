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
