#!/usr/bin/env bash
# container-watchdog - keeps selected Docker containers running.
#
# Everything lives in ONE folder (normally /etc/container-watchdog):
#   container-watchdog.sh   this daemon          watchdog.conf   your settings
#   watchdog.log            the only log         PAUSE           create to suspend restarts
#   container-watchdog.service, install.sh       (systemd unit and installer)
#
# Usage:
#   container-watchdog.sh                run the daemon (normally started by systemd)
#   container-watchdog.sh --status       show what it sees right now; changes nothing
#   container-watchdog.sh --test-notify  send a test message to NOTIFY_WEBHOOK
#   container-watchdog.sh --version
#
# Logging policy: NOTHING is written while everything is fine. A line is written only
# when a poll fails/needs a retry, a container is found down and acted on, an action
# fails, or a container is HARD DOWN (we gave up). Daemon start/stop, PAUSE changes and
# config problems are logged too. The webhook fires only for HARD DOWN.

VERSION="1.1.1"
export LC_ALL=C

DIR="${CW_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONF="$DIR/watchdog.conf"
LOG="$DIR/watchdog.log"
PAUSE_FILE="$DIR/PAUSE"
LOCK="$DIR/.lock"
RETRY_DELAY="${CW_RETRY_DELAY:-3}"     # seconds between poll retries (tests shorten it)
HOSTLABEL="$(hostname 2>/dev/null || echo host)"
MODE=daemon
START_TS=$(date +%s)
FLOOR_TS=$START_TS                      # a down-clock never starts earlier than this

declare -A C_CHECKS C_ACTION C_DIR C_SERVICE C_ENV C_GRACE C_PULL
declare -A DOWN_SINCE ERR_SINCE GAVE_UP ATTEMPTS
NAMES=()
CONFIG_ERR=""
LAST_CONFIG_ERR=""
LAST_NAMES=""
PAUSED=""

# ---------------------------------------------------------------- logging
rotate_log() {
  [ -f "$LOG" ] || return 0
  local size i
  size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$size" -lt $((LOG_MAX_KB * 1024)) ] && return 0
  i=$LOG_KEEP
  while [ "$i" -gt 1 ]; do
    [ -f "$LOG.$((i - 1))" ] && mv -f "$LOG.$((i - 1))" "$LOG.$i"
    i=$((i - 1))
  done
  mv -f "$LOG" "$LOG.1"
}

log() {   # log LEVEL message...   (daemon mode only; status mode stays silent)
  [ "$MODE" = daemon ] || return 0
  local lvl=$1; shift
  rotate_log
  printf '%s %-5s %s\n' "$(date -Iseconds)" "$lvl" "$*" >> "$LOG" 2>/dev/null \
    || printf '%s %-5s %s\n' "$(date -Iseconds)" "$lvl" "$*" >&2
}

# ---------------------------------------------------------------- config
set_defaults() {
  POLL_SECONDS=30
  GRACE_SECONDS=180
  MAX_RESTARTS=3
  RESTART_WINDOW=3600
  NOTIFY_WEBHOOK=""
  LOG_MAX_KB=1024
  LOG_KEEP=3
}

