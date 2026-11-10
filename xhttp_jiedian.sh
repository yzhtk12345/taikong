#!/bin/bash

# ==============================================================
# XHTTP & Vision 5协议大杀器部署模块 (xhttp_jiedian.sh)
# 包括：Vision直连、XHTTP Reality、XHTTP UDP直连、XHTTP TCP Argo、XHTTP UDP Argo
# 已完美集成：20000-60000 高位随机端口、智能防占用检测、防火墙放行、开机自启恢复与动态订阅同步
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
echo -e "${CYAN}      XHTTP & Vision 5 节点部署模块 (智能防端口占用版)        ${NC}"
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

# 3. 精确清理旧的进程
pkill -f "${QUICK_DIR}/xray/xray" >/dev/null 2>&1
pkill -f "cloudflared-linux" >/dev/null 2>&1

cd "$QUICK_DIR" || exit
rm -rf xray cloudflared-linux xray.zip

# 4. 架构判断与核心下载 (保证拉取最新 Xray 支持 XHTTP)
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

echo -e "${YELLOW}正在下载最新版 Xray-core 与 Cloudflared...${NC}"
curl -L "$xray_url" -o xray.zip >/dev/null 2>&1
curl -L "$cf_url" -o cloudflared-linux >/dev/null 2>&1

mkdir -p xray
unzip -q -o xray.zip -d xray
chmod +x cloudflared-linux xray/xray
rm -f xray.zip

# 5. 生成密钥与随机参数
uuid=$(cat /proc/sys/kernel/random/uuid)
x25519_key=$("${QUICK_DIR}/xray/xray" x25519)
private_key=$(echo "$x25519_key" | awk '/Private key:/{print $3}')
public_key=$(echo "$x25519_key" | awk '/Public key:/{print $3}')
short_id=$(openssl rand -hex 4)
dest_sni="learn.microsoft.com"

# 智能端口分配函数（在 20000-60000 之间随机挑选，自动检测系统占用，若占用则循环换一个）
get_available_port() {
    local candidate_port
    while true; do
        if command -v python3 &>/dev/null; then
            candidate_port=$(python3 -c "import random; print(random.randint(20000, 60000))" 2>/dev/null)
        else
            candidate_port=$((RANDOM % 40001 + 20000))
        fi
        
        # 检查是否被占用（兼顾 ss, netstat）
        if ! (ss -tuln 2>/dev/null | grep -q ":$candidate_port " || netstat -tuln 2>/dev/null | grep -q ":$candidate_port "); then
            echo "$candidate_port"
            return 0
        fi
    done
}

echo -e "${YELLOW}正在为 5 个节点在 20000-60000 区间智能分配可用端口...${NC}"
port_vision=$(get_available_port)
port_xhttp_reality=$(get_available_port)
port_xhttp_udp_direct=$(get_available_port)
port_argo_tcp=$(get_available_port)
port_argo_udp=$(get_available_port)

urlpath_argo_tcp="xhttp-tcp-$(echo "$uuid" | awk -F- '{print $1}')"
urlpath_argo_udp="xhttp-udp-$(echo "$uuid" | awk -F- '{print $1}')"

# 6. 生成安全的 config.json (包含 5 大节点)
cat > xray/config.json <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "tag": "vless-vision-in",
            "port": $port_vision,
            "listen": "0.0.0.0",
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "$uuid", "flow": "xtls-rprx-vision" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
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
                "clients": [{ "id": "$uuid" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "xhttpSettings": { "mode": "stream" },
                "realitySettings": {
                    "show": false,
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
                "clients": [{ "id": "$uuid" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "none",
                "xhttpSettings": { "mode": "packet" }
            }
        },
        {
            "tag": "argo-tcp-in",
            "port": $port_argo_tcp,
            "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "$uuid" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": { "path": "/$urlpath_argo_tcp", "mode": "stream" }
            }
        },
        {
            "tag": "argo-udp-in",
            "port": $port_argo_udp,
            "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "$uuid" }],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": { "path": "/$urlpath_argo_udp", "mode": "packet" }
            }
        }
    ],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 7. 启动 Xray 服务及双 Argo 隧道
