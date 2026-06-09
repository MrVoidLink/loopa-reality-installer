create_vless_ws_fronted_profile() {
  clear
  echo "Create new VLESS WebSocket fronted profile (seller-01 style)"
  read -rp "Enter port number (e.g. 8880): " PORT
  validate_port "$PORT"

  TAG="vless-ws-fronted-$PORT"
  UUID=$(cat /proc/sys/kernel/random/uuid)

  DETECTED_SERVER_ADDR=$(detect_public_ip || true)
  read -rp "Enter front address/domain for client link [${DETECTED_SERVER_ADDR:-required}]: " FRONT_ADDR
  FRONT_ADDR=${FRONT_ADDR:-$DETECTED_SERVER_ADDR}
  [ -z "${FRONT_ADDR:-}" ] && err "Front address/domain is required."
  FRONT_ADDR=$(clean_input "$FRONT_ADDR")
  validate_host_or_ip "$FRONT_ADDR"

  read -rp "Enter WebSocket host header [same as front address/domain]: " WS_HOST
  WS_HOST=${WS_HOST:-$FRONT_ADDR}
  WS_HOST=$(clean_input "$WS_HOST")
  validate_host_or_ip "$WS_HOST"

  WS_PATH="/"

  read -rp "Enter link name (default: $TAG): " LINK_NAME
  LINK_NAME=${LINK_NAME:-$TAG}
  SAFE_LINK_NAME=$(encode_link_name "$LINK_NAME")

  ensure_packages
  ensure_xray
  ensure_config
  ensure_tag_port_free "$TAG" "$PORT"

  INBOUND=$(jq -n \
    --arg port "$PORT" --arg tag "$TAG" --arg id "$UUID" --arg path "$WS_PATH" --arg host "$WS_HOST" '
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
        network: "ws",
        security: "none",
        wsSettings: {
          path: $path,
          host: $host
        }
      }
    }')

  TMP=$(mktemp)
  jq ".inbounds += [ $INBOUND ]" "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

  chmod 644 "$CONFIG"
  restart_xray || err "xray service failed to start."

  LINK_HOST=$(urlencode_component "$WS_HOST")
  LINK_PATH=$(urlencode_component "$WS_PATH")
  LINK="vless://${UUID}@${FRONT_ADDR}:${PORT}?encryption=none&security=none&type=ws&host=${LINK_HOST}&path=${LINK_PATH}#${SAFE_LINK_NAME}"
  INFO_FILE="$DATA_DIR/loopa-vless-fronted-${PORT}.txt"
  CLIENT_JSON_FILE="$DATA_DIR/loopa-vless-fronted-client-${PORT}.json"

  cat > "$CLIENT_JSON_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "hosts": {
      "dns.google": [
        "8.8.8.8",
        "8.8.4.4",
        "2001:4860:4860::8888",
        "2001:4860:4860::8844"
      ],
      "dns.alidns.com": [
        "223.5.5.5",
        "223.6.6.6",
        "2400:3200::1",
        "2400:3200:baba::1"
      ],
      "one.one.one.one": [
        "1.1.1.1",
        "1.0.0.1",
        "2606:4700:4700::1111",
        "2606:4700:4700::1001"
      ],
      "1dot1dot1dot1.cloudflare-dns.com": [
        "1.1.1.1",
        "1.0.0.1",
        "2606:4700:4700::1111",
        "2606:4700:4700::1001"
      ],
      "cloudflare-dns.com": [
        "104.16.249.249",
        "104.16.248.249",
        "2606:4700::6810:f8f9",
        "2606:4700::6810:f9f9"
      ],
      "dns.cloudflare.com": [
        "104.16.132.229",
        "104.16.133.229",
        "2606:4700::6810:84e5",
        "2606:4700::6810:85e5"
      ],
      "dot.pub": [
        "1.12.12.12",
        "120.53.53.53"
      ],
      "doh.pub": [
        "1.12.12.12",
        "120.53.53.53"
      ],
      "dns.quad9.net": [
        "9.9.9.9",
        "149.112.112.112",
        "2620:fe::fe",
        "2620:fe::9"
      ],
      "dns.yandex.net": [
        "77.88.8.8",
        "77.88.8.1",
        "2a02:6b8::feed:0ff",
        "2a02:6b8:0:1::feed:0ff"
      ],
      "dns.sb": [
        "185.222.222.222",
        "2a09::"
      ],
      "dns.umbrella.com": [
        "208.67.220.220",
        "208.67.222.222",
        "2620:119:35::35",
        "2620:119:53::53"
      ],
      "dns.sse.cisco.com": [
        "208.67.220.220",
        "208.67.222.222",
        "2620:119:35::35",
        "2620:119:53::53"
      ],
      "engage.cloudflareclient.com": [
        "162.159.192.1",
        "2606:4700:d0::a29f:c001"
      ]
    },
    "servers": [
      {
        "address": "8.8.8.8",
        "domains": [
          "${FRONT_ADDR}"
        ],
        "skipFallback": true
      },
      {
        "address": "8.8.8.8",
        "domains": [
          "geosite:private"
        ],
        "skipFallback": true
      },
      {
        "address": "8.8.8.8",
        "domains": [
          "full:dns.google"
        ],
        "skipFallback": true
      },
      "https://dns.google/dns-query"
    ]
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "mixed",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": false
      },
      "settings": {
        "auth": "noauth",
        "udp": true,
        "allowTransparent": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${FRONT_ADDR}",
            "port": ${PORT},
            "users": [
              {
                "id": "${UUID}",
                "email": "t@t.tt",
                "security": "auto",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}",
          "host": "${WS_HOST}",
          "headers": {}
        }
      },
      "mux": {
        "enabled": false,
        "concurrency": -1
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "port": "443",
        "network": "udp",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": [
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          "geosite:private"
        ]
      },
      {
        "type": "field",
        "port": "0-65535",
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

  cat > "$INFO_FILE" <<EOF
Profile: seller-01-style
Tag: $TAG
Port: $PORT
FrontAddress: $FRONT_ADDR
WebSocketHost: $WS_HOST
WebSocketPath: $WS_PATH
UUID: $UUID
ClientConfigFile: $CLIENT_JSON_FILE
VLESS Link: $LINK
EOF

  echo ""
  echo "VLESS WS FRONTED LINK:"
  echo "$LINK"
  echo ""
  qrencode -t ansiutf8 "$LINK"
  echo ""
  echo "Saved info to: $INFO_FILE"
  echo "Saved client JSON to: $CLIENT_JSON_FILE"
  echo ""
  echo "Auto-generated tag: $TAG"
  echo "Auto-generated UUID: $UUID"
  echo "WebSocket host: $WS_HOST"
  echo "Fixed WebSocket path: $WS_PATH"
  echo ""
  echo "Important: the front address/domain must route traffic to this server."
  echo "If it does not, this profile will not work."
  read -rp "Press Enter to return..." _
}