load_config() {
  set_defaults
  NAMES=(); C_CHECKS=(); C_ACTION=(); C_DIR=(); C_SERVICE=(); C_ENV=(); C_GRACE=(); C_PULL=()
  CONFIG_ERR=""
  if [ ! -r "$CONF" ]; then CONFIG_ERR="cannot read $CONF"; return; fi

  local line lineno=0 key val name checks action rest opt k v ok c
  local -a _cs _opts
  local dir svc envf grace pull
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|\#*) continue ;; esac
    line="${line%%[[:space:]]#*}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue

    if [[ $line =~ ^([A-Z_]+)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
      val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
      case $key in
        POLL_SECONDS|GRACE_SECONDS|MAX_RESTARTS|RESTART_WINDOW|LOG_MAX_KB|LOG_KEEP)
          if [[ $val =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ]; then printf -v "$key" '%s' "$val"
          else CONFIG_ERR+="line $lineno: $key must be a positive integer; "; fi ;;
        NOTIFY_WEBHOOK) NOTIFY_WEBHOOK=$val ;;
        *) CONFIG_ERR+="line $lineno: unknown setting $key; " ;;
      esac
      continue
    fi

    # container line:  name  checks  action  [dir=..] [service=..] [env=..] [grace=..]
    read -r name checks action rest <<<"$line"
    checks=${checks:-running}; action=${action:-start}
    if ! [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then CONFIG_ERR+="line $lineno: bad container name; "; continue; fi
    ok=1
    IFS=',' read -ra _cs <<<"$checks"
    for c in "${_cs[@]}"; do case $c in running|ports) ;; *) ok=0 ;; esac; done
    case $action in start|compose-up|recreate) ;; *) ok=0 ;; esac
    if [ $ok -eq 0 ]; then CONFIG_ERR+="line $lineno: $name: checks must be running,ports and action start|compose-up|recreate; "; continue; fi

    dir=""; svc=""; envf=""; grace=""; pull="no"
    read -ra _opts <<<"$rest"
    for opt in "${_opts[@]}"; do
      k=${opt%%=*}; v=${opt#*=}
      case $k in
        dir) dir=$v ;; service) svc=$v ;; env) envf=$v ;; grace) grace=$v ;; pull) pull=$v ;;
        *) CONFIG_ERR+="line $lineno: $name: unknown option $k; "; ok=0 ;;
      esac
    done
    if [ -n "$grace" ] && ! [[ $grace =~ ^[0-9]+$ ]]; then CONFIG_ERR+="line $lineno: $name: grace must be a number; "; ok=0; fi
    case $pull in
      yes|no) ;;
      *) CONFIG_ERR+="line $lineno: $name: pull must be yes or no; "; ok=0 ;;
    esac
    if [ "$pull" = yes ] && [ "$action" = start ]; then CONFIG_ERR+="line $lineno: $name: pull=yes needs action compose-up or recreate (a plain start can only revive the old image); "; ok=0; fi
    if [ "$action" != start ] && [ -z "$dir" ]; then CONFIG_ERR+="line $lineno: $name: action $action needs dir=/path/to/compose/folder; "; ok=0; fi
    if [[ ,$checks, == *,ports,* ]] && [ "$action" != recreate ]; then CONFIG_ERR+="line $lineno: $name: the ports check needs action recreate; "; ok=0; fi
    if [ -n "${C_ACTION[$name]:-}" ]; then CONFIG_ERR+="line $lineno: $name listed twice; "; ok=0; fi
    [ $ok -eq 1 ] || continue

    NAMES+=("$name")
    C_CHECKS[$name]=$checks; C_ACTION[$name]=$action; C_DIR[$name]=$dir
    C_SERVICE[$name]=$svc; C_ENV[$name]=$envf; C_GRACE[$name]=$grace; C_PULL[$name]=$pull
  done < "$CONF"
}

