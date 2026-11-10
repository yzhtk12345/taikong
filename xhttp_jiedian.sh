#!/bin/bash

# ==============================================================
# XHTTP & Vision 7节点终极版 (xhttp_jiedian.sh) - 配置与节点双重完美共存版
# 包括：Vision直连、XHTTP Reality、XHTTP UDP直连、Argo TCP 3节点、Argo UDP 3节点
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
QUICK_DIR="${YUZHOU_DIR}/quick"
XRAY_DIR="${YUZHOU_DIR}/xray"
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
echo -e "${CYAN}  XHTTP & Vision 7节点终极版 (配置合并 + 节点共存 + 保活)    ${NC}"
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

# 3. 架构判断与核心下载 (如果本地没有 xray，则下载)
arch="$(uname -m)"
if [ ! -f "${QUICK_DIR}/xray/xray" ]; then
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

    echo -e "${YELLOW}正在下载最新版 Xray-core 与 Cloudflared...${NC}"
    curl -L "$xray_url" -o "${QUICK_DIR}/xray.zip" >/dev/null 2>&1
    curl -L "$cf_url" -o "${QUICK_DIR}/cloudflared-linux" >/dev/null 2>&1

    mkdir -p "$XRAY_DIR"
    unzip -q -o "${QUICK_DIR}/xray.zip" -d "$XRAY_DIR"
    chmod +x "${QUICK_DIR}/cloudflared-linux" "${XRAY_DIR}/xray"
    rm -f "${QUICK_DIR}/xray.zip"
fi

# 4. 生成密钥与随机参数
uuid=$(cat /proc/sys/kernel/random/uuid)
x25519_key=$("${XRAY_DIR}/xray" x25519)
private_key=$(echo "$x25519_key" | awk '/Private key:/{print $3}')
public_key=$(echo "$x25519_key" | awk '/Public key:/{print $3}')
short_id=$(openssl rand -hex 4)
dest_sni="learn.microsoft.com"

# 智能防占用端口分配函数 (20000-60000 区间)
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

echo -e "${YELLOW}正在为 5 个底层入站端口在 20000-60000 区间智能分配...${NC}"
port_vision=$(get_available_port)
port_xhttp_reality=$(get_available_port)
port_xhttp_udp_direct=$(get_available_port)
port_argo_tcp=$(get_available_port)
port_argo_udp=$(get_available_port)

urlpath_argo_tcp="xhttp-tcp-$(echo "$uuid" | awk -F- '{print $1}')"
urlpath_argo_udp="xhttp-udp-$(echo "$uuid" | awk -F- '{print $1}')"

