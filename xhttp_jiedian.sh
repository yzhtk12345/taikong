#!/bin/bash

# ==============================================================
# XHTTP & Vision 7节点终极版 (xhttp_jiedian.sh) 
# 【终极完美无错版】路径统一、密钥驼峰解析、剔除不兼容 XHTTP mode
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
echo -e "${CYAN}   XHTTP & Vision 7节点部署模块 (全协议共存终极无错版)     ${NC}"
echo -e "${CYAN}==============================================================${NC}"

# 0. 自动检查并安装基础依赖包
for pkg in unzip curl openssl python3; do
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

# 3. 更新 Xray-core 至最新官方二进制
arch="$(uname -m)"
case "$arch" in
    x86_64 | x64 | amd64 )
        xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        ;;
    armv8 | arm64 | aarch64 )
        xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
        cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
        ;;
    * )
        echo -e "${RED}当前架构 $arch 暂未直接适配${NC}"
        exit 1
        ;;
esac

echo -e "${YELLOW}正在检查并更新 ${XRAY_DIR} 下的最新 Xray-core 及 Cloudflared 核心...${NC}"
cd "$QUICK_DIR" || exit
curl -L "$xray_url" -o xray.zip >/dev/null 2>&1
curl -L "$cf_url" -o cloudflared-linux >/dev/null 2>&1

mkdir -p "$XRAY_DIR"
unzip -q -o xray.zip -d "$XRAY_DIR"
chmod +x cloudflared-linux "${XRAY_DIR}/xray"
rm -f xray.zip

# 4. 智能防占用端口分配函数 (20000-60000 区间)
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

echo -e "${YELLOW}正在为 5 个 XHTTP 底层入站在 20000-60000 区间智能分配空闲端口...${NC}"
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

# 5. 使用 Python 现场生成密钥并动态合并 config.json（已解决驼峰关键字抓取与 stream 模式不兼容问题）
config_file="${XRAY_DIR}/config.json"
python3 - <<EOF
import json
import os
import subprocess

xray_bin = "${XRAY_DIR}/xray"
res = subprocess.run([xray_bin, "x25519"], capture_output=True, text=True)
output = res.stdout + res.stderr

priv, pub = "", ""
for line in output.splitlines():
    if "PrivateKey" in line:
        priv = line.split(":")[-1].strip()
    elif "PublicKey" in line or "Password (PublicKey)" in line:
        pub = line.split(":")[-1].strip()

print(f"自动生成 PrivateKey: {priv}")
print(f"自动生成 PublicKey: {pub}")

if not priv:
    raise Exception("严重错误：Xray 自动生成私钥失败！")

config_path = "$config_file"
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
            "xhttpSettings": {"mode": "packet"}
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
            "xhttpSettings": {"path": "/$urlpath_argo_tcp"}
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
            "xhttpSettings": {"path": "/$urlpath_argo_udp", "mode": "packet"}
        }
    }
]

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

existing_inbounds = data.get("inbounds", [])
tags_to_remove = ["vless-vision-in", "vless-xhttp-reality-in", "vless-xhttp-udp-direct-in", "argo-tcp-in", "argo-udp-in"]
existing_inbounds = [ib for ib in existing_inbounds if ib.get("tag") not in tags_to_remove]

existing_inbounds.extend(new_inbounds)
data["inbounds"] = existing_inbounds

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
EOF

# 6. 精确杀死旧后台进程，并在正确路径重启 Xray 核心及 Cloudflared 隧道
if [ -f "${QUICK_DIR}/xray.pid" ]; then
    kill -9 $(cat "${QUICK_DIR}/xray.pid") >/dev/null 2>&1
    rm -f "${QUICK_DIR}/xray.pid"
fi
pkill -f "${XRAY_DIR}/xray" >/dev/null 2>&1
pkill -f "cloudflared-linux" >/dev/null 2>&1

"${XRAY_DIR}/xray" run -config "$config_file" >/dev/null 2>&1 &
echo $! > "${QUICK_DIR}/xray.pid"

"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_argo_tcp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_tcp.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_tcp.pid"

"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_argo_udp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_udp.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_udp.pid"

sleep 2

# 7. 等待并提取 Argo 临时域名
n=0
while true; do
    n=$[$n+1]
    clear
    echo "正在等待 Cloudflare 建立 XHTTP 双 Argo 隧道，已等待 $n 秒..."
    argo_tcp_domain=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_tcp.log | head -n 1 | awk -F// '{print $2}')
    argo_udp_domain=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_udp.log | head -n 1 | awk -F// '{print $2}')

    if [ $n -eq 25 ]; then
        n=0
        kill -9 $(cat "${QUICK_DIR}/cf_tcp.pid") >/dev/null 2>&1
        kill -9 $(cat "${QUICK_DIR}/cf_udp.pid") >/dev/null 2>&1
        rm -rf argo_tcp.log argo_udp.log
        "${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_argo_tcp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_tcp.log 2>&1 &
        echo $! > "${QUICK_DIR}/cf_tcp.pid"
        "${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_argo_udp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_udp.log 2>&1 &
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

