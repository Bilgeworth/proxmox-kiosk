#!/usr/bin/env bash
set -euo pipefail

KIOSK_USER="${KIOSK_USER:-kiosk}"
PURGE_PKGS="${PURGE_PKGS:-no}"
REMOVE_USER="${REMOVE_USER:-no}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

echo "[1/5] Stop kiosk session if running…"
loginctl terminate-user "${KIOSK_USER}" 2>/dev/null || true

echo "[2/5] Remove tty1 autologin override…"
rm -rf /etc/systemd/system/getty@tty1.service.d
systemctl daemon-reload
systemctl restart getty@tty1 || true

echo "[3/5] Remove lid ignore policy (if present)…"
rm -f /etc/systemd/logind.conf.d/lid.conf || true
systemctl restart systemd-logind || true

echo "[4/5] Remove kiosk artifacts…"
rm -f /usr/local/bin/kiosk-browser.sh /usr/local/bin/kioskctl || true
rm -rf "/home/${KIOSK_USER}/.config/sway" "/home/${KIOSK_USER}/.profile" || true

if [[ "${REMOVE_USER}" == "yes" ]]; then
  deluser --remove-home "${KIOSK_USER}" 2>/dev/null || true
fi

if [[ "${PURGE_PKGS}" == "yes" ]]; then
  apt purge -y sway seatd xwayland chromium fonts-dejavu policykit-1 x11-xserver-utils || true
  apt autoremove -y || true
fi

echo "Uninstall complete."
