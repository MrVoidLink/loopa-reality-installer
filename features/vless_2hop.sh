write_foreign_setup_script() {
  local script_path="$1"
  local foreign_port="$2"
  local foreign_uuid="$3"
  local foreign_tag="$4"
  local iran_ip="$5"

  cat > "$script_path" <<EOF
#!/bin/bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
XRAY_INSTALL_URL="$XRAY_INSTALL_URL"
FOREIGN_PORT="$foreign_port"
FOREIGN_UUID="$foreign_uuid"
FOREIGN_TAG="$foreign_tag"
IRAN_SERVER_IP="$iran_ip"

err() { echo "ERROR: \$*" >&2; exit 1; }
has() { command -v "\$1" >/dev/null 2>&1; }

if [ "\${EUID:-\$(id -u)}" -ne 0 ]; then
  err "Please run this script as root."
fi

for pkg in jq curl; do
  if ! has "\$pkg"; then
    apt update -y
    apt install -y "\$pkg"
  fi
done

if ! has xray; then
  bash <(curl -L "\$XRAY_INSTALL_URL") install
fi

mkdir -p "\$(dirname "\$CONFIG")"
if [ ! -f "\$CONFIG" ]; then
  cat > "\$CONFIG" <<'JSON'
{
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
JSON
else
  if ! jq -e '.inbounds' "\$CONFIG" >/dev/null 2>&1; then
    jq '. + {inbounds: []}' "\$CONFIG" > /tmp/xray_cfg_tmp && mv /tmp/xray_cfg_tmp "\$CONFIG"
  fi
  if ! jq -e '.outbounds' "\$CONFIG" >/dev/null 2>&1; then
    jq '. + {outbounds: [{protocol:"freedom",settings:{}}]}' "\$CONFIG" > /tmp/xray_cfg_tmp && mv /tmp/xray_cfg_tmp "\$CONFIG"
  fi
fi

jq -e --argjson p "\$FOREIGN_PORT" '.inbounds[]? | select((.port // -1) == \$p)' "\$CONFIG" >/dev/null 2>&1 && err "Port \$FOREIGN_PORT already exists."
jq -e --arg tag "\$FOREIGN_TAG" '.inbounds[]? | select((.tag // "") == \$tag)' "\$CONFIG" >/dev/null 2>&1 && err "Tag \$FOREIGN_TAG already exists."

INBOUND=\$(jq -n \
  --arg port "\$FOREIGN_PORT" --arg tag "\$FOREIGN_TAG" --arg id "\$FOREIGN_UUID" '
  {
    port: (\$port|tonumber),
    listen: "0.0.0.0",
    protocol: "vless",
    tag: \$tag,
    settings: {
      clients: [{ id: \$id, level: 8 }],
      decryption: "none"
    },
    streamSettings: {
      network: "tcp",
      security: "none",
      tcpSettings: {
        header: { type: "none" }
      }
    }
  }')

TMP=\$(mktemp)
jq ".inbounds += [ \$INBOUND ]" "\$CONFIG" > "\$TMP" && mv "\$TMP" "\$CONFIG"
chmod 644 "\$CONFIG"

systemctl restart xray
sleep 1
systemctl is-active --quiet xray || err "xray failed to start."

if has ufw && ufw status 2>/dev/null | head -n1 | grep -q "active"; then
  if [[ "\$IRAN_SERVER_IP" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]]; then
    ufw allow from "\$IRAN_SERVER_IP" to any port "\$FOREIGN_PORT" proto tcp
    ufw deny proto tcp from any to any port "\$FOREIGN_PORT" || true
  else
    echo "Could not detect a valid IRAN public IP automatically."
    echo "Run manually:"
    echo "  sudo ufw allow proto tcp from <IRAN_SERVER_PUBLIC_IP> to any port \$FOREIGN_PORT"
    echo "  sudo ufw deny  proto tcp from any to any port \$FOREIGN_PORT"
  fi
fi

echo "FOREIGN inbound created."
echo "Port: \$FOREIGN_PORT"
echo "Tag: \$FOREIGN_TAG"
echo "UUID: \$FOREIGN_UUID"
EOF
  chmod +x "$script_path"
}

apply_foreign_setup_over_ssh() {
  local script_path="$1"
  local foreign_host="$2"
  local SSH_USER SSH_PORT REMOTE_SCRIPT

  if ! has ssh; then
    echo "ssh is not installed. Skipping remote FOREIGN setup."
    return 1
  fi

  read -rp "SSH user for FOREIGN [root]: " SSH_USER
  SSH_USER=${SSH_USER:-root}
  read -rp "SSH port [22]: " SSH_PORT
  SSH_PORT=${SSH_PORT:-22}
  validate_port "$SSH_PORT"

  REMOTE_SCRIPT="/tmp/loopa-foreign-setup.sh"
  echo "Uploading and executing setup script on FOREIGN..."

  if has scp; then
    scp -P "$SSH_PORT" "$script_path" "${SSH_USER}@${foreign_host}:${REMOTE_SCRIPT}" || return 1
    ssh -p "$SSH_PORT" "${SSH_USER}@${foreign_host}" "bash $REMOTE_SCRIPT" || return 1
  else
    ssh -p "$SSH_PORT" "${SSH_USER}@${foreign_host}" "cat > $REMOTE_SCRIPT && bash $REMOTE_SCRIPT" < "$script_path" || return 1
  fi
  return 0
}

create_vless_2hop_inbound() {
  clear
  echo "Create new VLESS TCP 2-Hop (IRAN -> FOREIGN, security=none)"
  echo "Client -> IRAN -> FOREIGN -> Internet"
  echo ""

  read -rp "IRAN inbound port (client connects here): " IRAN_PORT
  validate_port "$IRAN_PORT"

  read -rp "IRAN inbound tag (default: vless2hop-$IRAN_PORT): " IRAN_TAG
  IRAN_TAG=${IRAN_TAG:-vless2hop-$IRAN_PORT}

  read -rp "Client UUID for IRAN inbound (leave empty to auto-generate): " CLIENT_UUID
  CLIENT_UUID=${CLIENT_UUID:-$(cat /proc/sys/kernel/random/uuid)}

  read -rp "Client link name (default: $IRAN_TAG): " LINK_NAME
  LINK_NAME=${LINK_NAME:-$IRAN_TAG}
  SAFE_LINK_NAME=$(encode_link_name "$LINK_NAME")

  read -rp "FOREIGN host (IP or domain): " FOREIGN_HOST
  FOREIGN_HOST=$(clean_input "$FOREIGN_HOST")
  validate_host_or_ip "$FOREIGN_HOST"

  read -rp "FOREIGN inbound port: " FOREIGN_PORT
  validate_port "$FOREIGN_PORT"

  read -rp "FOREIGN inbound UUID (leave empty to auto-generate): " FOREIGN_UUID
  FOREIGN_UUID=${FOREIGN_UUID:-$(cat /proc/sys/kernel/random/uuid)}

  DETECTED_IRAN_HOST=$(detect_public_ip || true)
  read -rp "IRAN public host for client link [${DETECTED_IRAN_HOST:-required}]: " IRAN_PUBLIC_HOST
  IRAN_PUBLIC_HOST=${IRAN_PUBLIC_HOST:-$DETECTED_IRAN_HOST}
  [ -z "${IRAN_PUBLIC_HOST:-}" ] && err "IRAN public host is required."
  IRAN_PUBLIC_HOST=$(clean_input "$IRAN_PUBLIC_HOST")
  validate_host_or_ip "$IRAN_PUBLIC_HOST"

  ensure_packages
  ensure_xray
  ensure_config
  ensure_tag_port_free "$IRAN_TAG" "$IRAN_PORT"

  OUTBOUND_TAG="to-foreign-$IRAN_PORT"
  FOREIGN_INBOUND_TAG="from-iran-$IRAN_PORT"
  if outbound_tag_exists "$OUTBOUND_TAG"; then
    err "Outbound tag '$OUTBOUND_TAG' already exists in xray outbounds."
  fi

  INBOUND=$(jq -n \
    --arg port "$IRAN_PORT" --arg tag "$IRAN_TAG" --arg id "$CLIENT_UUID" '
    {
      port: ($port|tonumber),
      listen: "0.0.0.0",
      protocol: "vless",
      tag: $tag,
      settings: {
        clients: [{ id: $id, level: 8 }],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "none",
        tcpSettings: {
          header: { type: "none" }
        }
      }
    }')

  OUTBOUND=$(jq -n \
    --arg host "$FOREIGN_HOST" --arg port "$FOREIGN_PORT" --arg id "$FOREIGN_UUID" --arg tag "$OUTBOUND_TAG" '
    {
      tag: $tag,
      protocol: "vless",
      settings: {
        vnext: [
          {
            address: $host,
            port: ($port|tonumber),
            users: [
              {
                id: $id,
                encryption: "none"
              }
            ]
          }
        ]
      },
      streamSettings: {
        network: "tcp",
        security: "none",
        tcpSettings: {
          header: { type: "none" }
        }
      }
    }')

  ROUTE_RULE=$(jq -n \
    --arg inTag "$IRAN_TAG" --arg outTag "$OUTBOUND_TAG" '
    {
      type: "field",
      inboundTag: [$inTag],
      outboundTag: $outTag
    }')

  TMP=$(mktemp)
  jq "
    .routing |= (. // {})
    | .inbounds += [ $INBOUND ]
    | .outbounds += [ $OUTBOUND ]
    | .routing.rules = ([ $ROUTE_RULE ] + (.routing.rules // []))
  " "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

  chmod 644 "$CONFIG"
  restart_xray || err "xray service failed to start."

  LINK="vless://${CLIENT_UUID}@${IRAN_PUBLIC_HOST}:${IRAN_PORT}?encryption=none&security=none&type=tcp&headerType=none#${SAFE_LINK_NAME}"
  INFO_FILE="$DATA_DIR/loopa-vless-2hop-${IRAN_PORT}.txt"
  FOREIGN_SETUP_SCRIPT="$DATA_DIR/loopa-foreign-setup-${FOREIGN_PORT}.sh"
  IRAN_SERVER_IP="${DETECTED_IRAN_HOST:-<IRAN_SERVER_PUBLIC_IP>}"
  write_foreign_setup_script "$FOREIGN_SETUP_SCRIPT" "$FOREIGN_PORT" "$FOREIGN_UUID" "$FOREIGN_INBOUND_TAG" "$IRAN_SERVER_IP"

  read -rp "Apply FOREIGN setup now over SSH? [y/N]: " APPLY_FOREIGN_NOW
  if [[ "$APPLY_FOREIGN_NOW" =~ ^[Yy]$ ]]; then
    if apply_foreign_setup_over_ssh "$FOREIGN_SETUP_SCRIPT" "$FOREIGN_HOST"; then
      FOREIGN_APPLY_STATUS="applied-via-ssh"
    else
      FOREIGN_APPLY_STATUS="ssh-failed-manual-required"
      echo "Automatic FOREIGN setup failed. Use manual method below."
    fi
  else
    FOREIGN_APPLY_STATUS="manual-required"
  fi

  cat > "$INFO_FILE" <<EOF
Tag: $IRAN_TAG
Port: $IRAN_PORT
IranPublicHost: $IRAN_PUBLIC_HOST
ClientUUID: $CLIENT_UUID
OutboundTag: $OUTBOUND_TAG
ForeignHost: $FOREIGN_HOST
ForeignPort: $FOREIGN_PORT
ForeignUUID: $FOREIGN_UUID
ForeignInboundTag: $FOREIGN_INBOUND_TAG
ForeignSetupScript: $FOREIGN_SETUP_SCRIPT
ForeignApplyStatus: ${FOREIGN_APPLY_STATUS:-manual-required}
ForeignUfwAllow: sudo ufw allow proto tcp from $IRAN_SERVER_IP to any port $FOREIGN_PORT
ForeignUfwDeny: sudo ufw deny proto tcp from any to any port $FOREIGN_PORT
VLESS Link: $LINK
EOF

  echo ""
  echo "VLESS 2-HOP LINK (connect client to IRAN):"
  echo "$LINK"
  echo ""
  qrencode -t ansiutf8 "$LINK"
  echo ""
  echo "Saved IRAN summary to: $INFO_FILE"
  echo "Saved FOREIGN setup script to: $FOREIGN_SETUP_SCRIPT"
  echo ""
  echo "Manual FOREIGN setup (if not auto-applied):"
  echo "  1) Copy script to FOREIGN server"
  echo "  2) Run as root:"
  echo "     sudo bash /path/to/loopa-foreign-setup-${FOREIGN_PORT}.sh"
  echo ""
  echo "If UFW is active on FOREIGN, ensure only IRAN IP is allowed:"
  echo "  sudo ufw allow proto tcp from $IRAN_SERVER_IP to any port $FOREIGN_PORT"
  echo "  sudo ufw deny  proto tcp from any to any port $FOREIGN_PORT"
  read -rp "Press Enter to return..." _
}
