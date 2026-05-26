# claude-control

**[Русский](./README.md) · English**

Run [Claude Code](https://claude.com/claude-code) remote-control sessions for many projects, with a single always-on dispatcher session you can talk to from the Claude mobile app.

> Built on top of [`claude remote-control`](https://code.claude.com/docs/en/remote-control.md), which is currently a **research preview**. Requires the Claude Code CLI **≥ 2.1.51** and a Claude subscription login (`claude /login`) — Anthropic API keys do not work for remote-control.

## Why

Claude Code already supports remote-control sessions (`claude remote-control --name X`) you can reach from the Claude mobile app or the browser. Great idea, awkward in practice: to get into the right project, you have to be physically at your Mac, open a terminal, `cd` into the repo, run `claude remote-control --name <repo>` there, and only then go to your phone. If you're not at the Mac, the whole thing is useless.

`claude-control` closes that gap:

- A single **control session** runs on the Mac at all times (launchd keeps it alive). It's reachable from the phone around the clock.
- From the phone you tell the control session "lift `<project>`". It runs `claude-rc <project>`, which spawns the per-project session in `tmux` inside the right directory.
- Open the Claude app again, you see a new `<project>` session — you're inside the project, remotely, with no SSH and no manual `cd`.
- A small **watchdog** restarts the control session if it silently dies (see [docs/troubleshooting.md](./docs/troubleshooting.md)) — launchd doesn't notice on its own.

## What you get

- **Any project from your phone in one flow.** Just say "lift `<name>`" in the control session. From there it's the usual Claude workflow, just with a mobile keyboard.
- **No pre-warmed sessions.** Lift a project only when you actually need it — you don't end up with a dozen idle sessions across all your repos.
- **Single registry file.** `~/.claude-control/projects.yaml` is a short `name: path` list. Adding a new project is one line.
- **Idempotent.** A repeated "lift `<name>`" sees a live `tmux` and refuses to duplicate; if the session died on idle, it spawns a fresh one.
- **Self-contained install/uninstall.** One `./install.sh`, one `./uninstall.sh`. No global packages and no system services — just user-level launchd agents and scripts in `~/.local/bin/`.

## What it looks like from the phone

```
You (in the Claude app)  - open Code, pick session "control"
You                      - "lift webapp"
control session          - runs claude-rc webapp, replies with the tmux name
You                      - open Code again, pick session "webapp"
You                      - inside the project, remotely
```

## Requirements

- macOS (launchd) or Linux with systemd user services (Ubuntu 22.04+, Debian 12+, any recent distro).
- [Claude Code CLI](https://docs.claude.com/claude-code) ≥ 2.1.51, logged in via `claude /login` (Claude subscription).
- `tmux` — `brew install tmux` (macOS) or `apt install tmux` (Linux).
- `yq` from mikefarah, v4 — `brew install yq` on macOS; on Linux **download the binary from [GitHub releases](https://github.com/mikefarah/yq/releases)**, the `yq` apt package is a different project and won't work. `install.sh` checks the version and fails fast if it's the wrong one.
- On macOS, keep the Mac awake while you're remote. launchd doesn't run user agents during sleep; remote-control sessions die with the system. Usual trick: a separate launchd agent running `caffeinate -i`; this repo doesn't ship one.
- On Linux, enable **lingering** or user services stop on logout and won't come back after reboot. One-time: `loginctl enable-linger $USER` (may need sudo depending on your polkit setup). `install.sh` checks and warns if it's off.

## Quickstart

```sh
git clone https://github.com/dewil/claude-control.git
cd claude-control
./install.sh
$EDITOR ~/.claude-control/projects.yaml   # add your projects
```

That's it — the control session is already running. Go to the Claude mobile app: **Code -> session `control` -> "lift `<name>`"**.

If you're planning to hack on the repo, install with `./install.sh --link` — scripts in `~/.local/bin/` become symlinks into `bin/` in the repo, so `git pull` updates the live code.

## Principles

- **Idempotent.** `./install.sh` is safe to re-run: units are reloaded, existing `~/.claude-control/projects.yaml`, `CLAUDE.md`, and logs are left alone.
- **Repo separate from runtime.** The repo lives wherever (e.g. `~/Work/claude-control/`); user data lives in `~/.claude-control/`. After a copying install the repo can be deleted safely.
- **User-level supervisor only.** macOS uses launchd user agents, Linux uses `systemctl --user`. No `sudo`, no system services, everything goes into the user prefix.
- **No magic in the watchdog.** The watchdog reads the last 30 lines of `control.log` and kicks the supervisor when the heartbeat is missing (`launchctl kickstart` on macOS, `systemctl --user restart` on Linux). Everything it does is visible by eye in `~/.claude-control/watchdog.log`.

## Repo layout

- [`bin/claude-rc`](./bin/claude-rc) — the command the control session calls; spawns the per-project session in `tmux`.
- [`bin/claude-control-session`](./bin/claude-control-session) — supervisor entrypoint (the always-on control session).
- [`bin/claude-control-watchdog`](./bin/claude-control-watchdog) — health check for the control session (every 5 minutes).
- [`launchd/`](./launchd/) — macOS plist templates; `install.sh` renders them into `~/Library/LaunchAgents/`.
- [`systemd/`](./systemd/) — Linux `.service` / `.timer` templates; `install.sh` renders them into `~/.config/systemd/user/`.
- [`examples/`](./examples/) — starter `projects.yaml`, `CLAUDE.md`, `settings.local.json` for `~/.claude-control/`.
- [`docs/architecture.md`](./docs/architecture.md) — diagram and component description (Russian-only for now).
- [`docs/troubleshooting.md`](./docs/troubleshooting.md) — common failure modes (Russian-only for now).
- [`install.sh`](./install.sh) / [`uninstall.sh`](./uninstall.sh) — install and remove.

## What ends up where after install

**macOS:**

```
~/.local/bin/
  claude-rc, claude-control-session, claude-control-watchdog

~/Library/LaunchAgents/
  com.<user>.claude-control.plist
  com.<user>.claude-control-watchdog.plist

~/.claude-control/
  projects.yaml                # your project registry (gitignored in the repo)
  CLAUDE.md                    # control-session project context
  .claude/settings.local.json  # allow-list of bash commands for the control session
  control.log, control.err     # control-session stdout/stderr
  watchdog.log                 # history of kickstarts
  watchdog.out, watchdog.err   # watchdog stdout/stderr
```

**Linux:**

```
~/.local/bin/
  claude-rc, claude-control-session, claude-control-watchdog

~/.config/systemd/user/
  claude-control.service
  claude-control-watchdog.service
  claude-control-watchdog.timer

~/.claude-control/
  projects.yaml, CLAUDE.md, .claude/settings.local.json
  control.log, control.err
  watchdog.log, watchdog.out, watchdog.err
```

Optional on Linux: create `~/.config/claude-control/env` with shell-style vars (e.g. `CLAUDE_BIN=/path/to/claude`); the service picks them up via `EnvironmentFile=` without editing the unit.

## Uninstall

```sh
./uninstall.sh           # remove agents and scripts from ~/.local/bin/
./uninstall.sh --purge   # also delete ~/.claude-control/
```

## License

[MIT](./LICENSE). Take it, modify it, use it — just keep the copyright notice in derivative copies.
