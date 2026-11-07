#!/bin/bash

# ==============================================================
# 一键 Argo 6 节点与 Quicktunnel 部署模块 (argo_jiedian.sh)
# 已完美集成：重启后自动恢复、动态抓取新临时域名与订阅自动更新
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
QUICK_DIR="${YUZHOU_DIR}/quick"
XRAY_DIR="${YUZHOU_DIR}/xray"
NODES_DIR="${YUZHOU_DIR}/nodes"
SUB_DIR="/var/www/suoha_sub"
LAST_PORTS_FILE="${YUZHOU_DIR}/last_opened_ports.txt"

mkdir -p "$QUICK_DIR" "$XRAY_DIR" "$NODES_DIR" "$SUB_DIR"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

clear
echo -e "${CYAN}==============================================================${NC}"
echo -e "${CYAN}          一键 Argo 6节点部署与配置模块 (自动保活版)          ${NC}"
echo -e "${CYAN}==============================================================${NC}"

# 1. 选择 Argo 连接模式 IPv4 或 IPv6
read -p "请选择 argo 连接模式 IPV4 或者 IPV6 (输入 4 或 6，默认 4): " ips < /dev/tty
if [ -z "$ips" ]; then
    ips=4
fi

if [ "$ips" != "4" ] && [ "$ips" != "6" ]; then
    echo -e "${RED}请输入正确的 argo 连接模式${NC}"
    exit 1
fi

# 2. 获取 ISP 信息
isp=$(curl -$ips -s --connect-timeout 2 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')
[ -z "$isp" ] && isp="Unknown_ISP"
echo -e "${GREEN}[+] 已检测到网络模式: IPv${ips} | ISP: ${isp}${NC}"

# 3. 精确清理旧的后台快速模式进程
if [ -f "${QUICK_DIR}/xray.pid" ]; then
    kill -9 $(cat "${QUICK_DIR}/xray.pid") >/dev/null 2>&1
    rm -f "${QUICK_DIR}/xray.pid"
fi
if [ -f "${QUICK_DIR}/cf_vl.pid" ]; then
    kill -9 $(cat "${QUICK_DIR}/cf_vl.pid") >/dev/null 2>&1
    rm -f "${QUICK_DIR}/cf_vl.pid"
fi
if [ -f "${QUICK_DIR}/cf_tr.pid" ]; then
    kill -9 $(cat "${QUICK_DIR}/cf_tr.pid") >/dev/null 2>&1
    rm -f "${QUICK_DIR}/cf_tr.pid"
fi

cd "$QUICK_DIR" || exit
rm -rf xray cloudflared-linux xray.zip

# 4. 架构判断与核心下载
case "$(uname -m)" in
    x86_64 | x64 | amd64 )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
    ;;
    i386 | i686 )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux
    ;;
    armv8 | arm64 | aarch64 )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
    ;;
    armv7l )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux
    ;;
    * )
    echo -e "${RED}当前架构 $(uname -m) 没有适配${NC}"
    exit 1
    ;;
esac

mkdir -p xray
unzip -q -o xray.zip -d xray
chmod +x cloudflared-linux xray/xray
rm -rf xray.zip

# 5. 生成 UUID 与端口
uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath_vless="vl-$(echo $uuid | awk -F- '{print $1}')"
urlpath_trojan="tr-$(echo $uuid | awk -F- '{print $1}')"

port_vless=$[$RANDOM+10000]
port_trojan=$[$port_vless+1]

