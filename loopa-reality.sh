#!/bin/bash
set -e
# Loopa Reality Setup Wizard (v3.4 - fixed config builder)
# Type: VLESS + TCP + REALITY 🔒
# Author: Mr Void 💀

CONFIG="/usr/local/etc/xray/config.json"

err(){ echo "❌ $*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

echo "🌀 Welcome to Loopa Reality inbound creator (v3.4 stable)"
echo "=============================================="
read -p "🔢 Enter port number (e.g. 443): " PORT
read -p "🌍 Enter your domain (e.g. vpn.loopa-vpn.com): " DOMAIN
read -p "🕵️ Enter camouflage SNI (e.g. www.microsoft.com): " CAMO
read -p "🏷 Enter tag name (default: reality-$PORT): " TAG
TAG=${TAG:-reality-$PORT}

# ---------- 🧹 Sanitize domain & SNI ----------
clean_input() {
  local value="$1"
  echo "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[[:space:]]//g' \
          -e 's/–/-/g' -e 's/—/-/g' -e 's/−/-/g' \
          -e 's/․/./g'
}
DOMAIN=$(clean_input "$DOMAIN")
CAMO=$(clean_input "$CAMO")

# Check ASCII-only
if printf %s "$DOMAIN" | LC_ALL=C grep -qP '[^\x00-\x7F]'; then
  err "❌ Domain contains non-ASCII characters. Type with English keyboard."
fi
if printf %s "$CAMO" | LC_ALL=C grep -qP '[^\x00-\x7F]'; then
  err "❌ SNI contains non-ASCII characters. Type with English keyboard."
fi

# Validate host format
echo "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
  || err "❌ Invalid domain format: $DOMAIN"
echo "$CAMO" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
  || err "❌ Invalid SNI format: $CAMO"

echo ""
echo "✅ Summary:"
echo "Port: $PORT"
echo "Domain: $DOMAIN"
echo "SNI: $CAMO"
echo "Tag: $TAG"
echo "----------------------------------------------"
read -p "⚙️ Continue? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && echo "Cancelled." && exit 0

# ---------- Step 2: Ensure deps ----------
REQUIRED=(jq qrencode openssl curl)
for pkg in "${REQUIRED[@]}"; do
  if ! has "$pkg"; then
    echo "➡️ Installing $pkg..."
    apt update -y && apt install -y "$pkg"
  fi
done

# ---------- Step 3: Ensure Xray ----------
if ! has xray; then
  echo "⚙️ Installing Xray from official source..."
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
else
  echo "✅ Xray already installed: $(xray -v | head -n 1)"
fi

# ---------- Step 4: Ensure config.json (always with inbounds & outbounds) ----------
echo "🧱 Ensuring Xray config.json exists..."
mkdir -p "$(dirname "$CONFIG")"

# اگر فایل وجود ندارد، از صفر بساز:
if [ ! -f "$CONFIG" ]; then
  echo "📄 Creating new base config.json..."
  cat > "$CONFIG" <<'JSON'
{
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
JSON
else
  # اگر فایل هست، چک کن آیا inbounds یا outbounds وجود دارند:
  if ! jq -e '.inbounds' "$CONFIG" >/dev/null 2>&1; then
    echo "⚠️ Missing inbounds array — fixing..."
    jq '. + {inbounds: []}' "$CONFIG" > /tmp/x && mv /tmp/x "$CONFIG"
  fi
  if ! jq -e '.outbounds' "$CONFIG" >/dev/null 2>&1; then
    echo "⚠️ Missing outbounds array — adding default freedom outbound..."
    jq '. + {outbounds: [{protocol:"freedom",settings:{}}]}' "$CONFIG" > /tmp/x && mv /tmp/x "$CONFIG"
  fi
  echo "✅ config.json verified and valid."
fi

# ---------- Step 5: Generate keys ----------
echo "🔐 Generating X25519 keypair..."
XOUT=$(xray x25519 2>/dev/null || true)
PRIV=$(echo "$XOUT" | awk -F': ' '/[Pp]rivate/ {print $2; exit}' | tr -d '\r\n')
PUB=$(echo "$XOUT" | awk -F': ' '/Password|Public key|PublicKey/ {print $2; exit}' | tr -d '\r\n')
[ -z "$PRIV" ] && err "❌ Failed to read private key!"
SHORTID=$(openssl rand -hex 8)
UUID=$(cat /proc/sys/kernel/random/uuid)

PRIVFILE="/usr/local/etc/xray/reality-priv-${PORT}.key"
mkdir -p "$(dirname "$PRIVFILE")"
echo -n "$PRIV" > "$PRIVFILE"
chmod 600 "$PRIVFILE"
chown root:root "$PRIVFILE"

# ---------- Step 6: Build inbound ----------
INBOUND=$(jq -n \
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
  }')

TMP=$(mktemp)
jq ".inbounds += [ $INBOUND ]" "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

chmod 644 "$CONFIG"
echo "✅ Inbound appended to config.json successfully."

systemctl restart xray
sleep 2

LINK="vless://${UUID}@${DOMAIN}:${PORT}?security=reality&sni=${CAMO}&pbk=${PUB}&sid=${SHORTID}&fp=chrome&type=tcp#${TAG}"

echo ""
echo "🔗 VLESS REALITY LINK:"
echo "$LINK"
echo ""
echo "📱 QR Code:"
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
