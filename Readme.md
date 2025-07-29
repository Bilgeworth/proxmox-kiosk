# Proxmox Kiosk Installer

Minimal on-device kiosk UI for Proxmox VE hosts using Sway + Chromium:
- TTY1: autologin `kiosk` user → Sway → Chromium in fullscreen to the Proxmox Web UI
- TTY2: normal root console for break-glass troubleshooting
- Ignores laptop lid switch so it runs docked/headless.

## Quick install (run on the Proxmox node)
Replace `bilgeworth/proxmox-kiosk` if you fork/rename.

```bash
curl -fsSL https://raw.githubusercontent.com/bilgeworth/proxmox-kiosk/main/install.sh | bash -s -- --url https://127.0.0.1:8006
```

If you want to avoid the lid policy or tty2 console:

```bash
curl -fsSL https://raw.githubusercontent.com/ilgeworth/proxmox-kiosk/main/install.sh | bash -s -- --url https://127.0.0.1:8006 --no-lid --no-tty2
```

If you want to inspect the script first:
```bash
# Download the script
curl -fsSL -o install.sh https://raw.githubusercontent.com/bilgeworth/proxmox-kiosk/main/install.sh

# Inspect the script
less install.sh

# Then run it
bash install.sh --url https://127.0.0.1:8006
```

### Options

* `--url <URL>`: Web UI URL (default: `https://127.0.0.1:8006`)
* `--user <name>`: kiosk username (default: `kiosk`)
* `--no-tty2`: don’t enable a root console on tty2
* `--no-lid`: don’t install the “ignore lid” policy
* `--browser <chromium|chromium-browser>`: override browser binary

## Uninstall / disable

```bash
curl -fsSL https://raw.githubusercontent.com/bilgeworth/proxmox-kiosk/main/uninstall.sh | bash
```

### Options

* `--REMOVE_USER`: Removes kiosk user account (default: no)
* `--PURGE_PKGS`: Removes sway seatd xwayland chromium fonts-dejavu policykit-1 and x11-xserver-utils, (default: no)

## Notes

* If your USB‑C dock uses **DisplayLink**, install the DisplayLink driver on the *host*; containers/VMs aren’t needed for this setup.
* Certificates: using `127.0.0.1` will prompt for the self‑signed cert. For fewer warnings, set `--url` to your node’s FQDN and install a proper cert in Proxmox.

# quick troubleshooting

`kioskctl status`
`kioskctl doctor`
`kioskctl restart`

## Altered files

> These are **not** used by the installer (it writes the same contents), but are included in the repo for clarity.

### `/etc/systemd/system/getty@tty1.service.d/override.conf`

```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
Type=idle
```

### `/etc/systemd/logind.conf.d/lid.conf`

```ini
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

### `/home/kiosk/.profile`

```sh
# Auto-start sway on VT1
if [ -z "$WAYLAND_DISPLAY" ] && [ "${XDG_VTNR:-}" = "1" ]; then
  exec sway
fi
```

### `/home/kiosk/.config/sway/config`

```ini
set $mod Mod4
output * bg #000000 solid_color
exec /usr/local/bin/kiosk-browser.sh
bindsym $mod+q exec pkill -f chromium
bindsym $mod+Shift+e exec systemctl poweroff
```
