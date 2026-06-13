trim_vless_ws_tls_fronted_input() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

generate_vless_ws_tls_fronted_path() {
  local token
  token="$(openssl rand -hex 8)"
  printf '/l/w/%s?ed=2047' "$token"
}

resolve_tls_cert_pair() {
  local domain="$1"
  local cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local key_file="/etc/letsencrypt/live/${domain}/privkey.pem"

  [ -f "$cert_file" ] || err "TLS certificate file not found: $cert_file"
  [ -f "$key_file" ] || err "TLS private key file not found: $key_file"

  printf '%s\n%s\n' "$cert_file" "$key_file"
}

create_vless_ws_tls_fronted_profile() {
  clear
  echo "Create new VLESS WebSocket TLS fronted profile (seller-02 style)"

  ensure_packages

  read -rp "Enter port number [443]: " PORT
  PORT=${PORT:-443}
  validate_port "$PORT"

  TAG="vless-ws-tls-fronted-$PORT"
  UUID=$(cat /proc/sys/kernel/random/uuid)

  DETECTED_SERVER_ADDR=$(detect_public_ip || true)
  read -rp "Enter front address/IP for client link [${DETECTED_SERVER_ADDR:-required}]: " FRONT_ADDR
  FRONT_ADDR=${FRONT_ADDR:-$DETECTED_SERVER_ADDR}
  [ -z "${FRONT_ADDR:-}" ] && err "Front address/IP is required."
  FRONT_ADDR=$(clean_input "$FRONT_ADDR")
  validate_host_or_ip "$FRONT_ADDR"

  read -rp "Enter TLS domain / SNI (must match certificate): " TLS_DOMAIN
  [ -z "${TLS_DOMAIN:-}" ] && err "TLS domain / SNI is required."
  TLS_DOMAIN=$(clean_input "$TLS_DOMAIN")
  validate_domain "$TLS_DOMAIN"

  read -rp "Enter WebSocket host header [same as TLS domain]: " WS_HOST
  WS_HOST=${WS_HOST:-$TLS_DOMAIN}
  WS_HOST=$(clean_input "$WS_HOST")
  validate_host_or_ip "$WS_HOST"

  WS_PATH=$(generate_vless_ws_tls_fronted_path)

  mapfile -t TLS_CERT_PAIR < <(resolve_tls_cert_pair "$TLS_DOMAIN")
  CERT_FILE="${TLS_CERT_PAIR[0]}"
  KEY_FILE="${TLS_CERT_PAIR[1]}"

  read -rp "Enter link name (default: $TAG): " LINK_NAME
  LINK_NAME=${LINK_NAME:-$TAG}
  SAFE_LINK_NAME=$(encode_link_name "$LINK_NAME")

  ensure_xray
  ensure_config
  ensure_tag_port_free "$TAG" "$PORT"

  INBOUND=$(jq -n \
    --arg port "$PORT" \
    --arg tag "$TAG" \
    --arg id "$UUID" \
    --arg path "$WS_PATH" \
    --arg host "$WS_HOST" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" '
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
        security: "tls",
        tlsSettings: {
          certificates: [
            {
              certificateFile: $cert,
              keyFile: $key
            }
          ]
        },
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
  LINK_SNI=$(urlencode_component "$TLS_DOMAIN")
  LINK="vless://${UUID}@${FRONT_ADDR}:${PORT}?path=${LINK_PATH}&security=tls&encryption=none&insecure=0&host=${LINK_HOST}&type=ws&allowInsecure=0&sni=${LINK_SNI}#${SAFE_LINK_NAME}"
  INFO_FILE="$DATA_DIR/loopa-vless-ws-tls-fronted-${PORT}.txt"
  CLIENT_JSON_FILE="$DATA_DIR/loopa-vless-ws-tls-fronted-client-${PORT}.json"

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
        "security": "tls",
        "tlsSettings": {
          "allowInsecure": false,
          "serverName": "${TLS_DOMAIN}"
        },
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
Profile: seller-02-style
Tag: $TAG
Port: $PORT
FrontAddress: $FRONT_ADDR
TLSDomain: $TLS_DOMAIN
WebSocketHost: $WS_HOST
WebSocketPath: $WS_PATH
CertificateFile: $CERT_FILE
PrivateKeyFile: $KEY_FILE
UUID: $UUID
ClientConfigFile: $CLIENT_JSON_FILE
VLESS Link: $LINK
EOF

  echo ""
  echo "VLESS WS TLS FRONTED LINK:"
  echo "$LINK"
  echo ""
  qrencode -t ansiutf8 "$LINK"
  echo ""
  echo "Saved info to: $INFO_FILE"
  echo "Saved client JSON to: $CLIENT_JSON_FILE"
  echo ""
  echo "Auto-generated tag: $TAG"
  echo "Auto-generated UUID: $UUID"
  echo "TLS domain / SNI: $TLS_DOMAIN"
  echo "TLS certificate: $CERT_FILE"
  echo "TLS private key: $KEY_FILE"
  echo "WebSocket host: $WS_HOST"
  echo "WebSocket path: $WS_PATH"
  echo ""
  echo "Important:"
  echo "1) the front address/IP must route traffic to this server"
  echo "2) the TLS certificate must be valid for the TLS domain / SNI"
  echo "3) if port $PORT is already used by another service, this profile will not work"
  read -rp "Press Enter to return..." _
}
