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
# 功能函数 1: 交互获取 9 个节点端口并持久化保存
# ==========================================
action_input_ports() {
    echo -e "\n===================================="
    echo "  开始配置：输入或随机生成 9 个代理端口"
    echo "===================================="

    mkdir -p /etc/sing-box/value

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

    for node in "${nodes[@]}" ; do
        rand_port=$(get_random_port)
        while true; do
            read -p "请为 $node 提供端口，范围在20000-60000之间，回车随机生成 [$rand_port]: " input_port < /dev/tty
            if [ -z "$input_port" ]; then
                port="$rand_port"
                echo "[+] 已自动随机生成未占用端口: $port"
                break
            elif [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 20000 ] && [ "$input_port" -le 60000 ]; then
                if is_port_in_use "$input_port"; then
                    echo "[-] 警告：端口 $input_port 当前已被系统其他服务占用，请更换一个端口！"
                    continue
                fi
                port="$input_port"
                break
            else
                echo "[-] 格式错误，请输入 20000 到 60000 之间的数字。"
            fi
        done
        echo "$port" > "/etc/sing-box/value/${node}_port"
        echo "[+] $node -> 端口 $port 已保存。"
    done

    echo "[√] 所有 9 个节点的端口配置与保存已全部完成！"
}

# ==========================================
# 功能函数 2: 检测/安装防火墙并按需放行 TCP/UDP
# ==========================================
action_setup_firewall() {
    echo -e "\n===================================="
    echo "  开始配置：防火墙检测、安装与端口放行"
    echo "===================================="

    if command -v apt-get &>/dev/null; then
        OS_FAMILY="debian"
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        OS_FAMILY="redhat"
    else
        OS_FAMILY="debian"
    fi

    HAS_UFW=0
    HAS_FIREWALLD=0
    command -v ufw &>/dev/null && HAS_UFW=1
    command -v firewall-cmd &>/dev/null && HAS_FIREWALLD=1

    if [ "$OS_FAMILY" = "debian" ]; then
        if [ "$HAS_FIREWALLD" -eq 1 ]; then
            systemctl stop firewalld &>/dev/null
            systemctl disable firewalld &>/dev/null
            apt-get purge -y firewalld &>/dev/null
        fi
        if [ "$HAS_UFW" -eq 0 ]; then
            apt-get update -y &>/dev/null
            apt-get install -y ufw &>/dev/null
        fi
        ACTIVE_FW="ufw"
    else
        if [ "$HAS_UFW" -eq 1 ]; then
            systemctl stop ufw &>/dev/null
            systemctl disable ufw &>/dev/null
            if command -v dnf &>/dev/null; then
                dnf remove -y ufw &>/dev/null
            else
                yum remove -y ufw &>/dev/null
            fi
        fi
        if [ "$HAS_FIREWALLD" -eq 0 ]; then
            if command -v dnf &>/dev/null; then
                dnf install -y firewalld &>/dev/null
            else
                yum install -y firewalld &>/dev/null
            fi
        fi
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
                if [[ "$p" =~ ^[0-9]+$ ]]; then
                    case "$node" in
                        "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                            ufw allow "$p"/udp comment "$node" &>/dev/null
                            ;;
                        *)
                            ufw allow "$p"/tcp comment "$node" &>/dev/null
                            ;;
                    esac
                fi
            fi
        done
        ufw reload &>/dev/null
        echo "[√] UFW 防火墙及端口规则配置完毕！"
    else
        systemctl start firewalld &>/dev/null
        systemctl enable firewalld &>/dev/null
        firewall-cmd --permanent --add-port="$SSH_PORT"/tcp &>/dev/null
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/${node}_port"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                if [[ "$p" =~ ^[0-9]+$ ]]; then
                    case "$node" in
                        "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                            firewall-cmd --permanent --add-port="$p"/udp &>/dev/null
                            ;;
                        *)
                            firewall-cmd --permanent --add-port="$p"/tcp &>/dev/null
                            ;;
                    esac
                fi
            fi
        done
        firewall-cmd --reload &>/dev/null
        echo "[√] Firewalld 防火墙及端口规则配置完毕！"
    fi
}

# ==========================================
# 基础生成函数（证书、Reality、密码、用户名）
# ==========================================
action_gen_hy2_cert() {
    mkdir -p /etc/sing-box/ziqian
    if [ ! -f /etc/sing-box/ziqian/private.key ]; then
        openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/ziqian/private.key
        openssl req -new -x509 -days 36500 -key /etc/sing-box/ziqian/private.key -out /etc/sing-box/ziqian/cert.pem -subj "/CN=www.bing.com"
    fi
}

