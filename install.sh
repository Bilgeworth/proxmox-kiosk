#!/usr/bin/env bash
set -euo pipefail

# Defaults (can be overridden by flags)
KIOSK_USER="kiosk"
KIOSK_URL="https://127.0.0.1:8006"
ENABLE_TTY2="yes"
IGNORE_LID="yes"
BROWSER_OVERRIDE=""

usage() {
  cat <<EOF
Usage: $0 [--url URL] [--user NAME] [--no-tty2] [--no-lid] [--browser BIN]

--url URL         Proxmox Web UI URL (default: https://127.0.0.1:8006)
--user NAME       Kiosk username (default: kiosk)
--no-tty2         Do not enable a root getty on tty2
--no-lid          Do not install "ignore lid" policy
--browser BIN     Force browser binary (chromium or chromium-browser)
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) KIOSK_URL="$2"; shift 2 ;;
    --user) KIOSK_USER="$2"; shift 2 ;;
    --no-tty2) ENABLE_TTY2="no"; shift ;;
    --no-lid) IGNORE_LID="no"; shift ;;
    --browser) BROWSER_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi
if ! command -v apt >/dev/null 2>&1; then
  echo "This installer expects a Debian/Proxmox host (apt not found)." >&2
  exit 1
fi

echo "[1/9] Installing packages…"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  sway seatd xwayland chromium fonts-dejavu policykit-1 x11-xserver-utils

# Browser binary resolution (allow override)
if [[ -n "$BROWSER_OVERRIDE" ]]; then
  BROWSER_BIN="$BROWSER_OVERRIDE"
else
  BROWSER_BIN="$(command -v chromium || command -v chromium-browser || true)"
fi
if [[ -z "${BROWSER_BIN}" ]]; then
  echo "Chromium not found and no --browser provided. Aborting." >&2
  exit 1
fi

echo "[2/9] Creating or repairing user '${KIOSK_USER}'…"
if ! id -u "${KIOSK_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${KIOSK_USER}"
fi
# Ensure groups (idempotent)
for g in video input render; do
  if getent group "$g" >/dev/null; then
    usermod -aG "$g" "${KIOSK_USER}" || true
  fi
done

echo "[3/9] Enable seatd and (optionally) TTY2 root console…"
systemctl enable --now seatd
if [[ "$ENABLE_TTY2" == "yes" ]]; then
  systemctl enable --now getty@tty2
fi

echo "[4/9] Configure autologin on tty1 for ${KIOSK_USER}…"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
Type=idle
EOF

echo "[5/9] Install kiosk helper scripts…"
install -o root -g root -m 0755 -d /usr/local/bin

# Browser launcher: write to a user-writable runtime dir
cat >/usr/local/bin/kiosk-browser.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
URL="\${1:-${KIOSK_URL}}"
BROWSER_BIN="${BROWSER_BIN}"
# Prefer XDG_RUNTIME_DIR; fallback to /run/user/UID; final fallback /tmp
RUNDIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/kiosk-chrome"
if [[ ! -d "\${RUNDIR}" ]]; then
  mkdir -p "\${RUNDIR}" 2>/dev/null || RUNDIR="/tmp/kiosk-chrome"
  mkdir -p "\${RUNDIR}" 2>/dev/null || true
fi
exec "\${BROWSER_BIN}" --kiosk --incognito --user-data-dir="\${RUNDIR}" \
  --noerrdialogs --disable-session-crashed-bubble "\${URL}"
EOF
chmod +x /usr/local/bin/kiosk-browser.sh

# Management helper
cat >/usr/local/bin/kioskctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
USER="${KIOSK_USER:-kiosk}"
LOG="/home/${KIOSK_USER:-kiosk}/.sway.log"
cmd="${1:-status}"
case "$cmd" in
  restart)
    loginctl terminate-user "$USER" || true
    systemctl restart getty@tty1
    echo "kiosk restarted."
    ;;
  stop)
    loginctl terminate-user "$USER" || true
    echo "kiosk stopped."
    ;;
  start)
    systemctl start getty@tty1
    echo "kiosk started."
    ;;
  status)
    systemctl is-active --quiet seatd && echo "seatd: active" || echo "seatd: INACTIVE"
    systemctl is-active --quiet getty@tty1 && echo "getty@tty1: active" || echo "getty@tty1: INACTIVE"
    id "$USER" || true
    ls -l /dev/dri 2>/dev/null || true
    if [[ -f "$LOG" ]]; then
      echo "--- last 20 lines of $LOG ---"
      tail -n 20 "$LOG" || true
    else
      echo "No sway log yet at $LOG."
    fi
    ;;
  log)
    exec tail -n 200 -f "$LOG"
    ;;
  doctor)
    echo "[doctor] Checking seatd…"
    systemctl is-active --quiet seatd || { echo " seatd not active"; systemctl status seatd --no-pager; }
    echo "[doctor] DRM nodes…"
    ls -l /dev/dri || echo " no /dev/dri — headless or missing DRM driver."
    echo "[doctor] Groups…"
    id "$USER"
    echo "[doctor] Sway log…"
    if [[ -f "$LOG" ]]; then tail -n 120 "$LOG"; else echo " no log yet"; fi
    ;;
  *)
    echo "Usage: kioskctl {start|stop|restart|status|log|doctor}"
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/kioskctl
# substitute kiosk user into kioskctl
sed -i "s/\${KIOSK_USER:-kiosk}/${KIOSK_USER}/g" /usr/local/bin/kioskctl

echo "[6/9] Write Sway config…"
install -o "${KIOSK_USER}" -g "${KIOSK_USER}" -d "/home/${KIOSK_USER}/.config/sway"
cat >"/home/${KIOSK_USER}/.config/sway/config" <<'EOF'
set $mod Mod4
output * bg #000000 solid_color

# start browser in kiosk
exec /usr/local/bin/kiosk-browser.sh

# minimal bindings
bindsym $mod+q exec pkill -f chromium
bindsym $mod+Shift+e exec systemctl poweroff
EOF
chown -R "${KIOSK_USER}:${KIOSK_USER}" "/home/${KIOSK_USER}/.config"

echo "[7/9] Auto-start Sway on tty1 (robust XDG_RUNTIME_DIR + logging)…"
cat >"/home/${KIOSK_USER}/.profile" <<'EOF'
# Auto-start sway on VT1; log to ~/.sway.log
if [ -z "$WAYLAND_DISPLAY" ] && [ "${XDG_VTNR:-}" = "1" ]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" || true
  exec sway -d 2>~/.sway.log
fi
EOF
chown "${KIOSK_USER}:${KIOSK_USER}" "/home/${KIOSK_USER}/.profile"

echo "[8/9] Ignore lid switch (for docked/headless) …"
if [[ "$IGNORE_LID" == "yes" ]]; then
  mkdir -p /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/lid.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  systemctl restart systemd-logind
fi

echo "[9/9] Reloading systemd and starting kiosk…"
systemctl daemon-reload
# bounce tty1 to pick up autologin immediately; safe if not active yet
loginctl terminate-user "${KIOSK_USER}" 2>/dev/null || true
systemctl restart getty@tty1 || true

# Post-check (best-effort): wait for sway to write a log and show status
sleep 2
echo
echo "=== kiosk status ==="
kioskctl status || true
echo
echo "If the screen is still black with a cursor, run:  kioskctl doctor"
echo "To restart the kiosk session:                  kioskctl restart"
echo
echo "Done."
