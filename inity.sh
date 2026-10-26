#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误：请使用 root 权限运行此脚本！"
  exit 1
fi

# 数据持久化与独立目录
DATA_DIR="/etc/taikong"
CONFIG_FILE="/etc/sing-box/config.json"
DATA_JSON="$DATA_DIR/deploy_data.json"
CERT_YUMING_DIR="/etc/sing-box/yuming"
CERT_ZHIQIAN_DIR="/etc/sing-box/zhiqian"

mkdir -p "$DATA_DIR" /etc/sing-box "$CERT_YUMING_DIR" "$CERT_ZHIQIAN_DIR"

# ==========================================
# 步骤 1: 系统与环境基础检测
# ==========================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$(echo "${NAME:-Linux}" | tr -d '\0')
    OS_VERSION=$(echo "${VERSION_ID:-Unknown}" | tr -d '\0')
else
    OS_NAME=$(uname -s | tr -d '\0')
    OS_VERSION=$(uname -r | tr -d '\0')
fi
CPU_ARCH=$(uname -m | tr -d '\0')

CPU_V_LEVEL="不适用 (非 x86_64)"
SINGBOX_CPU_SUFFIX="amd64"
if [ "$CPU_ARCH" = "x86_64" ]; then
    if grep -q "avx2" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v3 (高性能)"
        SINGBOX_CPU_SUFFIX="amd64-v3"
    else
        CPU_V_LEVEL="x86-64-v1 (通用)"
        SINGBOX_CPU_SUFFIX="amd64"
    fi
elif [ "$CPU_ARCH" = "aarch64" ]; then
    CPU_V_LEVEL="ARM64"
    SINGBOX_CPU_SUFFIX="arm64"
fi

CURRENT_HOSTNAME=$(hostname)
SERVER_IP=$(curl -sSL -4 ip.sb 2>/dev/null || hostname -I | awk '{print $1}')

get_local_singbox_status() {
    if command -v sing-box &>/dev/null; then
        LOCAL_SB_VERSION=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        echo "已安装 (${LOCAL_SB_VERSION:-未知})"
    else
        echo "未安装"
    fi
}

check_port_free() {
    local port=$1
    local proto=$2
    if [ "$proto" = "udp" ]; then
        ss -uln | grep -q ":$port "
    else
        ss -tln | grep -q ":$port "
    fi
}

get_random_port() {
    while true; do
        local p=$((RANDOM % 40001 + 20000))
        if ! check_port_free "$p" "tcp" && ! check_port_free "$p" "udp"; then
            echo "$p"
            return
        fi
    done
}

# ==========================================
# 功能函数 1: 系统初始化与安全加固
# ==========================================
action_init_security() {
    echo -e "\n===================================="
    echo "  开始执行：系统初始化与安全加固"
    echo "===================================="
    SSHD_CONFIG="/etc/ssh/sshd_config"
    RANDOM_USER="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    read -p "请输入要创建的新用户名 [$RANDOM_USER]: " NEW_USER < /dev/tty
    [ -z "$NEW_USER" ] && NEW_USER="$RANDOM_USER"
    
    useradd -m -s /bin/bash "$NEW_USER" 2>/dev/null
    echo "[+] 请为用户 '$NEW_USER' 设置密码："
    passwd "$NEW_USER"

    RANDOM_PORT=$((RANDOM % 64512 + 1024))
    read -p "请输入新的 SSH 端口 [$RANDOM_PORT]: " NEW_SSH_PORT < /dev/tty
    [ -z "$NEW_SSH_PORT" ] && NEW_SSH_PORT="$RANDOM_PORT"

    sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    echo "[√] 安全加固完成！新端口: $NEW_SSH_PORT"
}

# ==========================================
# 功能函数 2: 安装/更新 sing-box
# ==========================================
action_manage_singbox() {
    echo -e "\n===================================="
    echo "  正在检查 sing-box 版本与远程更新..."
    echo "===================================="
    DOWNLOAD_URL=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep "browser_download_url" | grep -E "linux-$SINGBOX_CPU_SUFFIX" | head -n 1 | cut -d '"' -f 4)
    [ -z "$DOWNLOAD_URL" ] && DOWNLOAD_URL=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep "browser_download_url" | grep -E "linux-amd64" | head -n 1 | cut -d '"' -f 4)

    TEMP_FILE="/tmp/sing-box-extended.tar.gz"
    if curl -sSL "$DOWNLOAD_URL" -o "$TEMP_FILE"; then
        mkdir -p /tmp/sing-box-extract
        tar -xzf "$TEMP_FILE" -C /tmp/sing-box-extract --strip-components=1 2>/dev/null || tar -xzf "$TEMP_FILE" -C /tmp/sing-box-extract
        SB_BINARY=$(find /tmp/sing-box-extract -type f -name "sing-box" | head -n 1)
        if [ -n "$SB_BINARY" ]; then
            cp -f "$SB_BINARY" /usr/local/bin/sing-box
            chmod +x /usr/local/bin/sing-box
            echo "[√] sing-box 安装/更新成功！"
        fi
        rm -rf "$TEMP_FILE" /tmp/sing-box-extract
    else
        echo "[-] 错误：下载失败！"
    fi
}

