# ops/ — host operational scripts

Local-install operational tooling for running NanoClaw on this macOS + Podman
host. These are **installation-specific** (they reference this machine's
launchd labels, the OneCLI pod, and the podman VM) and are not meant for
upstream PRs.

## `start.sh` — cold start after a reboot

The podman VM does **not** auto-start at macOS login. After a reboot the
launchd agents come back but can't reach any containers until the VM and the
OneCLI gateway are up. `start.sh` starts everything in dependency order and is
safe to re-run:

```
ops/start.sh            # start podman machine → OneCLI pod → nanoclaw → watchdog
ops/start.sh --status   # report current state only, change nothing
```

`~/start.sh` is a thin wrapper that calls this, so you can run it from home.

### Boot wiring — `com.user.nanoclaw-coldstart`

`start.sh` is run automatically at login by a launchd agent
(`~/Library/LaunchAgents/com.user.nanoclaw-coldstart.plist`, `RunAtLoad`). This
install runs with **no auto-login** (keeps the account cold at rest): the Mac
boots to the login window — reachable over Tailscale, SSH, and Screen Sharing,
which are all *system* daemons up before any login — and the stack comes up
when a human logs in (typically via Screen Sharing). That login fires the agent,
which runs `start.sh`.

**Critical plist key — `AbandonProcessGroup=true`.** `start.sh` calls
`podman machine start`, which spawns the gvproxy + VM helper processes. A
one-shot LaunchAgent defaults to `AbandonProcessGroup=false`, so launchd kills
the job's entire process group when `start.sh` exits — taking the freshly
started podman VM down with it (symptom: a clean `stopped` state seconds after a
"successful" start, then nanoclaw can't reach any containers).
`AbandonProcessGroup=true` lets the VM survive the agent exiting. **Do not
remove it.**

```bash
# install (load)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.nanoclaw-coldstart.plist
# uninstall (unload)
launchctl bootout   gui/$(id -u)/com.user.nanoclaw-coldstart
```

## `podman-watchdog.sh` — auto-recover a wedged VM

Background: the applehv VM + gvproxy networking layer occasionally wedges hard
— the VM reports "running" but every `podman` command hangs, so nanoclaw can't
reach its containers and nothing responds. On 2026-06-05 this caused a ~40h
silent outage (see `notes/setup-bugs.md`). The fix is the same bounce that
`~/.onecli/upgrade.sh` uses: `podman machine stop && start`.

This watchdog runs every 2 minutes via launchd. If the VM is wedged it bounces
the machine, brings the OneCLI pod back, and kicks nanoclaw to reconnect —
turning a 40h manual outage into a ~3-minute self-heal. A cleanly *stopped*
machine is left alone (that's `start.sh`'s job). A cooldown prevents bounce
storms.

```
ops/podman-watchdog.sh            # one pass (what launchd runs)
ops/podman-watchdog.sh --check    # report health only, never act
ops/podman-watchdog.sh --dry-run  # log what it would do, don't act
```

Logs: `logs/podman-watchdog.log` (script) and
`logs/podman-watchdog.launchd.log` (launchd stdout/err).
State: `data/.watchdog/` (last-bounce timestamp, run lock).

### Install / uninstall the watchdog

The launchd plist lives at `~/Library/LaunchAgents/com.user.podman-watchdog.plist`
and points at `ops/podman-watchdog.sh`.

```bash
# install (load)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.podman-watchdog.plist
# uninstall (unload)
launchctl bootout   gui/$(id -u)/com.user.podman-watchdog
# check it's loaded
launchctl print     gui/$(id -u)/com.user.podman-watchdog | head
```

`start.sh` also loads the watchdog if it isn't already loaded.

## `adapter-watchdog.sh` — auto-recover a wedged channel adapter

Background: the host holds long-lived connections to chat platforms. Slack
Socket Mode is a persistent WebSocket; intermittent network blips kill it and
it flaps (disconnect/reconnect) or goes half-open (pong timeouts), silently
stopping inbound DMs. On 2026-06-12 work-Quill was dead ~4 days this way while
Telegram (stateless polling) shrugged the same blips off. The **podman
watchdog only checks the VM**, so this class is invisible to it — hence a
second watchdog.

Each 120s tick it reads only the *new* bytes of the host logs (byte offset, so
it's cheap regardless of log size) and counts Slack failure signals:
`pong wasn't received` (in `logs/nanoclaw.error.log`) and
`Slack socket mode disconnected` (in `logs/nanoclaw.log`). It restarts the host
(`launchctl kickstart`) when a tick is severe (burst) or two consecutive ticks
are bad. Cooldown prevents restart storms; a clean connection produces zero
signals. Deterministic — no LLM, no tokens once running.

```
ops/adapter-watchdog.sh            # one tick (what launchd runs)
ops/adapter-watchdog.sh --check    # report counts only, never act
ops/adapter-watchdog.sh --dry-run  # log what it would do, don't restart
```

Logs: `logs/adapter-watchdog.log`. State: `data/.watchdog/adapter-state`
(byte offsets, strike count, last-restart timestamp). Plist:
`~/Library/LaunchAgents/com.user.adapter-watchdog.plist`. Install/uninstall
exactly like the podman watchdog (swap the label). `start.sh` loads it too.

Tuning knobs are constants at the top of the script: `PONG_BAD` (5),
`PONG_BURST` (15), `DISC_BAD` (2), `STRIKES_TO_ACT` (2), `COOLDOWN` (600s).

## `lint.sh` — static checks for these scripts

Run before committing any change to `ops/*.sh`:

```
ops/lint.sh            # lint every ops/*.sh
ops/lint.sh <file>     # lint one file
```

Three layers, because no single tool catches everything:
1. `bash -n` — syntax.
2. `shellcheck` — the broad class of shell bugs (`brew install shellcheck`).
3. **non-ASCII-after-var gate** — hard-fails if a multibyte char is glued onto
   a `$variable` (e.g. an ellipsis written with no space after a var). Under a
   non-UTF-8 locale bash folds those bytes into the variable name and dies with
   `unbound variable`. shellcheck does **not** catch this; it shipped once
   (2026-06-07, see `notes/setup-bugs.md`), hence the dedicated gate.
