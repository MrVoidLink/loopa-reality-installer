#!/bin/bash
set -e
# Loopa Reality Setup Wizard (v4.0 - Manager Edition)
# Type: VLESS + TCP + REALITY 🔒
# Author: Mr Void 💀

CONFIG="/usr/local/etc/xray/config.json"
DATA_DIR="$HOME"
err(){ echo "❌ $*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

# ---------- 🧭 Main Menu ----------
while true; do
  clear
  echo "🌀 Loopa Reality Wizard (v4.0)"
  echo "=============================="
  echo "1) Create new Reality inbound"
  echo "2) Show existing configs (list + QR)"
  echo "3) Exit"
  read -p "Select an option [1-3]: " CHOICE

  case $CHOICE in
    1)
      clear
      echo "🚀 Starting inbound creation..."
      break
      ;;
    2)
      clear
      echo "📂 Available Loopa Reality configs:"
      FILES=($(ls $DATA_DIR/loopa-reality-*.txt 2>/dev/null || true))
      if [ ${#FILES[@]} -eq 0 ]; then
        echo "⚠️ No configs found yet."
        read -p "Press Enter to return to menu..." _
        continue
      fi
      i=1
      for f in "${FILES[@]}"; do
        echo "  $i) $(basename "$f")"
        ((i++))
      done
      echo ""
      read -p "Select a config number: " NUM
      IDX=$((NUM-1))
      [ -z "${FILES[$IDX]}" ] && echo "❌ Invalid choice!" && sleep 1 && continue

      FILE="${FILES[$IDX]}"
      clear
      echo "📄 Showing config: $(basename "$FILE")"
      LINK=$(grep "Reality Link:" "$FILE" | cut -d' ' -f3-)
      if [ -z "$LINK" ]; then
        echo "❌ No link found inside file!"
      else
        echo ""
        echo "🔗 $LINK"
        echo ""
        echo "📱 QR Code:"
        qrencode -t ansiutf8 "$LINK"
      fi
      echo ""
      read -p "Press Enter to return to menu..." _
      continue
      ;;
    3)
      echo "👋 Bye!"
      exit 0
      ;;
    *)
      echo "❌ Invalid option!"
      sleep 1
      continue
      ;;
  esac
done

# ---------- 🧱 Build New Inbound ----------
read -p "🔢 Enter port number (e.g. 443): " PORT
read -p "🌍 Enter your domain (e.g. vpn.loopa-vpn.com): " DOMAIN
read -p "🕵️ Enter camouflage SNI (e.g. www.microsoft.com): " CAMO
read -p "🏷 Enter tag name (default: reality-$PORT): " TAG
TAG=${TAG:-reality-$PORT}

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

# Check ASCII
if printf %s "$DOMAIN" | LC_ALL=C grep -qP '[^\x00-\x7F]'; then err "❌ Domain contains non-ASCII characters."; fi
if printf %s "$CAMO" | LC_ALL=C grep -qP '[^\x00-\x7F]'; then err "❌ SNI contains non-ASCII characters."; fi

# Validate format
echo "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || err "❌ Invalid domain format"
echo "$CAMO" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || err "❌ Invalid SNI format"

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
  echo "⚙️ Installing Xray..."
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
else
  echo "✅ Xray already installed: $(xray -v | head -n 1)"
fi

# ---------- Step 4: Ensure config.json ----------
echo "🧱 Ensuring config.json..."
mkdir -p "$(dirname "$CONFIG")"
if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<'JSON'
{
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
JSON
else
  if ! jq -e '.inbounds' "$CONFIG" >/dev/null 2>&1; then jq '. + {inbounds: []}' "$CONFIG" > /tmp/x && mv /tmp/x "$CONFIG"; fi
  if ! jq -e '.outbounds' "$CONFIG" >/dev/null 2>&1; then jq '. + {outbounds: [{protocol:"freedom",settings:{}}]}' "$CONFIG" > /tmp/x && mv /tmp/x "$CONFIG"; fi
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
echo -n "$PRIV" > "$PRIVFILE"
chmod 600 "$PRIVFILE"

# ---------- Step 6: Add inbound ----------
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
read -p "Press Enter to return to main menu..." _
exec "$0"
