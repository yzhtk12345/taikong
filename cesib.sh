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
# 功能函数 1: 交互获取 9 个节点端口并持久化保存 (含防占用检测)
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
        # 寻找一个未被系统占用的随机端口作为默认推荐
        while true; do
            rand_port=$((RANDOM % 40001 + 20000))
            if ! is_port_in_use "$rand_port"; then
                break
            fi
        done

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
        echo "$port" > "/etc/sing-box/value/$node"
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

    # 1. 判断系统系别
    if command -v apt-get &>/dev/null; then
        OS_FAMILY="debian"
    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        OS_FAMILY="redhat"
    else
        OS_FAMILY="debian"
    fi

    # 2. 检查现有防火墙并按需清理/安装
    HAS_UFW=0
    HAS_FIREWALLD=0
    command -v ufw &>/dev/null && HAS_UFW=1
    command -v firewall-cmd &>/dev/null && HAS_FIREWALLD=1

    if [ "$OS_FAMILY" = "debian" ]; then
        if [ "$HAS_FIREWALLD" -eq 1 ]; then
            echo "[!] 检测到不适配的 firewalld，正在卸载..."
            systemctl stop firewalld &>/dev/null
            systemctl disable firewalld &>/dev/null
            apt-get purge -y firewalld &>/dev/null
        fi
        if [ "$HAS_UFW" -eq 0 ]; then
            echo "[+] 正在安装 ufw 防火墙..."
            apt-get update -y &>/dev/null
            apt-get install -y ufw &>/dev/null
        fi
        ACTIVE_FW="ufw"
    else
        if [ "$HAS_UFW" -eq 1 ]; then
            echo "[!] 检测到不适配的 ufw，正在卸载..."
            systemctl stop ufw &>/dev/null
            systemctl disable ufw &>/dev/null
            if command -v dnf &>/dev/null; then
                dnf remove -y ufw &>/dev/null
            else
                yum remove -y ufw &>/dev/null
            fi
        fi
        if [ "$HAS_FIREWALLD" -eq 0 ]; then
            echo "[+] 正在安装 firewalld 防火墙..."
            if command -v dnf &>/dev/null; then
                dnf install -y firewalld &>/dev/null
            else
                yum install -y firewalld &>/dev/null
            fi
        fi
        ACTIVE_FW="firewalld"
    fi

    # 3. 获取当前 SSH 端口
    SSH_PORT=$(grep -E "^[#\s]*Port\s+[0-9]+" /etc/ssh/sshd_config | awk '{print $2}' | tail -n 1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    echo "[+] 当前检测到 SSH 端口为: $SSH_PORT"

    # 4. 定义 9 个节点列表并校验是否存在对应的端口文件
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

    VALID_COUNT=0
    if [ -d /etc/sing-box/value ]; then
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/$node"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                [[ "$p" =~ ^[0-9]+$ ]] && VALID_COUNT=$((VALID_COUNT + 1))
            fi
        done
    fi

    if [ "$VALID_COUNT" -eq 0 ]; then
        echo "[-] 警告：未在 /etc/sing-box/value/ 目录下找到任何有效的端口配置，请先运行选项 1！"
        return
    fi

    # 5. 配置防火墙规则并按需放行协议（区分 TCP / UDP）
    if [ "$ACTIVE_FW" = "ufw" ]; then
        echo "[+] 正在配置 UFW 防火墙规则..."
        ufw --force enable &>/dev/null
        ufw allow "$SSH_PORT"/tcp comment "ssh端口" &>/dev/null
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/$node"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                if [[ "$p" =~ ^[0-9]+$ ]]; then
                    case "$node" in
                        "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                            ufw allow "$p"/udp comment "$node" &>/dev/null
                            echo "[+] UFW 已放行端口: $p (UDP) [备注: $node]"
                            ;;
                        *)
                            ufw allow "$p"/tcp comment "$node" &>/dev/null
                            echo "[+] UFW 已放行端口: $p (TCP) [备注: $node]"
                            ;;
                    esac
                fi
            fi
        done
        ufw reload &>/dev/null
        echo "[√] UFW 防火墙规则配置完毕！"
    else
        echo "[+] 正在配置 Firewalld 防火墙规则..."
        systemctl start firewalld &>/dev/null
        systemctl enable firewalld &>/dev/null
        firewall-cmd --permanent --add-port="$SSH_PORT"/tcp &>/dev/null
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/$node"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                if [[ "$p" =~ ^[0-9]+$ ]]; then
                    case "$node" in
                        "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                            firewall-cmd --permanent --add-port="$p"/udp &>/dev/null
                            echo "[+] Firewalld 已放行端口: $p (UDP)"
                            ;;
                        *)
                            firewall-cmd --permanent --add-port="$p"/tcp &>/dev/null
                            echo "[+] Firewalld 已放行端口: $p (TCP)"
                            ;;
                    esac
                fi
            fi
        done
        firewall-cmd --reload &>/dev/null
        echo "[√] Firewalld 防火墙规则配置完毕！"
    fi
}

