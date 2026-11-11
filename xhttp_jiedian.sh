#!/bin/bash

# ==============================================================
# XHTTP & Vision 7节点精准追加更新模块 (xhttp_jiedian.sh)
# 【跳过核心安装检测，纯精准注入，完美兼容现有 Argo/Hy2环境】
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
QUICK_DIR="${YUZHOU_DIR}/quick"
XRAY_DIR="${QUICK_DIR}/xray"
SUB_DIR="/var/www/suoha_sub"
LAST_PORTS_FILE="${YUZHOU_DIR}/last_xhttp_ports.txt"

mkdir -p "$QUICK_DIR" "$XRAY_DIR" "$SUB_DIR"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

clear
echo -e "${CYAN}==============================================================${NC}"
echo -e "${CYAN}     XHTTP & Vision 节点精准追加模块 (跳过核心重复安装)       ${NC}"
echo -e "${CYAN}==============================================================${NC}"

# 0. 自动检查基础运行依赖（仅保留 python3 / openssl）
for pkg in openssl python3; do
    if ! command -v $pkg &>/dev/null; then
        echo -e "${YELLOW}检测到系统未安装 $pkg，正在自动安装...${NC}"
        if [ -f /etc/debian_version ]; then
            apt-get update >/dev/null 2>&1 && apt-get install -y $pkg >/dev/null 2>&1
        elif [ -f /etc/redhat-release ] || grep -qi "rhel" /etc/os-release || grep -qi "centos" /etc/os-release; then
            yum install -y $pkg >/dev/null 2>&1 || dnf install -y $pkg >/dev/null 2>&1
        elif grep -qi "alpine" /etc/os-release 2>/dev/null; then
            apk add --no-cache $pkg >/dev/null 2>&1
        fi
    fi
done

# 自动寻找本地已有的 xray 核心路径
xray_bin=""
if [ -f "${XRAY_DIR}/xray" ]; then
    xray_bin="${XRAY_DIR}/xray"
elif [ -f "${QUICK_DIR}/xray/xray" ]; then
    xray_bin="${QUICK_DIR}/xray/xray"
elif command -v xray &>/dev/null; then
    xray_bin="xray"
else
    echo -e "${RED}[错误] 未在系统中找到 xray 可执行文件，请先完整安装一次基础环境！${NC}"
    exit 1
fi

# 1. 选择 Argo 连接模式 IPv4 或 IPv6
read -p "请选择 argo 连接模式 IPV4 或者 IPV6 (输入 4 或 6，默认 4): " ips < /dev/tty
[ -z "$ips" ] && ips=4

if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then
    echo -e "${RED}请输入正确的 argo 连接模式${NC}"
    exit 1
fi

