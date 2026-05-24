#!/usr/bin/env bash
# uninstall.sh: remove launchd units and bin/ scripts installed by install.sh.
# Leaves ~/.claude-control/ alone (user data — projects.yaml, logs).
#
#   ./uninstall.sh                 Use default paths and labels.
#   ./uninstall.sh --prefix DIR    Same as install.sh.
#   ./uninstall.sh --label LABEL   Same as install.sh.
#   ./uninstall.sh --purge         Also delete ~/.claude-control/.
set -euo pipefail

PREFIX="$HOME/.local"
LABEL="com.${USER}.claude-control"
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --label)  LABEL="$2"; shift 2 ;;
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

BIN_DIR="$PREFIX/bin"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
CONTROL_DIR="$HOME/.claude-control"
WATCHDOG_LABEL="${LABEL}-watchdog"

say() { echo "==> $*"; }

remove_unit() {
  local label="$1"
  local plist="$LAUNCHD_DIR/${label}.plist"
  if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
    say "Bootout $label"
    launchctl bootout "gui/$UID/$label" || true
  fi
  if [[ -e "$plist" ]]; then
    say "Remove $plist"
    rm -f "$plist"
  fi
}

remove_unit "$WATCHDOG_LABEL"
remove_unit "$LABEL"

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
else
  say "Leaving $CONTROL_DIR in place (use --purge to remove)."
fi

say "Done."