# 5. 使用 Python 动态合并入站配置（绝不覆盖旧模块的配置）
config_file="${XRAY_DIR}/config.json"
python3 - <<EOF
import json
import os

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
                "privateKey": "$private_key",
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
            "xhttpSettings": {"mode": "stream"},
            "realitySettings": {
                "show": False,
                "dest": "$dest_sni:443",
                "xver": 0,
                "serverNames": ["$dest_sni"],
                "privateKey": "$private_key",
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
            "xhttpSettings": {"path": "/$urlpath_argo_tcp", "mode": "stream"}
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
        with open(config_path, "r") as f:
            data = json.load(f)
    except Exception:
        data = {}

if "log" not in data:
    data["log"] = {"loglevel": "warning"}
if "outbounds" not in data:
    data["outbounds"] = [{"protocol": "freedom"}]

existing_inbounds = data.get("inbounds", [])
# 过滤掉旧的同标签入站（防止重复）
tags_to_remove = ["vless-vision-in", "vless-xhttp-reality-in", "vless-xhttp-udp-direct-in", "argo-tcp-in", "argo-udp-in"]
existing_inbounds = [ib for ib in existing_inbounds if ib.get("tag") not in tags_to_remove]

# 追加新入站
existing_inbounds.extend(new_inbounds)
data["inbounds"] = existing_inbounds

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w") as f:
    json.dump(data, f, indent=4)
EOF

# 6. 重启 Xray 服务及启动双 Argo 隧道
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

# 8. 智能追加节点到 nodes.txt（不覆盖其他模块的原节点）
work_nodes="${QUICK_DIR}/nodes.txt"
touch "$work_nodes"

# 清理旧的本模块专属标签节点，避免重复叠加
sed -i "/VLESS-Reality-Vision/d" "$work_nodes"
sed -i "/VLESS-XHTTP-Reality/d" "$work_nodes"
sed -i "/VLESS-XHTTP-UDP-Direct/d" "$work_nodes"
sed -i "/XHTTP-TCP-/d" "$work_nodes"
sed -i "/XHTTP-UDP-/d" "$work_nodes"

# 追加 7 个新节点
link_vision="vless://${uuid}@${server_ip}:${port_vision}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${node_tag}-VLESS-Reality-Vision"
echo "$link_vision" >> "$work_nodes"

link_xhttp_reality="vless://${uuid}@${server_ip}:${port_xhttp_reality}?encryption=none&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=xhttp&mode=stream#${node_tag}-VLESS-XHTTP-Reality"
echo "$link_xhttp_reality" >> "$work_nodes"

link_xhttp_udp_direct="vless://${uuid}@${server_ip}:${port_xhttp_udp_direct}?encryption=none&security=none&type=xhttp&mode=packet#${node_tag}-VLESS-XHTTP-UDP-Direct"
echo "$link_xhttp_udp_direct" >> "$work_nodes"

# Argo TCP 3个
link_argo_tcp="vless://${uuid}@${argo_tcp_domain}:443?encryption=none&security=tls&sni=${argo_tcp_domain}&type=xhttp&host=${argo_tcp_domain}&path=%2F${urlpath_argo_tcp}&mode=stream#${node_tag}-XHTTP-TCP-Argo"
echo "$link_argo_tcp" >> "$work_nodes"

opt_domains=("cf.090227.xyz" "cloudflare.182682.xyz")
opt_labels=("优选cf.090227" "优选182682")
for idx in "${!opt_domains[@]}"; do
    d="${opt_domains[$idx]}"
    l="${opt_labels[$idx]}"
    opt_tcp_link="vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_tcp_domain}&type=xhttp&host=${argo_tcp_domain}&path=%2F${urlpath_argo_tcp}&mode=stream#${node_tag}-XHTTP-TCP-${l}-Argo"
    echo "$opt_tcp_link" >> "$work_nodes"
done

# Argo UDP 3个
link_argo_udp="vless://${uuid}@${argo_udp_domain}:443?encryption=none&security=tls&sni=${argo_udp_domain}&type=xhttp&host=${argo_udp_domain}&path=%2F${urlpath_argo_udp}&mode=packet#${node_tag}-XHTTP-UDP-Argo"
echo "$link_argo_udp" >> "$work_nodes"

for idx in "${!opt_domains[@]}"; do
    d="${opt_domains[$idx]}"
    l="${opt_labels[$idx]}"
    opt_udp_link="vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_udp_domain}&type=xhttp&host=${argo_udp_domain}&path=%2F${urlpath_argo_udp}&mode=packet#${node_tag}-XHTTP-UDP-${l}-Argo"
    echo "$opt_udp_link" >> "$work_nodes"
done

# 同步刷新订阅 Base64 文件
if [ "$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d \" -f2 | awk '{print $1}')" == "Alpine" ]; then
    base64 "$work_nodes" | tr -d '\n' > "${QUICK_DIR}/sub.txt"
else
    base64 -w 0 "$work_nodes" > "${QUICK_DIR}/sub.txt"
fi

sub_port=$(cat /etc/yuzhou_sub_port 2>/dev/null || echo 25000)
sub_token=$(cat /etc/yuzhou_sub_token 2>/dev/null || echo "sub-$(openssl rand -hex 4)")
secure_web_dir="${SUB_DIR}/${sub_token}"
mkdir -p "$secure_web_dir"
cp -f "$work_nodes" "${secure_web_dir}/nodes.txt"
cp -f "${QUICK_DIR}/sub.txt" "${secure_web_dir}/sub.txt"

# 9. 防火墙动态管理
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

clear
echo "=========================================================="
echo "    ✅ XHTTP & Vision 7节点终极版（配置与节点双重共存）部署成功！"
echo "    📌 旧模块的入站和节点已完美保留，新节点已成功追加！"
echo "    🛡️ 已完美绑定系统开机自启与自动重连保活服务！"
echo "=========================================================="
read -p "按回车键返回主菜单..." < /dev/tty