# 6. 写入原版标准的 config.json 结构
cat > xray/config.json <<EOF
{
    "inbounds": [
        {
            "tag": "vless-in",
            "port": $port_vless,
            "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {
                "decryption": "none",
                "clients": [
                    {
                        "id": "$uuid"
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/$urlpath_vless"
                }
            }
        },
        {
            "tag": "trojan-in",
            "port": $port_trojan,
            "listen": "127.0.0.1",
            "protocol": "trojan",
            "settings": {
                "clients": [
                    {
                        "password": "$uuid"
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/$urlpath_trojan"
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {}
        }
    ]
}
EOF

# 7. 启动 Xray 与 双协议 Argo 隧道
"${QUICK_DIR}/xray/xray" run -config "${QUICK_DIR}/xray/config.json" >/dev/null 2>&1 &
echo $! > "${QUICK_DIR}/xray.pid"

"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_vl.pid"

"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_tr.pid"

sleep 2

# 8. 等待抓取 Argo 临时域名
n=0
while true
do
    n=$[$n+1]
    clear
    echo "等待 cloudflare argo 生成双协议专属地址，已等待 $n 秒..."
    argo_vl=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_vless.log | head -n 1 | awk -F// '{print $2}')
    argo_tr=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_trojan.log | head -n 1 | awk -F// '{print $2}')

    if [ $n == 20 ]
    then
        n=0
        [ -f "${QUICK_DIR}/cf_vl.pid" ] && kill -9 $(cat "${QUICK_DIR}/cf_vl.pid") >/dev/null 2>&1
        [ -f "${QUICK_DIR}/cf_tr.pid" ] && kill -9 $(cat "${QUICK_DIR}/cf_tr.pid") >/dev/null 2>&1
        rm -rf argo_vless.log argo_trojan.log
        clear
        echo "argo 获取超时，正在重新尝试建立双隧道..."
        "${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
        echo $! > "${QUICK_DIR}/cf_vl.pid"
        "${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
        echo $! > "${QUICK_DIR}/cf_tr.pid"
        sleep 2
    elif [[ -z "$argo_vl" || -z "$argo_tr" ]]
    then
        sleep 1
    else
        rm -rf argo_vless.log argo_trojan.log
        break
    fi
done
clear

node_tag=$(echo $isp | sed -e 's/_/%20/g' -e 's/,/%2C/g')
if [[ -z "$node_tag" || "$node_tag" == "--" ]]; then
    node_tag="Argo_Node"
fi

opt_domains=("cf.090227.xyz" "cloudflare.182682.xyz")
opt_labels=("优选cf.090227" "优选182682")

> nodes.txt

cat > clash.yaml <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
proxies:
EOF

proxy_names=()

vless_domains=("$argo_vl" "${opt_domains[@]}")
vless_labels=("默认Argo" "${opt_labels[@]}")

for idx in "${!vless_domains[@]}"; do
    d="${vless_domains[$idx]}"
    l="${vless_labels[$idx]}"

    vless_tls="vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_vl}&type=ws&host=${argo_vl}&path=%2F${urlpath_vless}#${node_tag}-VLESS-${l}-443"
    echo "$vless_tls" >> nodes.txt
    proxy_names+=("${node_tag}-VLESS-${l}-443")
    cat >> clash.yaml <<EOF
  - name: "${node_tag}-VLESS-${l}-443"
    type: vless
    server: ${d}
    port: 443
    uuid: ${uuid}
    cipher: auto
    tls: true
    udp: true
    servername: ${argo_vl}
    network: ws
    ws-opts:
      path: /${urlpath_vless}
      headers:
        Host: ${argo_vl}
EOF
done

trojan_domains=("$argo_tr" "${opt_domains[@]}")
trojan_labels=("默认Argo" "${opt_labels[@]}")

for idx in "${!trojan_domains[@]}"; do
    d="${trojan_domains[$idx]}"
    l="${trojan_labels[$idx]}"

    trojan_tls="trojan://${uuid}@${d}:443?security=tls&sni=${argo_tr}&type=ws&host=${argo_tr}&path=%2F${urlpath_trojan}#${node_tag}-Trojan-${l}-443"
    echo "$trojan_tls" >> nodes.txt
    proxy_names+=("${node_tag}-Trojan-${l}-443")
    cat >> clash.yaml <<EOF
  - name: "${node_tag}-Trojan-${l}-443"
    type: trojan
    server: ${d}
    port: 443
    password: ${uuid}
    udp: true
    sni: ${argo_tr}
    network: ws
    ws-opts:
      path: /${urlpath_trojan}
      headers:
        Host: ${argo_tr}
EOF
done

cat >> clash.yaml <<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF

for pname in "${proxy_names[@]}"; do
    echo "      - \"${pname}\"" >> clash.yaml
done

cat >> clash.yaml <<EOF
rules:
  - MATCH,PROXY
EOF

if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
then
    base64 nodes.txt | tr -d '\n' > sub.txt
else
    base64 -w 0 nodes.txt > sub.txt
fi

# 获取服务端口与 Token
sub_port=25000
[ -f "/etc/yuzhou_sub_port" ] && sub_port=$(cat /etc/yuzhou_sub_port) || { echo "$sub_port" > /etc/yuzhou_sub_port; }

sub_token="sub-$(cat /proc/sys/kernel/random/uuid | awk -F- '{print $1}')"
[ -f "/etc/yuzhou_sub_token" ] && sub_token=$(cat /etc/yuzhou_sub_token) || { echo "$sub_token" > /etc/yuzhou_sub_token; }

secure_web_dir="${SUB_DIR}/${sub_token}"
mkdir -p "$secure_web_dir" >/dev/null 2>&1
cp -f nodes.txt "${secure_web_dir}/nodes.txt"
cp -f sub.txt "${secure_web_dir}/sub.txt"
cp -f clash.yaml "${secure_web_dir}/clash.yaml"

# 启动本地 HTTP 订阅服务
pkill -f "http.server $sub_port" >/dev/null 2>&1
if [ -x "$(command -v python3)" ]; then
    nohup python3 -m http.server $sub_port --directory "$SUB_DIR" >/dev/null 2>&1 &
fi

# ==============================================================
# 防火墙端口管理核心逻辑
# ==============================================================
echo -e "\n${CYAN}正在检查并更新防火墙放行端口...${NC}"
ssh_port=$(ss -tlnp | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
[ -z "$ssh_port" ] && ssh_port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
[ -z "$ssh_port" ] && ssh_port=22

if command -v ufw &>/dev/null && systemctl is-active --quiet ufw 2>/dev/null; then
    if [ -f "$LAST_PORTS_FILE" ]; then
        for old_port in $(cat "$LAST_PORTS_FILE"); do
            if [ "$old_port" != "$ssh_port" ] && [ -n "$old_port" ]; then
                ufw delete allow "$old_port"/tcp >/dev/null 2>&1
            fi
        done
    fi
    ufw allow "$port_vless"/tcp comment 'Yuzhou VLESS Port' >/dev/null 2>&1
    ufw allow "$port_trojan"/tcp comment 'Yuzhou Trojan Port' >/dev/null 2>&1
    ufw allow "$sub_port"/tcp comment 'Yuzhou Sub Port' >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    if [ -f "$LAST_PORTS_FILE" ]; then
        for old_port in $(cat "$LAST_PORTS_FILE"); do
            if [ "$old_port" != "$ssh_port" ] && [ -n "$old_port" ]; then
                firewall-cmd --permanent --remove-port="$old_port"/tcp >/dev/null 2>&1
            fi
        done
    fi
    firewall-cmd --permanent --add-port="$port_vless"/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$port_trojan"/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$sub_port"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

echo -e "$port_vless\n$port_trojan\n$sub_port" > "$LAST_PORTS_FILE"


# ==============================================================
# 💡【全新内嵌】自动生成开机恢复脚本与注册系统服务（一键搞定无需手动）
# ==============================================================
cat > /etc/yuzhou/auto_argo_update.sh << 'EOF'
#!/bin/bash
YUZHOU_DIR="/etc/yuzhou"
QUICK_DIR="${YUZHOU_DIR}/quick"
SUB_DIR="/var/www/suoha_sub"
sleep 15
kill -9 $(pgrep -f "xray") >/dev/null 2>&1
kill -9 $(pgrep -f "cloudflared-linux") >/dev/null 2>&1
pkill -f "http.server" >/dev/null 2>&1
[ ! -f "${QUICK_DIR}/xray/config.json" ] && exit 0
cd "$QUICK_DIR" || exit
"${QUICK_DIR}/xray/xray" run -config "${QUICK_DIR}/xray/config.json" >/dev/null 2>&1 &
echo $! > "${QUICK_DIR}/xray.pid"
config_file="${QUICK_DIR}/xray/config.json"
uuid=$(python3 -c "import json; data=json.load(open('$config_file')); print(data['inbounds'][0]['settings']['clients'][0]['id'])" 2>/dev/null)
port_vless=$(python3 -c "import json; data=json.load(open('$config_file')); print(data['inbounds'][0]['port'])" 2>/dev/null)
port_trojan=$(python3 -c "import json; data=json.load(open('$config_file')); print(data['inbounds'][1]['port'])" 2>/dev/null)
urlpath_vless=$(python3 -c "import json; data=json.load(open('$config_file')); print(data['inbounds'][0]['streamSettings']['wsSettings']['path'].lstrip('/'))" 2>/dev/null)
urlpath_trojan=$(python3 -c "import json; data=json.load(open('$config_file')); print(data['inbounds'][1]['streamSettings']['wsSettings']['path'].lstrip('/'))" 2>/dev/null)
[ -z "$uuid" ] && exit 1
ips=4
rm -rf argo_vless.log argo_trojan.log
"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_vl.pid"
"${QUICK_DIR}/cloudflared-linux" tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
echo $! > "${QUICK_DIR}/cf_tr.pid"
n=0
argo_vl=""
argo_tr=""
while true; do
    n=$[$n+1]
    argo_vl=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_vless.log | head -n 1 | awk -F// '{print $2}')
    argo_tr=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_trojan.log | head -n 1 | awk -F// '{print $2}')
    [ $n -gt 30 ] && break
    [[ -z "$argo_vl" || -z "$argo_tr" ]] && sleep 2 || break
done
[[ -z "$argo_vl" || -z "$argo_tr" ]] && exit 1
node_tag="Argo_Node"
opt_domains=("cf.090227.xyz" "cloudflare.182682.xyz")
> nodes.txt
cat > clash.yaml <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
proxies:
EOF
proxy_names=()
for d in "$argo_vl" "${opt_domains[@]}"; do
    if [ "$d" == "$argo_vl" ]; then l="默认Argo"; else l="优选节点"; fi
    echo "vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_vl}&type=ws&host=${argo_vl}&path=%2F${urlpath_vless}#${node_tag}-VLESS-${l}-443" >> nodes.txt
    proxy_names+=("${node_tag}-VLESS-${l}-443")
    cat >> clash.yaml <<EOF
  - name: "${node_tag}-VLESS-${l}-443"
    type: vless
    server: ${d}
    port: 443
    uuid: ${uuid}
    cipher: auto
    tls: true
    udp: true
    servername: ${argo_vl}
    network: ws
    ws-opts:
      path: /${urlpath_vless}
      headers:
        Host: ${argo_vl}
EOF
done
for d in "$argo_tr" "${opt_domains[@]}"; do
    if [ "$d" == "$argo_tr" ]; then l="默认Argo"; else l="优选节点"; fi
    echo "trojan://${uuid}@${d}:443?security=tls&sni=${argo_tr}&type=ws&host=${argo_tr}&path=%2F${urlpath_trojan}#${node_tag}-Trojan-${l}-443" >> nodes.txt
    proxy_names+=("${node_tag}-Trojan-${l}-443")
    cat >> clash.yaml <<EOF
  - name: "${node_tag}-Trojan-${l}-443"
    type: trojan
    server: ${d}
    port: 443
    password: ${uuid}
    udp: true
    sni: ${argo_tr}
    network: ws
    ws-opts:
      path: /${urlpath_trojan}
      headers:
        Host: ${argo_tr}
EOF
done
cat >> clash.yaml <<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF
for pname in "${proxy_names[@]}"; do
    echo "      - \"${pname}\"" >> clash.yaml
done
cat >> clash.yaml <<EOF
rules:
  - MATCH,PROXY
EOF
base64 -w 0 nodes.txt > sub.txt
sub_token=$(cat /etc/yuzhou_sub_token 2>/dev/null || echo "default_token")
secure_web_dir="${SUB_DIR}/${sub_token}"
mkdir -p "$secure_web_dir"
cp -f nodes.txt "${secure_web_dir}/nodes.txt"
cp -f sub.txt "${secure_web_dir}/sub.txt"
cp -f clash.yaml "${secure_web_dir}/clash.yaml"
sub_port=$(cat /etc/yuzhou_sub_port 2>/dev/null || echo 25000)
pkill -f "http.server $sub_port" >/dev/null 2>&1
nohup python3 -m http.server $sub_port --directory "$SUB_DIR" >/dev/null 2>&1 &
EOF

chmod +x /etc/yuzhou/auto_argo_update.sh

cat > /etc/systemd/system/yuzhou-dynamic-sub.service << 'EOF'
[Unit]
Description=Yuzhou Dynamic Argo Sub Auto Renewal Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash /etc/yuzhou/auto_argo_update.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable yuzhou-dynamic-sub.service >/dev/null 2>&1
# ==============================================================

# 获取公网 IP
server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[ -z "$server_ip" ] && server_ip=$(curl -s4 --connect-timeout 2 https://api.ip.sb/ip 2>/dev/null)
[ -z "$server_ip" ] && server_ip="$argo_vl"

sub_online_url="http://${server_ip}:${sub_port}/${sub_token}/sub.txt"
clash_online_url="http://${server_ip}:${sub_port}/${sub_token}/clash.yaml"

cat > v2ray.txt <<EOF
======================== 一键梭哈 443 TLS 节点列表 ========================
$(cat nodes.txt)

======================== 客户端订阅及导入链接 ========================
1. 通用订阅链接:
${sub_online_url}

2. v2rayN / NekoBox 一键导入协议链接:
sub://${sub_online_url}

3. Clash 一键导入配置:
clash://install-config?url=${clash_online_url}
=====================================================================
EOF

cat v2ray.txt
echo -e "\n信息已保存至 ${QUICK_DIR}/v2ray.txt"
echo -e "${GREEN}✅ 已自动植入开机自启与动态订阅服务，VPS重启后只需点一次更新订阅即可恢复！${NC}"
read -p "按回车键返回主菜单..." < /dev/tty
