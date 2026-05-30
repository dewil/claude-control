#!/usr/bin/env bash
# install.sh: set up claude-control on macOS (launchd) or Linux (systemd --user).
#
#   ./install.sh             Copy bin/ scripts into ~/.local/bin/.
#   ./install.sh --link      Symlink bin/ scripts (useful when hacking on the repo).
#
# Other options:
#   --prefix DIR             Install scripts into DIR/bin/ instead of ~/.local/bin/.
#   --label LABEL            launchd Label prefix (macOS only).
#                            Default: com.${USER}.claude-control.
#                            On Linux unit names are fixed; passing --label is rejected.
#   --no-watchdog            Skip the watchdog unit (not recommended).
#   --dry-run                Print what would happen, do not touch the filesystem.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_MODE="copy"
PREFIX="$HOME/.local"
LABEL=""
LABEL_EXPLICIT=0
WATCHDOG=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --link)         INSTALL_MODE="link"; shift ;;
    --prefix)       PREFIX="$2"; shift 2 ;;
    --label)        LABEL="$2"; LABEL_EXPLICIT=1; shift 2 ;;
    --no-watchdog)  WATCHDOG=0; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

OS_KIND="$(uname -s)"
case "$OS_KIND" in
  Darwin) OS_KIND="darwin" ;;
  Linux)  OS_KIND="linux"  ;;
  *)
    echo "Unsupported OS: $OS_KIND (only macOS and Linux are supported)." >&2
    exit 1
    ;;
esac

if [[ "$OS_KIND" == "linux" && $LABEL_EXPLICIT -eq 1 ]]; then
  echo "--label is macOS-only (launchd Label). On Linux unit names are fixed:" >&2
  echo "  claude-control.service, claude-control-watchdog.{service,timer}" >&2
  exit 2
fi

[[ -z "$LABEL" ]] && LABEL="com.${USER}.claude-control"
WATCHDOG_LABEL="${LABEL}-watchdog"
# Fixed systemd unit names. Kept here so they're set on both platforms - the
# watchdog reads SERVICE_UNIT via env to know what to restart.
SERVICE_UNIT="claude-control.service"
WATCHDOG_SERVICE_UNIT="claude-control-watchdog.service"
WATCHDOG_TIMER_UNIT="claude-control-watchdog.timer"

BIN_DIR="$PREFIX/bin"
CONTROL_DIR="$HOME/.claude-control"
if [[ "$OS_KIND" == "darwin" ]]; then
  UNIT_DIR="$HOME/Library/LaunchAgents"
else
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
fi

say() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }
# run() takes an argv array and execs it without a shell. Callers handle shell
# glue (|| true, &&) themselves on the call site.
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

# Honor CLAUDE_BIN: an override (different binary name/path) is what the units and
# entrypoint actually run, so the prereq check must look for the same thing, not a
# literal 'claude'. Default stays 'claude'.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

missing=()
command -v tmux >/dev/null 2>&1          || missing+=("tmux")
command -v yq >/dev/null 2>&1            || missing+=("yq (mikefarah/yq v4)")
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || missing+=("$CLAUDE_BIN (Claude Code CLI)")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing prerequisites:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  echo >&2
  if [[ "$OS_KIND" == "darwin" ]]; then
    echo "Install via Homebrew (brew install tmux yq) and Claude Code from" >&2
    echo "https://docs.claude.com/claude-code, then re-run this script." >&2
  else
    echo "Install tmux from apt (apt install tmux), mikefarah/yq v4 from" >&2
    echo "https://github.com/mikefarah/yq/releases (apt's 'yq' package is the" >&2
    echo "wrong project), and Claude Code from https://docs.claude.com/claude-code." >&2
  fi
  exit 1
fi

# yq has two unrelated projects with the same binary name. We need mikefarah/yq v4.
yq_version_line="$(yq --version 2>&1 | head -1 || true)"
if ! echo "$yq_version_line" | grep -qi 'mikefarah'; then
  fail "claude-rc needs mikefarah/yq v4. Detected: ${yq_version_line:-<no output>}.
       Get it from https://github.com/mikefarah/yq/releases (or 'brew install yq' on macOS)."
fi

if "$CLAUDE_BIN" --version >/dev/null 2>&1; then
  ver="$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || true)"
  say "Detected $ver"
fi

