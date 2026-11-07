#!/bin/bash

# ==============================================================================
# 脚本名称: yuzhou (原名kkk suoha代码修改)
# 功能说明: 多协议代理节点快捷部署与管理工具 (支持 VPS加固、Argo 快速/固定隧道、IPv6 SS、Hy2、WARP 分流等)
# ==============================================================================

# 1. 系统环境初始化与基础依赖检测
linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")
n=0

for i in `echo ${linux_os[@]}`
do
    if [ $i == $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') ]
    then
        break
    else
        n=$[$n+1]
    fi
done

if [ $n == 5 ]
then
    echo "当前系统 $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2) 未完全适配，默认使用 APT 包管理器"
    n=0
fi

# 确保核心基础工具安装完整
if [ -z $(type -P unzip) ]; then ${linux_update[$n]}; ${linux_install[$n]} unzip; fi
if [ -z $(type -P curl) ]; then ${linux_update[$n]}; ${linux_install[$n]} curl; fi
if [ -z $(type -P python3) ]; then ${linux_update[$n]}; ${linux_install[$n]} python3; fi
if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') != "Alpine" ]
then
    if [ -z $(type -P systemctl) ]; then ${linux_update[$n]}; ${linux_install[$n]} systemctl; fi
fi

# ==============================================================================
# 2. 基础核心工具函数模块 (获取IP、端口、Token、启动订阅服务)
# ==============================================================================

# 获取服务器公网 IPv4 地址
function get_server_ip(){
    local ip=""
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    if [[ -z "$ip" || "$ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]; then
        ip=$(curl -s4 --connect-timeout 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/ip/{print $2}')
    fi
    if [ -z "$ip" ]; then ip=$(curl -s4 --connect-timeout 2 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n\r '); fi
    if [ -z "$ip" ]; then ip=$(curl -s4 --connect-timeout 2 https://api.ip.sb/ip 2>/dev/null | tr -d '\n\r '); fi
    if [ -z "$ip" ]; then ip=$(curl -s6 --connect-timeout 2 https://api64.ipify.org 2>/dev/null | tr -d '\n\r '); fi
    echo "$ip"
}

# 获取服务器公网 IPv6 地址
function get_server_ipv6(){
    local ip6=""
    ip6=$(curl -s6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null | tr -d '\n\r ')
    if [ -z "$ip6" ]; then ip6=$(curl -s6 --connect-timeout 3 https://ipv6.icanhazip.com 2>/dev/null | tr -d '\n\r '); fi
    if [ -z "$ip6" ]; then ip6=$(curl -s6 --connect-timeout 3 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26}' | grep ":" | tr -d '\n\r '); fi
    if [ -z "$ip6" ]; then ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n 1 | tr -d '\n\r '); fi
    echo "$ip6"
}

# 获取或持久化生成订阅服务端口
function get_or_create_sub_port(){
    local port_file="/etc/kkk_sub_port"
    local port=""
    if [ -f "$port_file" ]; then
        port=$(cat "$port_file" | tr -d '\n\r ')
    fi
    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        port=$[$RANDOM%10000+25000]
        echo "$port" > "$port_file"
    fi
    echo "$port"
}

# 获取或持久化生成安全订阅 Token
function get_or_create_sub_token(){
    local token_file="/etc/kkk_sub_token"
    local token=""
    if [ -f "$token_file" ]; then
        token=$(cat "$token_file" | tr -d '\n\r ')
    fi
    if [ -z "$token" ]; then
        token="sub-$(cat /proc/sys/kernel/random/uuid | awk -F- '{print $1}')"
        echo "$token" > "$token_file"
    fi
    echo "$token"
}

# 后台启动 Python HTTP 订阅文件分发服务
function start_sub_server(){
    local web_dir="$1"
    local port="$2"

    pkill -f "http.server $port" >/dev/null 2>&1
    fuser -k ${port}/tcp >/dev/null 2>&1

    if [ -x "$(command -v python3)" ]; then
        nohup python3 -m http.server $port --directory "$web_dir" >/dev/null 2>&1 &
    elif [ -x "$(command -v python)" ]; then
        cd "$web_dir" && nohup python -m SimpleHTTPServer $port >/dev/null 2>&1 &
        cd - >/dev/null 2>&1
    fi
}

# 将生成的节点文件同步至静态 Web 目录
function sync_to_static_web(){
    local src_dir="$1"
    local static_dir="/var/www/kkk_sub"
    mkdir -p "$static_dir" >/dev/null 2>&1
    [ -f "${src_dir}/nodes.txt" ] && cp -f "${src_dir}/nodes.txt" "${static_dir}/nodes.txt" 2>/dev/null
    [ -f "${src_dir}/sub.txt" ] && cp -f "${src_dir}/sub.txt" "${static_dir}/sub.txt" 2>/dev/null
    [ -f "${src_dir}/clash.yaml" ] && cp -f "${src_dir}/clash.yaml" "${static_dir}/clash.yaml" 2>/dev/null
}


# ==============================================================================
# 3. 核心节点部署与安全配置模块
# ==============================================================================

# VPS 主机系统初始化与安全加固 (改主机名、新用户、改SSH端口、禁Root)
action_init_security() {
    echo "===================================="
    echo "  开始执行：系统初始化与安全加固"
    echo "===================================="
    
    # 1. 修改主机名
    read -p "请输入新的主机名 (回车跳过): " NEW_HOSTNAME < /dev/tty
    if [ -n "$NEW_HOSTNAME" ]; then hostnamectl set-hostname "$NEW_HOSTNAME"; fi

    # 2. 创建新用户
    RANDOM_USER="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    read -p "请输入要创建的新用户名 [默认 $RANDOM_USER]: " NEW_USER < /dev/tty
    [ -z "$NEW_USER" ] && NEW_USER="$RANDOM_USER"
    useradd -m -s /bin/bash "$NEW_USER"
    passwd "$NEW_USER"

    # 3. 赋予 Sudo 权限
    usermod -aG sudo "$NEW_USER" 2>/dev/null || usermod -aG wheel "$NEW_USER" 2>/dev/null || echo "$NEW_USER ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$NEW_USER"

    # 4. 修改 SSH 端口及禁用 Root 登录
    local sshd_config="/etc/ssh/sshd_config"
    RANDOM_PORT=$((RANDOM % 64512 + 1024))
    read -p "请输入新的 SSH 端口 [默认 $RANDOM_PORT]: " NEW_SSH_PORT < /dev/tty
    [ -z "$NEW_SSH_PORT" ] && NEW_SSH_PORT="$RANDOM_PORT"

    sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" "$sshd_config"
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$sshd_config"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    
    echo "安全加固完成！新 SSH 端口: $NEW_SSH_PORT, 请妥善保存。"
}

# 快速梭哈模式 (Argo Quick Tunnel 自动生成 VLESS & Trojan 节点)
function quicktunnel(){
mkdir -p /opt/kkk_quick >/dev/null 2>&1
cd /opt/kkk_quick

# 精确清理旧的后台进程及 PID 文件
if [ -f "/opt/kkk_quick/xray.pid" ]; then
    kill -9 $(cat /opt/kkk_quick/xray.pid) >/dev/null 2>&1
    rm -f /opt/kkk_quick/xray.pid
fi
if [ -f "/opt/kkk_quick/cf_vl.pid" ]; then
    kill -9 $(cat /opt/kkk_quick/cf_vl.pid) >/dev/null 2>&1
    rm -f /opt/kkk_quick/cf_vl.pid
fi
if [ -f "/opt/kkk_quick/cf_tr.pid" ]; then
    kill -9 $(cat /opt/kkk_quick/cf_tr.pid) >/dev/null 2>&1
    rm -f /opt/kkk_quick/cf_tr.pid
fi

rm -rf xray cloudflared-linux xray.zip

# 根据系统架构下载对应版本的 Xray-core 与 cloudflared
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
    echo "当前架构 $(uname -m) 没有适配"
    exit
    ;;
esac

mkdir xray
unzip -d xray xray.zip
chmod +x cloudflared-linux xray/xray
rm -rf xray.zip

uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath_vless="vl-$(echo $uuid | awk -F- '{print $1}')"
urlpath_trojan="tr-$(echo $uuid | awk -F- '{print $1}')"

port_vless=$[$RANDOM+10000]
port_trojan=$[$port_vless+1]

# 生成 Xray 配置文件 (包含 VLESS 和 Trojan 双协议入站)
cat>xray/config.json<<EOF
{
    "inbounds": [
        {
            "tag": "vless-in",
            "port": $port_vless,
            "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {
                "decryption": "none",
                "clients": [{"id": "$uuid"}]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {"path": "/$urlpath_vless"}
            }
        },
        {
            "tag": "trojan-in",
            "port": $port_trojan,
            "listen": "127.0.0.1",
            "protocol": "trojan",
            "settings": {
                "clients": [{"password": "$uuid"}]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {"path": "/$urlpath_trojan"}
            }
        }
    ],
    "outbounds": [{"protocol": "freedom", "settings": {}}]
}
EOF

# 启动 Xray 核心并记录 PID
/opt/kkk_quick/xray/xray run -config /opt/kkk_quick/xray/config.json >/dev/null 2>&1 &
echo $! > /opt/kkk_quick/xray.pid

# 启动 Cloudflare Argo 临时隧道实例
/opt/kkk_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
echo $! > /opt/kkk_quick/cf_vl.pid

/opt/kkk_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
echo $! > /opt/kkk_quick/cf_tr.pid

sleep 2

# 循环等待 Argo 隧道临时域名成功生成
n=0
while true
do
n=$[$n+1]
clear
echo "等待 Cloudflare Argo 生成双协议专属地址，已等待 $n 秒..."
argo_vl=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_vless.log | head -n 1 | awk -F// '{print $2}')
argo_tr=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" argo_trojan.log | head -n 1 | awk -F// '{print $2}')

if [ $n == 20 ]
then
    n=0
    [ -f "/opt/kkk_quick/cf_vl.pid" ] && kill -9 $(cat /opt/kkk_quick/cf_vl.pid) >/dev/null 2>&1
    [ -f "/opt/kkk_quick/cf_tr.pid" ] && kill -9 $(cat /opt/kkk_quick/cf_tr.pid) >/dev/null 2>&1
    rm -rf argo_vless.log argo_trojan.log
    clear
    echo "Argo 获取超时，正在重新尝试建立双隧道..."
    /opt/kkk_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
    echo $! > /opt/kkk_quick/cf_vl.pid
    /opt/kkk_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
    echo $! > /opt/kkk_quick/cf_tr.pid
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

cat>clash.yaml<<EOF
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

# 拼装 VLESS 节点及 Clash 配置
for idx in "${!vless_domains[@]}"; do
    d="${vless_domains[$idx]}"
    l="${vless_labels[$idx]}"

    vless_tls="vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${argo_vl}&type=ws&host=${argo_vl}&path=%2F${urlpath_vless}#${node_tag}-VLESS-${l}-443"
    echo "$vless_tls" >> nodes.txt
    proxy_names+=("${node_tag}-VLESS-${l}-443")
    cat>>clash.yaml<<EOF
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

# 拼装 Trojan 节点及 Clash 配置
for idx in "${!trojan_domains[@]}"; do
    d="${trojan_domains[$idx]}"
    l="${trojan_labels[$idx]}"

    trojan_tls="trojan://${uuid}@${d}:443?security=tls&sni=${argo_tr}&type=ws&host=${argo_tr}&path=%2F${urlpath_trojan}#${node_tag}-Trojan-${l}-443"
    echo "$trojan_tls" >> nodes.txt
    proxy_names+=("${node_tag}-Trojan-${l}-443")
    cat>>clash.yaml<<EOF
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

cat>>clash.yaml<<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF

for pname in "${proxy_names[@]}"; do
    echo "      - \"${pname}\"" >> clash.yaml
done

cat>>clash.yaml<<EOF
rules:
  - MATCH,PROXY
EOF

if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
then
    base64 nodes.txt | tr -d '\n' > sub.txt
else
    base64 -w 0 nodes.txt > sub.txt
fi

server_ip=$(get_server_ip)
if [ -z "$server_ip" ]; then server_ip="$argo_vl"; fi

sub_port=$(get_or_create_sub_port)
sub_token=$(get_or_create_sub_token)

secure_web_dir="/var/www/kkk_sub/${sub_token}"
mkdir -p "$secure_web_dir" >/dev/null 2>&1
[ -f "/opt/kkk_quick/nodes.txt" ] && cp -f /opt/kkk_quick/nodes.txt "${secure_web_dir}/nodes.txt"
[ -f "/opt/kkk_quick/sub.txt" ] && cp -f /opt/kkk_quick/sub.txt "${secure_web_dir}/sub.txt"
[ -f "/opt/kkk_quick/clash.yaml" ] && cp -f /opt/kkk_quick/clash.yaml "${secure_web_dir}/clash.yaml"

start_sub_server "/var/www/kkk_sub" "$sub_port"

# 生成快速模式的开机自启恢复脚本
cat > /opt/kkk_quick/start.sh << EOF
#!/bin/bash
cd /opt/kkk_quick || exit
[ -f "xray.pid" ] && kill -9 \$(cat xray.pid) 2>/dev/null
[ -f "cf_vl.pid" ] && kill -9 \$(cat cf_vl.pid) 2>/dev/null
[ -f "cf_tr.pid" ] && kill -9 \$(cat cf_tr.pid) 2>/dev/null
rm -rf argo_vless.log argo_trojan.log

./xray/xray run -config xray/config.json >/dev/null 2>&1 &
echo \$! > xray.pid

./cloudflared-linux tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
echo \$! > /opt/kkk_quick/cf_vl.pid

./cloudflared-linux tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
echo \$! > /opt/kkk_quick/cf_tr.pid

n=0
while [ \$n -lt 40 ]; do
    n=\$[ \$n + 1 ]
    argo_vl=\$(grep -oE "https://[a-zA-Z0-9.-]+\\.trycloudflare\\.com" argo_vless.log | head -n 1 | awk -F// '{print \$2}')
    argo_tr=\$(grep -oE "https://[a-zA-Z0-9.-]+\\.trycloudflare\\.com" argo_trojan.log | head -n 1 | awk -F// '{print \$2}')
    if [[ -n "\$argo_vl" && -n "\$argo_tr" ]]; then
        break
    fi
    sleep 1
done

if [[ -n "\$argo_vl" && -n "\$argo_tr" ]]; then
    > nodes.txt
    vless_domains=("\$argo_vl" "cf.090227.xyz" "cloudflare.182682.xyz")
    vless_labels=("默认Argo" "优选cf.090227" "优选182682")
    for idx in "\${!vless_domains[@]}"; do
        d="\${vless_domains[\$idx]}"
        l="\${vless_labels[\$idx]}"
        echo "vless://$uuid@\${d}:443?encryption=none&security=tls&sni=\$argo_vl&type=ws&host=\$argo_vl&path=%2F$urlpath_vless#$node_tag-VLESS-\$l-443" >> nodes.txt
    done

    trojan_domains=("\$argo_tr" "cf.090227.xyz" "cloudflare.182682.xyz")
    trojan_labels=("默认Argo" "优选cf.090227" "优选182682")
    for idx in "\${!trojan_domains[@]}"; do
        d="\${trojan_domains[\$idx]}"
        l="\${trojan_labels[\$idx]}"
        echo "trojan://$uuid@\${d}:443?security=tls&sni=\$argo_tr&type=ws&host=\$argo_tr&path=%2F$urlpath_trojan#$node_tag-Trojan-\$l-443" >> nodes.txt
    done

    base64 -w 0 nodes.txt > sub.txt 2>/dev/null || base64 nodes.txt | tr -d '\n' > sub.txt
    sub_token=$(cat /etc/kkk_sub_token 2>/dev/null || echo "sub-default")
    secure_web_dir="/var/www/kkk_sub/\$sub_token"
    mkdir -p "\$secure_web_dir"
    cp -f sub.txt "\$secure_web_dir/sub.txt"
    cp -f clash.yaml "\$secure_web_dir/clash.yaml"
fi

python3 -m http.server $sub_port --directory /var/www/kkk_sub >/dev/null 2>&1 &
EOF

chmod +x /opt/kkk_quick/start.sh

# 注册 Systemd 开机自启服务
cat > /lib/systemd/system/kkk-quick.service <<EOF
[Unit]
Description=KKK Quick Tunnel Auto Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/bin/bash /opt/kkk_quick/start.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kkk-quick.service >/dev/null 2>&1

sub_online_url="http://${server_ip}:${sub_port}/${sub_token}/sub.txt"
clash_online_url="http://${server_ip}:${sub_port}/${sub_token}/clash.yaml"

cat>v2ray.txt<<EOF
======================== KKK 快速模式 443 TLS 节点列表 ========================
$(cat nodes.txt)

端口替换提示:
443 端口可根据需要改为 CF 其它 TLS 端口: 2053, 2083, 2087, 2096, 8443

======================== 客户端订阅及导入链接 ========================
本机固定订阅服务端口: ${sub_port}

1. 通用订阅链接:
${sub_online_url}

2. v2rayN / NekoBox 一键导入协议链接:
sub://${sub_online_url}

3. Clash / Mihomo 一键导入配置:
clash://install-config?url=${clash_online_url}

4. Clash 在线配置文件直链:
${clash_online_url}

持久订阅存储目录: /var/www/kkk_sub/
=====================================================================
EOF

cat v2ray.txt
echo -e "\n信息已保存在 /opt/kkk_quick/v2ray.txt"
}

# 安装服务模式 (自定义域名绑定固定 Argo 隧道)
function installtunnel(){
mkdir -p /opt/kkk/ >/dev/null 2>&1
cd /opt/kkk
rm -rf xray cloudflared-linux xray.zip

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
    echo "当前架构 $(uname -m) 没有适配"
    exit
    ;;
esac

mkdir xray
unzip -d xray xray.zip
chmod +x cloudflared-linux xray/xray
mv xray/xray /opt/kkk/
rm -rf xray xray.zip

uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath_vless="vl-$(echo $uuid | awk -F- '{print $1}')"
urlpath_trojan="tr-$(echo $uuid | awk -F- '{print $1}')"
port_vless=$[$RANDOM+10000]
port_trojan=$[$port_vless+1]

cat>/opt/kkk/config.json<<EOF
{
    "inbounds": [
        {
            "tag": "vless-in",
            "port": $port_vless,
            "listen": "127.0.0.1",
            "protocol": "vless",
            "settings": {
                "decryption": "none",
                "clients": [{"id": "$uuid"}]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {"path": "/$urlpath_vless"}
            }
        },
        {
            "tag": "trojan-in",
            "port": $port_trojan,
            "listen": "127.0.0.1",
            "protocol": "trojan",
            "settings": {
                "clients": [{"password": "$uuid"}]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {"path": "/$urlpath_trojan"}
            }
        }
    ],
    "outbounds": [{"protocol": "freedom", "settings": {}}]
}
EOF

clear
echo "请复制下方链接在浏览器中打开并授权绑定域名..."
/opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel login
clear
/opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel list >argo.log 2>&1
echo -e "当前已绑定的 Tunnel 服务如下:\n"
sed 1,2d argo.log | awk '{print $2}'
echo -e "\n请输入绑定的完整二级域名 (例如: xxx.example.com):"
read -p "输入完整二级域名: " domain
if [ -z "$domain" ]; then echo "未输入域名"; exit; fi
if [ $(echo $domain | grep "\." | wc -l) == 0 ]; then echo "域名格式不正确"; exit; fi

name=$(echo $domain | awk -F\. '{print $1}')
if [ $(sed 1,2d argo.log | awk '{print $2}' | grep -w $name | wc -l) == 0 ]
then
    /opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel create $name >argo.log 2>&1
else
    if [ ! -f "/root/.cloudflared/$(sed 1,2d argo.log | awk '{print $1" "$2}' | grep -w $name | awk '{print $1}').json" ]
    then
        /opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel cleanup $name >argo.log 2>&1
        /opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel delete $name >argo.log 2>&1
        /opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel create $name >argo.log 2>&1
    else
        /opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel cleanup $name >argo.log 2>&1
    fi
fi

/opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel route dns --overwrite-dns $name $domain >argo.log 2>&1
tunneluuid=$(cut -d= -f2 argo.log)

node_tag=$(echo $isp | sed -e 's/_/%20/g' -e 's/,/%2C/g')
if [[ -z "$node_tag" || "$node_tag" == "--" ]]; then node_tag="Argo_Node"; fi

domains=("$domain" "cf.090227.xyz" "cloudflare.182682.xyz")
labels=("自定域名" "优选cf.090227" "优选182682")

> /opt/kkk/nodes.txt

cat>/opt/kkk/clash.yaml<<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
proxies:
EOF

proxy_names=()
for idx in "${!domains[@]}"; do
    d="${domains[$idx]}"
    l="${labels[$idx]}"

    vless_tls="vless://${uuid}@${d}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=%2F${urlpath_vless}#${node_tag}-VLESS-${l}-443"
    echo "$vless_tls" >> /opt/kkk/nodes.txt
    proxy_names+=("${node_tag}-VLESS-${l}-443")
    cat>>/opt/kkk/clash.yaml<<EOF
  - name: "${node_tag}-VLESS-${l}-443"
    type: vless
    server: ${d}
    port: 443
    uuid: ${uuid}
    cipher: auto
    tls: true
    udp: true
    servername: ${domain}
    network: ws
    ws-opts:
      path: /${urlpath_vless}
      headers:
        Host: ${domain}
EOF

    trojan_tls="trojan://${uuid}@${d}:443?security=tls&sni=${domain}&type=ws&host=${domain}&path=%2F${urlpath_trojan}#${node_tag}-Trojan-${l}-443"
    echo "$trojan_tls" >> /opt/kkk/nodes.txt
    proxy_names+=("${node_tag}-Trojan-${l}-443")
    cat>>/opt/kkk/clash.yaml<<EOF
  - name: "${node_tag}-Trojan-${l}-443"
    type: trojan
    server: ${d}
    port: 443
    password: ${uuid}
    udp: true
    sni: ${domain}
    network: ws
    ws-opts:
      path: /${urlpath_trojan}
      headers:
        Host: ${domain}
EOF
done

cat>>/opt/kkk/clash.yaml<<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF

for pname in "${proxy_names[@]}"; do
    echo "      - \"${pname}\"" >> /opt/kkk/clash.yaml
done

cat>>/opt/kkk/clash.yaml<<EOF
rules:
  - MATCH,PROXY
EOF

if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
then
    base64 /opt/kkk/nodes.txt | tr -d '\n' > /opt/kkk/sub.txt
else
    base64 -w 0 /opt/kkk/nodes.txt > /opt/kkk/sub.txt
fi

server_ip=$(get_server_ip)
if [ -z "$server_ip" ]; then server_ip="$domain"; fi

sub_port=$(get_or_create_sub_port)
sync_to_static_web "/opt/kkk"
start_sub_server "/var/www/kkk_sub" "$sub_port"

sub_online_url="http://${server_ip}:${sub_port}/sub.txt"
clash_online_url="http://${server_ip}:${sub_port}/clash.yaml"

cat>/opt/kkk/v2ray.txt<<EOF
======================== KKK 固定模式节点连接信息 ========================
$(cat /opt/kkk/nodes.txt)

1. 通用在线订阅链接:
${sub_online_url}

2. v2rayN / NekoBox 一键导入协议链接:
sub://${sub_online_url}

3. Clash / Mihomo 一键导入配置:
clash://install-config?url=${clash_online_url}
==============================================================
EOF

rm -rf argo.log

cat>/opt/kkk/config.yaml<<EOF
tunnel: $tunneluuid
credentials-file: /root/.cloudflared/$tunneluuid.json

ingress:
  - hostname: $domain
    path: /$urlpath_vless
    service: http://127.0.0.1:$port_vless
  - hostname: $domain
    path: /$urlpath_trojan
    service: http://127.0.0.1:$port_trojan
  - service: http_status:404
EOF

# 注册系统守护进程服务
if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
then
    cat>/etc/local.d/cloudflared.start<<EOF
/opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/kkk/config.yaml run $name &
EOF
    cat>/etc/local.d/xray.start<<EOF
/opt/kkk/xray run -config /opt/kkk/config.json &
EOF
    chmod +x /etc/local.d/cloudflared.start /etc/local.d/xray.start
    rc-update add local
    /etc/local.d/cloudflared.start >/dev/null 2>&1
    /etc/local.d/xray.start >/dev/null 2>&1
else
    cat>/lib/systemd/system/cloudflared.service<<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/kkk/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/kkk/config.yaml run $name
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    cat>/lib/systemd/system/xray.service<<EOF
[Unit]
Description=Xray
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/kkk/xray run -config /opt/kkk/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable cloudflared.service >/dev/null 2>&1
    systemctl enable xray.service >/dev/null 2>&1
    systemctl --system daemon-reload
    systemctl start cloudflared.service
    systemctl start xray.service
fi

# 生成交互式管理控制脚本并软链接到 /usr/bin/kkk (已规范子菜单返回选项)
cat>/opt/kkk/kkk.sh<<EOF
#!/bin/bash
clear
while true
do
echo 1.管理TUNNEL
echo 2.启动服务
echo 3.停止服务
echo 4.重启服务
echo 5.卸载服务
echo 6.查看当前订阅与节点链接
echo 0.退出脚本
read -p "请选择菜单(默认0): " menu
[ -z "\$menu" ] && menu=0

if [ \$menu == 1 ]
then
    clear
    while true
    do
        /opt/kkk/cloudflared-linux tunnel list
        echo 1.删除TUNNEL
        echo 0.返回菜单
        read -p "请选择菜单(默认0): " tunneladmin
        [ -z "\$tunneladmin" ] && tunneladmin=0
        if [ \$tunneladmin == 1 ]
        then
            read -p "请输入要删除的TUNNEL NAME: " tunnelname
            /opt/kkk/cloudflared-linux tunnel cleanup \$tunnelname
            /opt/kkk/cloudflared-linux tunnel delete \$tunnelname
        else
            break
        fi
    done
elif [ \$menu == 2 ]
then
    systemctl start cloudflared.service xray.service 2>/dev/null || true
    clear
elif [ \$menu == 3 ]
then
    systemctl stop cloudflared.service xray.service 2>/dev/null || true
    clear
elif [ \$menu == 4 ]
then
    systemctl restart cloudflared.service xray.service 2>/dev/null || true
    clear
elif [ \$menu == 5 ]
then
    systemctl stop cloudflared.service xray.service 2>/dev/null || true
    systemctl disable cloudflared.service xray.service 2>/dev/null || true
    rm -rf /opt/kkk /opt/kkk_quick /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/kkk ~/.cloudflared /etc/kkk_sub_port /var/www/kkk_sub
    systemctl --system daemon-reload
    echo "服务已全部卸载"
    exit
elif [ \$menu == 6 ]
then
    clear
    cat /opt/kkk/v2ray.txt
elif [ \$menu == 0 ]
then
    exit
fi
done
EOF
chmod +x /opt/kkk/kkk.sh
ln -sf /opt/kkk/kkk.sh /usr/bin/kkk
}

# 额外增加 IPv6 Shadowsocks 直连节点共存部署
function install_ipv6_ss(){
    clear
    echo "正在检测机器公网 IPv6 地址..."
    local ipv6_addr
    ipv6_addr=$(get_server_ipv6)

    if [ -z "$ipv6_addr" ]; then
        echo "未检测到可用的公网 IPv6 地址！"
        read -p "按回车键返回..."
        return
    fi

    local xray_dir=""
    local cfg_json=""
    if [ -f "/opt/kkk/config.json" ]; then
        xray_dir="/opt/kkk"
        cfg_json="/opt/kkk/config.json"
    elif [ -f "/opt/kkk_quick/xray/config.json" ]; then
        xray_dir="/opt/kkk_quick"
        cfg_json="/opt/kkk_quick/xray/config.json"
    else
        echo "未检测到运行中的 Xray 服务！"
        read -p "按回车键返回..."
        return
    fi

    local ss_port=$[$RANDOM%10000+30000]
    local ss_password=$(cat /proc/sys/kernel/random/uuid | awk -F- '{print $1$2}')
    local ss_method="aes-128-gcm"

    python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    data = json.load(f)
data['inbounds'] = [ib for ib in data.get('inbounds', []) if ib.get('tag') != 'ss-ipv6']
data['inbounds'].append({
    'tag': 'ss-ipv6',
    'port': int('$ss_port'),
    'listen': '::',
    'protocol': 'shadowsocks',
    'settings': {'method': '$ss_method', 'password': '$ss_password', 'network': 'tcp,udp'}
})
with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
    systemctl restart xray.service 2>/dev/null || pkill -f xray
    
    local ss_user_info="${ss_method}:${ss_password}"
    local ss_base64=$(echo -n "$ss_user_info" | base64 -w 0 2>/dev/null || echo -n "$ss_user_info" | base64 | tr -d '\n')
    local ss_link="ss://${ss_base64}@[${ipv6_addr}]:${ss_port}#IPv6-SS-Direct"

    echo "$ss_link" >> "${xray_dir}/nodes.txt"
    sync_to_static_web "$xray_dir"
    echo "IPv6 Shadowsocks 直连节点添加成功！"
    read -p "按回车键返回..."
}

# 额外增加 Hysteria 2 直连备用节点
install_hy2_direct() {
    echo "正在部署 Hysteria 2 直连备用节点..."
    local xray_dir="/opt/kkk_quick"
    local cfg_json="/opt/kkk_quick/xray/config.json"
    
    if [ ! -f "$cfg_json" ]; then
        echo "未找到 Xray 配置文件，请先运行梭哈模式！"
        read -p "按回车键返回..."
        return
    fi

    local ipv4=$(curl -4 -s --connect-timeout 3 ip.sb)
    local hy2_port=$((RANDOM % 10000 + 10000))
    local hy2_pass=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p "$xray_dir/xray"
    openssl ecparam -genkey -name prime256v1 -out "$xray_dir/xray/hy2.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$xray_dir/xray/hy2.key" -out "$xray_dir/xray/hy2.crt" -subj "/CN=bing.com" 2>/dev/null
    local cert_pin=$(openssl x509 -in "$xray_dir/xray/hy2.crt" -noout -sha256 -fingerprint 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    data = json.load(f)
data['inbounds'] = [ib for ib in data.get('inbounds', []) if ib.get('tag') != 'hy2-direct']
data['inbounds'].append({
    'tag': 'hy2-direct',
    'listen': '0.0.0.0',
    'port': int('$hy2_port'),
    'protocol': 'hysteria',
    'settings': {'version': 2, 'clients': [{'auth': '$hy2_pass'}]},
    'streamSettings': {
        'network': 'hysteria',
        'security': 'tls',
        'hysteriaSettings': {'version': 2},
        'tlsSettings': {
            'alpn': ['h3'],
            'certificates': [{'certificateFile': '/opt/kkk_quick/xray/hy2.crt', 'keyFile': '/opt/kkk_quick/xray/hy2.key'}]
        }
    }
})
with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
    pkill -f xray
    nohup /opt/kkk_quick/xray/xray run -config "$cfg_json" >/dev/null 2>&1 &
    
    echo "hysteria2://${hy2_pass}@${ipv4}:${hy2_port}?alpn=h3&pinSHA256=${cert_pin}#Hy2-v4-Backup" >> "${xray_dir}/nodes.txt"
    sync_to_static_web "$xray_dir"
    echo "Hysteria 2 节点部署成功！"
    read -p "按回车键返回..."
}


# ==============================================================================
# 4. 系统优化与运维管理模块 (WARP路由、BBR加速)
# ==============================================================================

# 配置 Cloudflare WARP 灵活路由与分流 (已规范子菜单返回文案)
configure_warp_routing() {
    local cfg_json="/opt/kkk_quick/xray/config.json"
    if [ ! -f "$cfg_json" ]; then
        echo "未找到 Xray 配置文件！"
        read -p "按回车键返回..."
        return
    fi
    
    if ! command -v warp-cli &>/dev/null; then
        apt update && apt install -y cloudflare-warp >/dev/null 2>&1 || true
    fi
    systemctl enable --now warp-svc >/dev/null 2>&1
    warp-cli registration new >/dev/null 2>&1 || true
    warp-cli mode proxy >/dev/null 2>&1
    warp-cli proxy port 40000 >/dev/null 2>&1
    warp-cli connect >/dev/null 2>&1

    while true; do
        clear
        echo "=========================================================="
        echo "        Cloudflare WARP 灵活路由与分流管理菜单"
        echo "=========================================================="
        echo "1. 自定义添加指定域名/应用走 WARP"
        echo "2. 切换为【全局模式】(所有外网流量走 WARP)"
        echo "3. 查看当前 WARP 路由状态"
        echo "4. 关闭并停用 WARP 代理 (恢复直连)"
        echo "0. 返回菜单"
        echo "=========================================================="
        read -p "请选择操作 [1-4, 0]: " warp_choice

        case "$warp_choice" in
            1)
                read -p "请输入需要走 WARP 的域名或关键字: " user_domains
                [ -z "$user_domains" ] && continue
                python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    data = json.load(f)
outbounds = data.get('outbounds', [])
if not any(ob.get('tag') == 'warp-out' for ob in outbounds):
    outbounds.append({'tag': 'warp-out', 'protocol': 'socks', 'settings': {'servers': [{'address': '127.0.0.1', 'port': 40000}]}})
data['outbounds'] = outbounds
routing = data.get('routing', {'domainStrategy': 'AsIs', 'rules': []})
rules = routing.get('rules', [])
new_domains = '$user_domains'.split()
custom_rule = next((r for r in rules if r.get('tag') == 'custom-warp-rule'), None)
if not custom_rule:
    rules.insert(0, {'type': 'field', 'outboundTag': 'warp-out', 'domain': new_domains, 'tag': 'custom-warp-rule'})
else:
    custom_rule['domain'] = list(set(custom_rule.get('domain', []) + new_domains))
routing['rules'] = rules
data['routing'] = routing
with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
                pkill -f xray || true
                nohup "$(dirname "$cfg_json")/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
                echo "✅ 自定义域名规则已成功注入并生效！"
                read -p "按回车键继续..." < /dev/tty
                ;;
            2)
                python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    data = json.load(f)
outbounds = data.get('outbounds', [])
if not any(ob.get('tag') == 'warp-out' for ob in outbounds):
    outbounds.append({'tag': 'warp-out', 'protocol': 'socks', 'settings': {'servers': [{'address': '127.0.0.1', 'port': 40000}]}})
data['outbounds'] = outbounds
data['routing'] = {
    'domainStrategy': 'AsIs',
    'rules': [
        { 'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:private', 'geoip:cn'] },
        { 'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:cn'] },
        { 'type': 'field', 'outboundTag': 'warp-out', 'network': 'tcp,udp' }
    ]
}
with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
                pkill -f xray || true
                nohup "$(dirname "$cfg_json")/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
                echo "✅ 已成功切换为【全局 WARP 模式】！"
                read -p "按回车键继续..." < /dev/tty
                ;;
            3)
                echo ""
                warp-cli status
                echo ""
                read -p "按回车键继续..." < /dev/tty
                ;;
            4)
                warp-cli disconnect >/dev/null 2>&1 || true
                systemctl stop warp-svc >/dev/null 2>&1 || true
                echo "✅ WARP 已关闭。"
                read -p "按回车键继续..." < /dev/tty
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

# BBR 拥塞控制管理 (已规范子菜单返回文案)
_bbr_check() {
    [ "$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')" = "bbr" ]
}

manage_bbr() {
    while true; do
        clear
        echo "========================================"
        echo "           BBR 拥塞控制管理             "
        echo "========================================"
        if _bbr_check; then echo "当前状态: [ 🔥 BBR 已开启 ]"; else echo "当前状态: [ ⏳ BBR 未开启 ]"; fi
        echo "----------------------------------------"
        echo "1. 开启 BBR"
        echo "2. 关闭 BBR"
        echo "0. 返回菜单"
        echo "========================================"
        read -p "请输入选项 [1-2, 0]: " sub_choice
        
        case "$sub_choice" in
            1)
                echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-bbr.conf
                echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
                sysctl --system >/dev/null 2>&1
                echo "BBR 已成功开启！"
                read -p "按回车继续..." < /dev/tty
                ;;
            2)
                rm -f /etc/sysctl.d/99-bbr.conf
                sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
                echo "BBR 已关闭，恢复为 cubic。"
                read -p "按回车继续..." < /dev/tty
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项，请重新输入。"
                sleep 1
                ;;
        esac
    done
}


# ==============================================================================
# 5. 主菜单入口及模式分发逻辑
# ==============================================================================
clear
echo "=========================================================="
echo "         yuzhou 多协议代理节点快捷部署与管理工具(梭哈改)              "
echo "=========================================================="
echo "==本脚本改编至梭哈脚本，加入作者通过ai 加入了自己需要的的功能=="
echo "1. 加固 VPS 主机系统"
echo "2. 梭哈模式 (自动生成 VLESS + Trojan 443 TLS 优选节点)"
echo "3. 安装服务 (自定义域名绑定固定 Argo 隧道)"
echo "4. 卸载服务"
echo "5. 清空缓存"
echo "6. 额外增加 IPv6 SS 共存部署"
echo "7. 额外增加 Hysteria 2 直连备用节点"
echo "8. 配置 Cloudflare WARP 灵活路由与分流"
echo "9. 开启 BBR 加速"
echo "10.绑定域名 "
echo "0. 退出脚本"
echo "=========================================================="
read -p "请选择运行模式 (默认1): " mode
[ -z "$mode" ] && mode=1

case "$mode" in
    1)
        action_init_security
        ;;
    2)
        read -p "请选择 Argo 连接模式 IPv4 或 IPv6 (输入 4 或 6，默认 4): " ips
        [ -z "$ips" ] && ips=4
        isp=$(curl -$ips -s --connect-timeout 2 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')
        pkill -f xray >/dev/null 2>&1
        pkill -f cloudflared-linux >/dev/null 2>&1
        quicktunnel
        ;;
    3)
        read -p "请选择 Argo 连接模式 IPv4 或 IPv6 (输入 4 或 6，默认 4): " ips
        [ -z "$ips" ] && ips=4
        isp=$(curl -$ips -s --connect-timeout 2 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')
        installtunnel
        cat /opt/kkk/v2ray.txt
        echo "服务安装完成，日常管理请运行命令: kkk"
        ;;
    4)
        systemctl stop cloudflared.service xray.service kkk-quick.service 2>/dev/null || true
        systemctl disable cloudflared.service xray.service kkk-quick.service 2>/dev/null || true
        pkill -f "http.server" >/dev/null 2>&1
        rm -rf /opt/kkk /opt/kkk_quick /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /lib/systemd/system/kkk-quick.service /usr/bin/kkk ~/.cloudflared /etc/kkk_sub_port /etc/kkk_sub_token /var/www/kkk_sub
        systemctl --system daemon-reload
        echo "所有服务与缓存已彻底卸载清理完成！"
        ;;
    5)
        pkill -f xray >/dev/null 2>&1
        pkill -f cloudflared-linux >/dev/null 2>&1
        pkill -f "http.server" >/dev/null 2>&1
        rm -rf /opt/kkk_quick/nodes.txt /opt/kkk_quick/sub.txt /opt/kkk_quick/clash.yaml
        echo "缓存已清空！"
        ;;
    6)
        install_ipv6_ss
        ;;
    7)
        install_hy2_direct
        ;;
    8)
        configure_warp_routing
        ;;
    9)
        manage_bbr
        ;;
    10)
        bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/acme.sh)
        ;;  
    *)
        echo "已成功退出脚本。"
        exit 0
        ;;
esac
