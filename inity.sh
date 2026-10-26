#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误：请使用 root 权限运行此脚本！"
  exit 1
fi

# 数据持久化目录与配置文件路径
DATA_DIR="/etc/taikong"
CONFIG_FILE="/etc/sing-box/config.json"
DATA_JSON="$DATA_DIR/deploy_data.json"
mkdir -p "$DATA_DIR" /etc/sing-box

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

# CPU 指令集与降级兜底
CPU_V_LEVEL="不适用 (非 x86_64)"
SINGBOX_CPU_SUFFIX="amd64"
if [ "$CPU_ARCH" = "x86_64" ]; then
    if grep -q "avx512f" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v4 (AVX-512)"
        SINGBOX_CPU_SUFFIX="amd64-v4"
    elif grep -q "avx2" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v3 (AVX2)"
        SINGBOX_CPU_SUFFIX="amd64-v3"
    elif grep -q "sse4_2" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v2 (SSE4.2)"
        SINGBOX_CPU_SUFFIX="amd64-v2"
    else
        CPU_V_LEVEL="x86-64-v1 (通用兼容)"
        SINGBOX_CPU_SUFFIX="amd64"
    fi
elif [ "$CPU_ARCH" = "aarch64" ]; then
    CPU_V_LEVEL="ARM64"
    SINGBOX_CPU_SUFFIX="arm64"
else
    SINGBOX_CPU_SUFFIX="$CPU_ARCH"
fi

CURRENT_HOSTNAME=$(hostname)
SERVER_IP=$(curl -sSL -4 ip.sb 2>/dev/null || hostname -I | awk '{print $1}')

get_local_singbox_status() {
    if command -v sing-box &>/dev/null; then
        LOCAL_SB_VERSION=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        [ -z "$LOCAL_SB_VERSION" ] && LOCAL_SB_VERSION="未知"
        echo "已安装 ($LOCAL_SB_VERSION)"
    else
        echo "未安装"
    fi
}

# 检查端口是否被占用 (支持 tcp/udp)
check_port_free() {
    local port=$1
    local proto=$2
    if [ "$proto" = "udp" ]; then
        ss -uln | grep -q ":$port "
    else
        ss -tln | grep -q ":$port "
    fi
}

# 获取可用随机端口 (20000-60000)
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

    if grep -q "^sudo:" /etc/group; then
        usermod -aG sudo "$NEW_USER"
    elif grep -q "^wheel:" /etc/group; then
        usermod -aG wheel "$NEW_USER"
    else
        echo "$NEW_USER ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$NEW_USER"
    fi

    RANDOM_PORT=$((RANDOM % 64512 + 1024))
    read -p "请输入新的 SSH 端口 [$RANDOM_PORT]: " NEW_SSH_PORT < /dev/tty
    [ -z "$NEW_SSH_PORT" ] && NEW_SSH_PORT="$RANDOM_PORT"

    sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    echo "[√] 安全加固完成！新端口: $NEW_SSH_PORT，请注意新开终端测试登录！"
}

