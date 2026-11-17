# container-watchdog

A small always-on service that notices when a Docker container is **down and not coming back by itself**, waits a sensible grace period, and brings it back, optionally pulling a newer image first.

One folder, one config file, one log, one systemd service. No dependencies beyond bash 5, Docker and (for compose actions) Docker Compose.

```
/etc/container-watchdog/
  container-watchdog.sh        the daemon
  watchdog.conf                the only file you edit
  watchdog.log                 the only log (rotates itself, silent when all is well)
  container-watchdog.service   systemd unit (systemd gets a symlink to this)
  install.sh                   install / --update / --status / --uninstall / --purge
  PAUSE                        create this file to suspend all restarts
```

## Why this exists

It was written after an auto-updater took down its own lifeline.

Dockhand manages several Docker hosts through a [`docker-socket-proxy`](https://github.com/Tecnativa/docker-socket-proxy) container on each one. When an update arrived for the proxy image, Dockhand pulled it and sent a stop to the proxy container. The stop was delivered through that same proxy, so the connection died mid-update and the follow-up *start* never arrived. The proxy stayed exited and every host behind it went dark.

Docker's own restart policies don't help here. `restart: unless-stopped` and `always` deliberately do **not** restart a container that was stopped through the Docker API, which is exactly what an updater does. Something outside the container has to notice it is gone and put it back.

That is all this does, and it turns out to be useful for more than proxies.

## What it does

- Polls the containers you list (default every 30 seconds).
- Acts only after a container has been **down for a grace period** (default 180 seconds, measured from Docker's own `FinishedAt` timestamp). Updaters, reboots and your own maintenance get time to finish before the watchdog steps in.
- Brings it back with `docker start`, `docker compose up -d`, or `docker compose up -d --force-recreate`.
- Optionally **pulls the newest image first** (`pull=yes`), so a recovery also updates the container. A failed pull is logged and never blocks the restart.
- Limits itself: after `MAX_RESTARTS` attempts inside `RESTART_WINDOW` it stops, logs **HARD DOWN**, and fires one webhook message. It resumes watching once the container is running again.
- Stays **quiet**: nothing is written to the log while everything is healthy. Lines appear only for poll errors, a container found down and the action taken, failures, hard down, daemon start/stop, `PAUSE` changes and config problems. A silent log means a healthy host.

## Beyond the original use case

The same loop covers more than a socket proxy:

| Use | How |
|---|---|
| **Anything an updater might stop** (Watchtower, Dockhand, Portainer, scripts) | list the container with `compose-up` |
| **Running, but not reachable** (published ports vanished after a network or daemon hiccup) | `running,ports` with `recreate` |
| **Keep a service on the latest image** without a separate updater | `pull=yes`; every recovery also updates it |
| **Containers that must come back after maintenance** | the grace period waits out your own work; `PAUSE` stops it entirely |
| **Replacing ad-hoc cron/timer restart scripts** | one config, one log, same behaviour on every host |
| **Docker Engine inside WSL2 with systemd** | runs as an ordinary service; point `dir=` at `/mnt/c/...` compose folders |
| **Fleet-wide "is it down for real?" signal** | the webhook fires only on HARD DOWN, so it is rare and worth reading |

It is deliberately not a monitoring suite: it has no metrics, no dashboards and no health-check logic of its own. It answers one question, "should this be running?", and fixes it when the answer is yes.

## Install

```
curl -fsSL https://raw.githubusercontent.com/downing-labs/container-watchdog/main/install.sh -o /tmp/cw-install.sh
bash /tmp/cw-install.sh
```

The installer asks for your sudo password itself, creates `/etc/container-watchdog/`, never overwrites an existing `watchdog.conf`, and enables the service. On a host that has a container named `docker-proxy` it also enables the default `docker-proxy` line.

On hosts that can't reach GitHub, copy this folder across and run `bash install.sh` from it.

| | |
|---|---|
| What does it see right now? | `bash /etc/container-watchdog/container-watchdog.sh --status` |
| Change what is watched | edit `watchdog.conf` (re-read every cycle, no restart) |
| Pause for maintenance | `touch /etc/container-watchdog/PAUSE` / `rm /etc/container-watchdog/PAUSE` |
| Update | `bash /etc/container-watchdog/install.sh --update` (keeps `watchdog.conf`) |
| Test the Discord webhook | `bash /etc/container-watchdog/container-watchdog.sh --test-notify` |
| Retire an old timer-based mail-bridge check | `bash /etc/container-watchdog/install.sh --retire-portwatch` |
| Remove | `install.sh --uninstall` (keeps the folder) or `--purge` (deletes it) |

## Configuration

`watchdog.conf` has optional settings, then one container per line:

```
# settings (defaults shown)
# POLL_SECONDS=30
# GRACE_SECONDS=180
# MAX_RESTARTS=3
# RESTART_WINDOW=3600
# NOTIFY_WEBHOOK=https://discord.com/api/webhooks/...     # used only for HARD DOWN
# LOG_MAX_KB=1024
# LOG_KEEP=3

# name            checks           action        options
docker-proxy      running          compose-up    dir=/opt/containers/docker-proxy   pull=yes
mail-bridge       running,ports    recreate      dir=/opt/containers/mail-bridge
```

**checks**

- `running`: the container must be running.
- `running,ports`: it must also still have its published ports (requires action `recreate`).

**action**

- `start`: `docker start <name>`
- `compose-up`: `cd <dir> && docker compose up -d`. Also picks up an image that was pulled in the meantime.
- `recreate`: `cd <dir> && docker compose up -d --force-recreate`

**options**

- `dir=/path` compose folder (required for `compose-up` and `recreate`)
- `service=name` one compose service only
- `env=/path/file.env` passed as `--env-file`
- `grace=300` per-container grace override
- `pull=yes|no` pull before restarting (default `no`; not allowed with `start`, because a plain start can only revive the old image)

A problem in the config is logged and that line is skipped. It never stops the daemon.

## How it behaves

1. A container found not running starts a timer from Docker's `FinishedAt` (or from daemon start / PAUSE resume, whichever is later, so a reboot or a long pause never causes an instant restart).
2. When the container has been down for the grace period, the action runs, and the result is checked for up to 30 seconds.
3. Success is logged once as `RECOVERED`. Failure counts toward `MAX_RESTARTS`.
4. At the limit: **HARD DOWN** is logged, one webhook is sent, and the watchdog backs off until the container is running again.
5. If Docker itself can't be reached, the poll is retried and the problem is logged. The watchdog does not act on a container it can't see.

If `docker compose` isn't available to root (for example the compose plugin is installed only under a normal user's `~/.docker/cli-plugins`), the watchdog finds that binary and uses it, and says so in the log.

## Requirements and limits

- Linux with systemd, bash 5+, Docker, `curl` (webhook and installer), and `flock`. Runs as root.
- `compose-up` and `recreate` need Docker Compose v2.
- The service uses `Wants=` and `After=` on Docker, not `Requires=`, so restarting Docker doesn't stop the watchdog.
- Immutable distros (such as Flatcar) mount `/etc` as `noexec`; the unit runs the script as `bash /etc/container-watchdog/container-watchdog.sh` for that reason.
- It watches containers on its own host only. Run it on each host you care about.
- It is not a replacement for restart policies; it complements them for the cases they skip.

## Tests

```
bash tests/run-tests.sh
```

59 checks against a fake `docker`, `curl` and `systemctl`. No root and no real containers are needed. They cover healthy silence, grace handling, hard down with a single webhook, Docker being unreachable, `PAUSE`, port loss, missing containers, config errors, `--status`, the pull option and the installer (fresh install, re-run, uninstall, purge).

## License

MIT. See [LICENSE](LICENSE).
