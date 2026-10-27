#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误：请使用 root 权限运行此脚本！"
  exit 1
fi

# ==========================================
# 辅助函数: 检查端口是否被占用
# ==========================================
is_port_in_use() {
    local p=$1
    if command -v ss &>/dev/null; then
        ss -tuln | grep -qE ":$p\b"
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -qE ":$p\b"
    else
        false
    fi
}

# ==========================================
# 辅助函数: 获取未被占用的随机端口
# ==========================================
get_random_port() {
    while true; do
        local rand_port=$((RANDOM % 40001 + 20000))
        if ! is_port_in_use "$rand_port"; then
            echo "$rand_port"
            return
        fi
    done
}

# ==========================================
# 基础生成函数: Hysteria2 自签证书
# ==========================================
action_gen_hy2_cert() {
    mkdir -p /etc/sing-box/ziqian
    if [ ! -f /etc/sing-box/ziqian/private.key ]; then
        openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/ziqian/private.key
        openssl req -new -x509 -days 36500 -key /etc/sing-box/ziqian/private.key -out /etc/sing-box/ziqian/cert.pem -subj "/CN=www.bing.com"
    fi
}

# ==========================================
# 功能函数 1: 9 节点完整交互式配置向导
# ==========================================
action_node_wizard() {
    echo -e "\n===================================="
    echo "  开始执行：sing-box 9 节点完整配置向导"
    echo "===================================="

    mkdir -p /etc/sing-box/value
    mkdir -p /etc/sing-box/ziqian
    action_gen_hy2_cert

    # -------------------------------- 1. anytls-01-bing --------------------------------
    echo -e "\n--- [1/9] 配置协议: anytls-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/anytls-01-bing_port ] && cat /etc/sing-box/value/anytls-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/anytls-01-bing_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/anytls-01-bing_password

    echo "检查到自签证书路径: /etc/sing-box/ziqian/cert.pem"
    echo "检查到域名证书路径: /root/ygkkkca/cert.crt"
    read -p "请选择证书类型 [1. 自签证书(默认) 2. 域名证书]: " cert_choice < /dev/tty
    if [ "$cert_choice" = "2" ] && [ -f /root/ygkkkca/cert.crt ]; then
        echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/anytls-01-bing_cert
        echo "/root/ygkkkca/private.key" > /etc/sing-box/value/anytls-01-bing_key
    else
        echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/anytls-01-bing_cert
        echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/anytls-01-bing_key
    fi

    # -------------------------------- 2. anytls-02-reality --------------------------------
    echo -e "\n--- [2/9] 配置协议: anytls-02-reality ---"
    p_def=$([ -f /etc/sing-box/value/anytls-02-reality_port ] && cat /etc/sing-box/value/anytls-02-reality_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/anytls-02-reality_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/anytls-02-reality_password

    read -p "请输入 server_name 与 server 地址 (回车默认 gateway.icloud.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="gateway.icloud.com"
    echo "$sname" > /etc/sing-box/value/anytls-02-reality_server

    if command -v sing-box &>/dev/null; then
        kp=$(sing-box generate reality-keypair 2>/dev/null)
        pri=$(echo "$kp" | grep -i "private" | awk '{print $NF}')
        pub=$(echo "$kp" | grep -i "public" | awk '{print $NF}')
        [ -z "$pri" ] && pri=$(echo "$kp" | head -n 1 | awk '{print $NF}')
        [ -z "$pub" ] && pub=$(echo "$kp" | tail -n 1 | awk '{print $NF}')
    else
        pri="gKPwgyITTWk1lrlGF19jTZGFrkTDJ4W7vD2jSs2K6Uk"
        pub="dummy_pub"
    fi
    echo "$pri" > /etc/sing-box/value/anytls-02-reality_pri
    sid=$(openssl rand -hex 4 2>/dev/null || echo "d1df3e44")
    echo "$sid" > /etc/sing-box/value/anytls-02-reality_sid

    # -------------------------------- 3. hysteria2-01-bing --------------------------------
    echo -e "\n--- [3/9] 配置协议: hysteria2-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/hysteria2-01-bing_port ] && cat /etc/sing-box/value/hysteria2-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/hysteria2-01-bing_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/hysteria2-01-bing_password
    echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/hysteria2-01-bing_cert
    echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/hysteria2-01-bing_key

    # -------------------------------- 4. hysteria2-02-yuming --------------------------------
    echo -e "\n--- [4/9] 配置协议: hysteria2-02-yuming ---"
    p_def=$([ -f /etc/sing-box/value/hysteria2-02-yuming_port ] && cat /etc/sing-box/value/hysteria2-02-yuming_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/hysteria2-02-yuming_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/hysteria2-02-yuming_password
    echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/hysteria2-02-yuming_cert
    echo "/root/ygkkkca/private.key" > /etc/sing-box/value/hysteria2-02-yuming_key

    # -------------------------------- 5. vless-reality-vision --------------------------------
    echo -e "\n--- [5/9] 配置协议: vless-reality-vision ---"
    p_def=$([ -f /etc/sing-box/value/vless-reality-vision_port ] && cat /etc/sing-box/value/vless-reality-vision_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/vless-reality-vision_port

    uuid_def=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    read -p "请输入 UUID (回车随机生成 [$uuid_def]): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid="$uuid_def"
    echo "$uuid" > /etc/sing-box/value/vless-reality-vision_uuid

    read -p "请输入 server_name 与 server (回车默认 dl.delivery.mp.microsoft.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="dl.delivery.mp.microsoft.com"
    echo "$sname" > /etc/sing-box/value/vless-reality-vision_server

    if command -v sing-box &>/dev/null; then
        kp=$(sing-box generate reality-keypair 2>/dev/null)
        pri=$(echo "$kp" | grep -i "private" | awk '{print $NF}')
        [ -z "$pri" ] && pri=$(echo "$kp" | head -n 1 | awk '{print $NF}')
    else
        pri="aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"
    fi
    echo "$pri" > /etc/sing-box/value/vless-reality-vision_pri
    echo "27dfe873147095d1" > /etc/sing-box/value/vless-reality-vision_sid

    # -------------------------------- 6. vless-xhttp-reality --------------------------------
    echo -e "\n--- [6/9] 配置协议: vless-xhttp-reality ---"
    p_def=$([ -f /etc/sing-box/value/vless-xhttp-reality_port ] && cat /etc/sing-box/value/vless-xhttp-reality_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/vless-xhttp-reality_port

    uuid_def=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "3179dce2-2ff9-413c-85b4-c1d53ed41668")
    read -p "请输入 UUID (回车随机生成 [$uuid_def]): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid="$uuid_def"
    echo "$uuid" > /etc/sing-box/value/vless-xhttp-reality_uuid

    read -p "请输入 server_name 与 server (回车默认 intl.cloud.tencent.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="intl.cloud.tencent.com"
    echo "$sname" > /etc/sing-box/value/vless-xhttp-reality_server

    echo "$pri" > /etc/sing-box/value/vless-xhttp-reality_pri
    echo "27dfe873147095d1" > /etc/sing-box/value/vless-xhttp-reality_sid

    # -------------------------------- 7. tuicv5-01-bing --------------------------------
    echo -e "\n--- [7/9] 配置协议: tuicv5-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/tuicv5-01-bing_port ] && cat /etc/sing-box/value/tuicv5-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/tuicv5-01-bing_port

    read -p "请输入 UUID (回车默认与 vless 相同): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid=$(cat /etc/sing-box/value/vless-reality-vision_uuid 2>/dev/null || echo "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    echo "$uuid" > /etc/sing-box/value/tuicv5-01-bing_uuid

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/tuicv5-01-bing_password
    echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/tuicv5-01-bing_cert
    echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/tuicv5-01-bing_key

    # -------------------------------- 8. mieru-01-tcp --------------------------------
    echo -e "\n--- [8/9] 配置协议: mieru-01-tcp ---"
    p_def=$([ -f /etc/sing-box/value/mieru-01-tcp_port ] && cat /etc/sing-box/value/mieru-01-tcp_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/mieru-01-tcp_port

    uname_def="y64rtyty"
    read -p "请输入用户名/name (回车采用 [$uname_def]): " uname < /dev/tty
    [ -z "$uname" ] && uname="$uname_def"
    echo "$uname" > /etc/sing-box/value/mieru-01-tcp_username

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/mieru-01-tcp_password

    # -------------------------------- 9. mieru-02-udp --------------------------------
    echo -e "\n--- [9/9] 配置协议: mieru-02-udp ---"
    p_def=$([ -f /etc/sing-box/value/mieru-02-udp_port ] && cat /etc/sing-box/value/mieru-02-udp_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/mieru-02-udp_port

    uname_def="3r33r3fs"
    read -p "请输入用户名/name (回车采用 [$uname_def]): " uname < /dev/tty
    [ -z "$uname" ] && uname="$uname_def"
    echo "$uname" > /etc/sing-box/value/mieru-02-udp_username

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/mieru-02-udp_password

    echo "[√] 所有 9 个协议节点向导配置及参数保存完毕！"
}

# ==========================================
# 功能函数 2: 防火墙检测、安装与端口放行
# ==========================================
action_setup_firewall() {
    echo -e "\n===================================="
    echo "  开始配置：防火墙检测、安装与端口放行"
    echo "===================================="

    if command -v apt-get &>/dev/null; then
        OS_FAMILY="debian"
    else
        OS_FAMILY="redhat"
    fi

    HAS_UFW=0
    HAS_FIREWALLD=0
    command -v ufw &>/dev/null && HAS_UFW=1
    command -v firewall-cmd &>/dev/null && HAS_FIREWALLD=1

    if [ "$OS_FAMILY" = "debian" ]; then
        [ "$HAS_FIREWALLD" -eq 1 ] && { systemctl stop firewalld &>/dev/null; apt-get purge -y firewalld &>/dev/null; }
        [ "$HAS_UFW" -eq 0 ] && { apt-get update -y &>/dev/null; apt-get install -y ufw &>/dev/null; }
        ACTIVE_FW="ufw"
    else
        [ "$HAS_UFW" -eq 1 ] && { systemctl stop ufw &>/dev/null; yum remove -y ufw &>/dev/null; }
        [ "$HAS_FIREWALLD" -eq 0 ] && { yum install -y firewalld &>/dev/null || dnf install -y firewalld &>/dev/null; }
        ACTIVE_FW="firewalld"
    fi

    SSH_PORT=$(grep -E "^[#\s]*Port\s+[0-9]+" /etc/ssh/sshd_config | awk '{print $2}' | tail -n 1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    nodes=(
        "hysteria2-01-bing"
        "hysteria2-02-yuming"
        "anytls-01-bing"
        "anytls-02-reality"
        "vless-reality-vision"
        "vless-xhttp-reality"
        "tuicv5-01-bing"
        "mieru-01-tcp"
        "mieru-02-udp"
    )

    if [ "$ACTIVE_FW" = "ufw" ]; then
        ufw --force enable &>/dev/null
        ufw allow "$SSH_PORT"/tcp comment "ssh端口" &>/dev/null
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/${node}_port"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                case "$node" in
                    "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                        ufw allow "$p"/udp comment "$node" &>/dev/null ;;
                    *)
                        ufw allow "$p"/tcp comment "$node" &>/dev/null ;;
                esac
            fi
        done
        ufw reload &>/dev/null
        echo "[√] UFW 防火墙端口放行完成！"
    else
        systemctl start firewalld &>/dev/null
        systemctl enable firewalld &>/dev/null
        firewall-cmd --permanent --add-port="$SSH_PORT"/tcp &>/dev/null
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/${node}_port"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                case "$node" in
                    "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                        firewall-cmd --permanent --add-port="$p"/udp &>/dev/null ;;
                    *)
                        firewall-cmd --permanent --add-port="$p"/tcp &>/dev/null ;;
                esac
            fi
        done
        firewall-cmd --reload &>/dev/null
        echo "[√] Firewalld 防火墙端口放行完成！"
    fi
}

# ==========================================
# 功能函数 3: 生成 /etc/sing-box/config.json
# ==========================================
action_generate_config_json() {
    echo -e "\n===================================="
    echo "  正在组装并写入 /etc/sing-box/config.json"
    echo "===================================="

    # 从 /etc/sing-box/value/ 读取各项配置（若不存在则采用默认占位值）
    read_val() {
        local file="/etc/sing-box/value/$1"
        [ -f "$file" ] && cat "$file" || echo "$2"
    }

    # 1. 读取各项参数
    p_any1=$(read_val "anytls-01-bing_port" "38559")
    pw_any1=$(read_val "anytls-01-bing_password" "dfgdfgerterterdfg234234")
    cert_any1=$(read_val "anytls-01-bing_cert" "/etc/sing-box/cert.pem")
    key_any1=$(read_val "anytls-01-bing_key" "/etc/sing-box/private.key")

    p_any2=$(read_val "anytls-02-reality_port" "49115")
    pw_any2=$(read_val "anytls-02-reality_password" "sdfsfsf2345dsf32r4rwer")
    srv_any2=$(read_val "anytls-02-reality_server" "gateway.icloud.com")
    pri_any2=$(read_val "anytls-02-reality_pri" "gKPwgyITTWk1lrlGF19jTZGFrkTDJ4W7vD2jSs2K6Uk")
    sid_any2=$(read_val "anytls-02-reality_sid" "d1df3e44")

    p_hy1=$(read_val "hysteria2-01-bing_port" "45688")
    pw_hy1=$(read_val "hysteria2-01-bing_password" "hgjghj56456ght45ty45y45y")
    cert_hy1=$(read_val "hysteria2-01-bing_cert" "/etc/sing-box/cert.pem")
    key_hy1=$(read_val "hysteria2-01-bing_key" "/etc/sing-box/private.key")

    p_hy2=$(read_val "hysteria2-02-yuming_port" "49115")
    pw_hy2=$(read_val "hysteria2-02-yuming_password" "asdweqwerwerdfgd23423")
    cert_hy2=$(read_val "hysteria2-02-yuming_cert" "/root/ygkkkca/cert.crt")
    key_hy2=$(read_val "hysteria2-02-yuming_key" "/root/ygkkkca/private.key")

    p_vvr=$(read_val "vless-reality-vision_port" "28911")
    uuid_vvr=$(read_val "vless-reality-vision_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    srv_vvr=$(read_val "vless-reality-vision_server" "dl.delivery.mp.microsoft.com")
    pri_vvr=$(read_val "vless-reality-vision_pri" "aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg")
    sid_vvr=$(read_val "vless-reality-vision_sid" "27dfe873147095d1")

    p_vxr=$(read_val "vless-xhttp-reality_port" "56433")
    uuid_vxr=$(read_val "vless-xhttp-reality_uuid" "3179dce2-2ff9-413c-85b4-c1d53ed41668")
    srv_vxr=$(read_val "vless-xhttp-reality_server" "intl.cloud.tencent.com")

    p_tuic=$(read_val "tuicv5-01-bing_port" "35688")
    uuid_tuic=$(read_val "tuicv5-01-bing_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    pw_tuic=$(read_val "tuicv5-01-bing_password" "3r34r34r34r34reffsfs")
    cert_tuic=$(read_val "tuicv5-01-bing_cert" "/etc/sing-box/cert.pem")
    key_tuic=$(read_val "tuicv5-01-bing_key" "/etc/sing-box/private.key")

    p_m1=$(read_val "mieru-01-tcp_port" "32498")
    u_m1=$(read_val "mieru-01-tcp_username" "y64rtyty")
    pw_m1=$(read_val "mieru-01-tcp_password" "asdade32rew23r2234r24")

    p_m2=$(read_val "mieru-02-udp_port" "46587")
    u_m2=$(read_val "mieru-02-udp_username" "3r33r3fs")
    pw_m2=$(read_val "mieru-02-udp_password" "a32e4r34rttfg5t5t53t3")

    # 2. 写入完整的 JSON 配置文件
    cat << EOF > /etc/sing-box/config.json
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
            "listen_port": $p_any1,
            "users": [
                {
                    "password": "$pw_any1"
                }
            ],
            "padding_scheme": [
                "stop=10",
                "0=30-30",
                "1=100-400,c,10-10",
                "2=200-300,c,200-300,c,200-300",
                "3=9-9",
                "4-9=50-100"
            ],
            "tls": {
                "enabled": true,
                "certificate_path": "$cert_any1",
                "key_path": "$key_any1"
            }
        },
        {
            "type": "anytls",
            "tag": "anytls-02-reality",
            "listen": "::",
            "listen_port": $p_any2,
            "users": [
                {
                    "password": "$pw_any2"
                }
            ],
            "padding_scheme": [],
            "tls": {
                "enabled": true,
                "server_name": "$srv_any2",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$srv_any2",
                        "server_port": 443
                    },
                    "private_key": "$pri_any2",
                    "short_id": [
                        "$sid_any2"
                    ]
                }
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-01-bing",
            "listen": "::",
            "listen_port": $p_hy1,
            "users": [
                {
                    "password": "$pw_hy1"
                }
            ],
            "ignore_client_bandwidth": false,
            "tls": {
                "enabled": true,
                "alpn": [
                    "h3"
                ],
                "certificate_path": "$cert_hy1",
                "key_path": "$key_hy1"
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-02-yuming",
            "listen": "::",
            "listen_port": $p_hy2,
            "users": [
                {
                    "password": "$pw_hy2"
                }
            ],
            "ignore_client_bandwidth": false,
            "tls": {
                "enabled": true,
                "alpn": [
                    "h3"
                ],
                "certificate_path": "$cert_hy2",
                "key_path": "$key_hy2"
            }
        },
        {
            "type": "vless",
            "tag": "vless-reality-vision",
            "listen": "::",
            "listen_port": $p_vvr,
            "users": [
                {
                    "uuid": "$uuid_vvr",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$srv_vvr",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$srv_vvr",
                        "server_port": 443
                    },
                    "private_key": "$pri_vvr",
                    "short_id": [
                        "$sid_vvr"
                    ]
                }
            }
        },
        {
            "type": "vless",
            "tag": "vless-xhttp-reality",
            "listen": "::",
            "listen_port": $p_vxr,
            "users": [
                {
                    "uuid": "$uuid_vxr",
                    "flow": ""
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$srv_vxr",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$srv_vxr",
                        "server_port": 443
                    },
                    "private_key": "$pri_vvr",
                    "short_id": [
                        "$sid_vvr"
                    ]
                }
            },
            "transport": {
                "type": "xhttp",
                "path": "/",
                "mode": "auto",
                "x_padding_bytes": "100-1000"
            }
        },
        {
            "type": "tuic",
            "tag": "tuicv5-01-bing",
            "listen": "::",
            "listen_port": $p_tuic,
            "users": [
                {
                    "uuid": "$uuid_tuic",
                    "password": "$pw_tuic"
                }
            ],
            "congestion_control": "cubic",
            "auth_timeout": "3s",
            "zero_rtt_handshake": false,
            "heartbeat": "10s",
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "alpn": [
                    "h3"
                ],
                "certificate_path": "$cert_tuic",
                "key_path": "$key_tuic"
            }
        },
        {
            "type": "mieru",
            "tag": "mieru-01-tcp",
            "listen_port": $p_m1,
            "transport": "TCP",
            "users": [
                {
                    "name": "$u_m1",
                    "password": "$pw_m1"
                }
            ],
            "traffic_pattern": "GgQIARAK",
            "mtu": 1400
        },
        {
            "type": "mieru",
            "tag": "mieru-02-udp",
            "listen_port": $p_m2,
            "transport": "UDP",
            "users": [
                {
                    "name": "$u_m2",
                    "password": "$pw_m2"
                }
            ],
            "traffic_pattern": "GgQIARAK",
            "mtu": 1400
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "endpoints": [
        {
            "type": "wireguard",
            "tag": "warp-out",
            "address": [
                "172.16.0.2/32",
                "2606:4700:110:8701:8c03:4abe:4756:1a71/128"
            ],
            "private_key": "CEfHC7QzBIo62pLZQMIEPchSXKoXW93XfKAwOIOATWE=",
            "peers": [
                {
                    "address": "162.159.193.10",
                    "port": 2408,
                    "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                    "allowed_ips": [
                        "0.0.0.0/0",
                        "::/0"
                    ]
                }
            ]
        }
    ],
    "route": {
        "rules": [
            {
                "action": "sniff"
            },
            {
                "domain": [
                    "gemini.google.com",
                    "generativelanguage.googleapis.com",
                    "aistudio.google.com",
                    "alkaliminer-pa.googleapis.com",
                    "accounts.google.com",
                    "ssl.gstatic.com",
                    "www.gstatic.com",
                    "fonts.gstatic.com",
                    "apis.google.com",
                    "openai.com",
                    "chat.openai.com",
                    "auth0.openai.com",
                    "cdn.openai.com",
                    "api.openai.com",
                    "auth0.com"
                ],
                "action": "route",
                "outbound": "warp-out"
            },
            {
                "outbound": "direct",
                "network": "udp,tcp"
            }
        ],
        "final": "direct"
    }
}
EOF

    echo "[√] 配置文件已成功写入 /etc/sing-box/config.json！"
}

# ==========================================
# 主菜单循环
# ==========================================
show_test_menu() {
    clear
    echo "=================================================="
    echo "      sing-box 9 节点一键配置与管理工具箱       "
    echo "=================================================="
    echo " 1. 🚀 运行完整 9 节点交互式配置向导 (端口/密码/证书/Reality)"
    echo " 2. 🛡️ 检测/安装防火墙并自动按需放行端口 (带备注)"
    echo " 3. 📝 自动组装并写入 /etc/sing-box/config.json"
    echo " 0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-3]: " choice < /dev/tty

    case "$choice" in
        1)
            action_node_wizard
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        2)
            action_setup_firewall
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        3)
            action_generate_config_json
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        0)
            echo "退出，再见！"
            exit 0
            ;;
        *)
            echo "[-] 无效的选择，请重新输入！"
            sleep 1
            ;;
    esac
}

# 保持菜单循环
while true; do
    show_test_menu
done
