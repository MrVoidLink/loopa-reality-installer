create_vless_tcp_inbound() {
  clear
  echo "Create new VLESS TCP inbound (security=none)"
  read -rp "Enter port number (e.g. 443): " PORT
  validate_port "$PORT"

  read -rp "Enter tag name (default: vless-$PORT): " TAG
  TAG=${TAG:-vless-$PORT}
  read -rp "Enter UUID (leave empty to auto-generate): " UUID
  UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
  read -rp "Enter link name (default: $TAG): " LINK_NAME
  LINK_NAME=${LINK_NAME:-$TAG}
  SAFE_LINK_NAME=$(encode_link_name "$LINK_NAME")

  SERVER_ADDR=$(detect_public_ip || true)
  [ -z "${SERVER_ADDR:-}" ] && err "Could not detect server public IPv4 address automatically."
  echo "Detected server address: $SERVER_ADDR"

  ensure_packages
  ensure_xray
  ensure_config
  ensure_tag_port_free "$TAG" "$PORT"

  INBOUND=$(jq -n \
    --arg port "$PORT" --arg tag "$TAG" --arg id "$UUID" '
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

  TMP=$(mktemp)
  jq ".inbounds += [ $INBOUND ]" "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

  chmod 644 "$CONFIG"
  restart_xray || err "xray service failed to start."

  LINK="vless://${UUID}@${SERVER_ADDR}:${PORT}?encryption=none&security=none&type=tcp&headerType=none#${SAFE_LINK_NAME}"
  INFO_FILE="$DATA_DIR/loopa-vless-${PORT}.txt"
  CLIENT_JSON_FILE="$DATA_DIR/loopa-vless-client-${PORT}.json"

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
        "address": "https://dns.alidns.com/dns-query",
        "domains": [
          "domain:alidns.com",
          "domain:doh.pub",
          "domain:dot.pub",
          "domain:360.cn",
          "domain:onedns.net"
        ],
        "skipFallback": true
      },
      {
        "address": "https://cloudflare-dns.com/dns-query",
        "domains": [
          "geosite:google"
        ],
        "skipFallback": true
      },
      {
        "address": "https://dns.alidns.com/dns-query",
        "domains": [
          "geosite:private",
          "geosite:cn"
        ],
        "skipFallback": true
      },
      {
        "address": "223.5.5.5",
        "domains": [
          "full:dns.alidns.com",
          "full:cloudflare-dns.com"
        ],
        "skipFallback": true
      },
      "https://cloudflare-dns.com/dns-query"
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
            "address": "${SERVER_ADDR}",
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
        "network": "tcp"
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
        "outboundTag": "proxy",
        "domain": [
          "geosite:google"
        ]
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
        "outboundTag": "direct",
        "ip": [
          "223.5.5.5",
          "223.6.6.6",
          "2400:3200::1",
          "2400:3200:baba::1",
          "119.29.29.29",
          "1.12.12.12",
          "120.53.53.53",
          "2402:4e00::",
          "2402:4e00:1::",
          "180.76.76.76",
          "2400:da00::6666",
          "114.114.114.114",
          "114.114.115.115",
          "114.114.114.119",
          "114.114.115.119",
          "114.114.114.110",
          "114.114.115.110",
          "180.184.1.1",
          "180.184.2.2",
          "101.226.4.6",
          "218.30.118.6",
          "123.125.81.6",
          "140.207.198.6",
          "1.2.4.8",
          "210.2.4.8",
          "52.80.66.66",
          "117.50.22.22",
          "2400:7fc0:849e:200::4",
          "2404:c2c0:85d8:901::4",
          "117.50.10.10",
          "52.80.52.52",
          "2400:7fc0:849e:200::8",
          "2404:c2c0:85d8:901::8",
          "117.50.60.30",
          "52.80.60.30"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          "domain:alidns.com",
          "domain:doh.pub",
          "domain:dot.pub",
          "domain:360.cn",
          "domain:onedns.net"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": [
          "geoip:cn"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          "geosite:cn"
        ]
      }
    ]
  }
}
EOF

  cat > "$INFO_FILE" <<EOF
Tag: $TAG
Port: $PORT
Address: $SERVER_ADDR
UUID: $UUID
ClientConfigFile: $CLIENT_JSON_FILE
VLESS Link: $LINK
EOF

  echo ""
  echo "VLESS LINK:"
  echo "$LINK"
  echo ""
  qrencode -t ansiutf8 "$LINK"
  echo ""
  echo "Saved info to: $INFO_FILE"
  echo "Saved client JSON to: $CLIENT_JSON_FILE"
  read -rp "Press Enter to return..." _
}