# ---------------------------------------------------------------- docker polling
# poll NAME -> sets S_STATUS S_FINISHED S_PORTCFG.  rc 0 ok, 1 container missing, 2 cannot poll
poll() {
  local out rc attempt=1 first_err=""
  while :; do
    out=$(timeout 20 docker container inspect -f '{{.State.Status}}|{{.State.FinishedAt}}|{{len .HostConfig.PortBindings}}' "$1" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
      IFS='|' read -r S_STATUS S_FINISHED S_PORTCFG <<<"$out"
      if [ $attempt -gt 1 ]; then log WARN "$1: poll needed $attempt attempts (first error: ${first_err:0:160})"; fi
      return 0
    fi
    out=${out//$'\n'/ }
    case "$out" in *"No such object"*|*"No such container"*) return 1 ;; esac
    [ $attempt -eq 1 ] && first_err=$out
    LAST_ERR=$out
    [ $attempt -ge 3 ] && return 2
    attempt=$((attempt + 1))
    sleep "$RETRY_DELAY"
  done
}

ports_published() {   # number of published port lines
  timeout 20 docker port "$1" 2>/dev/null | grep -c .
}

# ---------------------------------------------------------------- actions
COMPOSE_BIN=()
find_compose() {   # once: "docker compose", else a compose binary installed per-user (the service runs as root)
  [ ${#COMPOSE_BIN[@]} -gt 0 ] && return 0
  if timeout 20 docker compose version >/dev/null 2>&1; then COMPOSE_BIN=(docker compose); return 0; fi
  local f
  for f in /home/*/.docker/cli-plugins/docker-compose /root/.docker/cli-plugins/docker-compose \
           /usr/local/lib/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose \
           /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose /usr/bin/docker-compose; do
    if [ -x "$f" ] && timeout 20 "$f" version >/dev/null 2>&1; then
      COMPOSE_BIN=("$f"); log INFO "docker compose is not available to root; using $f"; return 0
    fi
  done
  COMPOSE_BIN=(docker compose); return 1
}

compose_base() {   # fills array COMPOSE_CMD for container $1
  find_compose
  COMPOSE_CMD=("${COMPOSE_BIN[@]}")
  [ -n "${C_ENV[$1]}" ] && COMPOSE_CMD+=(--env-file "${C_ENV[$1]}")
}

image_ids() {   # sorted image IDs of every image the compose folder uses (empty if unknown)
  local n=$1 img ids=""
  compose_base "$n"
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    ids+="$(timeout 20 docker image inspect -f '{{.Id}}' "$img" 2>/dev/null) "
  done < <(cd "${C_DIR[$n]}" && timeout 30 "${COMPOSE_CMD[@]}" config --images 2>/dev/null | sort -u)
  printf '%s' "$ids"
}

pull_images() {   # pull before starting; NEVER fatal - getting the service back matters more
  local n=$1 before after out rc
  local -a cmd
  before=$(image_ids "$n")
  compose_base "$n"; cmd=("${COMPOSE_CMD[@]}" pull)
  [ -n "${C_SERVICE[$n]}" ] && cmd+=("${C_SERVICE[$n]}")
  out=$(cd "${C_DIR[$n]}" && timeout 180 "${cmd[@]}" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    out=${out//$'\n'/ | }
    log WARN "$n: pull FAILED, continuing with the image already on this host: ${out:0:240}"
    return
  fi
  after=$(image_ids "$n")
  if [ -n "$after" ] && [ "$before" != "$after" ]; then
    log INFO "$n: pull ok - a NEWER image was downloaded"
  else
    log INFO "$n: pull ok - image was already current"
  fi
}

run_action() {   # run_action NAME -> ACT_OUT, rc 0/1
  local n=$1 a=${C_ACTION[$n]} d=${C_DIR[$n]} svc=${C_SERVICE[$n]} envf=${C_ENV[$n]}
  local -a cmd
  case $a in
    start)
      ACT_OUT=$(timeout 60 docker start "$n" 2>&1); return $? ;;
    compose-up|recreate)
      if [ ! -d "$d" ]; then ACT_OUT="compose folder not found: $d"; return 1; fi
      [ "${C_PULL[$n]}" = yes ] && pull_images "$n"
      compose_base "$n"; cmd=("${COMPOSE_CMD[@]}")
      cmd+=(up -d)
      [ "$a" = recreate ] && cmd+=(--force-recreate)
      [ -n "$svc" ] && cmd+=("$svc")
      ACT_OUT=$(cd "$d" && timeout 180 "${cmd[@]}" 2>&1); return $? ;;
  esac
}

verify_up() {   # wait up to 30s for the container to be running (and ports back if checked)
  local n=$1 i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if poll "$n" && [ "$S_STATUS" = running ]; then
      if [[ ,${C_CHECKS[$n]}, == *,ports,* ]] && [ "${S_PORTCFG:-0}" -gt 0 ] && [ "$(ports_published "$n")" -eq 0 ]; then
        :  # ports not back yet
      else
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/ }
  printf '%s' "$s"
}

notify() {   # notify MESSAGE ; rc 0 sent (or no webhook), 1 failed
  [ -n "$NOTIFY_WEBHOOK" ] || return 0
  local msg payload
  msg=$(json_escape "${1:0:1800}")
  payload="{\"content\":\"$msg\"}"
  if timeout 20 curl -fsS -m 15 -H 'Content-Type: application/json' -d "$payload" "$NOTIFY_WEBHOOK" >/dev/null 2>&1; then
    return 0
  fi
  log WARN "webhook notification failed to send"
  return 1
}

hard_down() {   # hard_down NAME WHY
  GAVE_UP[$1]=1
  log ERROR "$1: HARD DOWN - $2. Not retrying until it is running again."
  notify "[container-watchdog] $HOSTLABEL: $1 is HARD DOWN - $2"
}

act_on() {   # act_on NAME REASON DOWN_FOR_SECONDS MISSING(0/1)
  local n=$1 reason=$2 downfor=$3 missing=$4 now ts kept="" cnt
  now=$(date +%s)
  for ts in ${ATTEMPTS[$n]:-}; do
    [ $((now - ts)) -lt "$RESTART_WINDOW" ] && kept+="$ts "
  done
  ATTEMPTS[$n]=$kept
  cnt=$(wc -w <<<"$kept")
  cnt=${cnt// /}

  if [ "$missing" -eq 1 ] && [ "${C_ACTION[$n]}" = start ]; then
    hard_down "$n" "container does not exist and action=start cannot create it (down ${downfor}s)"
    return
  fi
  if [ "$cnt" -ge "$MAX_RESTARTS" ]; then
    hard_down "$n" "$reason; already tried $cnt times in the last $((RESTART_WINDOW / 60)) min"
    return
  fi

  log WARN "$n: DOWN ($reason) for ${downfor}s - running action ${C_ACTION[$n]} (attempt $((cnt + 1))/$MAX_RESTARTS)"
  ATTEMPTS[$n]+="$now "
  if run_action "$n"; then
    if verify_up "$n"; then
      log INFO "$n: RECOVERED via ${C_ACTION[$n]}"
      unset "DOWN_SINCE[$n]"
      return
    fi
    log ERROR "$n: action ${C_ACTION[$n]} completed but the container is still not healthy: ${ACT_OUT//$'\n'/ }" 
  else
    log ERROR "$n: action ${C_ACTION[$n]} FAILED: ${ACT_OUT//$'\n'/ }"
  fi
  DOWN_SINCE[$n]=$(date +%s)
  if [ $((cnt + 1)) -ge "$MAX_RESTARTS" ]; then
    hard_down "$n" "$reason; $MAX_RESTARTS attempts in the last $((RESTART_WINDOW / 60)) min did not bring it back"
  fi
}

# ---------------------------------------------------------------- one container, one cycle
check_one() {
  local n=$1 now rc down=0 missing=0 reason="" grace since f
  now=$(date +%s)
  grace=${C_GRACE[$n]:-$GRACE_SECONDS}

  poll "$n"; rc=$?
  if [ $rc -eq 2 ]; then
    if [ -z "${ERR_SINCE[$n]:-}" ]; then
      ERR_SINCE[$n]=$now
      log ERROR "$n: cannot poll docker: ${LAST_ERR:0:240} - will keep retrying every ${POLL_SECONDS}s"
    fi
    return
  fi
  if [ -n "${ERR_SINCE[$n]:-}" ]; then
    log INFO "$n: polling recovered after $((now - ERR_SINCE[$n]))s"
    unset "ERR_SINCE[$n]"
  fi

  if [ $rc -eq 1 ]; then
    down=1; missing=1; reason="container not found"
  else
    case $S_STATUS in
      running)
        if [[ ,${C_CHECKS[$n]}, == *,ports,* ]] && [ "${S_PORTCFG:-0}" -gt 0 ]; then
          if [ "$(ports_published "$n")" -eq 0 ]; then down=2; reason="running but its published ports are gone"; fi
        fi ;;
      exited|dead|created) down=1; reason="status=$S_STATUS" ;;
      *) : ;;   # restarting / paused / removing: not ours to touch
    esac
  fi

  if [ $down -eq 0 ]; then
    if [ -n "${GAVE_UP[$n]:-}" ]; then
      log INFO "$n: running again after being HARD DOWN"
      unset "GAVE_UP[$n]"; ATTEMPTS[$n]=""
    fi
    unset "DOWN_SINCE[$n]"
    return
  fi

  [ -n "${GAVE_UP[$n]:-}" ] && return

  if [ -z "${DOWN_SINCE[$n]:-}" ]; then
    since=$now
    if [ $rc -eq 0 ] && [ $down -eq 1 ] && [[ $S_FINISHED != 0001-* ]]; then
      f=$(date -d "$S_FINISHED" +%s 2>/dev/null) && [ -n "$f" ] && [ "$f" -lt "$since" ] && since=$f
    fi
    [ "$since" -lt "$FLOOR_TS" ] && since=$FLOOR_TS
    DOWN_SINCE[$n]=$since
  fi
  [ $((now - DOWN_SINCE[$n])) -ge "$grace" ] || return
  act_on "$n" "$reason" $((now - DOWN_SINCE[$n])) "$missing"
}

# ---------------------------------------------------------------- daemon
daemon_loop() {
  exec 9>"$LOCK"
  if ! flock -n 9; then echo "container-watchdog is already running (lock: $LOCK)" >&2; exit 1; fi
  trap 'log INFO "stopping (signal received)"; exit 0' TERM INT

  load_config
  log INFO "started v$VERSION on $HOSTLABEL: watching ${NAMES[*]:-nothing} (poll ${POLL_SECONDS}s, grace ${GRACE_SECONDS}s, max ${MAX_RESTARTS} restarts/$((RESTART_WINDOW / 60))min)"
  LAST_NAMES="${NAMES[*]}"
  if [ -n "$CONFIG_ERR" ]; then log ERROR "config problem: $CONFIG_ERR"; LAST_CONFIG_ERR=$CONFIG_ERR; fi

  local n
  while :; do
    load_config
    if [ "$CONFIG_ERR" != "$LAST_CONFIG_ERR" ]; then
      if [ -n "$CONFIG_ERR" ]; then log ERROR "config problem: $CONFIG_ERR"; else log INFO "config problems cleared"; fi
      LAST_CONFIG_ERR=$CONFIG_ERR
    fi
    if [ "${NAMES[*]}" != "$LAST_NAMES" ]; then
      log INFO "config reloaded: now watching ${NAMES[*]:-nothing}"
      LAST_NAMES="${NAMES[*]}"
    fi

    if [ -f "$PAUSE_FILE" ]; then
      if [ -z "$PAUSED" ]; then PAUSED=1; log INFO "PAUSE file present - restarts suspended"; fi
    else
      if [ -n "$PAUSED" ]; then
        PAUSED=""; FLOOR_TS=$(date +%s); DOWN_SINCE=()
        log INFO "PAUSE file removed - restarts resumed (grace period restarts now)"
      fi
      for n in "${NAMES[@]}"; do check_one "$n"; done
    fi

    sleep "$POLL_SECONDS" &
    wait $!
  done
}

# ---------------------------------------------------------------- status / helpers
show_status() {
  MODE=status
  load_config
  local n state ports act d
  echo "container-watchdog v$VERSION on $HOSTLABEL"
  echo "folder : $DIR"
  echo "config : $CONF"
  echo "log    : $LOG"
  if command -v systemctl >/dev/null 2>&1; then echo "service: $(systemctl is-active container-watchdog 2>/dev/null || true)"; fi
  echo "poll ${POLL_SECONDS}s | grace ${GRACE_SECONDS}s | max ${MAX_RESTARTS} restarts per $((RESTART_WINDOW / 60)) min | webhook: $([ -n "$NOTIFY_WEBHOOK" ] && echo set || echo not set)"
  [ -f "$PAUSE_FILE" ] && echo "*** PAUSED: $PAUSE_FILE exists, no restarts will happen ***"
  [ -n "$CONFIG_ERR" ] && echo "*** CONFIG PROBLEMS: $CONFIG_ERR ***"
  echo
  printf '%-24s %-14s %-12s %s\n' CONTAINER STATE PORTS ACTION
  for n in "${NAMES[@]}"; do
    poll "$n"; rc=$?
    if [ $rc -eq 1 ]; then state="NOT FOUND"; ports="-"
    elif [ $rc -eq 2 ]; then state="CANNOT POLL"; ports="-"
    else
      state=$S_STATUS; ports="-"
      if [[ ,${C_CHECKS[$n]}, == *,ports,* ]]; then
        if [ "${S_PORTCFG:-0}" -eq 0 ]; then ports="none-defined"
        elif [ "$S_STATUS" = running ]; then [ "$(ports_published "$n")" -gt 0 ] && ports=ok || ports="MISSING"; fi
      fi
    fi
    act=${C_ACTION[$n]}; d=${C_DIR[$n]}
    [ "${C_PULL[$n]}" = yes ] && act+=" +pull"
    printf '%-24s %-14s %-12s %s%s\n' "$n" "$state" "$ports" "$act" "${d:+ ($d)}"
  done
  [ ${#NAMES[@]} -eq 0 ] && echo "(no containers configured)"
  if [ -s "$LOG" ]; then echo; echo "last log lines:"; tail -n 5 "$LOG"; else echo; echo "log is empty (nothing has needed attention)"; fi
}

test_notify() {
  MODE=status
  load_config
  if [ -z "$NOTIFY_WEBHOOK" ]; then echo "NOTIFY_WEBHOOK is not set in $CONF"; exit 1; fi
  if notify "[container-watchdog] $HOSTLABEL: test message (v$VERSION) - ignore"; then echo "sent"; else echo "FAILED to send"; exit 1; fi
}

case "${1:-}" in
  --status|-s) show_status ;;
  --test-notify) test_notify ;;
  --version|-V) echo "container-watchdog $VERSION" ;;
  --help|-h) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  "") daemon_loop ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
