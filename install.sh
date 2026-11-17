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
  --retire-portwatch) ACTION=retire ;;
  --uninstall) ACTION=uninstall ;;
  --purge) ACTION=purge ;;
  -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
      if [ -d /opt/containers/docker-proxy ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx docker-proxy; then
        sed -i 's/^#\(docker-proxy[[:space:]]\)/\1/' "$INSTALL_DIR/watchdog.conf"
        say "docker-proxy found on this host: enabled in watchdog.conf"
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
