#!/usr/bin/env bash
# Behaviour tests for container-watchdog using a fake docker. Run: bash tests/run-tests.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../container-watchdog.sh"
export PATH="$HERE/fakebin:$PATH"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

new_env() {   # new_env "conf body"
  T=$(mktemp -d); export FAKE_DIR="$T/docker" CW_DIR="$T/cw" CW_RETRY_DELAY=1
  mkdir -p "$FAKE_DIR" "$CW_DIR" "$T/compose"
  printf '%s\n' "${1//@T@/$T}" > "$CW_DIR/watchdog.conf"
  : > "$FAKE_DIR/actions.log"
}
mk() { mkdir -p "$FAKE_DIR/$1"; echo "$2" > "$FAKE_DIR/$1/status"; echo "${3:-2026-11-17T00:00:00Z}" > "$FAKE_DIR/$1/finished"; echo "${4:-0}" > "$FAKE_DIR/$1/portcfg"; : > "$FAKE_DIR/$1/ports"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
start_daemon() { bash "$SCRIPT" & DPID=$!; sleep 1; }
stop_daemon() { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }
wait_log() {  # wait_log PATTERN SECONDS
  local i; for i in $(seq 1 $(( $2 * 2 ))); do grep -q -- "$1" "$CW_DIR/watchdog.log" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
logbody() { grep -v ' started v' "$CW_DIR/watchdog.log" 2>/dev/null | grep -v 'stopping'; }
CONF_BASE='POLL_SECONDS=1
GRACE_SECONDS=3
MAX_RESTARTS=3
RESTART_WINDOW=3600
NOTIFY_WEBHOOK=http://example.invalid/hook'

echo "1. healthy container: log stays silent (only the start line)"
new_env "$CONF_BASE
docker-proxy running start"
mk docker-proxy running
start_daemon; sleep 6; stop_daemon
[ -z "$(logbody)" ] && ok "no log lines while healthy" || { bad "log not silent:"; logbody; }
grep -q ' started v' "$CW_DIR/watchdog.log" && ok "start line present" || bad "no start line"

echo "2. container stops: restarted only after grace, logged, no webhook"
new_env "$CONF_BASE
docker-proxy running start"
mk docker-proxy running
start_daemon; sleep 2
echo exited > "$FAKE_DIR/docker-proxy/status"; echo "$(now_iso)" > "$FAKE_DIR/docker-proxy/finished"
sleep 1.5
[ ! -s "$FAKE_DIR/actions.log" ] && ok "no action inside the grace period" || bad "acted too early"
wait_log RECOVERED 12 && ok "recovered after grace" || bad "never recovered"
[ "$(cat "$FAKE_DIR/docker-proxy/status")" = running ] && ok "container running again" || bad "container still down"
grep -q 'DOWN (status=exited)' "$CW_DIR/watchdog.log" && ok "DOWN line logged" || bad "no DOWN line"
[ ! -f "$FAKE_DIR/webhook.log" ] && ok "no webhook for a successful restart" || bad "webhook fired"
stop_daemon

echo "3. start keeps failing: gives up after MAX_RESTARTS, ONE webhook, then stops trying"
new_env "$CONF_BASE
docker-proxy running start"
mk docker-proxy exited "$(now_iso)"; touch "$FAKE_DIR/START_FAILS"
start_daemon
wait_log 'HARD DOWN' 25 && ok "HARD DOWN logged" || bad "no HARD DOWN"
sleep 5
n=$(grep -c '^start' "$FAKE_DIR/actions.log"); [ "$n" -eq 3 ] && ok "exactly 3 attempts ($n)" || bad "attempts=$n"
w=$(wc -l < "$FAKE_DIR/webhook.log" 2>/dev/null || echo 0); [ "$w" -eq 1 ] && ok "exactly one webhook" || bad "webhooks=$w"
grep -q 'HARD DOWN' "$FAKE_DIR/webhook.log" && ok "webhook says HARD DOWN" || bad "webhook text"
rm "$FAKE_DIR/START_FAILS"; echo running > "$FAKE_DIR/docker-proxy/status"; sleep 3
grep -q 'running again after being HARD DOWN' "$CW_DIR/watchdog.log" && ok "logs recovery from hard-down" || bad "no hard-down recovery line"
stop_daemon

echo "4. docker unreachable: ONE error line, ONE recovery line, no spam, no restart attempts"
new_env "$CONF_BASE
docker-proxy running start"
mk docker-proxy running
start_daemon; sleep 2
touch "$FAKE_DIR/DOCKER_DOWN"; sleep 9
rm "$FAKE_DIR/DOCKER_DOWN"; sleep 4
e=$(grep -c 'cannot poll docker' "$CW_DIR/watchdog.log"); [ "$e" -eq 1 ] && ok "one poll error line" || bad "error lines=$e"
grep -q 'polling recovered' "$CW_DIR/watchdog.log" && ok "recovery logged" || bad "no recovery line"
[ ! -s "$FAKE_DIR/actions.log" ] && ok "no restart attempted while docker was unreachable" || bad "acted during outage"
stop_daemon

echo "5. PAUSE file: no action while paused, grace restarts on resume"
new_env "$CONF_BASE
docker-proxy running start"
mk docker-proxy exited "2026-11-17T00:00:00Z"
touch "$CW_DIR/PAUSE"
start_daemon; sleep 7
[ ! -s "$FAKE_DIR/actions.log" ] && ok "no action while paused" || bad "acted while paused"
rm "$CW_DIR/PAUSE"; sleep 1.5
[ ! -s "$FAKE_DIR/actions.log" ] && ok "no instant action on resume" || bad "instant action on resume"
wait_log RECOVERED 12 && ok "acted after grace following resume" || bad "never acted after resume"
grep -q 'PAUSE file present' "$CW_DIR/watchdog.log" && grep -q 'PAUSE file removed' "$CW_DIR/watchdog.log" && ok "pause transitions logged" || bad "pause not logged"
stop_daemon

echo "6. ports check: running but ports gone -> recreate; healthy ports -> silent"
new_env "$CONF_BASE
mail-bridge running,ports recreate dir=@T@/compose"
mk mail-bridge running "2026-11-17T00:00:00Z" 1
echo "8080/tcp -> 0.0.0.0:8080" > "$FAKE_DIR/mail-bridge/ports"
start_daemon; sleep 5
[ -z "$(logbody)" ] && ok "silent while ports are published" || { bad "log not silent"; logbody; }
: > "$FAKE_DIR/mail-bridge/ports"
wait_log RECOVERED 14 && ok "recreated and recovered" || bad "no recovery"
grep -q 'force-recreate' "$FAKE_DIR/actions.log" && ok "used --force-recreate" || bad "no force-recreate"
grep -q "cwd=$T/compose" "$FAKE_DIR/actions.log" && ok "ran in the compose folder" || bad "wrong cwd"
stop_daemon

echo "7. missing container with action=start: hard down + one webhook (can't be started)"
new_env "$CONF_BASE
ghost running start"
start_daemon
wait_log 'HARD DOWN' 12 && ok "HARD DOWN for missing container" || bad "no hard down"
sleep 3; w=$(wc -l < "$FAKE_DIR/webhook.log" 2>/dev/null || echo 0); [ "$w" -eq 1 ] && ok "one webhook" || bad "webhooks=$w"
stop_daemon

echo "8. compose-up on a missing container creates it (folder action)"
new_env "$CONF_BASE
docker-proxy running compose-up dir=@T@/compose"
mkdir -p "$FAKE_DIR/docker-proxy"; echo running > /dev/null   # container dir must exist for fake compose to flip it
mk docker-proxy exited "2026-11-17T00:00:00Z"
start_daemon; wait_log RECOVERED 12 && ok "compose-up recovered it" || bad "no recovery"
grep -q 'compose up -d' "$FAKE_DIR/actions.log" && ok "ran docker compose up -d" || bad "wrong command"
stop_daemon

echo "9. config errors are logged once and don't stop valid lines"
new_env "$CONF_BASE
docker-proxy running start
bad!!name running start
mail running,ports start dir=/x
FOO_BAR=3"
mk docker-proxy running
start_daemon; sleep 4; stop_daemon
c=$(grep -c 'config problem' "$CW_DIR/watchdog.log"); [ "$c" -eq 1 ] && ok "config problem logged once" || bad "config problem lines=$c"
grep -q 'unknown setting FOO_BAR' "$CW_DIR/watchdog.log" && ok "unknown setting reported" || bad "no unknown-setting message"

echo "10. --status runs read-only and prints the container"
new_env "$CONF_BASE
docker-proxy running start"
mk docker-proxy running
out=$(bash "$SCRIPT" --status); echo "$out" | grep -q 'docker-proxy' && echo "$out" | grep -q running && ok "--status shows the container" || { bad "--status output"; echo "$out"; }
[ ! -f "$CW_DIR/watchdog.log" ] && ok "--status wrote no log" || bad "--status wrote a log"

echo "13. pull=yes: pulls BEFORE up, logs that a newer image arrived"
new_env "$CONF_BASE
docker-proxy running compose-up dir=@T@/compose pull=yes"
mk docker-proxy exited "2026-11-17T00:00:00Z"; touch "$FAKE_DIR/PULL_NEWIMAGE"
start_daemon; wait_log RECOVERED 14 && ok "recovered" || bad "no recovery"
l1=$(grep -n ' pull' "$FAKE_DIR/actions.log" | head -1 | cut -d: -f1); l2=$(grep -n ' up -d' "$FAKE_DIR/actions.log" | head -1 | cut -d: -f1)
[ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] && ok "pull ran before up -d" || bad "order wrong (pull=$l1 up=$l2)"
grep -q 'NEWER image was downloaded' "$CW_DIR/watchdog.log" && ok "logged that a newer image arrived" || bad "no newer-image line"
stop_daemon

echo "14. pull=yes but image already current: logged as such"
new_env "$CONF_BASE
docker-proxy running compose-up dir=@T@/compose pull=yes"
mk docker-proxy exited "2026-11-17T00:00:00Z"
start_daemon; wait_log RECOVERED 14 && ok "recovered" || bad "no recovery"
grep -q 'image was already current' "$CW_DIR/watchdog.log" && ok "logged already-current" || bad "no already-current line"
stop_daemon

echo "15. pull FAILS (no internet): warned, restart still happens, no webhook"
new_env "$CONF_BASE
docker-proxy running compose-up dir=@T@/compose pull=yes"
mk docker-proxy exited "2026-11-17T00:00:00Z"; touch "$FAKE_DIR/PULL_FAILS"
start_daemon; wait_log RECOVERED 14 && ok "still recovered despite pull failure" || bad "pull failure blocked recovery"
grep -q 'pull FAILED, continuing' "$CW_DIR/watchdog.log" && ok "pull failure logged as WARN" || bad "pull failure not logged"
grep -q 'up -d' "$FAKE_DIR/actions.log" && ok "up -d still ran" || bad "up -d did not run"
[ ! -f "$FAKE_DIR/webhook.log" ] && ok "no webhook for a pull failure" || bad "webhook fired"
stop_daemon

echo "16. default (no pull option): never pulls"
new_env "$CONF_BASE
docker-proxy running compose-up dir=@T@/compose"
mk docker-proxy exited "2026-11-17T00:00:00Z"
start_daemon; wait_log RECOVERED 14 && ok "recovered" || bad "no recovery"
! grep -q ' pull' "$FAKE_DIR/actions.log" && ok "no pull without pull=yes" || bad "pulled unexpectedly"
stop_daemon

echo "17. pull=yes with action start is a config error; bad value rejected"
new_env "$CONF_BASE
a running start pull=yes
b running compose-up dir=/x pull=maybe
docker-proxy running start"
mk docker-proxy running
start_daemon; sleep 3; stop_daemon
grep -q 'a: pull=yes needs action compose-up or recreate' "$CW_DIR/watchdog.log" && ok "pull=yes+start rejected" || bad "pull+start not rejected"
grep -q 'b: pull must be yes or no' "$CW_DIR/watchdog.log" && ok "bad pull value rejected" || bad "bad value accepted"
grep -q ' started v.*watching docker-proxy ' "$CW_DIR/watchdog.log" && ok "valid line still watched" || bad "valid line dropped"

echo "11. installer: fresh install into one folder, docker-proxy line enabled when its folder exists"
T=$(mktemp -d); export FAKE_DIR="$T/docker"; mkdir -p "$FAKE_DIR"; export FAKE_SYSTEMCTL_LOG="$T/sc.log"
export CW_INSTALL_DIR="$T/etc-cw"
mkdir -p /opt/containers/docker-proxy
bash "$HERE/../install.sh" >"$T/out.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && ok "installer exit 0" || { bad "installer rc=$rc"; cat "$T/out.txt"; }
for f in container-watchdog.sh container-watchdog.service watchdog.conf.example install.sh watchdog.conf; do [ -f "$CW_INSTALL_DIR/$f" ] && ok "installed $f" || bad "missing $f"; done
grep -q '^docker-proxy ' "$CW_INSTALL_DIR/watchdog.conf" && ok "docker-proxy line enabled" || bad "docker-proxy line not enabled"
[ "$(stat -c %a "$CW_INSTALL_DIR/watchdog.conf")" = 600 ] && ok "watchdog.conf is mode 600" || bad "conf mode"
grep -q "enable $CW_INSTALL_DIR/container-watchdog.service" "$T/sc.log" && ok "systemd link/enable called on the unit in our folder" || bad "enable not called"
grep -q 'restart container-watchdog.service' "$T/sc.log" && ok "service started" || bad "service not started"

echo "12. installer: re-run keeps edited conf; no docker-proxy folder -> line stays commented"
echo "# my edit" >> "$CW_INSTALL_DIR/watchdog.conf"
bash "$HERE/../install.sh" >"$T/out2.txt" 2>&1
grep -q '^# my edit' "$CW_INSTALL_DIR/watchdog.conf" && ok "existing watchdog.conf untouched" || bad "conf overwritten"
rm -rf /opt/containers/docker-proxy; rmdir /opt/containers 2>/dev/null
export CW_INSTALL_DIR="$T/etc-cw2"
bash "$HERE/../install.sh" >"$T/out3.txt" 2>&1
grep -q '^#docker-proxy ' "$CW_INSTALL_DIR/watchdog.conf" && ! grep -q '^docker-proxy ' "$CW_INSTALL_DIR/watchdog.conf" && ok "line left commented when host has no docker-proxy" || bad "commented-line logic"
bash "$HERE/../install.sh" --uninstall >"$T/out4.txt" 2>&1
grep -q 'disable --now container-watchdog.service' "$T/sc.log" && [ -d "$CW_INSTALL_DIR" ] && ok "--uninstall unregisters but keeps the folder" || bad "uninstall"
bash "$HERE/../install.sh" --purge >"$T/out5.txt" 2>&1
[ ! -d "$CW_INSTALL_DIR" ] && ok "--purge removes the folder" || bad "purge"
unset CW_INSTALL_DIR FAKE_SYSTEMCTL_LOG


echo "18. empty config (docker-proxy line removed): daemon runs quietly and acts on nothing"
new_env "$CONF_BASE"
mk docker-proxy exited "2026-11-17T00:00:00Z"
start_daemon; sleep 5
kill -0 "$DPID" 2>/dev/null && ok "daemon still running with no containers configured" || bad "daemon exited"
grep -q 'watching nothing' "$CW_DIR/watchdog.log" && ok "logs 'watching nothing' once at start" || bad "no 'watching nothing' line"
[ -z "$(logbody)" ] && ok "no other log lines" || { bad "unexpected log lines:"; logbody; }
[ ! -s "$FAKE_DIR/actions.log" ] && ok "touches no container that is not listed" || bad "acted on an unlisted container"
bash "$SCRIPT" --status | grep -q 'no containers configured' && ok "--status says so" || bad "--status for empty config"
stop_daemon

echo "19. line removed while running: reload logged, container left alone afterwards"
new_env "$CONF_BASE
docker-proxy running start"
mk docker-proxy running
start_daemon; sleep 2
printf '%s\n' "$CONF_BASE" > "$CW_DIR/watchdog.conf"
wait_log 'now watching nothing' 6 && ok "config reload logged" || bad "reload not logged"
echo exited > "$FAKE_DIR/docker-proxy/status"; echo "2026-11-17T00:00:00Z" > "$FAKE_DIR/docker-proxy/finished"
sleep 6
[ ! -s "$FAKE_DIR/actions.log" ] && ok "removed container is no longer touched" || bad "acted on a removed container"
stop_daemon

echo "20. compose not available to root: fallback binary found, logged ONCE (even with pull=yes)"
new_env "$CONF_BASE
docker-proxy running compose-up dir=@T@/compose pull=yes"
mk docker-proxy exited "2026-11-17T00:00:00Z"; touch "$FAKE_DIR/NO_COMPOSE"
FB="$T/fallback-compose"; printf '#!/usr/bin/env bash\n[ "$1" = version ] && exit 0\nexec docker compose "$@"\n' > "$FB"; chmod +x "$FB"
export CW_COMPOSE_PATHS="$FB"
start_daemon; wait_log RECOVERED 14 && ok "recovered through the fallback compose binary" || bad "no recovery"
[ "$(grep -c 'docker compose is not available to root' "$CW_DIR/watchdog.log")" = 1 ] && ok "fallback logged exactly once" || bad "fallback line count: $(grep -c 'docker compose is not available' "$CW_DIR/watchdog.log")"
stop_daemon; unset CW_COMPOSE_PATHS

echo "21. installer: --set-webhook writes one live line, replaces it, validates, keeps mode 600"
T=$(mktemp -d); export FAKE_DIR="$T/docker"; mkdir -p "$FAKE_DIR"; export FAKE_SYSTEMCTL_LOG="$T/sc.log"; export CW_INSTALL_DIR="$T/etc-cw"
bash "$HERE/../install.sh" --set-webhook https://discord.com/api/webhooks/1/x >"$T/o0.txt" 2>&1 && bad "set-webhook worked before install" || ok "refused before the watchdog is installed"
bash "$HERE/../install.sh" >"$T/o1.txt" 2>&1
bash "$HERE/../install.sh" --set-webhook https://discord.com/api/webhooks/111/AAAAAA-token >"$T/o2.txt" 2>&1 && ok "set-webhook exit 0" || { bad "set-webhook failed"; cat "$T/o2.txt"; }
[ "$(grep -c '^NOTIFY_WEBHOOK=' "$CW_INSTALL_DIR/watchdog.conf")" = 1 ] && ok "exactly one live NOTIFY_WEBHOOK line" || bad "line count wrong"
bash "$CW_INSTALL_DIR/container-watchdog.sh" --status | grep -q 'webhook: set' && ok "--status shows webhook set" || bad "status does not show it"
grep -q '^# NOTIFY_WEBHOOK=' "$CW_INSTALL_DIR/watchdog.conf" && ok "explanatory comment kept" || bad "comment lost"
bash "$HERE/../install.sh" --set-webhook https://discord.com/api/webhooks/222/BBBBBB-token >"$T/o3.txt" 2>&1
[ "$(grep -c '^NOTIFY_WEBHOOK=' "$CW_INSTALL_DIR/watchdog.conf")" = 1 ] && grep -q '/222/BBBBBB-token$' "$CW_INSTALL_DIR/watchdog.conf" && ok "second run replaces, never duplicates" || bad "replace failed"
[ "$(stat -c %a "$CW_INSTALL_DIR/watchdog.conf")" = 600 ] && ok "conf still mode 600" || bad "conf mode changed"
grep -q 'BBBBBB-token' "$T/o3.txt" && bad "full webhook echoed to the screen" || ok "token not echoed in full"
bash "$HERE/../install.sh" --set-webhook "not-a-url" >"$T/o4.txt" 2>&1 && bad "accepted a non-https value" || ok "rejects a value that is not https://"
bash "$HERE/../install.sh" --set-webhook 'https://x.invalid/a b' >"$T/o5.txt" 2>&1 && bad "accepted a URL with a space" || ok "rejects a URL with a space"
grep -q '/222/BBBBBB-token$' "$CW_INSTALL_DIR/watchdog.conf" && ok "bad input leaves the saved webhook alone" || bad "bad input changed the conf"
unset CW_INSTALL_DIR FAKE_SYSTEMCTL_LOG

echo "22. installer: docker-proxy compose folder taken from the running container"
T=$(mktemp -d); export FAKE_DIR="$T/docker"; mkdir -p "$FAKE_DIR/docker-proxy" "$T/wsl/proxy"; export FAKE_SYSTEMCTL_LOG="$T/sc.log"
echo "$T/wsl/proxy" > "$FAKE_DIR/docker-proxy/workdir"
export CW_INSTALL_DIR="$T/etc-a"
bash "$HERE/../install.sh" >"$T/oa.txt" 2>&1
grep -q "^docker-proxy .*dir=$T/wsl/proxy " "$CW_INSTALL_DIR/watchdog.conf" && ok "line enabled with the container's real folder" || { bad "folder not taken from container"; grep docker-proxy "$CW_INSTALL_DIR/watchdog.conf"; }
! grep -q 'dir=/opt/containers/docker-proxy' "$CW_INSTALL_DIR/watchdog.conf" || ! grep -q '^docker-proxy ' "$CW_INSTALL_DIR/watchdog.conf" && ok "default /opt path not left on the live line" || bad "default path still live"
echo "$T/does-not-exist" > "$FAKE_DIR/docker-proxy/workdir"
export CW_INSTALL_DIR="$T/etc-b"
bash "$HERE/../install.sh" >"$T/ob.txt" 2>&1
! grep -q '^docker-proxy ' "$CW_INSTALL_DIR/watchdog.conf" && grep -q '^#docker-proxy ' "$CW_INSTALL_DIR/watchdog.conf" && ok "container found but folder unknown: line stays commented" || bad "enabled a line with a bad folder"
grep -q 'could not be determined' "$T/ob.txt" && ok "tells the user to set dir= themselves" || bad "no explanation printed"
unset CW_INSTALL_DIR FAKE_SYSTEMCTL_LOG
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