# ==========================================
# 功能函数 7: 永哥风格多平台 ACME 证书申请模块
# ==========================================
action_acme_cert() {
    echo -e "\n===================================="
    echo "     永哥风格 ACME 域名证书申请向导   "
    echo "===================================="
    echo " 1. 不申请域名，使用自签证书 (默认存放在 /etc/sing-box/zhiqian/)"
    echo " 2. Cloudflare API 托管模式申请证书"
    echo " 3. Cloudflare 80 端口独立 standalone 模式申请"
    echo " 4. 腾讯云 / 其它 DNS 模式"
    echo "------------------------------------"
    read -p "请选择申请方式 [1-4, 默认 1]: " acme_choice < /dev/tty
    [ -z "$acme_choice" ] && acme_choice="1"

    if [ "$acme_choice" = "1" ]; then
        echo "[+] 已选择：使用自签证书，正在生成至 $CERT_ZHIQIAN_DIR ..."
        openssl ecparam -genkey -name prime256v1 -out "$CERT_ZHIQIAN_DIR/private.key" 2>/dev/null
        openssl req -new -x509 -days 36500 -key "$CERT_ZHIQIAN_DIR/private.key" -out "$CERT_ZHIQIAN_DIR/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
        CERT_PATH="$CERT_ZHIQIAN_DIR/cert.pem"
        KEY_PATH="$CERT_ZHIQIAN_DIR/private.key"
        HAS_DOMAIN="false"
        DOMAIN_NAME=""
    else
        read -p "请输入你的有效主域名 (例如 example.com): " DOMAIN_NAME < /dev/tty
        if [ -n "$DOMAIN_NAME" ]; then
            mkdir -p "$CERT_YUMING_DIR"
            echo "[+] 正在针对域名 $DOMAIN_NAME 执行 ACME 证书申请..."
            curl https://get.acme.sh | sh -s email=admin@$DOMAIN_NAME 2>/dev/null
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>/dev/null
            
            if [ "$acme_choice" = "2" ]; then
                read -p "请输入 Cloudflare Global API Key: " CF_KEY < /dev/tty
                read -p "请输入 Cloudflare 注册邮箱: " CF_EMAIL < /dev/tty
                export CF_Key="$CF_KEY"
                export CF_Email="$CF_EMAIL"
                ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN_NAME" -d "*.$DOMAIN_NAME" -k ec-256 2>/dev/null
            else
                ~/.acme.sh/acme.sh --issue -d "$DOMAIN_NAME" --standalone -k ec-256 2>/dev/null
            fi

            ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN_NAME" --ecc \
                --fullchain-file "$CERT_YUMING_DIR/cert.crt" \
                --key-file "$CERT_YUMING_DIR/private.key" 2>/dev/null
            
            CERT_PATH="$CERT_YUMING_DIR/cert.crt"
            KEY_PATH="$CERT_YUMING_DIR/private.key"
            HAS_DOMAIN="true"
            echo "[√] 域名证书申请成功，已保存至 $CERT_YUMING_DIR"
        else
            HAS_DOMAIN="false"
            CERT_PATH="$CERT_ZHIQIAN_DIR/cert.pem"
            KEY_PATH="$CERT_ZHIQIAN_DIR/private.key"
        fi
    fi
}