# 8. 智能追加 7 个 XHTTP/Vision 节点至 /etc/yuzhou/quick/nodes.txt (不覆盖旧节点)
work_nodes="${QUICK_DIR}/nodes.txt"
touch "$work_nodes"

sed -i "/VLESS-Reality-Vision/d" "$work_nodes"
sed -i "/VLESS-XHTTP-Reality/d" "$work_nodes"
sed -i "/VLESS-XHTTP-UDP-Direct/d" "$work_nodes"
sed -i "/XHTTP-TCP-/d" "$work_nodes"
sed -i "/XHTTP-UDP-/d" "$work_nodes"

# 获取真实的 PublicKey 用于直连 Reality 链接
public_key=$(python3 -c "
import json
data = json.load(open('$config_file'))
priv = [ib for ib in data['inbounds'] if ib['tag']=='vless-vision-in'][0]['streamSettings']['realitySettings']['privateKey']
import subprocess
res = subprocess.run(['${XRAY_DIR}/xray', 'x25519', '-i', priv], capture_output=True, text=True)
for line in (res.stdout + res.stderr).splitlines():
    if 'PublicKey' in line or 'Password (PublicKey)' in line:
        print(line.split(':')[-1].strip())
        break
")

echo "vless://${uuid}@${server_ip}:${port_vision}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${node_tag}-VLESS-Reality-Vision" >> "$work_nodes"
echo "vless://${uuid}@${server_ip}:${port_xhttp_reality}?encryption=none&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=x&#${node_tag}-VLESS-XHTTP-Reality" >> "$work_nodes"
echo "vless://${uuid}@${server_ip}:${port_xhttp_udp_direct}?encryption=none&security=none&type=xhttp&mode=packet#${node_tag}-VLESS-XHTTP-UDP-Direct" >> "$work_nodes"

echo "vless://${uuid}@${argo_tcp_domain}:443?encryption=none&security=tls&sni=${argo_tcp_domain}&type=xhttp&host=${argo_tcp_domain}&path=%2F${urlpath_argo_tcp}#${node_tag}-XHTTP-TCP-Argo" >> "$work_nodes"
opt_domains=("cf.090227.xyz" "cloudflare.182682.xyz")
opt_labels=("优选cf.090227" "优选182682")
for idx in "${!opt_domains[@]}"; do
    d="${opt_domains[$idx]}"
    l="${opt_labels[$idx]}"
    echo "vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_tcp_domain}&type=xhttp&host=${argo_tcp_domain}&path=%2F${urlpath_argo_tcp}#${node_tag}-XHTTP-TCP-${l}-Argo" >> "$work_nodes"
done

echo "vless://${uuid}@${argo_udp_domain}:443?encryption=none&security=tls&sni=${argo_udp_domain}&type=xhttp&host=${argo_udp_domain}&path=%2F${urlpath_argo_udp}&mode=packet#${node_tag}-XHTTP-UDP-Argo" >> "$work_nodes"
for idx in "${!opt_domains[@]}"; do
    d="${opt_domains[$idx]}"
    l="${opt_labels[$idx]}"
    echo "vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_udp_domain}&type=xhttp&host=${argo_udp_domain}&path=%2F${urlpath_argo_udp}&mode=packet#${node_tag}-XHTTP-UDP-${l}-Argo" >> "$work_nodes"
done

# 9. 重新刷新 Base64 订阅并同步给本地 HTTP 订阅服务
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

# 10. 防火墙动态放行直连端口
echo -e "\n${CYAN}更新防火墙放行端口...${NC}"
if command -v ufw &>/dev/null && systemctl is-active --quiet ufw 2>/dev/null; then
    ufw allow "$port_vision"/tcp comment 'Yuzhou Vision Port' >/dev/null 2>&1
    ufw allow "$port_xhttp_reality"/tcp comment 'Yuzhou XHTTP Reality Port' >/dev/null 2>&1
    ufw allow "$port_xhttp_udp_direct"/tcp comment 'Yuzhou XHTTP UDP Port' >/dev/null 2>&1
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
echo "    ✅ XHTTP & Vision 7大节点已成功合并写入全套系统！"
echo "    📌 Xray 核心运行完美，所有旧协议与新协议完美共存！"
echo "    🌐 请在客户端中刷新订阅，体验全协议共存节点！"
echo "=========================================================="
read -p "按回车键返回主菜单..." < /dev/tty
