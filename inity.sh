#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误：请使用 root 权限运行此脚本！"
  exit 1
fi

export LANG=en_US.UTF-8

# 路径与目录规范
DATA_DIR="/etc/sing-box/xinxi"
CONFIG_FILE="/etc/sing-box/config.json"
DATA_JSON="$DATA_DIR/deploy_data.json"
CERT_YUMING_DIR="/etc/sing-box/yuming"
CERT_ZHIQIAN_DIR="/etc/sing-box/zhiqian"

mkdir -p "$DATA_DIR" /etc/sing-box "$CERT_YUMING_DIR" "$CERT_ZHIQIAN_DIR"

# ==========================================
# 步骤 1: 系统环境基础检测
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
# 步骤 2: 甬哥正宗 ACME 证书申请核心逻辑
# ==========================================
v4v6(){
    v4=$(curl -s4m5 icanhazip.com -k)
    v6=$(curl -s6m5 icanhazip.com -k)
}

acme_install_deps() {
    if [ -x "$(command -v apt-get)" ]; then
        apt update -y && apt install -y socat cron curl openssl lsof dnsutils tar wget
    elif [ -x "$(command -v yum)" ]; then
        yum update -y && yum install -y epel-release && yum install -y socat cronie bind-utils curl openssl lsof tar wget
    elif [ -x "$(command -v dnf)" ]; then
        dnf update -y && dnf install -y socat cronie bind-utils curl openssl lsof tar wget
    fi
}

acme2(){
    if [[ -n $(lsof -i :80|grep -v "PID") ]]; then
        echo "[!] 检测到80端口被占用，正在执行80端口释放..."
        lsof -i :80|grep -v "PID"|awk '{print "kill -9",$2}'|sh >/dev/null 2>&1
        sleep 2
    fi
}

checkip(){
    v4v6
    vpsip=${v4:-$v6}
    domainIP=$(dig @8.8.8.8 +time=2 +short "$ym" 2>/dev/null | grep -m1 '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+$')
    if [[ -z $domainIP ]]; then
        domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$ym" 2>/dev/null | grep -m1 ':')
    fi
    if [[ ! $domainIP =~ $v4 ]] && [[ ! $domainIP =~ $v6 ]]; then
        echo "[-] 错误：当前域名解析的 IP 与本地 VPS IP 不匹配！"
        return 1
    fi
    return 0
}

