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
# 基础生成函数: Hysteria2 及通用自签证书
# ==========================================
action_gen_hy2_cert() {
    mkdir -p /etc/sing-box/ziqian
    if [ ! -f /etc/sing-box/ziqian/private.key ] || [ ! -f /etc/sing-box/ziqian/cert.pem ]; then
        echo "[+] 正在生成 sing-box 默认自签证书..."
        openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/ziqian/private.key &>/dev/null
        openssl req -new -x509 -days 36500 -key /etc/sing-box/ziqian/private.key -out /etc/sing-box/ziqian/cert.pem -subj "/CN=www.bing.com" &>/dev/null
    fi
}

# ==========================================
# 证书状态全局检测函数
# ==========================================
check_certificates_status() {
    echo -e "\n===================================="
    echo "       TLS 证书环境状态检测         "
    echo "===================================="
    
    if [ -f /etc/sing-box/ziqian/cert.pem ] && [ -f /etc/sing-box/ziqian/private.key ]; then
        echo "[√] 自签证书状态: 已就绪 (/etc/sing-box/ziqian/)"
    else
        echo "[!] 自签证书不存在，正在自动生成..."
        action_gen_hy2_cert
        echo "[√] 自签证书状态: 已生成完成"
    fi

    if [ -f /root/ygkkkca/cert.crt ] && [ -f /root/ygkkkca/private.key ]; then
        echo "[√] 域名证书状态: 检测到有效证书 (/root/ygkkkca/cert.crt)"
        HAS_DOMAIN_CERT=1
    else
        echo "[x] 域名证书状态: 未在 /root/ygkkkca/ 检测到完整域名证书"
        HAS_DOMAIN_CERT=0
    fi
    echo "===================================="
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
    
    check_certificates_status

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

    if [ "$HAS_DOMAIN_CERT" -eq 1 ]; then
        read -p "请选择证书类型 [1. 自签证书(默认) 2. 域名证书]: " cert_choice < /dev/tty
        if [ "$cert_choice" = "2" ]; then
            echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/anytls-01-bing_cert
            echo "/root/ygkkkca/private.key" > /etc/sing-box/value/anytls-01-bing_key
        else
            echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/anytls-01-bing_cert
            echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/anytls-01-bing_key
        fi
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
        kp_output=$(sing-box generate reality-keypair 2>/dev/null)
        pri=$(echo "$kp_output" | grep -i "PrivateKey" | awk '{print $NF}')
        pub=$(echo "$kp_output" | grep -i "PublicKey" | awk '{print $NF}')
        [ -z "$pri" ] && pri=$(echo "$kp_output" | head -n 1 | awk '{print $NF}')
        [ -z "$pub" ] && pub=$(echo "$kp_output" | tail -n 1 | awk '{print $NF}')
    else
        pri="gKPwgyITTWk1lrlGF19jTZGFrkTDJ4W7vD2jSs2K6Uk"
        pub="dummy_public_key_anytls"
    fi
    echo "$pri" > /etc/sing-box/value/anytls-02-reality_pri
    echo "$pub" > /etc/sing-box/value/anytls-02-reality_pub
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

    if [ "$HAS_DOMAIN_CERT" -eq 1 ]; then
        echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/hysteria2-02-yuming_cert
        echo "/root/ygkkkca/private.key" > /etc/sing-box/value/hysteria2-02-yuming_key
    else
        echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/hysteria2-02-yuming_cert
        echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/hysteria2-02-yuming_key
    fi

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
        kp_output=$(sing-box generate reality-keypair 2>/dev/null)
        pri=$(echo "$kp_output" | grep -i "PrivateKey" | awk '{print $NF}')
        pub=$(echo "$kp_output" | grep -i "PublicKey" | awk '{print $NF}')
        [ -z "$pri" ] && pri=$(echo "$kp_output" | head -n 1 | awk '{print $NF}')
        [ -z "$pub" ] && pub=$(echo "$kp_output" | tail -n 1 | awk '{print $NF}')
    else
        pri="aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"
        pub="dummy_public_key_vless_vis"
    fi
    echo "$pri" > /etc/sing-box/value/vless-reality-vision_pri
    echo "$pub" > /etc/sing-box/value/vless-reality-vision_pub
    sid_vvr=$(openssl rand -hex 8 2>/dev/null || echo "27dfe873147095d1")
    echo "$sid_vvr" > /etc/sing-box/value/vless-reality-vision_sid

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

    if command -v sing-box &>/dev/null; then
        kp_output=$(sing-box generate reality-keypair 2>/dev/null)
        pri_vxr=$(echo "$kp_output" | grep -i "PrivateKey" | awk '{print $NF}')
        pub_vxr=$(echo "$kp_output" | grep -i "PublicKey" | awk '{print $NF}')
        [ -z "$pri_vxr" ] && pri_vxr=$(echo "$kp_output" | head -n 1 | awk '{print $NF}')
        [ -z "$pub_vxr" ] && pub_vxr=$(echo "$kp_output" | tail -n 1 | awk '{print $NF}')
    else
        pri_vxr="bEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"
        pub_vxr="dummy_public_key_vless_xhttp"
    fi
    echo "$pri_vxr" > /etc/sing-box/value/vless-xhttp-reality_pri
    echo "$pub_vxr" > /etc/sing-box/value/vless-xhttp-reality_pub
    sid_vxr=$(openssl rand -hex 8 2>/dev/null || echo "27dfe873147095d2")
    echo "$sid_vxr" > /etc/sing-box/value/vless-xhttp-reality_sid

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

    uname_def="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
    read -p "请输入用户名/name (回车随机生成 [$uname_def]): " uname < /dev/tty
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

    uname_def2="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
    read -p "请输入用户名/name (回车随机生成 [$uname_def2]): " uname < /dev/tty
    [ -z "$uname" ] && uname="$uname_def2"
    echo "$uname" > /etc/sing-box/value/mieru-02-udp_username

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/mieru-02-udp_password

    echo "[√] 所有 9 个协议节点向导配置及独立密钥对/参数保存完毕！"
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

    read_val() {
        local file="/etc/sing-box/value/$1"
        [ -f "$file" ] && cat "$file" || echo "$2"
    }

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
    pri_vxr=$(read_val "vless-xhttp-reality_pri" "bEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg")
    sid_vxr=$(read_val "vless-xhttp-reality_sid" "27dfe873147095d2")

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
# 功能函数 4: 创建系统服务并启动 sing-box
# ==========================================
action_start_singbox() {
    echo -e "\n===================================="
    echo "  正在创建 systemd 服务并启动 sing-box"
    echo "===================================="

    local SB_BIN=""
    if command -v sing-box &>/dev/null; then
        SB_BIN=$(command -v sing-box)
    elif [ -f /usr/local/bin/sing-box ]; then
        SB_BIN="/usr/local/bin/sing-box"
    elif [ -f /usr/bin/sing-box ]; then
        SB_BIN="/usr/bin/sing-box"
    else
        echo "[-] 错误：未检测到 sing-box 程序，请确认核心是否已安装！"
        return 1
    fi

    cat << EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SB_BIN run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box

    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo "[√] sing-box 服务已成功启动并设置为开机自启！"
        systemctl status sing-box --no-pager
    else
        echo "[-] 错误：sing-box 启动失败，请检查以下运行日志："
        journalctl -u sing-box -n 25 --no-pager
    fi
}

# ==========================================
# 功能函数 5: 生成客户端配置与订阅地址
# ==========================================
action_generate_client_configs() {
    echo -e "\n===================================="
    echo "  正在生成客户端配置与 9 节点订阅合计"
    echo "===================================="

    mkdir -p /etc/sing-box/kehu

    # 获取公网 IP
    PUBLIC_IP=$(curl -s ifconfig.me || curl -s api.ipify.org || hostname -I | awk '{print $1}')
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"

    read_val() {
        local file="/etc/sing-box/value/$1"
        [ -f "$file" ] && cat "$file" || echo "$2"
    }

    # 读取各项配置值
    p_any1=$(read_val "anytls-01-bing_port" "38559")
    pw_any1=$(read_val "anytls-01-bing_password" "dfgdfgerterterdfg234234")

    p_any2=$(read_val "anytls-02-reality_port" "49115")
    pw_any2=$(read_val "anytls-02-reality_password" "sdfsfsf2345dsf32r4rwer")
    srv_any2=$(read_val "anytls-02-reality_server" "gateway.icloud.com")
    pub_any2=$(read_val "anytls-02-reality_pub" "dummy_pub")
    sid_any2=$(read_val "anytls-02-reality_sid" "d1df3e44")

    p_hy1=$(read_val "hysteria2-01-bing_port" "45688")
    pw_hy1=$(read_val "hysteria2-01-bing_password" "hgjghj56456ght45ty45y45y")

    p_hy2=$(read_val "hysteria2-02-yuming_port" "49115")
    pw_hy2=$(read_val "hysteria2-02-yuming_password" "asdweqwerwerdfgd23423")

    p_vvr=$(read_val "vless-reality-vision_port" "28911")
    uuid_vvr=$(read_val "vless-reality-vision_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    srv_vvr=$(read_val "vless-reality-vision_server" "dl.delivery.mp.microsoft.com")
    pub_vvr=$(read_val "vless-reality-vision_pub" "dummy_pub")
    sid_vvr=$(read_val "vless-reality-vision_sid" "27dfe873147095d1")

    p_vxr=$(read_val "vless-xhttp-reality_port" "56433")
    uuid_vxr=$(read_val "vless-xhttp-reality_uuid" "3179dce2-2ff9-413c-85b4-c1d53ed41668")
    srv_vxr=$(read_val "vless-xhttp-reality_server" "intl.cloud.tencent.com")
    pub_vxr=$(read_val "vless-xhttp-reality_pub" "dummy_pub")
    sid_vxr=$(read_val "vless-xhttp-reality_sid" "27dfe873147095d2")

    p_tuic=$(read_val "tuicv5-01-bing_port" "35688")
    uuid_tuic=$(read_val "tuicv5-01-bing_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    pw_tuic=$(read_val "tuicv5-01-bing_password" "3r34r34r34r34reffsfs")

    p_m1=$(read_val "mieru-01-tcp_port" "32498")
    u_m1=$(read_val "mieru-01-tcp_username" "y64rtyty")
    pw_m1=$(read_val "mieru-01-tcp_password" "asdade32rew23r2234r24")

    p_m2=$(read_val "mieru-02-udp_port" "46587")
    u_m2=$(read_val "mieru-02-udp_username" "3r33r3fs")
    pw_m2=$(read_val "mieru-02-udp_password" "a32e4r34rttfg5t5t53t3")

    # 1. 生成 V2Ray/通用客户端的 9 协议订阅合计链接文件 (/etc/sing-box/kehu/v2ray_links.txt)
    cat << EOF > /etc/sing-box/kehu/v2ray_links.txt
==================================================
 sing-box 9 节点客户端分享与订阅合计
 服务器IP: $PUBLIC_IP
==================================================

1. anytls-01-bing (Port: $p_any1)
anytls://$pw_any1@$PUBLIC_IP:$p_any1?security=tls&sni=www.bing.com&allowInsecure=1#anytls-01-bing

2. anytls-02-reality (Port: $p_any2)
anytls://$pw_any2@$PUBLIC_IP:$p_any2?security=tls&sni=$srv_any2&pbk=$pub_any2&sid=$sid_any2#anytls-02-reality

3. hysteria2-01-bing (Port: $p_hy1)
hysteria2://$pw_hy1@$PUBLIC_IP:$p_hy1?insecure=1&sni=www.bing.com#hysteria2-01-bing

4. hysteria2-02-yuming (Port: $p_hy2)
hysteria2://$pw_hy2@$PUBLIC_IP:$p_hy2?sni=www.bing.com#hysteria2-02-yuming

5. vless-reality-vision (Port: $p_vvr)
vless://$uuid_vvr@$PUBLIC_IP:$p_vvr?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$srv_vvr&pbk=$pub_vvr&sid=$sid_vvr&type=tcp#vless-reality-vision

6. vless-xhttp-reality (Port: $p_vxr)
vless://$uuid_vxr@$PUBLIC_IP:$p_vxr?encryption=none&security=reality&sni=$srv_vxr&pbk=$pub_vxr&sid=$sid_vxr&type=xhttp&path=/#vless-xhttp-reality

7. tuicv5-01-bing (Port: $p_tuic)
tuic://$uuid_tuic:$pw_tuic@$PUBLIC_IP:$p_tuic?congestion_control=cubic&sni=www.bing.com&allow_insecure=1#tuicv5-01-bing

8. mieru-01-tcp (Port: $p_m1)
mieru://$u_m1:$pw_m1@$PUBLIC_IP:$p_m1?transport=TCP#mieru-01-tcp

9. mieru-02-udp (Port: $p_m2)
mieru://$u_m2:$pw_m2@$PUBLIC_IP:$p_m2?transport=UDP#mieru-02-udp
==================================================
EOF

    # 2. 生成 Mihomo 客户端配置 (/etc/sing-box/kehu/mihomo.yaml)
    cat << EOF > /etc/sing-box/kehu/mihomo.yaml
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
proxies:
  - name: "anytls-01-bing"
    type: anytls
    server: $PUBLIC_IP
    port: $p_any1
    password: "$pw_any1"
    tls: true
    sni: "www.bing.com"
    skip-cert-verify: true

  - name: "anytls-02-reality"
    type: anytls
    server: $PUBLIC_IP
    port: $p_any2
    password: "$pw_any2"
    tls: true
    sni: "$srv_any2"
    reality-opts:
      public-key: "$pub_any2"
      short-id: "$sid_any2"

  - name: "hysteria2-01-bing"
    type: hysteria2
    server: $PUBLIC_IP
    port: $p_hy1
    password: "$pw_hy1"
    sni: "www.bing.com"
    skip-cert-verify: true

  - name: "hysteria2-02-yuming"
    type: hysteria2
    server: $PUBLIC_IP
    port: $p_hy2
    password: "$pw_hy2"
    skip-cert-verify: true

  - name: "vless-reality-vision"
    type: vless
    server: $PUBLIC_IP
    port: $p_vvr
    uuid: "$uuid_vvr"
    flow: "xtls-rprx-vision"
    tls: true
    servername: "$srv_vvr"
    reality-opts:
      public-key: "$pub_vvr"
      short-id: "$sid_vvr"

  - name: "vless-xhttp-reality"
    type: vless
    server: $PUBLIC_IP
    port: $p_vxr
    uuid: "$uuid_vxr"
    tls: true
    servername: "$srv_vxr"
    network: xhttp
    reality-opts:
      public-key: "$pub_vxr"
      short-id: "$sid_vxr"
    xhttp-opts:
      path: "/"

  - name: "tuicv5-01-bing"
    type: tuic
    server: $PUBLIC_IP
    port: $p_tuic
    uuid: "$uuid_tuic"
    password: "$pw_tuic"
    sni: "www.bing.com"
    skip-cert-verify: true
    congestion-control: cubic

rule-providers: {}
rules:
  - MATCH,DIRECT
EOF

    # 3. 生成 Sing-box 客户端配置 (/etc/sing-box/kehu/client_config.json)
    cat << EOF > /etc/sing-box/kehu/client_config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anytls-01-bing",
      "server": "$PUBLIC_IP",
      "server_port": $p_any1,
      "password": "$pw_any1",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "www.bing.com"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-02-reality",
      "server": "$PUBLIC_IP",
      "server_port": $p_any2,
      "password": "$pw_any2",
      "tls": {
        "enabled": true,
        "server_name": "$srv_any2",
        "reality": {
          "enabled": true,
          "public_key": "$pub_any2",
          "short_id": "$sid_any2"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-01-bing",
      "server": "$PUBLIC_IP",
      "server_port": $p_hy1,
      "password": "$pw_hy1",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "www.bing.com"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-02-yuming",
      "server": "$PUBLIC_IP",
      "server_port": $p_hy2,
      "password": "$pw_hy2",
      "tls": {
        "enabled": true,
        "insecure": true
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-vision",
      "server": "$PUBLIC_IP",
      "server_port": $p_vvr,
      "uuid": "$uuid_vvr",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$srv_vvr",
        "reality": {
          "enabled": true,
          "public_key": "$pub_vvr",
          "short_id": "$sid_vvr"
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-xhttp-reality",
      "server": "$PUBLIC_IP",
      "server_port": $p_vxr,
      "uuid": "$uuid_vxr",
      "tls": {
        "enabled": true,
        "server_name": "$srv_vxr",
        "reality": {
          "enabled": true,
          "public_key": "$pub_vxr",
          "short_id": "$sid_vxr"
        }
      },
      "transport": {
        "type": "xhttp",
        "path": "/"
      }
    },
    {
      "type": "tuic",
      "tag": "tuicv5-01-bing",
      "server": "$PUBLIC_IP",
      "server_port": $p_tuic,
      "uuid": "$uuid_tuic",
      "password": "$pw_tuic",
      "congestion_control": "cubic",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "www.bing.com"
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    echo "[√] 所有客户端配置已成功保存至 /etc/sing-box/kehu/ 目录！"
    echo "--------------------------------------------------"
    echo "📄 订阅文件列表："
    echo "  1. 链接汇总: /etc/sing-box/kehu/v2ray_links.txt"
    echo "  2. Mihomo:   /etc/sing-box/kehu/mihomo.yaml"
    echo "  3. Sing-box: /etc/sing-box/kehu/client_config.json"
    echo "--------------------------------------------------"
    echo "💡 提示：您可以使用 cat /etc/sing-box/kehu/v2ray_links.txt 查看所有节点的链接。"
}

# ==========================================
# 主菜单循环
# ==========================================
show_test_menu() {
    clear
    echo "=================================================="
    echo "      sing-box 9 节点一键配置与管理工具箱       "
    echo "=================================================="
    echo " 1. 🚀 运行完整 9 节点交互式配置向导 (含证书检测与独立密钥)"
    echo " 2. 🛡️ 检测/安装防火墙并自动按需放行端口 (带备注)"
    echo " 3. 📝 自动组装并写入 /etc/sing-box/config.json"
    echo " 4. ⚙️ 创建并启动 sing-box 系统服务 (Systemd)"
    echo " 5. 📦 生成客户端配置与 9 节点订阅合计 (保存至kehu目录)"
    echo " 0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-5]: " choice < /dev/tty

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
        4)
            action_start_singbox
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        5)
            action_generate_client_configs
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        0)
            echo "退出，再见!"
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
