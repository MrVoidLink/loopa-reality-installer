#!/bin/bash
set -e
# Loopa Reality Setup Wizard (v4.0 - Manager Edition)
# Type: VLESS + TCP + REALITY 🔒
# Author: Mr Void 💀

CONFIG="/usr/local/etc/xray/config.json"
DATA_DIR="$HOME"
err(){ echo "❌ $*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

firewall_status() {
  if ! has ufw; then
    echo "Firewall tool (ufw) not installed."
    return 1
  fi
  ufw status 2>/dev/null | head -n1
}

firewall_menu() {
  if ! has ufw; then
    echo "?z??,? Installing ufw (firewall tool)..."
    apt update -y && apt install -y ufw
  fi

  while true; do
    clear
    STATUS_LINE=$(firewall_status)
    STATUS_STATE=$(echo "$STATUS_LINE" | awk '{print $2}')
    echo "dYO? Firewall (ufw)"
    echo "==================="
    echo "$STATUS_LINE"
    if [ "$STATUS_STATE" = "active" ]; then
      echo "1) Turn OFF firewall"
    else
      echo "1) Turn ON firewall"
    fi
    echo "2) Open a port (allow)"
    echo "3) Close a port (delete allow)"
    echo "4) List rules"
    echo "5) Back to main menu"
    read -p "Choose [1-5]: " FWCHOICE

    case $FWCHOICE in
      1)
        if [ "$STATUS_STATE" = "active" ]; then
          ufw disable
          echo "Firewall turned OFF."
        else
          ufw --force enable
          echo "Firewall turned ON."
        fi
        sleep 1
        ;;
      2)
        if [ "$STATUS_STATE" != "active" ]; then
          echo "Firewall is OFF. Turning it ON first..."
          ufw --force enable
          STATUS_STATE="active"
        fi
        read -p "Enter port to open (e.g. 443): " FWPORT
        [ -z "$FWPORT" ] && { echo "No port entered."; sleep 1; continue; }
        ufw allow "${FWPORT}/tcp"
        echo "Allowed TCP port $FWPORT."
        sleep 1
        ;;
      3)
        if [ "$STATUS_STATE" != "active" ]; then
          echo "Firewall is OFF. Nothing to close."
          sleep 1
          continue
        fi
        read -p "Enter port to close (delete allow): " FWPORT
        [ -z "$FWPORT" ] && { echo "No port entered."; sleep 1; continue; }
        if echo y | ufw delete allow "${FWPORT}/tcp"; then
          echo "Closed TCP port $FWPORT."
        else
          echo "Failed to close port $FWPORT."
        fi
        sleep 1
        ;;
      4)
        clear
        ufw status numbered
        echo ""
        read -p "Press Enter to return..." _
        ;;
      5)
        break
        ;;
      *)
        echo "??O Invalid firewall option!"
        sleep 1
        ;;
    esac
  done
}

# ---------- 🧭 Main Menu ----------
while true; do
  clear
  echo "🌀 Loopa Reality Wizard (v4.0)"
  echo "=============================="
  echo "1) Create new Reality inbound"
  echo "2) Show existing configs (list + QR)"
  echo "3) Delete existing configs"
  echo "4) Firewall (ufw)"
  echo "5) Exit"
  read -p "Select an option [1-5]: " CHOICE

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
      clear
      echo "dY\" Delete existing configs"
      FILES=($(ls $DATA_DIR/loopa-reality-*.txt 2>/dev/null || true))
      if [ ${#FILES[@]} -eq 0 ]; then
        echo "?s??,? No configs found yet."
        sleep 1
        continue
      fi
      i=1
      for f in "${FILES[@]}"; do
        echo "  $i) $(basename \"$f\")"
        ((i++))
      done
      echo ""
      read -p "Select a config number to delete: " NUM
      IDX=$((NUM-1))
      if [ -z "${FILES[$IDX]}" ]; then
        echo "??O Invalid choice!"
        sleep 1
        continue
      fi
      FILE="${FILES[$IDX]}"
      echo "Selected: $(basename "$FILE")"
      read -p "Are you sure you want to delete? [y/N]: " DELCHOICE
      if [[ "$DELCHOICE" =~ ^[Yy]$ ]]; then
        TAG_TO_DEL=$(grep "^Tag:" "$FILE" | awk '{print $2}')
        PORT_TO_DEL=$(grep "^Port:" "$FILE" | awk '{print $2}')
        PRIV_TO_DEL=$(grep "^PrivateKeyFile:" "$FILE" | awk '{print $2}')
        [ -z "$TAG_TO_DEL" ] && [ -n "$PORT_TO_DEL" ] && TAG_TO_DEL="reality-$PORT_TO_DEL"
        if [ -f "$CONFIG" ] && [ -n "$TAG_TO_DEL" ]; then
          TMPDEL=$(mktemp)
          if jq --arg tag "$TAG_TO_DEL" '
            if (.inbounds // null) then
              .inbounds = [ (.inbounds[]? | select(.tag != $tag)) ]
            else .
            end
          ' "$CONFIG" > "$TMPDEL"; then
            mv "$TMPDEL" "$CONFIG"
            echo "?o. Removed inbound with tag: $TAG_TO_DEL"
          else
            echo "??O Failed to update $CONFIG"
            rm -f "$TMPDEL"
          fi
        else
          echo "??O No valid tag found to delete."
        fi
        [ -n "$PRIV_TO_DEL" ] && [ -f "$PRIV_TO_DEL" ] && rm -f "$PRIV_TO_DEL"
        rm -f "$FILE"
        systemctl restart xray || true
        echo "dYZ% Config deleted."
      fi
      sleep 1
      continue
      ;;
    4)
      firewall_menu
      continue
      ;;
    5)
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