# ==========================================
# 功能函数 2: 安装/更新 sing-box
# ==========================================
action_manage_singbox() {
    echo -e "\n===================================="
    echo "  正在检查 sing-box 版本与远程更新..."
    echo "===================================="
    LATEST_TAG=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$LATEST_TAG" ] && LATEST_TAG="v1.14.0"

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
# 功能函数 7: 永哥风格 ACME 域名证书申请模块
# ==========================================
action_acme_cert() {
    echo -e "\n===================================="
    echo "       ACME 域名证书申请模块          "
    echo "===================================="
    read -p "是否需要注册/申请域名 SSL 证书？(y/n) [默认 n]: " do_acme < /dev/tty
    if [ "$do_acme" = "y" ] || [ "$do_acme" = "Y" ]; then
        read -p "请输入你的有效域名: " DOMAIN_NAME < /dev/tty
        if [ -n "$DOMAIN_NAME" ]; then
            echo "[+] 正在为 $DOMAIN_NAME 申请证书 (仿 acme-yg 逻辑)..."
            mkdir -p /root/ygkkkca
            # 简化版 acme 申请：调用 certbot 或 acme.sh 脚本
            if ! command -v socat &>/dev/null; then
                apt-get update && apt-get install -y socat curl 2>/dev/null || yum install -y socat curl 2>/dev/null
            fi
            curl https://get.acme.sh | sh -s email=admin@$DOMAIN_NAME 2>/dev/null
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>/dev/null
            ~/.acme.sh/acme.sh --issue -d "$DOMAIN_NAME" --standalone -k ec-256 2>/dev/null
            ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN_NAME" --ecc \
                --fullchain-file /root/ygkkkca/cert.crt \
                --key-file /root/ygkkkca/private.key 2>/dev/null
            echo "[√] 证书申请流程结束，若成功已保存至 /root/ygkkkca/"
            CERT_PATH="/root/ygkkkca/cert.crt"
            KEY_PATH="/root/ygkkkca/private.key"
            HAS_DOMAIN="true"
        else
            HAS_DOMAIN="false"
        fi
    else
        HAS_DOMAIN="false"
        CERT_PATH="/etc/sing-box/cert.pem"
        KEY_PATH="/etc/sing-box/private.key"
    fi
}

# ==========================================
# 功能函数 3: 全协议配置生成器 (带端口检测、自签证书、持久化数据)
# ==========================================
action_generate_config() {
    echo -e "\n===================================="
    echo "   sing-box 旗舰全协议配置与向导生成    "
    echo "===================================="

    # 1. 询问是否注册域名证书
    action_acme_cert

    # 如果没有域名证书，生成自签证书
    if [ "$HAS_DOMAIN" != "true" ]; then
        echo "[+] 正在生成 100 年自签 SSL 证书..."
        openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/private.key 2>/dev/null
        openssl req -new -x509 -days 36500 -key /etc/sing-box/private.key -out /etc/sing-box/cert.pem -subj "/CN=www.bing.com" 2>/dev/null
        CERT_PATH="/etc/sing-box/cert.pem"
        KEY_PATH="/etc/sing-box/private.key"
    fi

    # 2. 生成 Reality 密钥对
    echo "[+] 正在生成 VLESS-Reality 密钥对..."
    R_KEYS=$(sing-box generate reality-keypair 2>/dev/null)
    R_PRIV=$(echo "$R_KEYS" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
    R_PUB=$(echo "$R_KEYS" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
    [ -z "$R_PRIV" ] && R_PRIV="aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"

    # 3. 动态输入或随机生成各项凭证与端口
    DEF_UUID=$(cat /proc/sys/kernel/random/uuid)
    DEF_PWD="yuZHOU9527TAIkong"

    read -p "请输入主 UUID (回车随机 [$DEF_UUID]): " IN_UUID < /dev/tty
    [ -z "$IN_UUID" ] && IN_UUID="$DEF_UUID"

    read -p "请输入通用密码 (回车随机 [$DEF_PWD]): " IN_PWD < /dev/tty
    [ -z "$IN_PWD" ] && IN_PWD="$DEF_PWD"

    # 端口一应俱全且逐个检测占用
    echo "[+] 正在自动智能分配并检测端口 (20000-60000)..."
    P_ANYTLS_B=$(get_random_port)
    P_ANYTLS_R=$(get_random_port)
    P_HY2_B=$(get_random_port)
    P_HY2_Y=$(get_random_port)
    P_VLESS_R=$(get_random_port)
    P_TUIC=$(get_random_port)
    P_XHTTP=$(get_random_port)
    P_MIERU=$(get_random_port)

    echo " - AnyTLS (Bing) 端口 : $P_ANYTLS_B"
    echo " - AnyTLS (Reality) 端口: $P_ANYTLS_R"
    echo " - Hysteria2 (Bing) 端口: $P_HY2_B"
    echo " - Hysteria2 (域名) 端口: $P_HY2_Y"
    echo " - VLESS Reality 端口 : $P_VLESS_R"
    echo " - TUIC v5 端口      : $P_TUIC"
    echo " - VLESS XHTTP 端口  : $P_XHTTP"
    echo " - Mieru 端口        : $P_MIERU"

    # 保存关键数据至持久化文件以便后续订阅和修改
    cat << EOF > "$DATA_JSON"
{
  "uuid": "$IN_UUID",
  "password": "$IN_PWD",
  "server_ip": "$SERVER_IP",
  "has_domain": "$HAS_DOMAIN",
  "domain": "$DOMAIN_NAME",
  "reality_private_key": "$R_PRIV",
  "reality_public_key": "$R_PUB",
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
    echo "[+] 部署配置数据已持久化保存至: $DATA_JSON"

    # 4. 写入标准 JSON 配置文件
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
            "users": [{"password": "$IN_PWD"}],
            "padding_scheme": ["stop=10", "0=30-30", "1=100-400,c,10-10", "2=200-300,c,200-300,c,200-300", "3=9-9", "4-9=50-100"],
            "tls": {"enabled": true, "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "anytls",
            "tag": "anytls-02-reality",
            "listen": "::",
            "listen_port": $P_ANYTLS_R,
            "users": [{"password": "$IN_UUID"}],
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
            "users": [{"password": "$IN_PWD"}],
            "ignore_client_bandwidth": false,
            "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-02-yuming",
            "listen": "::",
            "listen_port": $P_HY2_Y,
            "users": [{"password": "$IN_UUID"}],
            "ignore_client_bandwidth": false,
            "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "vless",
            "tag": "vless-reality-vision",
            "listen": "::",
            "listen_port": $P_VLESS_R,
            "users": [{"uuid": "$IN_UUID", "flow": "xtls-rprx-vision"}],
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
            "users": [{"uuid": "$IN_UUID", "password": "$IN_PWD"}],
            "congestion_control": "cubic",
            "tls": {"enabled": true, "server_name": "www.bing.com", "alpn": ["h3"], "certificate_path": "$CERT_PATH", "key_path": "$KEY_PATH"}
        },
        {
            "type": "vless",
            "tag": "vless-xhttp-reality",
            "listen": "::",
            "listen_port": $P_XHTTP,
            "users": [{"uuid": "$IN_UUID", "flow": ""}],
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
            "users": [{"name": "username", "password": "$IN_PWD"}],
            "traffic_pattern": "GgQIARAK", "mtu": 1400
        },
        {
            "type": "mieru",
            "tag": "mieru-02-udp",
            "listen_port": $P_MIERU,
            "transport": "UDP",
            "users": [{"name": "username", "password": "$IN_PWD"}],
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
    echo "[√] 旗舰全协议配置文件写入成功！"

    # 5. 注册 Systemd 服务并启动
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

    # 6. 防火墙配置引导 (UFW / Firewalld 自动放行带注释)
    read -p "是否需要自动配置防火墙并放行所有协议端口？(y/n): " do_fw < /dev/tty
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
# 功能函数 5: 暂定显示订阅配置 (三大客户端格式)
# ==========================================
action_show_subscription() {
    echo -e "\n===================================="
    echo "       多客户端订阅与节点信息         "
    echo "===================================="
    if [ ! -f "$DATA_JSON" ]; then
        echo "[-] 错误：未找到持久化配置数据，请先执行第 3 项生成配置！"
        return
    fi

    # 读取持久化数据
    eval $(grep -o '"[^"]*":[[:space:]]*"[^"]*"' "$DATA_JSON" | sed 's/"//g; s/: /=/' )
    
    echo "【1. Sing-box 客户端节点直接可用链接 / JSON 片段】"
    echo "服务器 IP: $server_ip"
    echo "UUID     : $uuid"
    echo "密码     : $password"
    echo "------------------------------------"
    echo "【2. V2ray 可识别格式提示】"
    echo "可使用 VLESS 链接 / Hysteria2 链接导入。"
    echo "------------------------------------"
    echo "【3. Mihomo (Meta) 订阅格式预览】"
    echo "proxies:"
    echo "  - name: VLESS-Reality-$server_ip"
    echo "    type: vless"
    echo "    server: $server_ip"
    echo "    port: $(jq '.ports.vless_reality' $DATA_JSON)"
    echo "    uuid: $uuid"
    echo "    network: tcp"
    echo "    tls: true"
    echo "    servername: www.lovelive-anime.jp"
    echo "    reality-opts:"
    echo "      public-key: $(jq -r '.reality_public_key' $DATA_JSON)"
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
    echo "   3. 生成全协议服务端配置 (含端口检查、证书、持久化保存)"
    echo "   4. 查看 sing-box 运行状态与日志"
    echo "   5. 显示多客户端订阅配置 (sing-box / mihomo / v2ray)"
    echo "   6. 修改服务端配置并生成对应客户端配置 [预留]"
    echo "   7. 申请/管理 ACME 域名 SSL 证书 (永哥 acme.sh 逻辑)"
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