run_yongge_acme() {
    acme_install_deps
    echo "[+] 正在初始化安装 acme.sh 证书申请脚本..."
    auto=`date +%s%N |md5sum | cut -c 1-6`
    Aemail=$auto@gmail.com
    
    bash ~/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
    rm -rf ~/.acme.sh acme.sh
    curl https://get.acme.sh | sh -s email=$Aemail
    bash ~/.acme.sh/acme.sh --upgrade --use-wget --auto-upgrade >/dev/null 2>&1

    mkdir -p "$CERT_YUMING_DIR"

    echo "===================================="
    echo " 1. 独立 80 端口模式申请 IP/域名证书"
    echo " 2. DNS API 模式申请 (Cloudflare / 腾讯云 / 阿里云)"
    echo "===================================="
    read -p "请选择申请方式 [1-2]: " acme_mode < /dev/tty

    if [ "$acme_mode" = "1" ]; then
        acme2
        v4v6
        vpsip=${v4:-$v6}
        read -p "请输入要申请证书的域名或IP [回车默认 ${vpsip%% *}]: " ym < /dev/tty
        [ -z "$ym" ] && ym=${vpsip%% *}
        
        bash ~/.acme.sh/acme.sh --issue -d "$ym" --standalone -k ec-256 --server letsencrypt --insecure
        bash ~/.acme.sh/acme.sh --install-cert -d "$ym" --key-file "$CERT_YUMING_DIR/private.key" --fullchain-file "$CERT_YUMING_DIR/cert.crt" --ecc
    else
        read -p "请输入解析完成的域名: " ym < /dev/tty
        checkip || return 1
        echo -e "请选择托管域名解析服务商：\n1. Cloudflare\n2. 腾讯云 DNSPod\n3. 阿里云 Aliyun"
        read -p "请选择 [1-3]: " cd < /dev/tty
        case "$cd" in
            1 )
                read -p "请选择 Cloudflare 验证方式 (1. Token / 2. Global API Key): " cf_c < /dev/tty
                if [ "$cf_c" = "1" ]; then
                    read -p "请输入 Cloudflare Account ID: " CFAccountID
                    export CF_Account_ID="$CFAccountID"
                    read -p "请输入 Cloudflare API Token: " CFToken
                    export CF_Token="$CFToken"
                else
                    read -p "请输入 Cloudflare 注册邮箱: " CFemail
                    export CF_Email="$CFemail"
                    read -p "请输入 Cloudflare Global API Key: " GAK
                    export CF_Key="$GAK"
                fi
                bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${ym}" -k ec-256 --server letsencrypt --insecure
                ;;
            2 )
                read -p "请输入腾讯云 DP_Id: " DPID
                export DP_Id="$DPID"
                read -p "请输入腾讯云 DP_Key: " DPKEY
                export DP_Key="$DPKEY"
                bash ~/.acme.sh/acme.sh --issue --dns dns_dp -d "${ym}" -k ec-256 --server letsencrypt --insecure
                ;;
            3 )
                read -p "请输入阿里云 Ali_Key: " ALKEY
                export Ali_Key="$ALKEY"
                read -p "请输入阿里云 Ali_Secret: " ALSER
                export Ali_Secret="$ALSER"
                bash ~/.acme.sh/acme.sh --issue --dns dns_ali -d "${ym}" -k ec-256 --server letsencrypt --insecure
                ;;
        esac
        bash ~/.acme.sh/acme.sh --install-cert -d "${ym}" --key-file "$CERT_YUMING_DIR/private.key" --fullchain-file "$CERT_YUMING_DIR/cert.crt" --ecc
    fi

    if [ -s "$CERT_YUMING_DIR/cert.crt" ] && [ -s "$CERT_YUMING_DIR/private.key" ]; then
        echo "[√] 域名证书申请成功，已安全保存在 $CERT_YUMING_DIR"
        HAS_DOMAIN="true"
        DOMAIN_NAME="$ym"
    else
        echo "[-] 错误：证书申请失败！"
        HAS_DOMAIN="false"
        DOMAIN_NAME=""
    fi
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
# 功能函数 3: 全协议配置生成器 (完整核心功能)
# ==========================================
action_generate_config() {
    echo -e "\n===================================="
    echo "   sing-box 旗舰全协议配置与凭证向导    "
    echo "===================================="

    # 1. 端口输入与范围检查 (20000-60000，逐个检查占用，冲突则重新输入或随机)
    input_port_with_check() {
        local proto_name=$1
        local proto_type=$2
        local user_input
        while true; do
            read -p "请输入 $proto_name 端口 (20000-60000，直接回车随机生成): " user_input < /dev/tty
            if [ -z "$user_input" ]; then
                local rp=$(get_random_port)
                echo "[+] $proto_name 已自动随机生成可用端口: $rp"
                echo "$rp"
                return
            elif [[ "$user_input" =~ ^[0-9]+$ ]] && [ "$user_input" -ge 20000 ] && [ "$user_input" -le 60000 ]; then
                if check_port_free "$user_input" "$proto_type"; then
                    echo "[-] 端口 $user_input 已被占用！请重新输入或直接回车由系统随机生成。"
                else
                    echo "$user_input"
                    return
                fi
            else
                echo "[-] 范围错误，请输入 20000 到 60000 之间的端口号。"
            fi
        done
    }

    echo "[+] 开始配置各个协议端口..."
    P_ANYTLS_B=$(input_port_with_check "AnyTLS (Bing)" "tcp")
    P_ANYTLS_R=$(input_port_with_check "AnyTLS (Reality)" "tcp")
    P_HY2_B=$(input_port_with_check "Hysteria2 (Bing)" "udp")
    P_HY2_Y=$(input_port_with_check "Hysteria2 (域名)" "udp")
    P_VLESS_R=$(input_port_with_check "VLESS Reality" "tcp")
    P_TUIC=$(input_port_with_check "TUIC v5" "udp")
    P_XHTTP=$(input_port_with_check "VLESS XHTTP" "tcp")
    P_MIERU=$(input_port_with_check "Mieru" "tcp")

    # 2. 自签证书安装
    echo "[+] 正在生成基础自签证书至 $CERT_ZHIQIAN_DIR ..."
    openssl ecparam -genkey -name prime256v1 -out "$CERT_ZHIQIAN_DIR/private.key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$CERT_ZHIQIAN_DIR/private.key" -out "$CERT_ZHIQIAN_DIR/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
    ZHIQIAN_CERT="$CERT_ZHIQIAN_DIR/cert.pem"
    ZHIQIAN_KEY="$CERT_ZHIQIAN_DIR/private.key"

    # 3. 询问是否注册域名证书
    read -p "是否需要使用甬哥 ACME 脚本注册正经的域名证书？(y/n) [默认 n]: " do_acme < /dev/tty
    if [ "$do_acme" = "y" ] || [ "$do_acme" = "Y" ]; then
        run_yongge_acme
    else
        HAS_DOMAIN="false"
        DOMAIN_NAME=""
    fi

    if [ "$HAS_DOMAIN" = "true" ] && [ -s "$CERT_YUMING_DIR/cert.crt" ]; then
        YUMING_CERT="$CERT_YUMING_DIR/cert.crt"
        YUMING_KEY="$CERT_YUMING_DIR/private.key"
    else
        YUMING_CERT="$ZHIQIAN_CERT"
        YUMING_KEY="$ZHIQIAN_KEY"
    fi

    # 4. VLESS Reality 密钥与短 ID 生成
    echo "[+] 正在生成 VLESS-Reality 密钥对与 short_id..."
    R_KEYS=$(sing-box generate reality-keypair 2>/dev/null)
    R_PRIV=$(echo "$R_KEYS" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
    R_PUB=$(echo "$R_KEYS" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
    [ -z "$R_PRIV" ] && R_PRIV="aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"
    SHORT_ID=$(openssl rand -hex 8)

    # 5. 各协议用户名、UUID、密码输入（回车则独立随机生成）
    input_credential_with_default() {
        local prompt_name=$1
        local is_uuid=$2
        local val
        read -p "请输入 $prompt_name (直接回车将随机生成): " val < /dev/tty
        if [ -z "$val" ]; then
            if [ "$is_uuid" = "true" ]; then
                val=$(cat /proc/sys/kernel/random/uuid)
            else
                val=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
            fi
        fi
        echo "$val"
    }

    echo "[+] 开始配置各个协议凭证..."
    USER_VLESS_REALITY=$(input_credential_with_default "VLESS Reality UUID" "true")
    USER_XHTTP=$(input_credential_with_default "VLESS XHTTP UUID" "true")
    USER_TUIC=$(input_credential_with_default "TUIC v5 UUID" "true")
    USER_ANYTLS_R=$(input_credential_with_default "AnyTLS Reality 密码/UUID" "true")

    PWD_ANYTLS_B=$(input_credential_with_default "AnyTLS (Bing) 密码" "false")
    PWD_HY2_B=$(input_credential_with_default "Hysteria2 (Bing) 密码" "false")
    PWD_HY2_Y=$(input_credential_with_default "Hysteria2 (域名) 密码" "false")
    NAME_MIERU=$(input_credential_with_default "Mieru 用户名" "false")
    PWD_MIERU=$(input_credential_with_default "Mieru 密码" "false")
    [ -z "$NAME_MIERU" ] && NAME_MIERU="taikong"

    # 6. 持久化保存所有数据到 /etc/sing-box/xinxi/deploy_data.json
    cat << EOF > "$DATA_JSON"
{
  "server_ip": "$SERVER_IP",
  "has_domain": "$HAS_DOMAIN",
  "domain": "$DOMAIN_NAME",
  "reality_private_key": "$R_PRIV",
  "reality_public_key": "$R_PUB",
  "short_id": "$SHORT_ID",
  "uuids": {
    "vless_reality": "$USER_VLESS_REALITY",
    "xhttp": "$USER_XHTTP",
    "tuic": "$USER_TUIC",
    "anytls_reality": "$USER_ANYTLS_R"
  },
  "passwords": {
    "anytls_bing": "$PWD_ANYTLS_B",
    "hy2_bing": "$PWD_HY2_B",
    "hy2_yuming": "$PWD_HY2_Y",
    "mieru_name": "$NAME_MIERU",
    "mieru_pass": "$PWD_MIERU"
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
    echo "[√] 所有配置参数已成功持久化保存至: $DATA_JSON"

    # 7. 写入标准配置文件
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
            "tls": {"enabled": true, "certificate_path": "$ZHIQIAN_CERT", "key_path": "$ZHIQIAN_KEY"}
        },
        {
            "type": "anytls",
            "tag": "anytls-02-reality",
            "listen": "::",
            "listen_port": $P_ANYTLS_R,
            "users": [{"password": "$USER_ANYTLS_R"}],
            "tls": {
                "enabled": true,
                "server_name": "apple.com",
                "reality": {"enabled": true, "handshake": {"server": "apple.com", "server_port": 443}, "private_key": "$R_PRIV", "short_id": ["$SHORT_ID"]}
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-01-bing",
            "listen": "::",
            "listen_port": $P_HY2_B,
            "users": [{"password": "$PWD_HY2_B"}],
            "ignore_client_bandwidth": false,
            "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "$ZHIQIAN_CERT", "key_path": "$ZHIQIAN_KEY"}
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-02-yuming",
            "listen": "::",
            "listen_port": $P_HY2_Y,
            "users": [{"password": "$PWD_HY2_Y"}],
            "ignore_client_bandwidth": false,
            "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "$YUMING_CERT", "key_path": "$YUMING_KEY"}
        },
        {
            "type": "vless",
            "tag": "vless-reality-vision",
            "listen": "::",
            "listen_port": $P_VLESS_R,
            "users": [{"uuid": "$USER_VLESS_REALITY", "flow": "xtls-rprx-vision"}],
            "tls": {
                "enabled": true,
                "server_name": "www.lovelive-anime.jp",
                "reality": {"enabled": true, "handshake": {"server": "www.lovelive-anime.jp", "server_port": 443}, "private_key": "$R_PRIV", "short_id": ["$SHORT_ID"]}
            }
        },
        {
            "type": "tuic",
            "tag": "tuicv5-01-bing",
            "listen": "::",
            "listen_port": $P_TUIC,
            "users": [{"uuid": "$USER_TUIC", "password": "$PWD_ANYTLS_B"}],
            "congestion_control": "cubic",
            "tls": {"enabled": true, "server_name": "www.bing.com", "alpn": ["h3"], "certificate_path": "$ZHIQIAN_CERT", "key_path": "$ZHIQIAN_KEY"}
        },
        {
            "type": "vless",
            "tag": "vless-xhttp-reality",
            "listen": "::",
            "listen_port": $P_XHTTP,
            "users": [{"uuid": "$USER_XHTTP", "flow": ""}],
            "tls": {
                "enabled": true,
                "server_name": "www.lovelive-anime.jp",
                "reality": {"enabled": true, "handshake": {"server": "www.lovelive-anime.jp", "server_port": 443}, "private_key": "$R_PRIV", "short_id": ["$SHORT_ID"]}
            },
            "transport": {"type": "xhttp", "path": "/", "mode": "auto", "x_padding_bytes": "100-1000"}
        },
        {
            "type": "mieru",
            "tag": "mieru-01-tcp",
            "listen_port": $P_MIERU,
            "transport": "TCP",
            "users": [{"name": "$NAME_MIERU", "password": "$PWD_MIERU"}],
            "traffic_pattern": "GgQIARAK", "mtu": 1400
        },
        {
            "type": "mieru",
            "tag": "mieru-02-udp",
            "listen_port": $P_MIERU,
            "transport": "UDP",
            "users": [{"name": "$NAME_MIERU", "password": "$PWD_MIERU"}],
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
    echo "[√] sing-box 配置文件写入成功！"

    # 8. 注册并启动 Systemd 服务
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

    # 9. 检查运行状态
    if systemctl is-active --quiet sing-box; then
        echo "[√] 恭喜！sing-box 服务已成功启动并正常运行！"
    else
        echo "[-] 警告：sing-box 启动可能异常，请通过菜单第 4 项查看运行日志。"
    fi

    # 10. 防火墙询问与带注释规则放行
    read -p "是否需要安装并配置防火墙规则？(y/n): " do_fw < /dev/tty
    if [ "$do_fw" = "y" ] || [ "$do_fw" = "Y" ]; then
        if command -v ufw &>/dev/null; then
            echo "[+] 检测到 Debian 系列，正在配置 UFW 防火墙..."
            ufw allow $P_ANYTLS_B/tcp comment "AnyTLS Bing 端口"
            ufw allow $P_ANYTLS_R/tcp comment "AnyTLS Reality 端口"
            ufw allow $P_HY2_B/udp comment "Hysteria2 Bing 端口"
            ufw allow $P_HY2_Y/udp comment "Hysteria2 域名 端口"
            ufw allow $P_VLESS_R/tcp comment "VLESS Reality 端口"
            ufw allow $P_TUIC/udp comment "TUIC v5 端口"
            ufw allow $P_XHTTP/tcp comment "VLESS XHTTP 端口"
            ufw allow $P_MIERU/tcp comment "Mieru TCP 端口"
            ufw allow $P_MIERU/udp comment "Mieru UDP 端口"
            ufw --force enable
            ufw reload
        elif command -v firewall-cmd &>/dev/null; then
            echo "[+] 检测到 RedHat 系列，正在配置 Firewalld 防火墙..."
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
        echo "[√] 防火墙规则带注释放行完毕！"
    fi
}

# ==========================================
# 功能函数 4: 查看状态与日志
# ==========================================
action_check_status() {
    echo -e "\n===================================="
    echo "       sing-box 运行状态与日志        "
    echo "===================================="
    systemctl status sing-box --no-pager
    echo "------------------------------------"
    echo "最近 10 行运行日志:"
    journalctl -u sing-box -n 10 --no-pager
    echo "===================================="
}

# ==========================================
# 功能函数 5: 显示三大客户端订阅与配置
# ==========================================
action_show_subscription() {
    echo -e "\n===================================="
    echo "       多客户端订阅与节点配置         "
    echo "===================================="
    if [ ! -f "$DATA_JSON" ]; then
        echo "[-] 错误：未找到持久化数据文件 ($DATA_JSON)，请先执行第 3 项生成配置！"
        return
    fi

    HAS_DOM=$(grep -o '"has_domain"[[:space:]]*:[[:space:]]*"[^"]*"' "$DATA_JSON" | awk -F'"' '{print $4}')
    DOM_NAME=$(grep -o '"domain"[[:space:]]*:[[:space:]]*"[^"]*"' "$DATA_JSON" | awk -F'"' '{print $4}')
    
    if [ "$HAS_DOM" = "true" ] && [ -n "$DOM_NAME" ]; then
        SUB_PREFIX="https://$DOM_NAME"
    else
        SUB_PREFIX="http://$SERVER_IP"
    fi

    PUB_KEY=$(grep -o '"reality_public_key"[[:space:]]*:[[:space:]]*"[^"]*"' "$DATA_JSON" | awk -F'"' '{print $4}')
    SHORT_ID_VAL=$(grep -o '"short_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$DATA_JSON" | awk -F'"' '{print $4}')
    VLESS_UUID=$(grep -A 5 'uuids' "$DATA_JSON" | grep 'vless_reality' | awk -F'"' '{print $4}')
    VLESS_PORT=$(grep -A 10 'ports' "$DATA_JSON" | grep 'vless_reality' | awk '{print $2}' | tr -d ',')

    echo "【当前持久化数据存储路径】: $DATA_JSON"
    echo "【订阅协议前缀】          : $SUB_PREFIX"
    echo "------------------------------------"
    echo "【1. V2Ray / 常用客户端通用链接】"
    echo "vless://$VLESS_UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.lovelive-anime.jp&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID_VAL&type=tcp#VLESS-Reality-$SERVER_IP"
    echo "------------------------------------"
    echo "【2. Mihomo (Meta) 订阅节点片段】"
    echo "proxies:"
    echo "  - name: VLESS-Reality-$SERVER_IP"
    echo "    type: vless"
    echo "    server: $SERVER_IP"
    echo "    port: $VLESS_PORT"
    echo "    uuid: $VLESS_UUID"
    echo "    network: tcp"
    echo "    tls: true"
    echo "    servername: www.lovelive-anime.jp"
    echo "    flow: xtls-rprx-vision"
    echo "    reality-opts:"
    echo "      public-key: $PUB_KEY"
    echo "      short-id: $SHORT_ID_VAL"
    echo "------------------------------------"
    echo "【3. Sing-box 客户端订阅 / JSON 片段提示】"
    echo "各项凭证与完整配置已自动写入 /etc/sing-box/config.json"
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
    echo "   3. 生成全协议服务端配置 (含端口检查、双证书、独立凭证、ACME)"
    echo "   4. 查看 sing-box 运行状态与日志"
    echo "   5. 显示多客户端订阅配置 (v2ray / mihomo / sing-box)"
    echo "   6. 修改服务端配置 [预留]"
    echo "   7. 独立运行甬哥 ACME 证书申请模块"
    echo "   8. WireGuard 与 WARP 内容管理 [预留]"
    echo "   9. 策略分流规则管理 [预留]"
    echo "   0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-9]: " choice < /dev/tty

    case "$choice" in
        1) action_init_security ;;
        2) action_manage_singbox ;;
        3) action_generate_config ;;
        4) action_check_status ;;
        5) action_show_subscription ;;
        6) echo "[!] 正在开发中..." ;;
        7) run_yongge_acme ;;
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
