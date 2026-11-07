#!/bin/bash

# ==============================================================
# 额外增加 Hysteria 2 直连备用节点模块 (hy2_jiedian.sh)
# 路径适配到 /etc/yuzhou/，集成防火墙检查、旧端口清理与新端口放行带备注
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
echo -e "${CYAN}        Hysteria 2 直连备用节点部署模块 (hy2_jiedian.sh)      ${NC}"
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
# 5. 防火墙端口管理：检查防火墙类型、删除旧HY2端口、放行新端口（带备注）
# ==============================================================
echo -e "\n${CYAN}正在检查并更新防火墙端口规则...${NC}"

if command -v ufw &>/dev/null && systemctl is-active --quiet ufw 2>/dev/null; then
    # 清理旧的 HY2 端口
    if [ -f "$LAST_HY2_PORT_FILE" ]; then
        old_hy2_port=$(cat "$LAST_HY2_PORT_FILE")
        if [ -n "$old_hy2_port" ]; then
            ufw delete allow "$old_hy2_port"/udp >/dev/null 2>&1
        fi
    fi
    # 放行新端口 (UDP, 带备注)
    ufw allow "$hy2_port"/udp comment 'Yuzhou Hysteria2 UDP' >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    echo -e "${GREEN}[√] UFW 防火墙更新完成：已清理旧端口，成功放行新 HY2 端口 $hy2_port (UDP) 并带备注。${NC}"

elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    # 清理旧的 HY2 端口
    if [ -f "$LAST_HY2_PORT_FILE" ]; then
        old_hy2_port=$(cat "$LAST_HY2_PORT_FILE")
        if [ -n "$old_hy2_port" ]; then
            firewall-cmd --permanent --remove-port="$old_hy2_port"/udp >/dev/null 2>&1
        fi
    fi
    # 放行新端口 (UDP)
    firewall-cmd --permanent --add-port="$hy2_port"/udp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo -e "${GREEN}[√] Firewalld 防火墙更新完成：已清理旧端口，成功放行新 HY2 端口 $hy2_port (UDP)。${NC}"
else
    # 兜底原生 iptables
    if command -v iptables &>/dev/null; then
        if [ -f "$LAST_HY2_PORT_FILE" ]; then
            old_hy2_port=$(cat "$LAST_HY2_PORT_FILE")
            [ -n "$old_hy2_port" ] && iptables -D INPUT -p udp --dport "$old_hy2_port" -j ACCEPT 2>/dev/null || true
        fi
        iptables -A INPUT -p udp --dport "${hy2_port}" -j ACCEPT 2>/dev/null || true
    fi
    if command -v ip6tables &>/dev/null; then
        if [ -f "$LAST_HY2_PORT_FILE" ]; then
            old_hy2_port=$(cat "$LAST_HY2_PORT_FILE")
            [ -n "$old_hy2_port" ] && ip6tables -D INPUT -p udp --dport "$old_hy2_port" -j ACCEPT 2>/dev/null || true
        fi
        ip6tables -A INPUT -p udp --dport "${hy2_port}" -j ACCEPT 2>/dev/null || true
    fi
    echo -e "${YELLOW}[!] 未检测到 UFW/Firewalld，已通过原生 iptables/ip6tables 放行 UDP 端口 $hy2_port。${NC}"
fi

# 记录当前端口供下次清理使用
echo "$hy2_port" > "$LAST_HY2_PORT_FILE"

# 6. 使用 Python 安全注入带 TLS 的 Hysteria 2 入站配置
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

# 7. 清理旧的 Hy2 节点后重新追加，并同步写入 Clash 配置
work_nodes="${xray_dir}/nodes.txt"
clash_file="${xray_dir}/clash.yaml"

touch "$work_nodes"
sed -i '/Hy2-v4-Backup/d' "$work_nodes"
sed -i '/Hy2-v6-Backup/d' "$work_nodes"

if [ -f "$clash_file" ]; then
    python3 -c "
with open('$clash_file', 'r', encoding='utf-8') as f:
    content = f.read()
import re
content = re.sub(r'\n\s*-\s*name:\s*\"Hy2-v[46]-Backup\"[\s\S]*?(?=\n\s*-\s*name:|\nproxy-groups:|\Z)', '', content)
with open('$clash_file', 'w', encoding='utf-8') as f:
    f.write(content)
" 2>/dev/null || true
fi

links_summary=""

if [ -n "$ipv4" ]; then
    query_param="alpn=h3"
    if [ -n "$cert_pin" ]; then
        query_param="${query_param}&pinSHA256=${cert_pin}"
    else
        query_param="${query_param}&insecure=1"
    fi

    hy2_link_v4="hysteria2://${hy2_pass}@${ipv4}:${hy2_port}?${query_param}#Hy2-v4-Backup"
    echo "$hy2_link_v4" >> "$work_nodes"
    links_summary="${links_summary}\n   👉 IPv4 备用节点: ${hy2_link_v4}"

    if [ -f "$clash_file" ]; then
        cat >> "$clash_file" << EOT

  - name: "Hy2-v4-Backup"
    type: hysteria2
    server: ${ipv4}
    port: ${hy2_port}
    password: ${hy2_pass}
    alpn:
      - h3
    pinSHA256: ${cert_pin}
EOT
    fi
fi

if [ -n "$ipv6" ]; then
    query_param="alpn=h3"
    if [ -n "$cert_pin" ]; then
        query_param="${query_param}&pinSHA256=${cert_pin}"
    else
        query_param="${query_param}&insecure=1"
    fi

    hy2_link_v6="hysteria2://${hy2_pass}@[${ipv6}]:${hy2_port}?${query_param}#Hy2-v6-Backup"
    echo "$hy2_link_v6" >> "$work_nodes"
    links_summary="${links_summary}\n   👉 IPv6 备用节点: ${hy2_link_v6}"

    if [ -f "$clash_file" ]; then
        cat >> "$clash_file" << EOT

  - name: "Hy2-v6-Backup"
    type: hysteria2
    server: ${ipv6}
    port: ${hy2_port}
    password: ${hy2_pass}
    alpn:
      - h3
    pinSHA256: ${cert_pin}
EOT
    fi
fi

# 8. 重新生成 Base64 订阅并同步
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
echo "✅ Hysteria 2 备用节点部署成功！"
echo -e "📌 生成结果汇总:${links_summary}"
echo -e "🛡️ 防火墙放行端口 : ${YELLOW}$hy2_port (UDP)${NC}"
echo "=========================================================="
read -p "按回车键返回主菜单..." < /dev/tty
