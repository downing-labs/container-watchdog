#!/usr/bin/env bash
# container-watchdog installer.  Everything is installed into ONE folder: /etc/container-watchdog
#
#   curl -fsSL https://raw.githubusercontent.com/downing-labs/container-watchdog/main/install.sh -o /tmp/cw-install.sh
#   bash /tmp/cw-install.sh            (asks for your sudo password itself)
#
# Or copy this whole folder to the host and run:  bash install.sh
#
#   bash install.sh                    install or re-run (never overwrites watchdog.conf)
#   bash install.sh --update           fetch the newest files from GitHub, keep watchdog.conf
#   bash install.sh --status           show service state and what the watchdog sees
#   bash install.sh --set-webhook URL  set (or replace) the Discord webhook used for HARD DOWN alerts
#   bash install.sh --retire-portwatch disable the old mail-bridge-portwatch timer (kept, not deleted)
#   bash install.sh --uninstall        stop and unregister the service; the folder is kept
#   bash install.sh --purge            like --uninstall, and delete /etc/container-watchdog
set -u

INSTALL_DIR="${CW_INSTALL_DIR:-/etc/container-watchdog}"
BASE_URL="${CW_BASE_URL:-https://raw.githubusercontent.com/downing-labs/container-watchdog/main}"
FILES="container-watchdog.sh container-watchdog.service watchdog.conf.example install.sh"
SERVICE=container-watchdog.service

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ACTION=install
case "${1:-}" in
  ""|--install) ACTION=install ;;
  --update) ACTION=update ;;
  --status) ACTION=status ;;
  --set-webhook) ACTION=webhook; WEBHOOK_URL="${2:-}" ;;
  --retire-portwatch) ACTION=retire ;;
  --uninstall) ACTION=uninstall ;;
  --purge) ACTION=purge ;;
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

# ---- become root (prompts for the sudo password itself)
if [ "$(id -u)" -ne 0 ]; then
  [ -f "$0" ] || die "run this from a saved file (curl ... -o /tmp/cw-install.sh; bash /tmp/cw-install.sh) so sudo can ask for your password"
  command -v sudo >/dev/null 2>&1 || die "not root and sudo is not installed"
  say "Root is needed - re-running with sudo (enter your password if asked)..."
  exec sudo -E bash "$0" "$@"
fi
command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) not found"
command -v docker >/dev/null 2>&1 || say "WARNING: docker command not found on this host"

SRC="$(cd "$(dirname "$0")" && pwd)"

fetch_files() {   # put the newest/local files into $1
  local dest=$1 f
  if [ "$ACTION" != update ] && [ -f "$SRC/container-watchdog.sh" ] && [ -f "$SRC/container-watchdog.service" ] && [ -f "$SRC/watchdog.conf.example" ]; then
    say "Using files from $SRC"
    for f in $FILES; do [ -f "$SRC/$f" ] && cp "$SRC/$f" "$dest/$f"; done
  else
    command -v curl >/dev/null 2>&1 || die "curl not found - copy the container-watchdog folder to this host and run install.sh from it instead"
    say "Downloading from $BASE_URL"
    for f in $FILES; do
      curl -fsSL --max-time 30 "$BASE_URL/$f" -o "$dest/$f" || die "could not download $f (DMZ hosts may block GitHub - copy the folder over instead)"
    done
  fi
  bash -n "$dest/container-watchdog.sh" || die "container-watchdog.sh failed its syntax check - not installing"
  bash -n "$dest/install.sh" || die "install.sh failed its syntax check - not installing"
  grep -q '^ExecStart=' "$dest/container-watchdog.service" || die "service file looks wrong - not installing"
}

