#!/bin/bash

# ==============================================================
# 额外增加 Hysteria 2 直连备用节点模块 (hy2_jiedian.sh)
# 已集成：重启后自动恢复、防火墙放行、自动同步订阅
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
NODES_DIR="${YUZHOU_DIR}/nodes"
LAST_HY2_PORT_FILE="${YUZHOU_DIR}/last_hy2_port.txt"

mkdir -p "$NODES_DIR"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

clear
echo -e "${CYAN}==============================================================${NC}"
echo -e "${CYAN}        Hysteria 2 直连备用节点部署模块 (自动保活版)      ${NC}"
echo -e "${CYAN}==============================================================${NC}"

# 获取服务器 IP 函数
get_server_ip(){
    local ip=""
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    if [[ -z "$ip" || "$ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]; then
        ip=$(curl -s4 --connect-timeout 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/ip/{print $2}')
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -s4 --connect-timeout 2 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n\r ')
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -s4 --connect-timeout 2 https://api.ip.sb/ip 2>/dev/null | tr -d '\n\r ')
    fi
    echo "$ip"
}

# 检测现有的 Xray 配置文件及路径
xray_dir=""
is_installed_mode=0
cfg_json=""
xray_bin=""

if [ -f "${YUZHOU_DIR}/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/xray"
    is_installed_mode=1
    cfg_json="${YUZHOU_DIR}/xray/config.json"
    xray_bin="${YUZHOU_DIR}/xray/xray"
elif [ -f "${YUZHOU_DIR}/quick/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/quick"
    is_installed_mode=0
    cfg_json="${YUZHOU_DIR}/quick/xray/config.json"
    xray_bin="${YUZHOU_DIR}/quick/xray/xray"
elif [ -f "/opt/suoha/config.json" ]; then
    xray_dir="/opt/suoha"
    is_installed_mode=1
    cfg_json="/opt/suoha/config.json"
    xray_bin="/opt/suoha/xray"
elif [ -f "/opt/suoha_quick/xray/config.json" ]; then
    xray_dir="/opt/suoha_quick"
    is_installed_mode=0
    cfg_json="/opt/suoha_quick/xray/config.json"
    xray_bin="/opt/suoha_quick/xray/xray"
else
    echo -e "${RED}[错误] 未找到正在运行的 Xray 服务配置文件，请先执行梭哈模式或安装服务！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

# 1. 智能检测 IPv4 和 IPv6 地址
echo -e "${YELLOW}正在检测服务器网络栈 (IPv4/IPv6)...${NC}"
ipv4=$(curl -4 -s --connect-timeout 3 ip.sb || ip -4 addr show scope global 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
ipv6=$(curl -6 -s --connect-timeout 3 ip.sb || ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -v 'host' | awk '{print $2}' | cut -d/ -f1 | head -n1)

if [ -z "$ipv4" ]; then
    ipv4=$(get_server_ip)
fi

echo -e " - IPv4 地址: ${GREEN}${ipv4:-未检测到（单IPv6环境）}${NC}"
echo -e " - IPv6 地址: ${GREEN}${ipv6:-未检测到（单IPv4环境）}${NC}"

# 2. 生成随机 UDP 端口和统一密码
hy2_port=$((RANDOM % 10000 + 10000))
hy2_pass=$(cat /proc/sys/kernel/random/uuid)

# 3. 证书处理：仅当不存在时生成一次，确保指纹永久固定
xray_sub_dir="${xray_dir}/xray"
[ ! -d "$xray_sub_dir" ] && xray_sub_dir="$xray_dir"

mkdir -p "$xray_sub_dir"
if [ ! -f "${xray_sub_dir}/hy2.crt" ] || [ ! -f "${xray_sub_dir}/hy2.key" ]; then
    openssl ecparam -genkey -name prime256v1 -out "${xray_sub_dir}/hy2.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${xray_sub_dir}/hy2.key" -out "${xray_sub_dir}/hy2.crt" -subj "/CN=bing.com" 2>/dev/null
fi

# 4. 严格提取自签证书的 SHA-256 指纹
cert_pin=""
if [ -f "${xray_sub_dir}/hy2.crt" ]; then
    cert_pin=$(openssl x509 -in "${xray_sub_dir}/hy2.crt" -noout -sha256 -fingerprint 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
fi

# ==============================================================
# 5. 防火墙端口管理
# ==============================================================
echo -e "\n${CYAN}正在检查并更新防火墙端口规则...${NC}"

if command -v ufw &>/dev/null && systemctl is-active --quiet ufw 2>/dev/null; then
    if [ -f "$LAST_HY2_PORT_FILE" ]; then
        old_hy2_port=$(cat "$LAST_HY2_PORT_FILE")
        if [ -n "$old_hy2_port" ]; then
            ufw delete allow "$old_hy2_port"/udp >/dev/null 2>&1
        fi
    fi
    ufw allow "$hy2_port"/udp comment 'Yuzhou Hysteria2 UDP' >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    if [ -f "$LAST_HY2_PORT_FILE" ]; then
        old_hy2_port=$(cat "$LAST_HY2_PORT_FILE")
        if [ -n "$old_hy2_port" ]; then
            firewall-cmd --permanent --remove-port="$old_hy2_port"/udp >/dev/null 2>&1
        fi
    fi
    firewall-cmd --permanent --add-port="$hy2_port"/udp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
else
    if command -v iptables &>/dev/null; then
        [ -f "$LAST_HY2_PORT_FILE" ] && old_hy2_port=$(cat "$LAST_HY2_PORT_FILE") && [ -n "$old_hy2_port" ] && iptables -D INPUT -p udp --dport "$old_hy2_port" -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p udp --dport "${hy2_port}" -j ACCEPT 2>/dev/null || true
    fi
    if command -v ip6tables &>/dev/null; then
        [ -f "$LAST_HY2_PORT_FILE" ] && old_hy2_port=$(cat "$LAST_HY2_PORT_FILE") && [ -n "$old_hy2_port" ] && ip6tables -D INPUT -p udp --dport "$old_hy2_port" -j ACCEPT 2>/dev/null || true
        ip6tables -A INPUT -p udp --dport "${hy2_port}" -j ACCEPT 2>/dev/null || true
    fi
fi

echo "$hy2_port" > "$LAST_HY2_PORT_FILE"

# 6. 使用 Python 安全注入 Hysteria 2 入站配置
python3 -c "
import json, sys
cfg_file = '$cfg_json'
try:
    with open(cfg_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    data['inbounds'] = [ib for ib in data.get('inbounds', []) if ib.get('tag') != 'hy2-direct']
    hy2_ib = {
        'tag': 'hy2-direct',
        'listen': '0.0.0.0',
        'port': int('$hy2_port'),
        'protocol': 'hysteria',
        'settings': {
            'version': 2,
            'clients': [{'auth': '$hy2_pass'}]
        },
        'streamSettings': {
            'network': 'hysteria',
            'security': 'tls',
            'hysteriaSettings': {'version': 2},
            'tlsSettings': {
                'alpn': ['h3'],
                'certificates': [{
                    'certificateFile': '${xray_sub_dir}/hy2.crt',
                    'keyFile': '${xray_sub_dir}/hy2.key'
                }]
            }
        }
    }
    data['inbounds'].append(hy2_ib)
    with open(cfg_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
except Exception as e:
    sys.exit(1)
"
if [ $? -ne 0 ]; then
    echo -e "${RED}[错误] 写入 Xray 配置文件失败！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

# 保存持久化配置供开机自启恢复使用
cat > "${YUZHOU_DIR}/hy2_config.env" <<EOF
HY2_PORT="$hy2_port"
HY2_PASS="$hy2_pass"
EOF

# 自动将 hy2 恢复逻辑注入到开机自启订阅更新脚本中
AUTO_UPDATE_SCRIPT="/etc/yuzhou/auto_argo_update.sh"
if [ -f "$AUTO_UPDATE_SCRIPT" ] && ! grep -q "hy2_config.env" "$AUTO_UPDATE_SCRIPT"; then
    python3 -c "
with open('$AUTO_UPDATE_SCRIPT', 'r', encoding='utf-8') as f:
    content = f.read()
hy2_code = '''
# === Auto-injected Hysteria 2 recovery ===
if [ -f \\"/etc/yuzhou/hy2_config.env\\" ]; then
    source /etc/yuzhou/hy2_config.env
    h_v4=\\$(curl -4 -s --connect-timeout 2 ip.sb || ip -4 addr show scope global 2>/dev/null | grep inet | awk '{print \\\$2}' | cut -d/ -f1 | head -n1)
    [ -z \"\\$h_v4\" ] && h_v4=\\$(ip route get 1.1.1.1 2>/dev/null | awk '{print \\\$7; exit}')
    h_v6=\\$(curl -6 -s --connect-timeout 2 ip.sb || ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -v 'host' | awk '{print \\\$2}' | cut -d/ -f1 | head -n1)
    h_cert_pin=\\\"\\\"
    if [ -f \"\\${QUICK_DIR}/xray/hy2.crt\" ]; then
        h_cert_pin=\\$(openssl x509 -in \"\\${QUICK_DIR}/xray/hy2.crt\" -noout -sha256 -fingerprint 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    fi
    if [ -n \"\\$h_v4\" ]; then
        qp=\\\"alpn=h3\\\"
        [ -n \"\\$h_cert_pin\" ] && qp=\\\"\\${qp}&pinSHA256=\\${h_cert_pin}\\\" || qp=\\\"\\${qp}&insecure=1\\\"
        echo \"hysteria2://\\${HY2_PASS}@\\$h_v4:\\${HY2_PORT}?\\${qp}#Hy2-v4-Backup\" >> nodes.txt
        cat >> clash.yaml <<EOT

  - name: \\\"Hy2-v4-Backup\\\"
    type: hysteria2
    server: \\$h_v4
    port: \\${HY2_PORT}
    password: \\${HY2_PASS}
    alpn:
      - h3
    pinSHA256: \\$h_cert_pin
EOT
    fi
    if [ -n \"\\$h_v6\" ]; then
        qp=\\\"alpn=h3\\\"
        [ -n \"\\$h_cert_pin\" ] && qp=\\\"\\${qp}&pinSHA256=\\${h_cert_pin}\\\" || qp=\\\"\\${qp}&insecure=1\\\"
        echo \"hysteria2://\\${HY2_PASS}@[\\$h_v6]:\\${HY2_PORT}?\\${qp}#Hy2-v6-Backup\" >> nodes.txt
        cat >> clash.yaml <<EOT

  - name: \\\"Hy2-v6-Backup\\\"
    type: hysteria2
    server: \\$h_v6
    port: \\${HY2_PORT}
    password: \\${HY2_PASS}
    alpn:
      - h3
    pinSHA256: \\$h_cert_pin
EOT
    fi
fi
'''
target = 'cat >> clash.yaml <<\\x27EOF_CLASH\\x27\nproxy-groups:'
if target in content:
    content = content.replace(target, hy2_code + '\n' + target)
    with open('$AUTO_UPDATE_SCRIPT', 'w', encoding='utf-8') as f:
        f.write(content)
" 2>/dev/null || true
fi

# 精准重启 Xray 进程
if [ $is_installed_mode -eq 1 ]; then
    if [ "$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d \" -f2 | awk '{print $1}')" == "Alpine" ]; then
        /etc/local.d/xray.start >/dev/null 2>&1
    else
        systemctl restart xray.service >/dev/null 2>&1
    fi
else
    if [ -f "${xray_dir}/xray.pid" ]; then
        kill -9 $(cat "${xray_dir}/xray.pid") >/dev/null 2>&1
        rm -f "${xray_dir}/xray.pid"
    else
        kill -9 $(pgrep -f "${xray_dir}/xray/xray") >/dev/null 2>&1
    fi
    nohup $xray_bin run -config "$cfg_json" >/dev/null 2>&1 &
    echo $! > "${xray_dir}/xray.pid"
fi

# 7. 写入节点并同步
work_nodes="${xray_dir}/nodes.txt"
clash_file="${xray_dir}/clash.yaml"

touch "$work_nodes"
sed -i '/Hy2-v4-Backup/d' "$work_nodes"
sed -i '/Hy2-v6-Backup/d' "$work_nodes"

links_summary=""

if [ -n "$ipv4" ]; then
    query_param="alpn=h3"
    [ -n "$cert_pin" ] && query_param="${query_param}&pinSHA256=${cert_pin}" || query_param="${query_param}&insecure=1"
    hy2_link_v4="hysteria2://${hy2_pass}@${ipv4}:${hy2_port}?${query_param}#Hy2-v4-Backup"
    echo "$hy2_link_v4" >> "$work_nodes"
    links_summary="${links_summary}\n   👉 IPv4 备用节点: ${hy2_link_v4}"
fi

if [ -n "$ipv6" ]; then
    query_param="alpn=h3"
    [ -n "$cert_pin" ] && query_param="${query_param}&pinSHA256=${cert_pin}" || query_param="${query_param}&insecure=1"
    hy2_link_v6="hysteria2://${hy2_pass}@[${ipv6}]:${hy2_port}?${query_param}#Hy2-v6-Backup"
    echo "$hy2_link_v6" >> "$work_nodes"
    links_summary="${links_summary}\n   👉 IPv6 备用节点: ${hy2_link_v6}"
fi

# 重新生成 Base64 订阅并同步
if [ "$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d \" -f2 | awk '{print $1}')" == "Alpine" ]; then
    base64 "$work_nodes" | tr -d '\n' > "${xray_dir}/sub.txt"
else
    base64 -w 0 "$work_nodes" > "${xray_dir}/sub.txt"
fi

if [ -f "/etc/yuzhou_sub_token" ] || [ -f "/etc/suoha_sub_token" ]; then
    sub_token=$(cat /etc/yuzhou_sub_token 2>/dev/null || cat /etc/suoha_sub_token 2>/dev/null)
    secure_web_dir="/var/www/suoha_sub/${sub_token}"
    if [ -d "$secure_web_dir" ]; then
        cp -f "${xray_dir}/sub.txt" "${secure_web_dir}/sub.txt" 2>/dev/null
        cp -f "${xray_dir}/clash.yaml" "${secure_web_dir}/clash.yaml" 2>/dev/null
        cp -f "${xray_dir}/nodes.txt" "${secure_web_dir}/nodes.txt" 2>/dev/null
    fi
fi

clear
echo "=========================================================="
echo "✅ Hysteria 2 备用节点部署成功并已绑定开机自启！"
echo -e "📌 生成结果汇总:${links_summary}"
echo -e "🛡️ 防火墙放行端口 : ${YELLOW}$hy2_port (UDP)${NC}"
echo "=========================================================="
read -p "按回车键返回主菜单..." < /dev/tty