# 2. 获取 ISP 信息与 IP
isp=$(curl -$ips -s --connect-timeout 2 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')
[ -z "$isp" ] && isp="Unknown_ISP"

server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[ -z "$server_ip" ] && server_ip=$(curl -s4 --connect-timeout 2 https://api.ip.sb/ip 2>/dev/null)

echo -e "${GREEN}[+] 网络模式: IPv${ips} | ISP: ${isp} | 公网IP: ${server_ip}${NC}"

# 3. 智能分配端口
get_available_port() {
    local candidate_port
    while true; do
        if command -v python3 &>/dev/null; then
            candidate_port=$(python3 -c "import random; print(random.randint(20000, 60000))" 2>/dev/null)
        else
            candidate_port=$((RANDOM % 40001 + 20000))
        fi
        if ! (ss -tuln 2>/dev/null | grep -q ":$candidate_port " || netstat -tuln 2>/dev/null | grep -q ":$candidate_port "); then
            echo "$candidate_port"
            return 0
        fi
    done
}

port_vision=$(get_available_port)
port_xhttp_reality=$(get_available_port)
port_xhttp_udp_direct=$(get_available_port)
port_argo_tcp=$(get_available_port)
port_argo_udp=$(get_available_port)

uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath_argo_tcp="xhttp-tcp-$(echo "$uuid" | awk -F- '{print $1}')"
urlpath_argo_udp="xhttp-udp-$(echo "$uuid" | awk -F- '{print $1}')"
dest_sni="learn.microsoft.com"
short_id=$(openssl rand -hex 4)

# 4. 参考 Hy2 逻辑：精准注入 config.json（清理旧 xhttp/vision 标签，保留其他所有协议）
config_file="${XRAY_DIR}/config.json"
[ ! -f "$config_file" ] && config_file="${QUICK_DIR}/xray/config.json"

python3 - <<EOF
import json
import os
import subprocess

xray_bin = "$xray_bin"
res = subprocess.run([xray_bin, "x25519"], capture_output=True, text=True)
output = res.stdout + res.stderr

priv = ""
for line in output.splitlines():
    if "Private key" in line or "PrivateKey" in line:
        priv = line.split(":")[-1].strip()

if not priv:
    for line in output.splitlines():
        if ":" in line and len(line.strip()) > 30:
            priv = line.split(":")[-1].strip()

config_path = "$config_file"
data = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}

if "log" not in data:
    data["log"] = {"loglevel": "warning"}
if "outbounds" not in data:
    data["outbounds"] = [{"protocol": "freedom"}]

# 精准剥离旧的 xhttp/vision 标签，完美保留 ws, trojan, hy2, ss 等其他入站
existing_inbounds = data.get("inbounds", [])
tags_to_remove = ["vless-vision-in", "vless-xhttp-reality-in", "vless-xhttp-udp-direct-in", "argo-tcp-in", "argo-udp-in"]
existing_inbounds = [ib for ib in existing_inbounds if ib.get("tag") not in tags_to_remove]

new_inbounds = [
    {
        "tag": "vless-vision-in",
        "port": $port_vision,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": "$dest_sni:443",
                "xver": 0,
                "serverNames": ["$dest_sni"],
                "privateKey": priv,
                "shortIds": ["$short_id"]
            }
        }
    },
    {
        "tag": "vless-xhttp-reality-in",
        "port": $port_xhttp_reality,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "xhttpSettings": {},
            "realitySettings": {
                "show": False,
                "dest": "$dest_sni:443",
                "xver": 0,
                "serverNames": ["$dest_sni"],
                "privateKey": priv,
                "shortIds": ["$short_id"]
            }
        }
    },
    {
        "tag": "vless-xhttp-udp-direct-in",
        "port": $port_xhttp_udp_direct,
        "listen": "0.0.0.0",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {}
        }
    },
    {
        "tag": "argo-tcp-in",
        "port": $port_argo_tcp,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "xhttpSettings": {
                "path": "/$urlpath_argo_tcp"
            }
        }
    },
    {
        "tag": "argo-udp-in",
        "port": $port_argo_udp,
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "xhttpSettings": {
                "path": "/$urlpath_argo_udp"
            }
        }
    }
]

existing_inbounds.extend(new_inbounds)
data["inbounds"] = existing_inbounds

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
EOF

# 5. 重启后台进程并拉起 cloudflared 隧道
if [ -f "${QUICK_DIR}/xray.pid" ]; then
    kill -9 $(cat "${QUICK_DIR}/xray.pid") >/dev/null 2>&1
    rm -f "${QUICK_DIR}/xray.pid"
fi
pkill -f "$xray_bin" >/dev/null 2>&1
pkill -f "cloudflared-linux" >/dev/null 2>&1

"$xray_bin" run -config "$config_file" >/dev/null 2>&1 &
echo $! > "${QUICK_DIR}/xray.pid"

cf_bin=$(command -v cloudflared || echo "${QUICK_DIR}/cloudflared-linux")
"$cf_bin" tunnel --url http://127.0.0.1:$port_argo_tcp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_tcp.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_tcp.pid"

"$cf_bin" tunnel --url http://127.0.0.1:$port_argo_udp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_udp.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_udp.pid"

sleep 2

# 6. 抓取临时域名
n=0
while true; do
    n=$[$n+1]
    clear
    echo "正在等待 Cloudflare 建立双 Argo 隧道，已等待 $n 秒..."
    argo_tcp_domain=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_tcp.log | head -n 1 | awk -F// '{print $2}')
    argo_udp_domain=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_udp.log | head -n 1 | awk -F// '{print $2}')

    if [ $n -eq 25 ]; then
        n=0
        kill -9 $(cat "${QUICK_DIR}/cf_tcp.pid") >/dev/null 2>&1
        kill -9 $(cat "${QUICK_DIR}/cf_udp.pid") >/dev/null 2>&1
        rm -rf argo_tcp.log argo_udp.log
        "$cf_bin" tunnel --url http://127.0.0.1:$port_argo_tcp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_tcp.log 2>&1 &
        echo $! > "${QUICK_DIR}/cf_tcp.pid"
        "$cf_bin" tunnel --url http://127.0.0.1:$port_argo_udp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_udp.log 2>&1 &
        echo $! > "${QUICK_DIR}/cf_udp.pid"
        sleep 2
    elif [[ -n "$argo_tcp_domain" && -n "$argo_udp_domain" ]]; then
        rm -rf argo_tcp.log argo_udp.log
        break
    else
        sleep 1
    fi
done