case $ACTION in
  install|update)
    TMP=$(mktemp -d) || die "mktemp failed"
    trap 'rm -rf "$TMP"' EXIT
    fetch_files "$TMP"

    mkdir -p "$INSTALL_DIR" && chmod 755 "$INSTALL_DIR"
    for f in $FILES; do
      if [ -f "$INSTALL_DIR/$f" ] && cmp -s "$TMP/$f" "$INSTALL_DIR/$f"; then continue; fi
      install -m 755 "$TMP/$f" "$INSTALL_DIR/$f.new" && mv -f "$INSTALL_DIR/$f.new" "$INSTALL_DIR/$f"
    done
    chmod 644 "$INSTALL_DIR/container-watchdog.service" "$INSTALL_DIR/watchdog.conf.example"

    if [ ! -f "$INSTALL_DIR/watchdog.conf" ]; then
      cp "$INSTALL_DIR/watchdog.conf.example" "$INSTALL_DIR/watchdog.conf"
      PROXY_DIR=""; PROXY_SEEN=0
      if [ -d /opt/containers/docker-proxy ]; then
        PROXY_DIR=/opt/containers/docker-proxy
      elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx docker-proxy; then
        PROXY_SEEN=1
        d=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' docker-proxy 2>/dev/null)
        if [ -n "$d" ] && [ -d "$d" ]; then PROXY_DIR=$d; fi
      fi
      if [ -n "$PROXY_DIR" ]; then
        esc=$(printf '%s' "$PROXY_DIR" | sed 's/[\\&|]/\\&/g')
        sed -i -e 's/^#\(docker-proxy[[:space:]]\)/\1/' -e "s|dir=/opt/containers/docker-proxy|dir=$esc|" "$INSTALL_DIR/watchdog.conf"
        say "docker-proxy found on this host: enabled in watchdog.conf (compose folder: $PROXY_DIR)"
      elif [ "$PROXY_SEEN" = 1 ]; then
        say "docker-proxy container found, but its compose folder could not be determined: its line is left"
        say "commented out in watchdog.conf. Set dir= yourself, then remove the leading #."
      else
        say "no docker-proxy on this host: its line is left commented out in watchdog.conf"
      fi
      chmod 600 "$INSTALL_DIR/watchdog.conf"
      say "Created $INSTALL_DIR/watchdog.conf"
    else
      say "Kept your existing $INSTALL_DIR/watchdog.conf"
    fi

    systemctl enable "$INSTALL_DIR/$SERVICE" >/dev/null 2>&1 || die "systemctl enable failed"
    systemctl daemon-reload
    systemctl restart container-watchdog.service || die "service failed to start - see: journalctl -u container-watchdog"
    sleep 2
    say
    say "Installed. Everything is in $INSTALL_DIR  (config: watchdog.conf, log: watchdog.log)"
    if systemctl is-enabled mail-bridge-portwatch.timer >/dev/null 2>&1; then
      say
      say "NOTE: the old mail-bridge-portwatch timer is still enabled. Once watchdog.conf has the"
      say "      mail-bridge line and you are happy, run:  bash $INSTALL_DIR/install.sh --retire-portwatch"
    fi
    say
    bash "$INSTALL_DIR/container-watchdog.sh" --status
    ;;

  webhook)
    CONF="$INSTALL_DIR/watchdog.conf"
    [ -f "$CONF" ] || die "not installed ($CONF missing) - run install.sh first"
    case $WEBHOOK_URL in
      https://*) ;;
      *) die "usage: install.sh --set-webhook https://discord.com/api/webhooks/ID/TOKEN" ;;
    esac
    case $WEBHOOK_URL in
      *[[:space:]\\\|\&\"\']*) die "the webhook URL contains a character that is not allowed (space, quote, \\, | or &)" ;;
    esac
    TMPC=$(mktemp) || die "mktemp failed"
    # replace the live NOTIFY_WEBHOOK= line (first one wins, later duplicates dropped), else append; keep the comments
    awk -v u="$WEBHOOK_URL" 'BEGIN{d=0} /^NOTIFY_WEBHOOK=/ {if(!d){print "NOTIFY_WEBHOOK=" u; d=1}; next} {print} END{if(!d) print "NOTIFY_WEBHOOK=" u}' "$CONF" > "$TMPC" \
      && cat "$TMPC" > "$CONF"; rm -f "$TMPC"
    chmod 600 "$CONF"
    # no restart needed: the daemon re-reads the config every cycle
    if bash "$INSTALL_DIR/container-watchdog.sh" --status 2>/dev/null | grep -q 'webhook: set'; then
      say "Webhook saved in $CONF (ends ...${WEBHOOK_URL: -6}). It takes effect within one poll."
      say "Test it with:  bash $INSTALL_DIR/container-watchdog.sh --test-notify"
    else
      die "the webhook was written but --status does not show it as set - check $CONF"
    fi
    ;;

  status)
    [ -f "$INSTALL_DIR/container-watchdog.sh" ] || die "not installed ($INSTALL_DIR missing)"
    systemctl status container-watchdog.service --no-pager -n 0 2>&1 | head -5
    echo
    bash "$INSTALL_DIR/container-watchdog.sh" --status
    ;;

  retire)
    if systemctl list-unit-files mail-bridge-portwatch.timer >/dev/null 2>&1 && systemctl cat mail-bridge-portwatch.timer >/dev/null 2>&1; then
      systemctl disable --now mail-bridge-portwatch.timer
      say "Disabled mail-bridge-portwatch.timer (files kept)."
      say "Roll back with:  systemctl enable --now mail-bridge-portwatch.timer"
    else
      say "No mail-bridge-portwatch.timer found on this host."
    fi
    ;;

  uninstall|purge)
    systemctl disable --now container-watchdog.service >/dev/null 2>&1
    systemctl daemon-reload
    say "container-watchdog stopped and unregistered."
    if [ "$ACTION" = purge ]; then
      rm -rf "$INSTALL_DIR"; say "Deleted $INSTALL_DIR"
    else
      say "Folder kept: $INSTALL_DIR  (delete it with: bash $INSTALL_DIR/install.sh --purge, or rm -rf)"
    fi
    ;;
esac
