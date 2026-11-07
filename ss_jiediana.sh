#!/bin/bash

# ==============================================================
# 额外增加 IPv6 SS 共存部署模块 (ss_jiedian.sh)
# 已集成：重启后自动恢复、防火墙放行、自动同步订阅
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
NODES_DIR="${YUZHOU_DIR}/nodes"
LAST_SS_PORT_FILE="${YUZHOU_DIR}/last_ss_port.txt"

mkdir -p "$NODES_DIR"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

clear
echo -e "${CYAN}==============================================================${NC}"
echo -e "${CYAN}          IPv6 Shadowsocks 直连节点部署模块 (自动保活版)      ${NC}"
echo -e "${CYAN}==============================================================${NC}"

# 获取服务器 IPv6 地址函数
get_server_ipv6() {
    local ip6=""
    ip6=$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null | tr -d '\n\r ')
    if [ -z "$ip6" ]; then
        ip6=$(curl -s6 --connect-timeout 3 https://ipv6.icanhazip.com 2>/dev/null | tr -d '\n\r ')
    fi
    if [ -z "$ip6" ]; then
        ip6=$(curl -s6 --connect-timeout 3 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26}' | grep ":" | tr -d '\n\r ')
    fi
    if [ -z "$ip6" ]; then
        ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n 1 | tr -d '\n\r ')
    fi
    echo "$ip6"
}

echo -e "${YELLOW}正在检测机器公网 IPv6 地址...${NC}"
ipv6_addr=$(get_server_ipv6)

if [ -z "$ipv6_addr" ]; then
    echo -e "${RED}未检测到可用的公网 IPv6 地址，无法部署 IPv6 直连 SS 节点！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

echo -e "${GREEN}检测到公网 IPv6: $ipv6_addr${NC}"

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
    echo -e "${RED}未检测到正在运行的 Xray 服务，请先执行主菜单【梭哈模式】或【安装服务】！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

ss_port=$[$RANDOM%10000+30000]
ss_password=$(cat /proc/sys/kernel/random/uuid | awk -F- '{print $1$2}')
ss_method="aes-128-gcm"

echo -e "${YELLOW}正在注入 IPv6 Shadowsocks 节点 (端口: $ss_port, 加密: $ss_method)...${NC}"

