#!/bin/bash
set -e
# Loopa Reality Setup Wizard (v3.6 - safe config + auto merge)
# Type: VLESS + TCP + REALITY 🔒
# Author: Mr Void 💀

CONFIG="/usr/local/etc/xray/config.json"
INBOUND_DIR="/usr/local/etc/xray/inbounds"
MERGE_SCRIPT="/usr/local/bin/xray_merge.py"
SERVICE_DROPIN="/etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf"

err(){ echo "❌ $*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

echo "🌀 Welcome to Loopa Reality inbound creator (v3.6)"
echo "=============================================="
read -p "🔢 Enter port number (e.g. 443): " PORT
read -p "🌍 Enter your domain (e.g. vpn.loopa-vpn.com): " DOMAIN
read -p "🕵️ Enter camouflage SNI (e.g. www.microsoft.com): " CAMO
read -p "🏷 Enter tag name (default: reality-$PORT): " TAG
TAG=${TAG:-reality-$PORT}

# ---------- Step 0: Prepare deps ----------
REQUIRED=(jq qrencode openssl curl python3)
for pkg in "${REQUIRED[@]}"; do
  has "$pkg" || (echo "➡️ Installing $pkg..." && apt update -y && apt install -y "$pkg")
done

mkdir -p "$(dirname "$CONFIG")" "$INBOUND_DIR"

# ---------- Step 1: Base Xray config ----------
if [ ! -s "$CONFIG" ]; then
  echo "🧱 Creating base Xray config.json..."
  mkdir -p "$(dirname "$CONFIG")"
  cat <<EOF | sudo tee "$CONFIG" >/dev/null
{
  "log": { "loglevel": "warning" },
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF
  if [ ! -s "$CONFIG" ]; then
    err "❌ Failed to write $CONFIG"
  fi
else
  echo "✅ Existing config.json found."
fi

# ---------- Step 2: Create Python merge script ----------
if [ ! -f "$MERGE_SCRIPT" ]; then
  echo "🐍 Installing xray_merge.py..."
  cat > "$MERGE_SCRIPT" <<'PYCODE'
#!/usr/bin/env python3
import json, glob, os

BASE_DIR = "/usr/local/etc/xray"
OUTPUT_FILE = os.path.join(BASE_DIR, "merged.json")
files = glob.glob(os.path.join(BASE_DIR, "**/*.json"), recursive=True)
merged = {"log": {"loglevel": "warning"}, "inbounds": [], "outbounds": []}

for f in files:
    try:
        with open(f) as fp:
            data = json.load(fp)
            if isinstance(data, dict):
                if all(k in data for k in ["protocol", "port"]):
                    merged["inbounds"].append(data)
                elif "inbounds" in data:
                    merged["inbounds"].extend(data["inbounds"])
                if "outbounds" in data:
                    merged["outbounds"].extend(data["outbounds"])
    except Exception as e:
        print(f"⚠️ Error reading {f}: {e}")

seen = set()
merged["inbounds"] = [
    i for i in merged["inbounds"]
    if not (i.get("tag") in seen or seen.add(i.get("tag")))
]

with open(OUTPUT_FILE, "w") as fp:
    json.dump(merged, fp, indent=2)

print(f"✅ Merged {len(files)} files into {OUTPUT_FILE}")
PYCODE
  chmod +x "$MERGE_SCRIPT"
fi

# ---------- Step 3: Patch systemd for merge ----------
if [ ! -f "$SERVICE_DROPIN" ]; then
  echo "⚙️ Configuring systemd to auto-merge before Xray start..."
  mkdir -p "$(dirname "$SERVICE_DROPIN")"
  cat > "$SERVICE_DROPIN" <<EOF
[Service]
User=root
ExecStart=
ExecStartPre=/usr/bin/python3 $MERGE_SCRIPT
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/merged.json
EOF
  systemctl daemon-reload
fi

# ---------- Step 4: Generate Keys ----------
echo "🔐 Generating X25519 keypair..."
XOUT=$(xray x25519 2>/dev/null || true)
PRIV=$(echo "$XOUT" | awk -F': ' '/[Pp]rivate/ {print $2; exit}' | tr -d '\r\n')
PUB=$(echo "$XOUT" | awk -F': ' '/Public/ {print $2; exit}' | tr -d '\r\n')
[ -z "$PRIV" ] && err "❌ Failed to read private key!"
SHORTID=$(openssl rand -hex 8)
UUID=$(cat /proc/sys/kernel/random/uuid)

PRIVFILE="/usr/local/etc/xray/reality-priv-${PORT}.key"
echo -n "$PRIV" > "$PRIVFILE"
chmod 600 "$PRIVFILE"

# ---------- Step 5: Create inbound ----------
INBOUND_FILE="$INBOUND_DIR/reality-${PORT}.json"
[ -f "$INBOUND_FILE" ] && err "❌ Inbound for port $PORT already exists!"

jq -n \
  --arg port "$PORT" --arg tag "$TAG" --arg id "$UUID" \
  --arg priv "$PRIV" --arg short "$SHORTID" --arg camo "$CAMO" '
  {
    listen: "0.0.0.0",
    port: ($port|tonumber),
    protocol: "vless",
    tag: $tag,
    settings: { clients: [{ id: $id }], decryption: "none" },
    streamSettings: {
      network: "tcp",
      security: "reality",
      realitySettings: {
        privateKey: $priv,
        shortIds: [$short],
        serverNames: [$camo],
        dest: ($camo + ":443"),
        show: false,
        spiderX: "/"
      }
    }
  }' > "$INBOUND_FILE"

echo "✅ Created inbound file: $INBOUND_FILE"

# ---------- Step 6: Restart Xray ----------
echo "🔁 Restarting Xray with auto-merge..."
systemctl daemon-reload
systemctl restart xray
sleep 2

LINK="vless://${UUID}@${DOMAIN}:${PORT}?security=reality&sni=${CAMO}&pbk=${PUB}&sid=${SHORTID}&fp=chrome&type=tcp#${TAG}"

echo ""
echo "🔗 VLESS REALITY LINK:"
echo "$LINK"
echo ""
qrencode -t ansiutf8 "$LINK"

cat > ~/loopa-reality-${PORT}.txt <<EOF
Tag: $TAG
Port: $PORT
Domain: $DOMAIN
SNI: $CAMO
UUID: $UUID
PublicKey: $PUB
PrivateKeyFile: $PRIVFILE
ShortId: $SHORTID
Reality Link: $LINK
EOF

echo ""
echo "✅ Saved info to: ~/loopa-reality-${PORT}.txt"
echo "🎉 Reality inbound created and auto-merged successfully!"
