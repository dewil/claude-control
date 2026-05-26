#!/usr/bin/env bash
# uninstall.sh: remove units and bin/ scripts installed by install.sh.
# Leaves ~/.claude-control/ alone (user data - projects.yaml, logs).
#
#   ./uninstall.sh                 Use default paths and labels.
#   ./uninstall.sh --prefix DIR    Same as install.sh.
#   ./uninstall.sh --label LABEL   Same as install.sh (macOS only).
#   ./uninstall.sh --purge         Also delete ~/.claude-control/ and ~/.config/claude-control/.
set -euo pipefail

PREFIX="$HOME/.local"
LABEL=""
LABEL_EXPLICIT=0
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --label)  LABEL="$2"; LABEL_EXPLICIT=1; shift 2 ;;
    --purge)  PURGE=1; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
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
    echo "Unsupported OS: $OS_KIND" >&2
    exit 1
    ;;
esac

if [[ "$OS_KIND" == "linux" && $LABEL_EXPLICIT -eq 1 ]]; then
  echo "--label is macOS-only. On Linux unit names are fixed." >&2
  exit 2
fi

[[ -z "$LABEL" ]] && LABEL="com.${USER}.claude-control"
WATCHDOG_LABEL="${LABEL}-watchdog"
SERVICE_UNIT="claude-control.service"
WATCHDOG_SERVICE_UNIT="claude-control-watchdog.service"
WATCHDOG_TIMER_UNIT="claude-control-watchdog.timer"

BIN_DIR="$PREFIX/bin"
CONTROL_DIR="$HOME/.claude-control"
ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-control"
if [[ "$OS_KIND" == "darwin" ]]; then
  UNIT_DIR="$HOME/Library/LaunchAgents"
else
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
fi

say() { echo "==> $*"; }

if [[ "$OS_KIND" == "darwin" ]]; then

  remove_launchd_unit() {
    local label="$1"
    local plist="$UNIT_DIR/${label}.plist"
    if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
      say "Bootout $label"
      launchctl bootout "gui/$UID/$label" || true
    fi
    if [[ -e "$plist" ]]; then
      say "Remove $plist"
      rm -f "$plist"
    fi
  }

  remove_launchd_unit "$WATCHDOG_LABEL"
  remove_launchd_unit "$LABEL"

else  # linux

  # Tolerant of missing units: --no-watchdog installs leave only the control
  # service; old installs may not have all units.
  for unit in "$WATCHDOG_TIMER_UNIT" "$WATCHDOG_SERVICE_UNIT" "$SERVICE_UNIT"; do
    if systemctl --user list-unit-files "$unit" 2>/dev/null | grep -q "^$unit"; then
      say "Stop+disable $unit"
      systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
    fi
  done

  for f in "$UNIT_DIR/$WATCHDOG_TIMER_UNIT" "$UNIT_DIR/$WATCHDOG_SERVICE_UNIT" "$UNIT_DIR/$SERVICE_UNIT"; do
    if [[ -e "$f" ]]; then
      say "Remove $f"
      rm -f "$f"
    fi
  done

  systemctl --user daemon-reload >/dev/null 2>&1 || true

fi

for script in claude-rc claude-control-session claude-control-watchdog; do
  target="$BIN_DIR/$script"
  if [[ -e "$target" || -L "$target" ]]; then
    say "Remove $target"
    rm -f "$target"
  fi
done

if [[ $PURGE -eq 1 ]]; then
  if [[ -d "$CONTROL_DIR" ]]; then
    say "Purge $CONTROL_DIR"
    rm -rf "$CONTROL_DIR"
  fi
  if [[ -d "$ENV_DIR" ]]; then
    say "Purge $ENV_DIR"
    rm -rf "$ENV_DIR"
  fi
else
  say "Leaving $CONTROL_DIR in place (use --purge to remove)."
  if [[ -d "$ENV_DIR" ]]; then
    say "Leaving $ENV_DIR in place (use --purge to remove)."
  fi
fi

say "Done."