node_tag=$(echo "$isp" | sed -e 's/_/%20/g' -e 's/,/%2C/g')
[ -z "$node_tag" ] && node_tag="XHTTP_Node"

work_nodes="${QUICK_DIR}/nodes.txt"
touch "$work_nodes"

sed -i "/VLESS-Reality-Vision/d" "$work_nodes"
sed -i "/VLESS-XHTTP-Reality/d" "$work_nodes"
sed -i "/VLESS-XHTTP-UDP-Direct/d" "$work_nodes"
sed -i "/XHTTP-TCP-/d" "$work_nodes"
sed -i "/XHTTP-UDP-/d" "$work_nodes"

public_key=$("$xray_bin" x25519 -i "$(python3 -c "import json; data=json.load(open('$config_file')); print([ib for ib in data['inbounds'] if ib['tag']=='vless-vision-in'][0]['streamSettings']['realitySettings']['privateKey'])")" 2>/dev/null | grep "Public key" | awk '{print $3}')

echo "vless://${uuid}@${server_ip}:${port_vision}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${node_tag}-VLESS-Reality-Vision" >> "$work_nodes"
echo "vless://${uuid}@${server_ip}:${port_xhttp_reality}?encryption=none&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=xhttp#${node_tag}-VLESS-XHTTP-Reality" >> "$work_nodes"
echo "vless://${uuid}@${server_ip}:${port_xhttp_udp_direct}?encryption=none&security=none&type=xhttp#${node_tag}-VLESS-XHTTP-UDP-Direct" >> "$work_nodes"

echo "vless://${uuid}@${argo_tcp_domain}:443?encryption=none&security=tls&sni=${argo_tcp_domain}&type=xhttp&host=${argo_tcp_domain}&path=%2F${urlpath_argo_tcp}#${node_tag}-XHTTP-TCP-Argo" >> "$work_nodes"
opt_domains=("cf.090227.xyz" "cloudflare.182682.xyz")
opt_labels=("优选cf.090227" "优选182682")
for idx in "${!opt_domains[@]}"; do
    d="${opt_domains[$idx]}"
    l="${opt_labels[$idx]}"
    echo "vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_tcp_domain}&type=xhttp&host=${argo_tcp_domain}&path=%2F${urlpath_argo_tcp}#${node_tag}-XHTTP-TCP-${l}-Argo" >> "$work_nodes"
done

echo "vless://${uuid}@${argo_udp_domain}:443?encryption=none&security=tls&sni=${argo_udp_domain}&type=xhttp&host=${argo_udp_domain}&path=%2F${urlpath_argo_udp}#${node_tag}-XHTTP-UDP-Argo" >> "$work_nodes"
for idx in "${!opt_domains[@]}"; do
    d="${opt_domains[$idx]}"
    l="${opt_labels[$idx]}"
    echo "vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_udp_domain}&type=xhttp&host=${argo_udp_domain}&path=%2F${urlpath_argo_udp}#${node_tag}-XHTTP-UDP-${l}-Argo" >> "$work_nodes"
done

# 7. 刷新 Base64 订阅并同步
if [ "$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d \" -f2 | awk '{print $1}')" == "Alpine" ]; then
    base64 "$work_nodes" | tr -d '\n' > "${QUICK_DIR}/sub.txt"
else
    base64 -w 0 "$work_nodes" > "${QUICK_DIR}/sub.txt"
fi

sub_token=$(cat /etc/yuzhou_sub_token 2>/dev/null || cat /etc/suoha_sub_token 2>/dev/null)
if [ -n "$sub_token" ]; then
    secure_web_dir="${SUB_DIR}/${sub_token}"
    mkdir -p "$secure_web_dir"
    cp -f "$work_nodes" "${secure_web_dir}/nodes.txt"
    cp -f "${QUICK_DIR}/sub.txt" "${secure_web_dir}/sub.txt"
fi

# 8. 防火墙端口放行
if command -v ufw &>/dev/null && systemctl is-active --quiet ufw 2>/dev/null; then
    ufw allow "$port_vision"/tcp >/dev/null 2>&1
    ufw allow "$port_xhttp_reality"/tcp >/dev/null 2>&1
    ufw allow "$port_xhttp_udp_direct"/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="$port_vision"/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$port_xhttp_reality"/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$port_xhttp_udp_direct"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

echo -e "$port_vision\n$port_xhttp_reality\n$port_xhttp_udp_direct" > "$LAST_PORTS_FILE"

clear
echo "=========================================================="
echo "    ✅ XHTTP & Vision 7节点精准追加更新完成！"
echo "    📌 未重复下载核心，完美继承现有 Argo/Hy2/WS 环境！"
echo "=========================================================="
read -p "按回车键返回主菜单..." < /dev/tty
