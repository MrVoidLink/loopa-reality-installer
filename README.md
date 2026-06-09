# Loopa Xray Installer (v5.0)

Interactive installer/manager for Xray with these connection modes:
- `VLESS + TCP + REALITY`
- `VLESS + TCP + security=none` (no TLS)
- `VLESS + WebSocket + security=none` (no TLS)
- `VLESS + TCP + security=none` 2-Hop (`IRAN -> FOREIGN`)

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
- Adds new inbounds/outbounds (and 2-hop routing rules) without destroying existing ones
- Restarts `xray` safely
- Shows VLESS link + QR code
- Saves config summary files
- Includes full uninstall cleanup flow

## Menu
1. Create new Reality inbound
2. Create new VLESS TCP inbound (no TLS)
3. Create new VLESS TCP 2-Hop (IRAN -> FOREIGN, no TLS)
4. Create new VLESS WebSocket inbound (no TLS)
5. Create new VLESS WebSocket fronted profile (seller-01 style)
6. Show existing configs (list + QR)
7. Delete existing configs
8. Firewall (ufw)
9. Stats API (CPU/RAM/Load)
10. Exit
11. Uninstall Loopa/Xray (full cleanup)

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

## New VLESS WebSocket (no TLS) Option
When you choose option `4`, the wizard asks:
- `Port`
- `Public host/IP` for the client link
- `WebSocket host header` (default `vip.proyaar.ir`)
- `Link name`

What it configures:
- Creates a VLESS inbound with `network=ws` and `security=none`
- Generates a client link with `type=ws`, `host`, and `path`
- Saves a matching client JSON template
- Auto-generates `Tag` as `vless-ws-PORT`
- Auto-generates `UUID`
- Uses fixed WebSocket path `/`

Generated files:
- `~/loopa-vless-ws-PORT.txt`
- `~/loopa-vless-ws-client-PORT.json`

Important behavior:
- If the client link address is different from the real server IP/domain, you must place a reverse proxy/CDN/fronting layer in front of Xray so that WebSocket traffic reaches this inbound.

## New VLESS WebSocket Fronted Profile
When you choose option `5`, the wizard asks:
- `Port`
- `Front address/domain` for the client link
- `WebSocket host header`
- `Link name`

What it configures:
- Creates a VLESS inbound with `network=ws` and `security=none`
- Uses a separate WebSocket host that can be different from the front address/domain
- Uses fixed WebSocket path `/`
- Auto-generates `Tag` as `vless-ws-fronted-PORT`
- Auto-generates `UUID`
- Generates a client link where link address and WebSocket host can be intentionally different

Generated files:
- `~/loopa-vless-fronted-PORT.txt`
- `~/loopa-vless-fronted-client-PORT.json`

Important behavior:
- The front address/domain must actually route traffic to this server. If it does not, this profile will not work.

## VLESS 2-Hop Option
When you choose option `3`, the wizard asks:
- `IRAN inbound port`
- `IRAN inbound tag` (default `vless2hop-PORT`)
- `Client UUID` (optional, auto-generate if empty)
- `Client link name`
- `FOREIGN host` (IP or domain)
- `FOREIGN inbound port`
- `FOREIGN inbound UUID` (optional, auto-generate if empty)
- `IRAN public host` for client link

What it configures:
- On IRAN: creates a VLESS TCP noTLS inbound for clients
- On IRAN: creates a VLESS outbound to FOREIGN
- On IRAN: adds routing rule so all traffic from that inbound goes to FOREIGN outbound

Generated files:
- `~/loopa-vless-2hop-IRAN_PORT.txt` (summary + client link)
- `~/loopa-foreign-setup-FOREIGN_PORT.sh` (run this on FOREIGN to create inbound there)

Optional automation:
- The wizard can try to apply the FOREIGN setup over SSH directly.
- If skipped (or SSH fails), copy and run `loopa-foreign-setup-FOREIGN_PORT.sh` on FOREIGN manually.

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

## Full Uninstall
You can run uninstall in two ways:
- From wizard option `11`
- Directly:

```bash
sudo bash ./loopa-uninstall.sh
```
