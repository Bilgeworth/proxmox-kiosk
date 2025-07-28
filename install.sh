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

echo "[1/8] Installing packages…"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  sway seatd xwayland chromium fonts-dejavu policykit-1 \
  x11-xserver-utils

if [[ -n "$BROWSER_OVERRIDE" ]]; then
  BROWSER_BIN="$BROWSER_OVERRIDE"
else
  BROWSER_BIN="$(command -v chromium || command -v chromium-browser || true)"
fi

if [[ -z "${BROWSER_BIN}" ]]; then
  echo "Chromium not found and no --browser provided. Aborting." >&2
  exit 1
fi

echo "[2/8] Creating user '${KIOSK_USER}' if needed…"
if ! id -u "${KIOSK_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${KIOSK_USER}"
fi
for g in video input render; do
  if getent group "$g" >/dev/null; then
    usermod -aG "$g" "${KIOSK_USER}"
  fi
done

echo "[3/8] Enable seatd and TTY2 root console…"
systemctl enable --now seatd
if [[ "$ENABLE_TTY2" == "yes" ]]; then
  systemctl enable --now getty@tty2
fi

echo "[4/8] Configure autologin on tty1 for ${KIOSK_USER}…"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
Type=idle
EOF

echo "[5/8] Install kiosk launcher and Sway config…"
install -o root -g root -m 0755 -d /usr/local/bin
cat >/usr/local/bin/kiosk-browser.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
URL="\${1:-${KIOSK_URL}}"
RUNDIR="/run/${KIOSK_USER}-chrome"
mkdir -p "\${RUNDIR}"
exec "${BROWSER_BIN}" --kiosk --incognito --user-data-dir="\${RUNDIR}" \
  --noerrdialogs --disable-session-crashed-bubble "\${URL}"
EOF
chmod +x /usr/local/bin/kiosk-browser.sh

install -o "${KIOSK_USER}" -g "${KIOSK_USER}" -d "/home/${KIOSK_USER}/.config/sway"
cat >"/home/${KIOSK_USER}/.config/sway/config" <<'EOF'
set $mod Mod4
output * bg #000000 solid_color

# start browser in kiosk
exec /usr/local/bin/kiosk-browser.sh

# minimal bindings (optional)
bindsym $mod+q exec pkill -f chromium
bindsym $mod+Shift+e exec systemctl poweroff
EOF
chown -R "${KIOSK_USER}:${KIOSK_USER}" "/home/${KIOSK_USER}/.config"

echo "[6/8] Auto-start Sway on tty1 for ${KIOSK_USER}…"
cat >"/home/${KIOSK_USER}/.profile" <<'EOF'
# Auto-start sway on VT1
if [ -z "$WAYLAND_DISPLAY" ] && [ "${XDG_VTNR:-}" = "1" ]; then
  exec sway
fi
EOF
chown "${KIOSK_USER}:${KIOSK_USER}" "/home/${KIOSK_USER}/.profile"

echo "[7/8] Ignore lid switch (for docked/headless) …"
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

echo "[8/8] Reloading systemd and starting kiosk…"
systemctl daemon-reload
# bounce tty1 to pick up autologin immediately
systemctl restart getty@tty1 || true

cat <<EOF

Done.

- TTY1: kiosk session (Sway → Chromium to ${KIOSK_URL})
- TTY2: root console (Ctrl+Alt+F2) for troubleshooting

Useful commands:
  loginctl terminate-user ${KIOSK_USER}   # stop kiosk session
  systemctl restart getty@tty1            # restart kiosk session
  systemctl status pveproxy pvedaemon     # check Proxmox services

EOF