# ==========================================
# 功能函数 3: 全协议配置生成器 (独立凭证、静默随机生成)
# ==========================================
action_generate_config() {
    echo -e "\n===================================="
    echo "   sing-box 旗舰全协议配置与凭证向导    "
    echo "===================================="

    # 1. 证书向导
    action_acme_cert

    # 2. 为每个协议独立、静默生成完全不重复的 UUID 与独立密码
    echo "[+] 正在为各个协议独立静默生成不重复的随机 UUID 与高强度密码..."
    UUID_VLESS_REALITY=$(cat /proc/sys/kernel/random/uuid)
    UUID_XHTTP=$(cat /proc/sys/kernel/random/uuid)
    UUID_TUIC=$(cat /proc/sys/kernel/random/uuid)
    UUID_ANYTLS_R=$(cat /proc/sys/kernel/random/uuid)

    PWD_ANYTLS_B=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    PWD_HY2_B=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    PWD_HY2_Y=$(cat /proc/sys/kernel/random/uuid)
    PWD_MIERU=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 14)

    # 3. 生成 Reality 密钥对
    R_KEYS=$(sing-box generate reality-keypair 2>/dev/null)
    R_PRIV=$(echo "$R_KEYS" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
    R_PUB=$(echo "$R_KEYS" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
    [ -z "$R_PRIV" ] && R_PRIV="aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"

    # 4. 动态随机分配空闲端口 (20000-60000)
    echo "[+] 正在智能随机分配并检测空闲端口..."
    P_ANYTLS_B=$(get_random_port)
    P_ANYTLS_R=$(get_random_port)
    P_HY2_B=$(get_random_port)
    P_HY2_Y=$(get_random_port)
    P_VLESS_R=$(get_random_port)
    P_TUIC=$(get_random_port)
    P_XHTTP=$(get_random_port)
    P_MIERU=$(get_random_port)

    # 5. 持久化保存所有独立凭证到 deploy_data.json
    cat << EOF > "$DATA_JSON"
{
  "server_ip": "$SERVER_IP",
  "has_domain": "$HAS_DOMAIN",
  "domain": "$DOMAIN_NAME",
  "reality_private_key": "$R_PRIV",
  "reality_public_key": "$R_PUB",
  "uuids": {
    "vless_reality": "$UUID_VLESS_REALITY",
    "xhttp": "$UUID_XHTTP",
    "tuic": "$UUID_TUIC",
    "anytls_reality": "$UUID_ANYTLS_R"
  },
  "passwords": {
    "anytls_bing": "$PWD_ANYTLS_B",
    "hy2_bing": "$PWD_HY2_B",
    "hy2_yuming": "$PWD_HY2_Y",
    "mieru": "$PWD_MIERU"
  },
  "ports": {
    "anytls_bing": $P_ANYTLS_B,
    "anytls_reality": $P_ANYTLS_R,
    "hy2_bing": $P_HY2_B,
    "hy2_yuming": $P_HY2_Y,
    "vless_reality": $P_VLESS_R,
    "tuic": $P_TUIC,
    "xhttp": $P_XHTTP,
    "mieru": $P_MIERU
  }
}
EOF
    echo "[+] 所有独立凭证与端口数据已持久化保存至: $DATA_JSON"

    # 6. 写入标准 sing-box 配置文件
    cat << EOF > "$CONFIG_FILE"
{
    "log": {
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "anytls",
            "tag": "anytls-01-bing",
            "listen": "::",
            "listen_port": $P_ANYTLS_B,
            "users": [{"password": "$PWD_ANYTLS_B"}],
            "padding_scheme": ["stop=10", "0=30-30", "1=100-400,c,10-10", "2=200-300,c,200-300,c,200-300", "3=9-9", "4-9=50-100"],
            "tls": {"enabled": true, "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "anytls",
            "tag": "anytls-02-reality",
            "listen": "::",
            "listen_port": $P_ANYTLS_R,
            "users": [{"password": "$UUID_ANYTLS_R"}],
            "tls": {
                "enabled": true,
                "server_name": "apple.com",
                "reality": {"enabled": true, "handshake": {"server": "apple.com", "server_port": 443}, "private_key": "$R_PRIV", "short_id": ["d1df3e44"]}
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-01-bing",
            "listen": "::",
            "listen_port": $P_HY2_B,
            "users": [{"password": "$PWD_HY2_B"}],
            "ignore_client_bandwidth": false,
            "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-02-yuming",
            "listen": "::",
            "listen_port": $P_HY2_Y,
            "users": [{"password": "$PWD_HY2_Y"}],
            "ignore_client_bandwidth": false,
            "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "vless",
            "tag": "vless-reality-vision",
            "listen": "::",
            "listen_port": $P_VLESS_R,
            "users": [{"uuid": "$UUID_VLESS_REALITY", "flow": "xtls-rprx-vision"}],
            "tls": {
                "enabled": true,
                "server_name": "www.lovelive-anime.jp",
                "reality": {"enabled": true, "handshake": {"server": "www.lovelive-anime.jp", "server_port": 443}, "private_key": "$R_PRIV", "short_id": ["27dfe873147095d1"]}
            }
        },
        {
            "type": "tuic",
            "tag": "tuicv5-01-bing",
            "listen": "::",
            "listen_port": $P_TUIC,
            "users": [{"uuid": "$UUID_TUIC", "password": "$PWD_ANYTLS_B"}],
            "congestion_control": "cubic",
            "tls": {"enabled": true, "server_name": "www.bing.com", "alpn": ["h3"], "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "vless",
            "tag": "vless-xhttp-reality",
            "listen": "::",
            "listen_port": $P_XHTTP,
            "users": [{"uuid": "$UUID_XHTTP", "flow": ""}],
            "tls": {
                "enabled": true,
                "server_name": "www.lovelive-anime.jp",
                "reality": {"enabled": true, "handshake": {"server": "www.lovelive-anime.jp", "server_port": 443}, "private_key": "$R_PRIV", "short_id": ["27dfe873147095d1"]}
            },
            "transport": {"type": "xhttp", "path": "/", "mode": "auto", "x_padding_bytes": "100-1000"}
        },
        {
            "type": "mieru",
            "tag": "mieru-01-tcp",
            "listen_port": $P_MIERU,
            "transport": "TCP",
            "users": [{"name": "taikong", "password": "$PWD_MIERU"}],
            "traffic_pattern": "GgQIARAK", "mtu": 1400
        },
        {
            "type": "mieru",
            "tag": "mieru-02-udp",
            "listen_port": $P_MIERU,
            "transport": "UDP",
            "users": [{"name": "taikong", "password": "$PWD_MIERU"}],
            "traffic_pattern": "GgQIARAK", "mtu": 1400
        }
    ],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "endpoints": [
        {
            "type": "wireguard",
            "tag": "warp-out",
            "address": ["172.16.0.2/32", "2606:4700:110:8701:8c03:4abe:4756:1a71/128"],
            "private_key": "CEfHC7QzBIo62pLZQMIEPchSXKoXW93XfKAwOIOATWE=",
            "peers": [{"address": "162.159.193.10", "port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "allowed_ips": ["0.0.0.0/0", "::/0"]}]
        }
    ],
    "route": {
        "rules": [
            {"action": "sniff"},
            {"domain": ["openai.com", "chat.openai.com", "gemini.google.com"], "action": "route", "outbound": "warp-out"},
            {"outbound": "direct", "network": "udp,tcp"}
        ],
        "final": "direct"
    }
}
EOF
    echo "[√] 旗舰配置文件写入成功！"

    # 7. 注册 Systemd 服务
    cat << EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service (Extended Multi-Protocol)
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

    # 8. 防火墙联动
    read -p "是否自动配置防火墙并放行所有协议端口？(y/n): " do_fw < /dev/tty
    if [ "$do_fw" = "y" ]; then
        if command -v ufw &>/dev/null; then
            echo "[+] 配置 Debian/UFW 防火墙规则..."
            ufw allow $P_ANYTLS_B/tcp comment "AnyTLS Bing 端口"
            ufw allow $P_ANYTLS_R/tcp comment "AnyTLS Reality 端口"
            ufw allow $P_HY2_B/udp comment "Hysteria2 Bing 端口"
            ufw allow $P_HY2_Y/udp comment "Hysteria2 域名 端口"
            ufw allow $P_VLESS_R/tcp comment "VLESS Reality 端口"
            ufw allow $P_TUIC/udp comment "TUIC v5 端口"
            ufw allow $P_XHTTP/tcp comment "VLESS XHTTP 端口"
            ufw allow $P_MIERU/tcp comment "Mieru TCP 端口"
            ufw allow $P_MIERU/udp comment "Mieru UDP 端口"
            ufw reload
        elif command -v firewall-cmd &>/dev/null; then
            echo "[+] 配置 RedHat/Firewalld 防火墙规则..."
            firewall-cmd --permanent --add-port=$P_ANYTLS_B/tcp
            firewall-cmd --permanent --add-port=$P_ANYTLS_R/tcp
            firewall-cmd --permanent --add-port=$P_HY2_B/udp
            firewall-cmd --permanent --add-port=$P_HY2_Y/udp
            firewall-cmd --permanent --add-port=$P_VLESS_R/tcp
            firewall-cmd --permanent --add-port=$P_TUIC/udp
            firewall-cmd --permanent --add-port=$P_XHTTP/tcp
            firewall-cmd --permanent --add-port=$P_MIERU/tcp
            firewall-cmd --permanent --add-port=$P_MIERU/udp
            firewall-cmd --reload
        fi
        echo "[√] 防火墙端口放行完毕！"
    fi
}

# ==========================================
# 功能函数 5: 显示多客户端订阅配置
# ==========================================
action_show_subscription() {
    echo -e "\n===================================="
    echo "       多客户端订阅与节点信息         "
    echo "===================================="
    if [ ! -f "$DATA_JSON" ]; then
        echo "[-] 错误：未找到持久化配置数据，请先执行第 3 项生成配置！"
        return
    fi

    HAS_DOM=$(grep -o '"has_domain"[[:space:]]*:[[:space:]]*"[^"]*"' "$DATA_JSON" | awk -F'"' '{print $4}')
    DOM_NAME=$(grep -o '"domain"[[:space:]]*:[[:space:]]*"[^"]*"' "$DATA_JSON" | awk -F'"' '{print $4}')
    
    if [ "$HAS_DOM" = "true" ] && [ -n "$DOM_NAME" ]; then
        SUB_PREFIX="https://$DOM_NAME"
    else
        SUB_PREFIX="http://$SERVER_IP"
    fi

    echo "【订阅地址前缀】: $SUB_PREFIX"
    echo "------------------------------------"
    echo "【1. 各协议独立凭证信息摘要】"
    echo "服务器 IP         : $SERVER_IP"
    echo "VLESS Reality UUID: $(grep -A 5 'uuids' "$DATA_JSON" | grep 'vless_reality' | awk -F'"' '{print $4}')"
    echo "XHTTP UUID        : $(grep -A 5 'uuids' "$DATA_JSON" | grep 'xhttp' | awk -F'"' '{print $4}')"
    echo "TUIC UUID         : $(grep -A 5 'uuids' "$DATA_JSON" | grep 'tuic' | awk -F'"' '{print $4}')"
    echo "------------------------------------"
    echo "【2. Mihomo (Meta) 订阅片段格式预览】"
    echo "proxies:"
    echo "  - name: VLESS-Reality-$SERVER_IP"
    echo "    type: vless"
    echo "    server: $SERVER_IP"
    echo "    port: $(grep -A 10 'ports' "$DATA_JSON" | grep 'vless_reality' | awk '{print $2}' | tr -d ',')"
    echo "    uuid: $(grep -A 5 'uuids' "$DATA_JSON" | grep 'vless_reality' | awk -F'"' '{print $4}')"
    echo "    network: tcp"
    echo "    tls: true"
    echo "    servername: www.lovelive-anime.jp"
    echo "    reality-opts:"
    echo "      public-key: $(grep -o '"reality_public_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$DATA_JSON" | awk -F'"' '{print $4}')"
    echo "      short-id: 27dfe873147095d1"
    echo "===================================="
}

# ==========================================
# 主菜单循环
# ==========================================
show_menu() {
    clear
    SB_STATUS=$(get_local_singbox_status)

    echo "=================================================="
    echo "      Linux VPS 自动化运维与管理工具箱          "
    echo "=================================================="
    echo " [VPS 环境检测]"
    echo " - 系统发行版   : $OS_NAME $OS_VERSION"
    echo " - CPU 架构     : $CPU_ARCH ($CPU_V_LEVEL)"
    echo " - 外网 IP      : $SERVER_IP"
    echo " - sing-box状态 : $SB_STATUS"
    echo "=================================================="
    echo " 请选择要执行的功能操作："
    echo "   1. 执行系统初始化与安全加固"
    echo "   2. 安装/更新 sing-box (shtorm-7 扩展版)"
    echo "   3. 生成全协议服务端配置 (含独立随机凭证、ACME、持久化)"
    echo "   4. 查看 sing-box 运行状态与日志"
    echo "   5. 显示多客户端订阅配置 (sing-box / mihomo / v2ray)"
    echo "   6. 修改服务端配置并生成对应客户端配置 [预留]"
    echo "   7. 申请/管理 ACME 域名 SSL 证书 (永哥多平台逻辑)"
    echo "   8. WireGuard 与 WARP 内容管理 [预留]"
    echo "   9. 策略分流规则管理 [预留]"
    echo "   0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-9]: " choice < /dev/tty

    case "$choice" in
        1) action_init_security ;;
        2) action_manage_singbox ;;
        3) action_generate_config ;;
        4) action_check_singbox_status 2>/dev/null || systemctl status sing-box ;;
        5) action_show_subscription ;;
        6) echo "[!] 正在开发中..." ;;
        7) action_acme_cert ;;
        8) echo "[!] 正在开发中..." ;;
        9) echo "[!] 正在开发中..." ;;
        0) exit 0 ;;
        *) echo "[-] 无效选择！" ;;
    esac
    echo ""
    read -p "按回车键返回主菜单..." < /dev/tty
}

while true; do
    show_menu
done