# ==========================================
# 功能函数 4: 9 节点全套交互式配置向导（核心新增）
# ==========================================
action_node_wizard() {
    echo -e "\n===================================="
    echo "  开始执行：sing-box 9 节点完整配置向导"
    echo "===================================="

    mkdir -p /etc/sing-box/value
    mkdir -p /etc/sing-box/ziqian

    # 1. 确保自签证书就绪
    action_gen_hy2_cert

    # -------------------------------- 节点 1: anytls-01-bing --------------------------------
    echo -e "\n--- [1/9] 配置协议: anytls-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/anytls-01-bing_port ] && cat /etc/sing-box/value/anytls-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/anytls-01-bing_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/anytls-01-bing_password

    echo "检查到自签证书路径: /etc/sing-box/ziqian/cert.pem"
    echo "检查到域名证书路径: /root/ygkkkca/cert.crt (若无则不可用)"
    read -p "请选择证书类型 [1. 自签证书(默认) 2. 域名证书]: " cert_choice < /dev/tty
    if [ "$cert_choice" = "2" ] && [ -f /root/ygkkkca/cert.crt ]; then
        echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/anytls-01-bing_cert
        echo "/root/ygkkkca/private.key" > /etc/sing-box/value/anytls-01-bing_key
    else
        echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/anytls-01-bing_cert
        echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/anytls-01-bing_key
    fi

    # -------------------------------- 节点 2: anytls-02-reality --------------------------------
    echo -e "\n--- [2/9] 配置协议: anytls-02-reality ---"
    p_def=$([ -f /etc/sing-box/value/anytls-02-reality_port ] && cat /etc/sing-box/value/anytls-02-reality_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/anytls-02-reality_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成): " password < /dev/tty
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
        pri="dummy_private_key"
        pub="dummy_public_key"
    fi
    echo "$pri" > /etc/sing-box/value/anytls-02-reality_pri
    echo "$pub" > /etc/sing-box/value/anytls-02-reality_pub
    sid=$(openssl rand -hex 4 2>/dev/null || echo "d1df3e44")
    echo "$sid" > /etc/sing-box/value/anytls-02-reality_sid

    # -------------------------------- 节点 3: hysteria2-01-bing --------------------------------
    echo -e "\n--- [3/9] 配置协议: hysteria2-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/hysteria2-01-bing_port ] && cat /etc/sing-box/value/hysteria2-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/hysteria2-01-bing_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/hysteria2-01-bing_password
    echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/hysteria2-01-bing_cert
    echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/hysteria2-01-bing_key

    # -------------------------------- 节点 4: hysteria2-02-yuming --------------------------------
    echo -e "\n--- [4/9] 配置协议: hysteria2-02-yuming ---"
    p_def=$([ -f /etc/sing-box/value/hysteria2-02-yuming_port ] && cat /etc/sing-box/value/hysteria2-02-yuming_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/hysteria2-02-yuming_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/hysteria2-02-yuming_password
    echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/hysteria2-02-yuming_cert
    echo "/root/ygkkkca/private.key" > /etc/sing-box/value/hysteria2-02-yuming_key

    # -------------------------------- 节点 5: vless-reality-vision --------------------------------
    echo -e "\n--- [5/9] 配置协议: vless-reality-vision ---"
    p_def=$([ -f /etc/sing-box/value/vless-reality-vision_port ] && cat /etc/sing-box/value/vless-reality-vision_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/vless-reality-vision_port

    uuid_def=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    read -p "请输入 UUID (回车随机生成): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid="$uuid_def"
    echo "$uuid" > /etc/sing-box/value/vless-reality-vision_uuid

    read -p "请输入 server_name 与 server (回车默认 dl.delivery.mp.microsoft.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="dl.delivery.mp.microsoft.com"
    echo "$sname" > /etc/sing-box/value/vless-reality-vision_server

    if command -v sing-box &>/dev/null; then
        kp=$(sing-box generate reality-keypair 2>/dev/null)
        pri=$(echo "$kp" | grep -i "private" | awk '{print $NF}')
        pub=$(echo "$kp" | grep -i "public" | awk '{print $NF}')
        [ -z "$pri" ] && pri=$(echo "$kp" | head -n 1 | awk '{print $NF}')
        [ -z "$pub" ] && pub=$(echo "$kp" | tail -n 1 | awk '{print $NF}')
    else
        pri="dummy_pri"
        pub="dummy_pub"
    fi
    echo "$pri" > /etc/sing-box/value/vless-reality-vision_pri
    echo "$pub" > /etc/sing-box/value/vless-reality-vision_pub
    echo "27dfe873147095d1" > /etc/sing-box/value/vless-reality-vision_sid

    # -------------------------------- 节点 6: vless-xhttp-reality --------------------------------
    echo -e "\n--- [6/9] 配置协议: vless-xhttp-reality ---"
    p_def=$([ -f /etc/sing-box/value/vless-xhttp-reality_port ] && cat /etc/sing-box/value/vless-xhttp-reality_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/vless-xhttp-reality_port

    uuid_def=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "3179dce2-2ff9-413c-85b4-c1d53ed41668")
    read -p "请输入 UUID (回车随机生成): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid="$uuid_def"
    echo "$uuid" > /etc/sing-box/value/vless-xhttp-reality_uuid

    read -p "请输入 server_name 与 server (回车默认 intl.cloud.tencent.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="intl.cloud.tencent.com"
    echo "$sname" > /etc/sing-box/value/vless-xhttp-reality_server

    echo "$pri" > /etc/sing-box/value/vless-xhttp-reality_pri
    echo "$pub" > /etc/sing-box/value/vless-xhttp-reality_pub
    echo "27dfe873147095d1" > /etc/sing-box/value/vless-xhttp-reality_sid

    # -------------------------------- 节点 7: tuicv5-01-bing --------------------------------
    echo -e "\n--- [7/9] 配置协议: tuicv5-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/tuicv5-01-bing_port ] && cat /etc/sing-box/value/tuicv5-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/tuicv5-01-bing_port

    read -p "请输入 UUID (回车随机生成): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid="$uuid_def"
    echo "$uuid" > /etc/sing-box/value/tuicv5-01-bing_uuid

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/tuicv5-01-bing_password
    echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/tuicv5-01-bing_cert
    echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/tuicv5-01-bing_key

    # -------------------------------- 节点 8: mieru-01-tcp --------------------------------
    echo -e "\n--- [8/9] 配置协议: mieru-01-tcp ---"
    p_def=$([ -f /etc/sing-box/value/mieru-01-tcp_port ] && cat /etc/sing-box/value/mieru-01-tcp_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/mieru-01-tcp_port

    uname_def="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
    read -p "请输入用户名/name (回车随机生成 [$uname_def]): " uname < /dev/tty
    [ -z "$uname" ] && uname="$uname_def"
    echo "$uname" > /etc/sing-box/value/mieru-01-tcp_username

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/mieru-01-tcp_password

    # -------------------------------- 节点 9: mieru-02-udp --------------------------------
    echo -e "\n--- [9/9] 配置协议: mieru-02-udp ---"
    p_def=$([ -f /etc/sing-box/value/mieru-02-udp_port ] && cat /etc/sing-box/value/mieru-02-udp_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/mieru-02-udp_port

    read -p "请输入用户名/name (回车随机生成 [$uname_def]): " uname < /dev/tty
    [ -z "$uname" ] && uname="$uname_def"
    echo "$uname" > /etc/sing-box/value/mieru-02-udp_username

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/mieru-02-udp_password

    echo -e "\n[√] 所有 9 个代理协议节点的参数配置与密钥已全部交互配置并保存完毕！"
}

# ==========================================
# 测试菜单主循环
# ==========================================
show_test_menu() {
    clear
    echo "=================================================="
    echo "         sing-box 自动化运维配置向导菜单          "
    echo "=================================================="
    echo " 1. 独立配置 9 个节点端口"
    echo " 2. 检测/安装防火墙并按需放行 TCP/UDP (带备注)"
    echo " 3. 生成 Hysteria2 自签证书"
    echo " 4. 🚀 运行完整 9 节点交互式配置向导 (端口/证书/Reality/密码)"
    echo " 0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-4]: " choice < /dev/tty

    case "$choice" in
        1)
            action_input_ports
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        2)
            action_setup_firewall
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        3)
            action_gen_hy2_cert
            echo "[√] 证书生成完毕！"
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        4)
            action_node_wizard
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        0)
            echo "退出测试，再见！"
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
