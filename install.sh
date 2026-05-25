#!/usr/bin/env bash
# install.sh: set up claude-control on macOS.
#
#   ./install.sh             Copy bin/ scripts into ~/.local/bin/.
#   ./install.sh --link      Symlink bin/ scripts (useful when hacking on the repo).
#
# Other options:
#   --prefix DIR             Install scripts into DIR/bin/ instead of ~/.local/bin/.
#   --label LABEL            launchd Label prefix. Defaults to com.${USER}.claude-control.
#   --no-watchdog            Skip the watchdog unit (not recommended).
#   --dry-run                Print what would happen, do not touch the filesystem.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_MODE="copy"
PREFIX="$HOME/.local"
LABEL="com.${USER}.claude-control"
WATCHDOG=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --link)         INSTALL_MODE="link"; shift ;;
    --prefix)       PREFIX="$2"; shift 2 ;;
    --label)        LABEL="$2"; shift 2 ;;
    --no-watchdog)  WATCHDOG=0; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

BIN_DIR="$PREFIX/bin"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
CONTROL_DIR="$HOME/.claude-control"
WATCHDOG_LABEL="${LABEL}-watchdog"

say() { echo "==> $*"; }
# run() takes an argv array and execs it without a shell. Callers handle shell
# glue (|| true, &&) themselves on the call site, e.g. `run launchctl bootout ... || true`.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# --- prereq checks -----------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "claude-control currently supports macOS only (Linux/systemd is on the roadmap)." >&2
  exit 1
fi

missing=()
command -v tmux >/dev/null 2>&1   || missing+=("tmux")
command -v yq >/dev/null 2>&1     || missing+=("yq (mikefarah/yq)")
command -v claude >/dev/null 2>&1 || missing+=("claude (Claude Code CLI)")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing prerequisites:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  echo >&2
  echo "Install via Homebrew (brew install tmux yq) and Claude Code from" >&2
  echo "https://docs.claude.com/claude-code, then re-run this script." >&2
  exit 1
fi

if claude --version >/dev/null 2>&1; then
  ver="$(claude --version 2>/dev/null | head -1 || true)"
  say "Detected $ver"
fi

# --- layout ------------------------------------------------------------------

say "Repo:     $REPO_DIR"
say "Bin dir:  $BIN_DIR"
say "launchd:  $LAUNCHD_DIR"
say "Runtime:  $CONTROL_DIR"
say "Label:    $LABEL"
say "Mode:     $INSTALL_MODE"

run mkdir -p "$BIN_DIR" "$LAUNCHD_DIR" "$CONTROL_DIR"
# Tighten CONTROL_DIR so stdout/stderr logs (which may capture claude tokens
# in error paths) and projects.yaml aren't world-readable.
run chmod 700 "$CONTROL_DIR"

# --- bin scripts -------------------------------------------------------------

backup_existing() {
  local target="$1"
  if [[ -e "$target" && ! -L "$target" ]]; then
    local backup
    backup="$(mktemp -u "${target}.bak.XXXXXX")"
    run mv "$target" "$backup"
  elif [[ -L "$target" ]]; then
    run rm "$target"
  fi
}

install_script() {
  local name="$1"
  local src="$REPO_DIR/bin/$name"
  local dst="$BIN_DIR/$name"
  backup_existing "$dst"
  if [[ "$INSTALL_MODE" == "link" ]]; then
    run ln -s "$src" "$dst"
  else
    run cp "$src" "$dst"
    run chmod +x "$dst"
  fi
}

for script in claude-rc claude-control-session claude-control-watchdog; do
  install_script "$script"
done

# --- runtime files (examples, idempotent) -----------------------------------

copy_example_if_missing() {
  local src="$1"
  local dst="$2"
  if [[ -e "$dst" ]]; then
    say "Keeping existing $dst"
  else
    say "Seeding $dst from example"
    run cp "$src" "$dst"
  fi
}

copy_example_if_missing "$REPO_DIR/examples/projects.yaml.example" \
                        "$CONTROL_DIR/projects.yaml"
copy_example_if_missing "$REPO_DIR/examples/control-CLAUDE.md.example" \
                        "$CONTROL_DIR/CLAUDE.md"

run mkdir -p "$CONTROL_DIR/.claude"
run chmod 700 "$CONTROL_DIR/.claude"
copy_example_if_missing "$REPO_DIR/examples/control-settings.local.json.example" \
                        "$CONTROL_DIR/.claude/settings.local.json"

# --- launchd plists ----------------------------------------------------------

render_plist() {
  local tmpl="$1"
  local out="$2"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: render $tmpl -> $out"
    return
  fi
  backup_existing "$out"
  sed \
    -e "s|__LABEL__|${LABEL}|g" \
    -e "s|__WATCHDOG_LABEL__|${WATCHDOG_LABEL}|g" \
    -e "s|__BIN_DIR__|${BIN_DIR}|g" \
    -e "s|__CONTROL_DIR__|${CONTROL_DIR}|g" \
    "$tmpl" > "$out"
}

bootout_if_loaded() {
  local label="$1"
  if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
    run launchctl bootout "gui/$UID/$label" || true
    # launchd needs a moment to release the slot before bootstrap can reuse it.
    [[ $DRY_RUN -eq 0 ]] && sleep 1
  fi
}

# bootstrap is racy right after a bootout — sometimes the slot is still held
# and launchctl returns one of several transient errors depending on macOS
# version: "Input/output error", "Operation now in progress", "Resource busy",
# "Bad file descriptor". Retry on any of those before giving up.
bootstrap_unit() {
  local plist="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: launchctl bootstrap 'gui/$UID' '$plist'"
    return
  fi
  local err
  err="$(mktemp -t launchctl_err)" || { echo "mktemp failed" >&2; return 1; }
  local attempt
  for attempt in 1 2 3; do
    if launchctl bootstrap "gui/$UID" "$plist" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    if grep -qiE '(in progress|input/output error|busy|bad file descriptor)' "$err"; then
      echo "    bootstrap transient error on attempt $attempt, retrying..." >&2
      sleep 2
      continue
    fi
    cat "$err" >&2
    rm -f "$err"
    return 1
  done
  echo "bootstrap failed after 3 attempts for $plist" >&2
  cat "$err" >&2
  rm -f "$err"
  return 1
}

CONTROL_PLIST="$LAUNCHD_DIR/${LABEL}.plist"
render_plist "$REPO_DIR/launchd/com.USER.claude-control.plist.tmpl" "$CONTROL_PLIST"
bootout_if_loaded "$LABEL"
bootstrap_unit "$CONTROL_PLIST"

if [[ $WATCHDOG -eq 1 ]]; then
  WATCHDOG_PLIST="$LAUNCHD_DIR/${WATCHDOG_LABEL}.plist"
  render_plist "$REPO_DIR/launchd/com.USER.claude-control-watchdog.plist.tmpl" "$WATCHDOG_PLIST"
  bootout_if_loaded "$WATCHDOG_LABEL"
  bootstrap_unit "$WATCHDOG_PLIST"
fi

# --- done --------------------------------------------------------------------

cat <<EOF

Done.

Next steps:
  1. Edit $CONTROL_DIR/projects.yaml and list the projects you want to expose.
  2. Make sure '$BIN_DIR' is on your PATH (add it to your shell profile if not).
  3. From the Claude mobile app or claude.ai/code, open Code -> session "control".
     Say: "lift <project-name>". The control session will run claude-rc for you.

Tail the control log:
  tail -f $CONTROL_DIR/control.log
EOF
