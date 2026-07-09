# Loopa Server Installer (v6.0)

Interactive installer/manager with two sections:
- `Telegram MTProto Proxy`
- `Loopa Xray Configs`

The Xray section supports these connection modes:
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
- Splits the wizard into `Telegram Proxy` and `Loopa Configs`
- Installs required packages (`curl`, `jq`, `openssl`, `qrencode`) if missing
- Installs `xray` if missing
- Ensures `/usr/local/etc/xray/config.json` has required structure
- Adds new inbounds/outbounds (and 2-hop routing rules) without destroying existing ones
- Restarts `xray` safely
- Shows VLESS link + QR code
- Saves config summary files
- Can build and manage official `MTProxy` from Telegram's repository
- Supports multiple independent Telegram proxies on the same server
- Includes full uninstall cleanup flow

## Main Menu
1. Telegram Proxy (MTProto)
2. Loopa Configs (Xray)
3. Exit

## Telegram Proxy Menu
1. Create new MTProto proxy
2. Show proxy link
3. Rotate secret
4. Set/Clear MTProxy tag
5. Refresh Telegram upstream config (restart all)
6. Restart proxy
7. Show status
8. List proxies
9. Remove proxy
10. Back

Important behavior:
- The installer builds `MTProxy` from Telegram's official GitHub repository.
- It downloads `proxy-secret` and `proxy-multi.conf` from `core.telegram.org`.
- Each proxy instance gets its own systemd service and summary file such as `~/loopa-mtproxy-proxy-1.txt`.
- The compiled MTProxy binary and Telegram upstream files are shared across instances.
- If you want Telegram-side channel promotion, register the proxy in `@MTProxybot` and set the returned tag.

## Loopa Configs Menu
1. Create new Reality inbound
2. Create new VLESS TCP inbound (no TLS)
3. Create new VLESS TCP 2-Hop (IRAN -> FOREIGN, no TLS)
4. Create new VLESS WebSocket inbound (no TLS)
5. Create new VLESS WebSocket fronted profile (seller-01 style)
6. Create new VLESS WebSocket TLS fronted profile (seller-02 style)
7. Show existing configs (list + QR)
8. Delete existing configs
9. Firewall (ufw)
10. Stats API (CPU/RAM/Load)
11. Connection stats (IPs now / 10m / 1h / 24h)
12. Back
13. Uninstall Loopa/Xray (full cleanup)

## Connection Stats Option
When you choose option `11`, the wizard can:
- enable real Xray access logging to `/var/log/xray/access.log`
- keep only the last `24` hourly log files
- show `unique client IPs` for:
  - `Active Now`
  - `Last 10 Minutes`
  - `Last 1 Hour`
  - `Last 24 Hours`

Important behavior:
- the report lists unique IPs, not TCP sessions
- `Active Now` comes from live connections
- the time-based windows come from Xray access logs

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

## New VLESS WebSocket TLS Fronted Profile
When you choose option `6`, the wizard asks:
- `Port` (default `443`)
- `Front address/IP` for the client link
- `TLS domain / SNI`
- `WebSocket host header` (default: same as TLS domain)
- `Link name`

What it configures:
- Creates a VLESS inbound with `network=ws` and `security=tls`
- Uses a front address/IP for the link and a separate TLS domain/SNI
- Uses a configurable WebSocket host
- Auto-generates a random seller-style WebSocket path
- Automatically uses standard Let's Encrypt certificate files for the TLS domain
- Auto-generates `Tag` as `vless-ws-tls-fronted-PORT`
- Auto-generates `UUID`
- Generates a client link with `security=tls`, `host`, `path`, and `sni`

Generated files:
- `~/loopa-vless-ws-tls-fronted-PORT.txt`
- `~/loopa-vless-ws-tls-fronted-client-PORT.json`

Important behavior:
- The front address/IP must actually route traffic to this server.
- The TLS certificate must be valid for the TLS domain / SNI.
- If another service is already using the selected port, this profile will not work.

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
- From wizard option `13`
- Directly:

```bash
sudo bash ./loopa-uninstall.sh
```
