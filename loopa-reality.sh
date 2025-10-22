#!/bin/bash
set -e
# Loopa Reality Setup Wizard (v3.3 - multi-inbound safe)
# Type: VLESS + TCP + REALITY 🔒
# Author: Mr Void 💀

CONFIG="/usr/local/etc/xray/config.json"
INBOUND_DIR="/usr/local/etc/xray/inbounds"

err(){ echo "❌ $*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

echo "🌀 Welcome to Loopa Reality inbound creator (v3.3)"
echo "=============================================="
read -p "🔢 Enter port number (e.g. 443): " PORT
read -p "🌍 Enter your domain (e.g. vpn.loopa-vpn.com): " DOMAIN
read -p "🕵️ Enter camouflage SNI (e.g. www.microsoft.com): " CAMO
read -p "🏷 Enter tag name (default: reality-$PORT): " TAG
TAG=${TAG:-reality-$PORT}

# ---------- 🧹 Sanitize ----------
clean_input() {
  local value="$1"
  echo "$value" | tr '[:upper:]' '[:lower:]' | sed -e 's/[[:space:]]//g' \
       -e 's/–/-/g' -e 's/—/-/g' -e 's/−/-/g' -e 's/․/./g'
}
DOMAIN=$(clean_input "$DOMAIN")
CAMO=$(clean_input "$CAMO")

# ---------- Validate ----------
[[ $DOMAIN =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || err "❌ Invalid domain: $DOMAIN"
[[ $CAMO =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || err "❌ Invalid SNI: $CAMO"

echo ""
echo "✅ Summary:"
echo "Port: $PORT"
echo "Domain: $DOMAIN"
echo "SNI: $CAMO"
echo "Tag: $TAG"
echo "----------------------------------------------"
read -p "⚙️ Continue? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "Cancelled." && exit 0

# ---------- Step 1: Deps ----------
REQUIRED=(jq qrencode openssl curl)
for pkg in "${REQUIRED[@]}"; do
  has "$pkg" || (echo "➡️ Installing $pkg..." && apt update -y && apt install -y "$pkg")
done

# ---------- Step 2: Xray ----------
if ! has xray; then
  echo "⚙️ Installing Xray..."
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
else
  echo "✅ Xray already installed: $(xray -v | head -n 1)"
fi

# ---------- Step 3: Base config ----------
mkdir -p "$(dirname "$CONFIG")" "$INBOUND_DIR"

if [ ! -f "$CONFIG" ]; then
  echo "🧱 Creating base Xray config.json..."
  cat > "$CONFIG" <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ],
  "include": "/usr/local/etc/xray/inbounds/*.json"
}
JSON
fi

# ---------- Step 4: Keys ----------
echo "🔐 Generating X25519 keypair..."
XOUT=$(xray x25519 2>/dev/null || true)
PRIV=$(echo "$XOUT" | awk -F': ' '/[Pp]rivate/ {print $2; exit}' | tr -d '\r\n')
PUB=$(echo "$XOUT" | awk -F': ' '/Password|Public key|PublicKey/ {print $2; exit}' | tr -d '\r\n')
[ -z "$PRIV" ] && err "❌ Failed to read private key!"
SHORTID=$(openssl rand -hex 8)
UUID=$(cat /proc/sys/kernel/random/uuid)

PRIVFILE="/usr/local/etc/xray/reality-priv-${PORT}.key"
echo -n "$PRIV" > "$PRIVFILE"
chmod 600 "$PRIVFILE"
chown root:root "$PRIVFILE"

# ---------- Step 5: Build inbound file ----------
INBOUND_FILE="$INBOUND_DIR/reality-${PORT}.json"
[ -f "$INBOUND_FILE" ] && err "❌ Inbound for port $PORT already exists: $INBOUND_FILE"

jq -n \
  --arg port "$PORT" --arg tag "$TAG" --arg id "$UUID" \
  --arg priv "$PRIV" --arg short "$SHORTID" --arg camo "$CAMO" '
  {
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

chmod 644 "$INBOUND_FILE"
echo "✅ Created inbound file: $INBOUND_FILE"

# ---------- Step 6: Restart ----------
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
echo "🎉 Reality inbound created successfully!"
