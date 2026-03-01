create_reality_inbound() {
  clear
  echo "Create new Reality inbound"
  read -rp "Enter port number (e.g. 443): " PORT
  validate_port "$PORT"

  read -rp "Enter your domain (e.g. vpn.loopa-vpn.com): " DOMAIN
  read -rp "Enter camouflage SNI (e.g. www.microsoft.com): " CAMO
  read -rp "Enter tag name (default: reality-$PORT): " TAG
  TAG=${TAG:-reality-$PORT}

  DOMAIN=$(clean_input "$DOMAIN")
  CAMO=$(clean_input "$CAMO")
  validate_domain "$DOMAIN"
  validate_domain "$CAMO"

  ensure_packages
  ensure_xray
  ensure_config
  ensure_tag_port_free "$TAG" "$PORT"

  echo "Generating X25519 keypair..."
  XOUT=$(xray x25519 2>/dev/null || true)
  PRIV=$(echo "$XOUT" | awk -F': ' '/[Pp]rivate/ {print $2; exit}' | tr -d '\r\n')
  PUB=$(echo "$XOUT" | awk -F': ' '/Password|Public key|PublicKey/ {print $2; exit}' | tr -d '\r\n')
  [ -z "$PRIV" ] && err "Failed to read private key."
  SHORTID=$(openssl rand -hex 8)
  UUID=$(cat /proc/sys/kernel/random/uuid)

  PRIVFILE="/usr/local/etc/xray/reality-priv-${PORT}.key"
  echo -n "$PRIV" > "$PRIVFILE"
  chmod 600 "$PRIVFILE"

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
  restart_xray || err "xray service failed to start."

  LINK="vless://${UUID}@${DOMAIN}:${PORT}?security=reality&sni=${CAMO}&pbk=${PUB}&sid=${SHORTID}&fp=chrome&type=tcp#${TAG}"
  INFO_FILE="$DATA_DIR/loopa-reality-${PORT}.txt"

  cat > "$INFO_FILE" <<EOF
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
  echo "VLESS REALITY LINK:"
  echo "$LINK"
  echo ""
  qrencode -t ansiutf8 "$LINK"
  echo ""
  echo "Saved info to: $INFO_FILE"
  read -rp "Press Enter to return..." _
}
