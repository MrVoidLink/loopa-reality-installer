# Loopa Xray Installer (v5.0)

Interactive installer/manager for Xray with two inbound types:
- `VLESS + TCP + REALITY`
- `VLESS + TCP + security=none` (no TLS)

## Quick Install
Run as `root` on Ubuntu/Debian:

```bash
bash -c 'set -e; TMP_DIR="$(mktemp -d)"; curl -fsSL https://github.com/MrVoidLink/loopa-reality-installer/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP_DIR"; SCRIPT_PATH="$(find "$TMP_DIR" -type f -name loopa-reality.sh | head -n1)"; [ -n "$SCRIPT_PATH" ] || { echo "loopa-reality.sh not found in archive"; exit 1; }; cd "$(dirname "$SCRIPT_PATH")"; bash ./loopa-reality.sh'
```

Why this command: the installer is now modular and loads `lib/` and `features/`, so it must run from the project folder, not as a single raw script.

## What It Does
- Installs required packages (`curl`, `jq`, `openssl`, `qrencode`) if missing
- Installs `xray` if missing
- Ensures `/usr/local/etc/xray/config.json` has required structure
- Adds new inbounds without destroying existing ones
- Restarts `xray` safely
- Shows VLESS link + QR code
- Saves config summary files

## Menu
1. Create new Reality inbound
2. Create new VLESS TCP inbound (no TLS)
3. Show existing configs (list + QR)
4. Delete existing configs
5. Firewall (ufw)
6. Stats API (CPU/RAM/Load)
7. Exit

## New VLESS (no TLS) Option
When you choose option `2`, the wizard asks:
- `Port`
- `Tag` (default `vless-PORT`)
- `UUID` (optional, auto-generate if empty)
- `Link name`

Important behavior:
- It does **not** ask for server IP.
- It auto-detects public IPv4 and uses it in the generated client link.

Output files:
- `~/loopa-vless-PORT.txt` (summary + link)
- `~/loopa-vless-client-PORT.json` (client config template)

## Reality Option
When you choose option `1`, the wizard asks:
- `Port`
- `Domain`
- `Camouflage SNI`
- `Tag` (default `reality-PORT`)

Output file:
- `~/loopa-reality-PORT.txt`

## Requirements
- Ubuntu/Debian with `systemd`
- Root access
- Internet access

## Paths
- Xray config: `/usr/local/etc/xray/config.json`
- Main script: `xray-Reality/loopa-reality.sh`
- Modules: `xray-Reality/lib/` and `xray-Reality/features/`
- Uninstall helper: `xray-Reality/loopa-uninstall.sh`