# 使用 Python 安全操作 JSON 注入入站配置[cite: 3]
python3 -c "
import json, sys
cfg_file = '$cfg_json'
try:
    with open(cfg_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    data['inbounds'] = [ib for ib in data.get('inbounds', []) if ib.get('tag') != 'ss-ipv6']
    ss_ib = {
        'tag': 'ss-ipv6',
        'port': int('$ss_port'),
        'listen': '::',
        'protocol': 'shadowsocks',
        'settings': {
            'method': '$ss_method',
            'password': '$ss_password',
            'network': 'tcp,udp'
        }
    }
    data['inbounds'].append(ss_ib)
    with open(cfg_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
except Exception as e:
    sys.exit(1)
"
if [ $? -ne 0 ]; then
    echo -e "${RED}注入 Xray 配置失败，请检查 python3 环境！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

# 保存持久化配置供开机自启恢复使用
cat > "${YUZHOU_DIR}/ss_config.env" <<EOF
SS_PORT="$ss_port"
SS_PASS="$ss_password"
SS_METHOD="$ss_method"
EOF

# 自动将 ss 恢复逻辑注入到开机自启订阅更新脚本中
AUTO_UPDATE_SCRIPT="/etc/yuzhou/auto_argo_update.sh"
if [ -f "$AUTO_UPDATE_SCRIPT" ] && ! grep -q "ss_config.env" "$AUTO_UPDATE_SCRIPT"; then
    python3 -c "
with open('$AUTO_UPDATE_SCRIPT', 'r', encoding='utf-8') as f:
    content = f.read()
ss_code = '''
# === Auto-injected Shadowsocks recovery ===
if [ -f \\"/etc/yuzhou/ss_config.env\\" ]; then
    source /etc/yuzhou/ss_config.env
    s_v6=\\$(ip -6 addr show scope global | grep inet6 | awk '{print \\\$2}' | cut -d/ -f1 | head -n 1 | tr -d '\n\r ')
    [ -z \"\\$s_v6\" ] && s_v6=\\$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null | tr -d '\n\r ')
    if [ -n \"\\$s_v6\" ]; then
        ss_info=\"\\${SS_METHOD}:\\${SS_PASS}\"
        ss_b64=\\$(echo -n \"\\$ss_info\" | base64 -w 0 2>/dev/null || echo -n \"\\$ss_info\" | base64 | tr -d '\n')
        echo \"ss://\\${ss_b64}@[\\$s_v6]:\\${SS_PORT}#IPv6-SS-Direct\" >> nodes.txt
    fi
fi
'''
target = 'cat >> clash.yaml <<\\x27EOF_CLASH\\x27\nproxy-groups:'
if target in content:
    content = content.replace(target, ss_code + '\n' + target)
    with open('$AUTO_UPDATE_SCRIPT', 'w', encoding='utf-8') as f:
        f.write(content)
" 2>/dev/null || true
fi

# 重启 Xray 进程
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
    nohup $xray_bin run -config $cfg_json >/dev/null 2>&1 &
    echo $! > "${xray_dir}/xray.pid"
fi

# ==============================================================
# 防火墙端口管理
# ==============================================================
echo -e "\n${CYAN}正在检查并更新防火墙端口规则...${NC}"

ssh_port=$(ss -tlnp | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
[ -z "$ssh_port" ] && ssh_port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
[ -z "$ssh_port" ] && ssh_port=22

if command -v ufw &>/dev/null && systemctl is-active --quiet ufw 2>/dev/null; then
    if [ -f "$LAST_SS_PORT_FILE" ]; then
        old_ss_port=$(cat "$LAST_SS_PORT_FILE")
        if [ -n "$old_ss_port" ] && [ "$old_ss_port" != "$ssh_port" ]; then
            ufw delete allow "$old_ss_port"/tcp >/dev/null 2>&1
            ufw delete allow "$old_ss_port"/udp >/dev/null 2>&1
        fi
    fi
    ufw allow "$ss_port"/tcp comment 'Yuzhou SS IPv6 TCP' >/dev/null 2>&1
    ufw allow "$ss_port"/udp comment 'Yuzhou SS IPv6 UDP' >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    if [ -f "$LAST_SS_PORT_FILE" ]; then
        old_ss_port=$(cat "$LAST_SS_PORT_FILE")
        if [ -n "$old_ss_port" ] && [ "$old_ss_port" != "$ssh_port" ]; then
            firewall-cmd --permanent --remove-port="$old_ss_port"/tcp >/dev/null 2>&1
            firewall-cmd --permanent --remove-port="$old_ss_port"/udp >/dev/null 2>&1
        fi
    fi
    firewall-cmd --permanent --add-port="$ss_port"/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$ss_port"/udp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

echo "$ss_port" > "$LAST_SS_PORT_FILE"

# 组装节点信息并写入 nodes.txt
ss_user_info="${ss_method}:${ss_password}"
if [ "$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d \" -f2 | awk '{print $1}')" == "Alpine" ]; then
    ss_base64=$(echo -n "$ss_user_info" | base64 | tr -d '\n')
else
    ss_base64=$(echo -n "$ss_user_info" | base64 -w 0)
fi
ss_link="ss://${ss_base64}@[${ipv6_addr}]:${ss_port}#IPv6-SS-Direct"

work_nodes="${xray_dir}/nodes.txt"
touch "$work_nodes"
sed -i '/IPv6-SS-Direct/d' "$work_nodes"
echo "$ss_link" >> "$work_nodes"

# 生成 Base64 订阅并同步[cite: 3]
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
        cp -f "${xray_dir}/nodes.txt" "${secure_web_dir}/nodes.txt" 2>/dev/null
    fi
fi

clear
echo "=========================================================="
echo "    IPv6 Shadowsocks 直连节点部署成功并已绑定开机自启！     "
echo "=========================================================="
echo -e " 📌 SS 直连节点链接: \n${GREEN}$ss_link${NC}"
echo -e " 🛡️ 防火墙放行端口 : ${YELLOW}$ss_port (TCP/UDP)${NC}"
echo "=========================================================="
read -p "按回车键返回主菜单..." < /dev/tty