"${QUICK_DIR}/xray/xray" run -config "${QUICK_DIR}/xray/config.json" >/dev/null 2>&1 &
echo $! > "${QUICK_DIR}/xray.pid"

"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_argo_tcp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_tcp.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_tcp.pid"

"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_argo_udp --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_udp.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_udp.pid"

sleep 2

# 8. 等待并提取 Argo 临时域名
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

# 9. 组装 5 大节点链接
> nodes.txt

# 节点 1: VLESS Reality Vision (直连王牌)
link_vision="vless://${uuid}@${server_ip}:${port_vision}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${node_tag}-VLESS-Reality-Vision"
echo "$link_vision" >> nodes.txt

# 节点 2: VLESS XHTTP Reality (高并发免域名)
link_xhttp_reality="vless://${uuid}@${server_ip}:${port_xhttp_reality}?encryption=none&security=reality&sni=${dest_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=xhttp&mode=stream#${node_tag}-VLESS-XHTTP-Reality"
echo "$link_xhttp_reality" >> nodes.txt

# 节点 3: VLESS XHTTP UDP (直连 UDP 优化)
link_xhttp_udp_direct="vless://${uuid}@${server_ip}:${port_xhttp_udp_direct}?encryption=none&security=none&type=xhttp&mode=packet#${node_tag}-VLESS-XHTTP-UDP-Direct"
echo "$link_xhttp_udp_direct" >> nodes.txt

# 节点 4: VLESS XHTTP TCP Argo (隧道标准版)
link_argo_tcp="vless://${uuid}@${argo_tcp_domain}:443?encryption=none&security=tls&sni=${argo_tcp_domain}&type=xhttp&host=${argo_tcp_domain}&path=%2F${urlpath_argo_tcp}&mode=stream#${node_tag}-VLESS-XHTTP-TCP-Argo"
echo "$link_argo_tcp" >> nodes.txt

# 节点 5: VLESS XHTTP UDP Argo (隧道 UDP 增强版)
link_argo_udp="vless://${uuid}@${argo_udp_domain}:443?encryption=none&security=tls&sni=${argo_udp_domain}&type=xhttp&host=${argo_udp_domain}&path=%2F${urlpath_argo_udp}&mode=packet#${node_tag}-VLESS-XHTTP-UDP-Argo"
echo "$link_argo_udp" >> nodes.txt

# 写入订阅文件
if [ "$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d \" -f2 | awk '{print $1}')" == "Alpine" ]; then
    base64 nodes.txt | tr -d '\n' > sub.txt
else
    base64 -w 0 nodes.txt > sub.txt
fi

sub_port=$(cat /etc/yuzhou_sub_port 2>/dev/null || echo 25000)
sub_token=$(cat /etc/yuzhou_sub_token 2>/dev/null || echo "sub-$(openssl rand -hex 4)")
secure_web_dir="${SUB_DIR}/${sub_token}"
mkdir -p "$secure_web_dir"
cp -f nodes.txt "${secure_web_dir}/nodes.txt"
cp -f sub.txt "${secure_web_dir}/sub.txt"

# 10. 防火墙动态管理
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
echo "    ✅ XHTTP & Vision 5大黄金节点部署成功（高位随机端口）"
echo "=========================================================="
echo -e "${GREEN}1. VLESS-Reality-Vision (端口 ${port_vision}):${NC}\n${link_vision}\n"
echo -e "${GREEN}2. VLESS-XHTTP-Reality (端口 ${port_xhttp_reality}):${NC}\n${link_xhttp_reality}\n"
echo -e "${GREEN}3. VLESS-XHTTP-UDP (端口 ${port_xhttp_udp_direct}):${NC}\n${link_xhttp_udp_direct}\n"
echo -e "${GREEN}4. VLESS-XHTTP-TCP-Argo (隧道):${NC}\n${link_argo_tcp}\n"
echo -e "${GREEN}5. VLESS-XHTTP-UDP-Argo (隧道):${NC}\n${link_argo_udp}\n"
echo "=========================================================="
read -p "按回车键返回主菜单..." < /dev/tty
