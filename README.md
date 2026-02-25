# Loopa Xray Installer (v5.0)

Interactive installer/manager for Xray with two inbound types:
- `VLESS + TCP + REALITY`
- `VLESS + TCP + security=none` (no TLS)

## Quick Install
Run as `root` on Ubuntu/Debian:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrVoidLink/loopa-reality-installer/main/loopa-reality.sh)"
```

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
- Main script: `loopa-reality.sh`
- Uninstall helper: `loopa-uninstall.sh`