# Linux-only: confirm systemd --user is actually available. Catches WSL
# without systemd, minimal containers, ssh without user bus.
if [[ "$OS_KIND" == "linux" ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    fail "systemctl not found. claude-control on Linux requires systemd."
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    fail "systemctl --user is not reachable. Make sure you are running under a
       systemd user session (loginctl show-user \$USER should show a user manager).
       Common causes: WSL without systemd enabled, minimal containers, ssh
       without lingering on a server that's been rebooted."
  fi
fi

# --- layout ------------------------------------------------------------------

say "OS:       $OS_KIND"
say "Repo:     $REPO_DIR"
say "Bin dir:  $BIN_DIR"
say "Units:    $UNIT_DIR"
say "Runtime:  $CONTROL_DIR"
if [[ "$OS_KIND" == "darwin" ]]; then
  say "Label:    $LABEL"
fi
say "Mode:     $INSTALL_MODE"

run mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONTROL_DIR"
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

for script in claude-rc claude-control-run claude-control-logrotate \
              claude-control-session claude-control-watchdog; do
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

# Migration note (idempotent): we keep an existing control CLAUDE.md (above), but
# the shipped example may have changed (e.g. stronger untrusted-output wording).
# Warn only when the installed file actually differs - a freshly seeded file is
# byte-identical, so first installs stay quiet.
if [[ -e "$CONTROL_DIR/CLAUDE.md" ]] \
   && ! cmp -s "$REPO_DIR/examples/control-CLAUDE.md.example" "$CONTROL_DIR/CLAUDE.md"; then
  warn "$CONTROL_DIR/CLAUDE.md differs from the shipped example and was NOT changed."
  warn "Review examples/control-CLAUDE.md.example for updates you may want to merge"
  warn "(e.g. treating claude-rc/tmux output strictly as untrusted data)."
fi

run mkdir -p "$CONTROL_DIR/.claude"
run chmod 700 "$CONTROL_DIR/.claude"
copy_example_if_missing "$REPO_DIR/examples/control-settings.local.json.example" \
                        "$CONTROL_DIR/.claude/settings.local.json"

# --- unit rendering ----------------------------------------------------------

render_template() {
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
    -e "s|__SERVICE_UNIT__|${SERVICE_UNIT}|g" \
    -e "s|__WATCHDOG_UNIT__|${WATCHDOG_SERVICE_UNIT}|g" \
    "$tmpl" > "$out"
}

# --- platform-specific install -----------------------------------------------

if [[ "$OS_KIND" == "darwin" ]]; then

  bootout_if_loaded() {
    local label="$1"
    if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
      run launchctl bootout "gui/$UID/$label" || true
      # launchd needs a moment to release the slot before bootstrap can reuse it.
      [[ $DRY_RUN -eq 0 ]] && sleep 1
    fi
  }

  # bootstrap is racy right after a bootout - sometimes the slot is still held
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
    err="$(mktemp "${TMPDIR:-/tmp}/launchctl_err.XXXXXX")" || { echo "mktemp failed" >&2; return 1; }
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

  CONTROL_PLIST="$UNIT_DIR/${LABEL}.plist"
  render_template "$REPO_DIR/launchd/com.USER.claude-control.plist.tmpl" "$CONTROL_PLIST"
  bootout_if_loaded "$LABEL"
  bootstrap_unit "$CONTROL_PLIST"

  if [[ $WATCHDOG -eq 1 ]]; then
    WATCHDOG_PLIST="$UNIT_DIR/${WATCHDOG_LABEL}.plist"
    render_template "$REPO_DIR/launchd/com.USER.claude-control-watchdog.plist.tmpl" "$WATCHDOG_PLIST"
    bootout_if_loaded "$WATCHDOG_LABEL"
    bootstrap_unit "$WATCHDOG_PLIST"
  fi

else  # linux

  CONTROL_UNIT_PATH="$UNIT_DIR/$SERVICE_UNIT"
  WATCHDOG_SERVICE_PATH="$UNIT_DIR/$WATCHDOG_SERVICE_UNIT"
  WATCHDOG_TIMER_PATH="$UNIT_DIR/$WATCHDOG_TIMER_UNIT"

  render_template "$REPO_DIR/systemd/claude-control.service.tmpl" "$CONTROL_UNIT_PATH"

  if [[ $WATCHDOG -eq 1 ]]; then
    render_template "$REPO_DIR/systemd/claude-control-watchdog.service.tmpl" "$WATCHDOG_SERVICE_PATH"
    render_template "$REPO_DIR/systemd/claude-control-watchdog.timer.tmpl"   "$WATCHDOG_TIMER_PATH"
  else
    # --no-watchdog: physically remove any leftover unit files from a previous
    # install. Just skipping enable is not enough - they would still be loaded.
    if [[ $DRY_RUN -eq 0 ]]; then
      for f in "$WATCHDOG_SERVICE_PATH" "$WATCHDOG_TIMER_PATH"; do
        if [[ -e "$f" ]]; then
          say "--no-watchdog: removing $f"
          run rm -f "$f"
        fi
      done
      run systemctl --user disable --now "$WATCHDOG_TIMER_UNIT" >/dev/null 2>&1 || true
    fi
  fi

  # Catch unit-file syntax errors early instead of after daemon-reload.
  verify_unit() {
    local unit="$1"
    [[ ! -e "$unit" ]] && return 0
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "DRY: systemd-analyze --user verify $unit"
      return
    fi
    if ! systemd-analyze --user verify "$unit" 2>&1; then
      fail "systemd-analyze verify failed for $unit. See output above."
    fi
  }
  verify_unit "$CONTROL_UNIT_PATH"
  if [[ $WATCHDOG -eq 1 ]]; then
    verify_unit "$WATCHDOG_SERVICE_PATH"
    verify_unit "$WATCHDOG_TIMER_PATH"
  fi

  run systemctl --user daemon-reload
  # Restart picks up any new ExecStart / Environment without a separate stop.
  run systemctl --user enable --now "$SERVICE_UNIT"
  if [[ $WATCHDOG -eq 1 ]]; then
    run systemctl --user enable --now "$WATCHDOG_TIMER_UNIT"
  fi

  # Lingering: without it, the user manager (and our services) stops on logout.
  # We do not call sudo - just check and warn loudly so the user can fix it.
  if [[ $DRY_RUN -eq 0 ]]; then
    linger_state="$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null || echo no)"
    if [[ "$linger_state" != "yes" ]]; then
      cat >&2 <<EOF

WARNING: lingering is NOT enabled for $USER (loginctl Linger=$linger_state).
         claude-control will stop when you log out, and won't start after reboot.
         Enable it once:
             loginctl enable-linger $USER
         (May require sudo depending on your polkit setup.)

EOF
    fi
  fi

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

if [[ "$OS_KIND" == "linux" ]]; then
  cat <<EOF

Linux service status:
  systemctl --user status $SERVICE_UNIT
EOF
  if [[ $WATCHDOG -eq 1 ]]; then
    echo "  systemctl --user status $WATCHDOG_TIMER_UNIT"
  fi
fi