# ==========================================
# 功能函数 3: 生成 Hysteria2 自签证书
# ==========================================
action_gen_hy2_cert() {
    echo -e "\n===================================="
    echo "  开始生成：Hysteria2 自签证书"
    echo "===================================="

    mkdir -p /etc/sing-box/ziqian
    openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/ziqian/private.key
    openssl req -new -x509 -days 36500 -key /etc/sing-box/ziqian/private.key -out /etc/sing-box/ziqian/cert.pem -subj "/CN=www.bing.com"

    echo "[√] Hysteria2 自签证书生成完毕！"
    echo " - 私钥路径 : /etc/sing-box/ziqian/private.key"
    echo " - 证书路径 : /etc/sing-box/ziqian/cert.pem"
}

# ==========================================
# 功能函数 4: 生成 Reality 秘钥对
# ==========================================
action_gen_reality_keys() {
    echo -e "\n===================================="
    echo "  开始生成：Reality 协议秘钥对"
    echo "===================================="

    if ! command -v sing-box &>/dev/null; then
        echo "[-] 错误：未检测到 sing-box 程序，无法生成 Reality 秘钥对，请先安装 sing-box！"
        return
    fi

    mkdir -p /etc/sing-box/value
    reality_nodes=(
        "anytls-02-reality"
        "vless-reality-vision"
        "vless-xhttp-reality"
    )

    for node in "${reality_nodes[@]}"; do
        echo "[+] 正在为 $node 生成独立 Reality 秘钥对..."
        keypair_output=$(sing-box generate reality-keypair 2>/dev/null)
        
        priv_key=$(echo "$keypair_output" | grep -i "private" | awk '{print $NF}')
        pub_key=$(echo "$keypair_output" | grep -i "public" | awk '{print $NF}')

        if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
            priv_key=$(echo "$keypair_output" | head -n 1 | awk '{print $NF}')
            pub_key=$(echo "$keypair_output" | tail -n 1 | awk '{print $NF}')
        fi

        echo "$priv_key" > "/etc/sing-box/value/${node}_private.key"
        echo "$pub_key" > "/etc/sing-box/value/${node}_public.key"

        echo "[+] $node 秘钥对已保存："
        echo "    -> 私钥: /etc/sing-box/value/${node}_private.key"
        echo "    -> 公钥: /etc/sing-box/value/${node}_public.key"
    done

    echo "[√] 所有 Reality 节点秘钥对生成完毕！"
}

# ==========================================
# 功能函数 5: 手动输入或随机生成 30 位密码
# ==========================================
action_input_passwords() {
    echo -e "\n===================================="
    echo "  开始配置：输入或随机生成节点密码/Token"
    echo "===================================="

    mkdir -p /etc/sing-box/value

    pwd_nodes=(
        "hysteria2-01-bing"
        "hysteria2-02-yuming"
        "tuicv5-01-bing"
        "mieru-01-tcp"
        "mieru-02-udp"
    )

    for node in "${pwd_nodes[@]}"; do
        rand_pwd=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
        while true; do
            read -p "请为 $node 提供密码/Token (直接回车随机生成 30 位 [$rand_pwd]): " input_pwd < /dev/tty
            if [ -z "$input_pwd" ]; then
                pwd_val="$rand_pwd"
                echo "[+] 已自动随机生成 30 位密码: $pwd_val"
                break
            else
                pwd_val="$input_pwd"
                break
            fi
        done
        echo "$pwd_val" > "/etc/sing-box/value/${node}_password"
        echo "[+] $node -> 密码已保存至 /etc/sing-box/value/${node}_password"
    done

    echo "[√] 所有密码类节点配置已全部完成！"
}

# ==========================================
# 测试菜单主循环
# ==========================================
show_test_menu() {
    clear
    echo "=================================================="
    echo "         功能函数扩展与测试工具箱菜单            "
    echo "=================================================="
    echo " 1. 配置 9 个节点端口 (带防占用检测)"
    echo " 2. 检测/安装防火墙并按需放行 TCP/UDP (带备注)"
    echo " 3. 生成 Hysteria2 自签证书"
    echo " 4. 生成 Reality 独立协议秘钥对"
    echo " 5. 配置节点密码/Token (支持随机 30 位)"
    echo " 0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-5]: " choice < /dev/tty

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
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        4)
            action_gen_reality_keys
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        5)
            action_input_passwords
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
