# ==========================================
# 功能函数 3: 全协议向导配置生成器 (旗舰版 - 修复 1.14+ DNS 语法)
# ==========================================
action_generate_config() {
    echo -e "\n===================================="
    echo "   sing-box 旗舰全协议配置文件向导   "
    echo "===================================="
    echo "说明: 依次输入各项配置，直接按回车将自动生成随机值。"
    echo "------------------------------------"

    DEF_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
    DEF_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    
    read -p "请输入主通用 UUID (直接回车随机生成): " IN_UUID < /dev/tty
    [ -z "$IN_UUID" ] && IN_UUID="$DEF_UUID"

    read -p "请输入通用访问密码/AnyTLS密码 (直接回车随机生成): " IN_PWD < /dev/tty
    [ -z "$IN_PWD" ] && IN_PWD="$DEF_PASSWORD"

    read -p "请输入 VLESS-REALITY 伪装域名 (默认: dl.google.com): " IN_REALITY_SNI < /dev/tty
    [ -z "$IN_REALITY_SNI" ] && IN_REALITY_SNI="dl.google.com"

    read -p "请输入 XHTTP 伪装路径 (默认: /xhttp): " IN_XHTTP_PATH < /dev/tty
    [ -z "$IN_XHTTP_PATH" ] && IN_XHTTP_PATH="/xhttp"

    read -p "请输入 VLESS/XHTTP 绑定的域名 (若有证书，选填): " IN_DOMAIN < /dev/tty
    [ -z "$IN_DOMAIN" ] && IN_DOMAIN="yourdomain.com"

    echo "[+] 正在为 REALITY 协议生成临时公私钥..."
    REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null)
    if [ -n "$REALITY_KEYS" ]; then
        R_PRIV=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
        R_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
    else
        R_PRIV="E_xample_Priv_Key_Replace_Me_1234567890"
        R_PUB="E_xample_Pub_Key_Replace_Me_1234567890"
    fi

    echo "[+] 生成参数摘要："
    echo " - UUID        : $IN_UUID"
    echo " - 密码        : $IN_PWD"
    echo " - REALITY SNI : $IN_REALITY_SNI"
    echo " - XHTTP 路径  : $IN_XHTTP_PATH"
    echo "------------------------------------"
    read -p "确认写入配置文件并注册服务？(y/n): " confirm < /dev/tty
    [ "$confirm" != "y" ] && return

    CONFIG_PATH="/etc/sing-box/config.json"
    mkdir -p /etc/sing-box

    cat << EOF > "$CONFIG_PATH"
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "local-dns",
        "address": "local"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "$IN_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_REALITY_SNI",
        "reality": {
          "enabled": true,
          "pubkey": "$R_PUB",
          "privkey": "$R_PRIV"
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-xhttp-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        {
          "uuid": "$IN_UUID",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      },
      "transport": {
        "type": "xhttp",
        "path": "$IN_XHTTP_PATH",
        "mode": "auto"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": 9443,
      "users": [
        {
          "password": "$IN_PWD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 8444,
      "users": [
        {
          "password": "$IN_PWD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": 8445,
      "users": [
        {
          "uuid": "$IN_UUID",
          "password": "$IN_PWD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      },
      "congestion_control": "bbr"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

    echo "[+] 配置文件已成功写入: $CONFIG_PATH"

    SERVICE_FILE="/etc/systemd/system/sing-box.service"
    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=sing-box service (Extended Multi-Protocol)
Documentation=https://github.com/shtorm-7/sing-box-extended
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -C /etc/sing-box
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box
    echo "[√] sing-box 系统服务已成功更新并启动！"
}
