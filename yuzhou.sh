#!/bin/bash
# onekey suoha
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
    echo "当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配"
    echo "默认使用APT包管理器"
    n=0
fi
if [ -z $(type -P unzip) ]
then
    ${linux_update[$n]}
    ${linux_install[$n]} unzip
fi
if [ -z $(type -P curl) ]
then
    ${linux_update[$n]}
    ${linux_install[$n]} curl
fi
if [ -z $(type -P python3) ]
then
    ${linux_update[$n]}
    ${linux_install[$n]} python3
fi
if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') != "Alpine" ]
then
    if [ -z $(type -P systemctl) ]
    then
        ${linux_update[$n]}
        ${linux_install[$n]} systemctl
    fi
fi

function get_server_ip(){
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
    if [ -z "$ip" ]; then
        ip=$(curl -s6 --connect-timeout 2 https://api64.ipify.org 2>/dev/null | tr -d '\n\r ')
    fi
    echo "$ip"
}

function get_server_ipv6(){
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

function get_or_create_sub_port(){
    local port_file="/etc/suoha_sub_port"
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

function get_or_create_sub_token(){
    local token_file="/etc/suoha_sub_token"
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

function sync_to_static_web(){
    local src_dir="$1"
    local static_dir="/var/www/suoha_sub"
    mkdir -p "$static_dir" >/dev/null 2>&1
    [ -f "${src_dir}/nodes.txt" ] && cp -f "${src_dir}/nodes.txt" "${static_dir}/nodes.txt" 2>/dev/null
    [ -f "${src_dir}/sub.txt" ] && cp -f "${src_dir}/sub.txt" "${static_dir}/sub.txt" 2>/dev/null
    [ -f "${src_dir}/clash.yaml" ] && cp -f "${src_dir}/clash.yaml" "${static_dir}/clash.yaml" 2>/dev/null
}

function quicktunnel(){
mkdir -p /opt/suoha_quick >/dev/null 2>&1
cd /opt/suoha_quick

# 精确清理旧的后台快速模式进程，严禁使用盲目匹配
if [ -f "/opt/suoha_quick/xray.pid" ]; then
    kill -9 $(cat /opt/suoha_quick/xray.pid) >/dev/null 2>&1
    rm -f /opt/suoha_quick/xray.pid
fi
if [ -f "/opt/suoha_quick/cf_vl.pid" ]; then
    kill -9 $(cat /opt/suoha_quick/cf_vl.pid) >/dev/null 2>&1
    rm -f /opt/suoha_quick/cf_vl.pid
fi
if [ -f "/opt/suoha_quick/cf_tr.pid" ]; then
    kill -9 $(cat /opt/suoha_quick/cf_tr.pid) >/dev/null 2>&1
    rm -f /opt/suoha_quick/cf_tr.pid
fi

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
    echo arm64
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
    ;;
    armv7l )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux
    ;;
    * )
    echo "当前架构$(uname -m)没有适配"
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

# 精确记录 Xray PID
/opt/suoha_quick/xray/xray run -config /opt/suoha_quick/xray/config.json >/dev/null 2>&1 &
echo $! > /opt/suoha_quick/xray.pid

# 精确记录 cloudflared 实例 PID
/opt/suoha_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
echo $! > /opt/suoha_quick/cf_vl.pid

/opt/suoha_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
echo $! > /opt/suoha_quick/cf_tr.pid

sleep 2

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
    [ -f "/opt/suoha_quick/cf_vl.pid" ] && kill -9 $(cat /opt/suoha_quick/cf_vl.pid) >/dev/null 2>&1
    [ -f "/opt/suoha_quick/cf_tr.pid" ] && kill -9 $(cat /opt/suoha_quick/cf_tr.pid) >/dev/null 2>&1
    rm -rf argo_vless.log argo_trojan.log
    clear
    echo "argo 获取超时，正在重新尝试建立双隧道..."
    /opt/suoha_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
    echo $! > /opt/suoha_quick/cf_vl.pid
    /opt/suoha_quick/cloudflared-linux tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
    echo $! > /opt/suoha_quick/cf_tr.pid
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
if [ -z "$server_ip" ]; then
    server_ip="$argo_vl"
fi

sub_port=$(get_or_create_sub_port)
sub_token=$(get_or_create_sub_token)

# 将文件同步到带有随机 Token 的安全加密子目录中
secure_web_dir="/var/www/suoha_sub/${sub_token}"
mkdir -p "$secure_web_dir" >/dev/null 2>&1
[ -f "/opt/suoha_quick/nodes.txt" ] && cp -f /opt/suoha_quick/nodes.txt "${secure_web_dir}/nodes.txt"
[ -f "/opt/suoha_quick/sub.txt" ] && cp -f /opt/suoha_quick/sub.txt "${secure_web_dir}/sub.txt"
[ -f "/opt/suoha_quick/clash.yaml" ] && cp -f /opt/suoha_quick/clash.yaml "${secure_web_dir}/clash.yaml"

start_sub_server "/var/www/suoha_sub" "$sub_port"

# ==================== 👇 完美修复版：固化变量并实现开机自动恢复 👇 ====================

cat > /opt/suoha_quick/start.sh << EOF
#!/bin/bash
cd /opt/suoha_quick || exit
[ -f "xray.pid" ] && kill -9 \$(cat xray.pid) 2>/dev/null
[ -f "cf_vl.pid" ] && kill -9 \$(cat cf_vl.pid) 2>/dev/null
[ -f "cf_tr.pid" ] && kill -9 \$(cat cf_tr.pid) 2>/dev/null
rm -rf argo_vless.log argo_trojan.log

# 1. 启动 Xray
./xray/xray run -config xray/config.json >/dev/null 2>&1 &
echo \$! > xray.pid

# 2. 启动双协议 Argo 临时隧道 (固化当时生成的端口: $port_vless 和 $port_trojan)
./cloudflared-linux tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
echo \$! > /opt/suoha_quick/cf_vl.pid

./cloudflared-linux tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
echo \$! > /opt/suoha_quick/cf_tr.pid

# 3. 循环等待新域名生成
n=0
while [ \$n -lt 40 ]; do
    n=\$[ \$n + 1 ]
    argo_vl=\$(grep -oE "https://[a-zA-Z0-9.-]+\\.trycloudflare\\.com" argo_vless.log | head -n 1 | awk -F// '{print \$2}')
    argo_tr=\$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\\.com" argo_trojan.log | head -n 1 | awk -F// '{print \$2}')
    if [[ -n "\$argo_vl" && -n "\$argo_tr" ]]; then
        break
    fi
    sleep 1
done

# 4. 如果成功获取新域名，重写 nodes.txt 并刷新订阅
if [[ -n "\$argo_vl" && -n "\$argo_tr" ]]; then
    # 重新生成 nodes.txt (基于当前固定的 uuid 和 urlpath)
    > nodes.txt
    
    # 重新拼接 VLESS 节点
    vless_domains=("\$argo_vl" "cf.090227.xyz" "cloudflare.182682.xyz")
    vless_labels=("默认Argo" "优选cf.090227" "优选182682")
    for idx in "\${!vless_domains[@]}"; do
        d="\${vless_domains[\$idx]}"
        l="\${vless_labels[\$idx]}"
        echo "vless://$uuid@\${d}:443?encryption=none&security=tls&sni=\$argo_vl&type=ws&host=\$argo_vl&path=%2F$urlpath_vless#$node_tag-VLESS-\$l-443" >> nodes.txt
    done

    # 重新拼接 Trojan 节点
    trojan_domains=("\$argo_tr" "cf.090227.xyz" "cloudflare.182682.xyz")
    trojan_labels=("默认Argo" "优选cf.090227" "优选182682")
    for idx in "\${!trojan_domains[@]}"; do
        d="\${trojan_domains[\$idx]}"
        l="\${trojan_labels[\$idx]}"
        echo "trojan://$uuid@\${d}:443?security=tls&sni=\$argo_tr&type=ws&host=\$argo_tr&path=%2F$urlpath_trojan#$node_tag-Trojan-\$l-443" >> nodes.txt
    done

    # 生成 Base64 订阅
    base64 -w 0 nodes.txt > sub.txt 2>/dev/null || base64 nodes.txt | tr -d '\n' > sub.txt
    
    # 同步静态 Web 目录
    # 同步到带安全 Token 的子目录（确保重启后 Token 和路径依然一致）
    sub_token=$(cat /etc/suoha_sub_token 2>/dev/null || echo "sub-default")
    secure_web_dir="/var/www/suoha_sub/\$sub_token"
    mkdir -p "\$secure_web_dir"
    cp -f sub.txt "\$secure_web_dir/sub.txt"
    cp -f clash.yaml "\$secure_web_dir/clash.yaml"
fi

# 5. 确保开机时恢复 Python 订阅网页服务
python3 -m http.server $sub_port --directory /var/www/suoha_sub >/dev/null 2>&1 &
EOF

chmod +x /opt/suoha_quick/start.sh

# 注册 Systemd 开机自启服务
cat > /lib/systemd/system/suoha-quick.service <<EOF
[Unit]
Description=Suoha Quick Tunnel Auto Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/bin/bash /opt/suoha_quick/start.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable suoha-quick.service >/dev/null 2>&1

# ==================== 👆 替换结束 👆 ====================



sub_online_url="http://${server_ip}:${sub_port}/${sub_token}/sub.txt"
clash_online_url="http://${server_ip}:${sub_port}/${sub_token}/clash.yaml"

cat>v2ray.txt<<EOF
======================== 一键梭哈 443 TLS 节点列表 ========================
$(cat nodes.txt)

端口替换提示:
443 端口可根据需要改为 CF 其它 TLS 端口: 2053, 2083, 2087, 2096, 8443

======================== 客户端订阅及导入链接 ========================
本机固定订阅服务端口: ${sub_port} (已永久保存，重新梭哈无需重新导入客户端)

1. 通用订阅链接 (支持 v2rayN / NekoBox / Shadowrocket):
${sub_online_url}

2. v2rayN / NekoBox 一键导入协议链接:
sub://${sub_online_url}

3. Clash / Clash.Meta / Mihomo 一键导入配置:
clash://install-config?url=${clash_online_url}

4. Clash 在线配置文件直链:
${clash_online_url}

持久订阅存储目录: /var/www/suoha_sub/
=====================================================================
EOF

cat v2ray.txt
echo -e "\n信息已经保存在 /opt/suoha_quick/v2ray.txt,再次查看请运行 cat /opt/suoha_quick/v2ray.txt"
}

function install_ipv6_ss(){
    clear
    echo "正在检测机器公网 IPv6 地址..."
    local ipv6_addr
    ipv6_addr=$(get_server_ipv6)

    if [ -z "$ipv6_addr" ]; then
        echo "未检测到可用的公网 IPv6 地址，无法部署 IPv6 直连 SS 节点！"
        read -p "按回车键返回主菜单..."
        return
    fi

    echo "检测到公网 IPv6: $ipv6_addr"

    local xray_dir=""
    local is_installed_mode=0
    local cfg_json=""
    local xray_bin=""

    if [ -f "/opt/suoha/config.json" ]; then
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
        echo "未检测到正在运行的 Xray 服务，请先执行【1.梭哈模式】或【2.安装服务】！"
        read -p "按回车键返回主菜单..."
        return
    fi

    local ss_port=$[$RANDOM%10000+30000]
    local ss_password=$(cat /proc/sys/kernel/random/uuid | awk -F- '{print $1$2}')
    local ss_method="aes-128-gcm"

    echo "正在注入 IPv6 Shadowsocks 节点 (端口: $ss_port, 加密: $ss_method)..."

    # 使用 Python 安全操作 JSON，杜绝写入截断
    python3 -c "
import json, sys

cfg_file = '$cfg_json'
try:
    with open(cfg_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    # 移除已有的 ss-ipv6，保留原本的所有 vless 和 trojan 入站
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
        echo "注入 Xray 配置失败，请检查 python3 环境！"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 只精准重启 Xray 进程，严禁使用盲目 pkill，防止杀掉正在连接的 cloudflared 隧道
    if [ $is_installed_mode -eq 1 ]; then
        if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
        then
            /etc/local.d/xray.start >/dev/null 2>&1
        else
            systemctl restart xray.service >/dev/null 2>&1
        fi
    else
        # 针对梭哈模式，只精准击杀记录的 xray PID，绝不触碰 cloudflared
        if [ -f "/opt/suoha_quick/xray.pid" ]; then
            kill -9 $(cat /opt/suoha_quick/xray.pid) >/dev/null 2>&1
            rm -f /opt/suoha_quick/xray.pid
        else
            kill -9 $(pgrep -f "/opt/suoha_quick/xray/xray") >/dev/null 2>&1
        fi
        nohup $xray_bin run -config $cfg_json >/dev/null 2>&1 &
        echo $! > /opt/suoha_quick/xray.pid
    fi

    local ss_user_info="${ss_method}:${ss_password}"
    local ss_base64
    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
    then
        ss_base64=$(echo -n "$ss_user_info" | base64 | tr -d '\n')
    else
        ss_base64=$(echo -n "$ss_user_info" | base64 -w 0)
    fi
    local ss_link="ss://${ss_base64}@[${ipv6_addr}]:${ss_port}#IPv6-SS-Direct"

    # 读取旧 nodes.txt，去除旧 SS 节点后安全追加，绝不破坏原有节点
    local work_nodes="${xray_dir}/nodes.txt"
    touch "$work_nodes"
    sed -i '/IPv6-SS-Direct/d' "$work_nodes"
    echo "$ss_link" >> "$work_nodes"

    # 追加到 clash.yaml
    local clash_file="${xray_dir}/clash.yaml"
    if [ -f "$clash_file" ]; then
        python3 -c "
yaml_file = '$clash_file'
try:
    with open(yaml_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    filtered = []
    skip = False
    for l in lines:
        if 'name: \"IPv6-SS-Direct\"' in l:
            skip = True
            continue
        if skip and l.startswith('  - name:'):
            skip = False
        if not skip and '      - \"IPv6-SS-Direct\"' not in l:
            filtered.append(l)
    
    new_lines = []
    proxy_inserted = False
    group_inserted = False
    for line in filtered:
        if line.strip().startswith('proxy-groups:') and not proxy_inserted:
            new_lines.append('  - name: \"IPv6-SS-Direct\"\n')
            new_lines.append('    type: ss\n')
            new_lines.append('    server: \"${ipv6_addr}\"\n')
            new_lines.append('    port: ${ss_port}\n')
            new_lines.append('    cipher: ${ss_method}\n')
            new_lines.append('    password: \"${ss_password}\"\n')
            new_lines.append('    udp: true\n')
            proxy_inserted = True
        if line.strip().startswith('rules:') and not group_inserted:
            new_lines.append('      - \"IPv6-SS-Direct\"\n')
            group_inserted = True
        new_lines.append(line)
    
    with open(yaml_file, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
except Exception:
    pass
"
    fi

    # 重新生成 Base64 订阅并同步
    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
    then
        base64 "$work_nodes" | tr -d '\n' > "${xray_dir}/sub.txt"
    else
        base64 -w 0 "$work_nodes" > "${xray_dir}/sub.txt"
    fi

    sync_to_static_web "$xray_dir"
# 1. 同步到带安全 Token 的子目录
            if [ -f "/etc/suoha_sub_token" ]; then
                local sub_token=$(cat /etc/suoha_sub_token 2>/dev/null)
                local secure_web_dir="/var/www/suoha_sub/${sub_token}"
                if [ -d "$secure_web_dir" ]; then
                    cp -f "${xray_dir}/sub.txt" "${secure_web_dir}/sub.txt" 2>/dev/null
                    cp -f "${xray_dir}/clash.yaml" "${secure_web_dir}/clash.yaml" 2>/dev/null
                    cp -f "${xray_dir}/nodes.txt" "${secure_web_dir}/nodes.txt" 2>/dev/null
                fi
            fi

            # 2. 将 SS 节点持久化写入开机自启脚本 start.sh，防止重启丢失
            if [ $is_installed_mode -eq 0 ] && [ -f "/opt/suoha_quick/start.sh" ]; then
                if ! grep -q "IPv6-SS-Direct" /opt/suoha_quick/start.sh; then
                    cat >> /opt/suoha_quick/start.sh << EOT

# --- 自动恢复 IPv6 SS 直连节点 ---
if [[ -n "\$ss_link" ]] || true; then
    ss_port="${ss_port}"
    ss_method="${ss_method}"
    ss_password="${ss_password}"
    ipv6_addr="${ipv6_addr}"
    ss_user_info="\${ss_method}:\${ss_password}"
    if [ \$(grep -i PRETTY_NAME /etc/os-release | cut -d \\" -f2 | awk '{print \$1}') == "Alpine" ]; then
        ss_base64=\$(echo -n "\$ss_user_info" | base64 | tr -d '\\n')
    else
        ss_base64=\$(echo -n "\$ss_user_info" | base64 -w 0)
    fi
    ss_link="ss://\${ss_base64}@[\${ipv6_addr}]:\${ss_port}#IPv6-SS-Direct"
    
    echo "\$ss_link" >> nodes.txt
    
    # 重新生成 Base64 订阅并同步到安全 Token 目录
    base64 -w 0 nodes.txt > sub.txt 2>/dev/null || base64 nodes.txt | tr -d '\\n' > sub.txt
    sub_token=$(cat /etc/suoha_sub_token 2>/dev/null || echo "sub-default")
    secure_web_dir="/var/www/suoha_sub/\$sub_token"
    mkdir -p "\$secure_web_dir"
    cp -f sub.txt "\$secure_web_dir/sub.txt"
    cp -f clash.yaml "\$secure_web_dir/clash.yaml"
fi
EOT
                fi
            fi
    # 2. 在它下面紧接着加上这一段（同步到带 Token 的加密子目录）
    if [ -f "/etc/suoha_sub_token" ]; then
        local sub_token=$(cat /etc/suoha_sub_token 2>/dev/null)
        local secure_web_dir="/var/www/suoha_sub/${sub_token}"
        if [ -d "$secure_web_dir" ]; then
            cp -f "${xray_dir}/sub.txt" "${secure_web_dir}/sub.txt" 2>/dev/null
            cp -f "${xray_dir}/clash.yaml" "${secure_web_dir}/clash.yaml" 2>/dev/null
            cp -f "${xray_dir}/nodes.txt" "${secure_web_dir}/nodes.txt" 2>/dev/null
        fi
    fi

    local sub_port=$(get_or_create_sub_port)
    local server_ip=$(get_server_ip)
    local sub_token=$(get_or_create_sub_token)
    local sub_online_url="http://${server_ip}:${sub_port}/${sub_token}/sub.txt"

    clear
    echo "=========================================================="
    echo "       IPv6 Shadowsocks 直连节点共存部署成功！            "
    echo "=========================================================="
    echo "SS 直连链接:"
    echo "$ss_link"
    echo ""
    echo "原 Argo 临时隧道依然持续运行，所有节点完好无损！"
    echo "客户端直接点击【更新订阅】即可同步获取全部节点："
    echo "订阅地址: ${sub_online_url}"
    echo "=========================================================="
    echo ""
    read -p "按回车键返回主菜单..."
}

install_hy2_direct() {
    echo "=========================================================="
    echo "正在部署 Hysteria 2 直连备用节点 (防丢失与自愈增强版)..."
    echo "=========================================================="

    local xray_dir="/opt/suoha_quick"
    local xray_sub_dir="/opt/suoha_quick/xray"
    local cfg_json="/opt/suoha_quick/xray/config.json"
    
    if [ ! -f "$cfg_json" ]; then
        echo "[错误] 未找到 Xray 配置文件: $cfg_json，请先运行梭哈模式！"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 1. 智能检测 IPv4 和 IPv6 地址
    local ipv4=""
    local ipv6=""
    
    ipv4=$(curl -4 -s --connect-timeout 3 ip.sb || ip -4 addr show scope global 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    ipv6=$(curl -6 -s --connect-timeout 3 ip.sb || ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -v 'host' | awk '{print $2}' | cut -d/ -f1 | head -n1)

    if [ -z "$ipv4" ] && command -v get_server_ip &>/dev/null; then
        ipv4=$(get_server_ip)
    fi

    echo "--------------------------------------------------"
    echo "📊 网络栈检测结果："
    echo " - IPv4 地址: ${ipv4:-未检测到（单IPv6环境）}"
    echo " - IPv6 地址: ${ipv6:-未检测到（单IPv4环境）}"
    echo "--------------------------------------------------"

    # 2. 生成随机 UDP 端口和统一密码
    local hy2_port=$((RANDOM % 10000 + 10000))
    local hy2_pass=$(cat /proc/sys/kernel/random/uuid)

    # 3. 证书处理：仅当不存在时生成一次，确保指纹永久固定！
    mkdir -p "$xray_sub_dir"
    if [ ! -f "${xray_sub_dir}/hy2.crt" ] || [ ! -f "${xray_sub_dir}/hy2.key" ]; then
        openssl ecparam -genkey -name prime256v1 -out "${xray_sub_dir}/hy2.key" 2>/dev/null
        openssl req -new -x509 -days 3650 -key "${xray_sub_dir}/hy2.key" -out "${xray_sub_dir}/hy2.crt" -subj "/CN=bing.com" 2>/dev/null
    fi

    # 4. 严格提取自签证书的 SHA-256 指纹
    local cert_pin=""
    if [ -f "${xray_sub_dir}/hy2.crt" ]; then
        cert_pin=$(openssl x509 -in "${xray_sub_dir}/hy2.crt" -noout -sha256 -fingerprint 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    fi

    # 5. 防火墙实时放行 UDP 端口
    if [ -n "$ipv4" ]; then
        iptables -A INPUT -p udp --dport ${hy2_port} -j ACCEPT 2>/dev/null || true
    fi
    if [ -n "$ipv6" ]; then
        ip6tables -A INPUT -p udp --dport ${hy2_port} -j ACCEPT 2>/dev/null || true
    fi

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
                    'certificateFile': '/opt/suoha_quick/xray/hy2.crt',
                    'keyFile': '/opt/suoha_quick/xray/hy2.key'
                }]
            }
        }
    }
    data['inbounds'].append(hy2_ib)
    
    with open(cfg_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
    if [ $? -ne 0 ]; then
        echo "[错误] 写入 Xray 配置文件失败！"
        read -p "按回车键返回主菜单..."
        return
    fi

    # 精准重启 Xray 进程
    if [ -f "/opt/suoha_quick/xray.pid" ]; then
        kill -9 $(cat /opt/suoha_quick/xray.pid) >/dev/null 2>&1
        rm -f /opt/suoha_quick/xray.pid
    else
        kill -9 $(pgrep -f "/opt/suoha_quick/xray/xray") >/dev/null 2>&1
    fi
    nohup /opt/suoha_quick/xray/xray run -config "$cfg_json" >/dev/null 2>&1 &
    echo $! > /opt/suoha_quick/xray.pid

    # 7. 清理旧的 Hy2 节点后重新追加，并同步写入带 pinSHA256 的 clash.yaml
    local work_nodes="${xray_dir}/nodes.txt"
    local clash_file="${xray_dir}/clash.yaml"
    
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

    local links_summary=""
    
    if [ -n "$ipv4" ]; then
        local query_param="alpn=h3"
        if [ -n "$cert_pin" ]; then
            query_param="${query_param}&pinSHA256=${cert_pin}"
        else
            query_param="${query_param}&insecure=1"
        fi

        local hy2_link_v4="hysteria2://${hy2_pass}@${ipv4}:${hy2_port}?${query_param}#Hy2-v4-Backup"
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
        local query_param="alpn=h3"
        if [ -n "$cert_pin" ]; then
            query_param="${query_param}&pinSHA256=${cert_pin}"
        else
            query_param="${query_param}&insecure=1"
        fi

        local hy2_link_v6="hysteria2://${hy2_pass}@[${ipv6}]:${hy2_port}?${query_param}#Hy2-v6-Backup"
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

    # 8. 重新生成 Base64 订阅并同步到安全 Token 目录
    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]; then
        base64 "$work_nodes" | tr -d '\n' > "${xray_dir}/sub.txt"
    else
        base64 -w 0 "$work_nodes" > "${xray_dir}/sub.txt"
    fi

    sync_to_static_web "$xray_dir"
    if [ -f "/etc/suoha_sub_token" ]; then
        local sub_token=$(cat /etc/suoha_sub_token 2>/dev/null)
        local secure_web_dir="/var/www/suoha_sub/${sub_token}"
        if [ -d "$secure_web_dir" ]; then
            cp -f "${xray_dir}/sub.txt" "${secure_web_dir}/sub.txt" 2>/dev/null
            cp -f "${xray_dir}/clash.yaml" "${secure_web_dir}/clash.yaml" 2>/dev/null
            cp -f "${xray_dir}/nodes.txt" "${secure_web_dir}/nodes.txt" 2>/dev/null
        fi
    fi

    # 9. 智能更新开机脚本 start.sh（采用标记块覆盖，确保每次运行都能更新到最新逻辑）
    local start_script="/opt/suoha_quick/start.sh"
    if [ ! -f "$start_script" ]; then
        echo "#!/bin/bash" > "$start_script"
    fi

    # 用 Python 移除旧的 HY2 块（如果存在），防止死代码残留或无法更新
    python3 -c "
with open('$start_script', 'r', encoding='utf-8') as f:
    content = f.read()
import re
content = re.sub(r'# --- HY2 CONFIG START ---[\s\S]*?# --- HY2 CONFIG END ---', '', content)
with open('$start_script', 'w', encoding='utf-8') as f:
    f.write(content.strip() + '\n')
" 2>/dev/null || true

    # 写入最新的带防火墙放行、固定指纹及防重复清理机制的自愈逻辑
    cat >> "$start_script" << EOT

# --- HY2 CONFIG START ---
hy2_port="${hy2_port}"
hy2_pass="${hy2_pass}"

# 开机自动重新放行防火墙 UDP 端口
if command -v iptables &>/dev/null; then
    iptables -A INPUT -p udp --dport \${hy2_port} -j ACCEPT 2>/dev/null || true
fi
if command -v ip6tables &>/dev/null; then
    ip6tables -A INPUT -p udp --dport \${hy2_port} -j ACCEPT 2>/dev/null || true
fi

# 获取持久固定的证书指纹
cert_pin="\$(openssl x509 -in /opt/suoha_quick/xray/hy2.crt -noout -sha256 -fingerprint 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
v4="\$(curl -4 -s --connect-timeout 2 ip.sb || ip -4 addr show scope global 2>/dev/null | grep inet | awk '{print \$2}' | cut -d/ -f1 | head -n1)"
v6="\$(curl -6 -s --connect-timeout 2 ip.sb || ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -v 'host' | awk '{print \$2}' | cut -d/ -f1 | head -n1)"

# 清理 nodes.txt 和 clash.yaml 中旧的 Hy2 节点，防止重启导致重复堆积
sed -i '/Hy2-v4-Backup/d' nodes.txt 2>/dev/null || true
sed -i '/Hy2-v6-Backup/d' nodes.txt 2>/dev/null || true

if [ -f "clash.yaml" ]; then
    python3 -c "
with open('clash.yaml', 'r', encoding='utf-8') as f:
    content = f.read()
import re
content = re.sub(r'\n\s*-\s*name:\s*\"Hy2-v[46]-Backup\"[\s\S]*?(?=\n\s*-\s*name:|\nproxy-groups:|\Z)', '', content)
with open('clash.yaml', 'w', encoding='utf-8') as f:
    f.write(content)
" 2>/dev/null || true
fi

if [ -n "\$v4" ]; then
    echo "hysteria2://\${hy2_pass}@\${v4}:\${hy2_port}?alpn=h3&pinSHA256=\${cert_pin}#Hy2-v4-Backup" >> nodes.txt
    cat >> clash.yaml << 'EOF_YAML'

  - name: "Hy2-v4-Backup"
    type: hysteria2
    server: \${v4}
    port: \${hy2_port}
    password: \${hy2_pass}
    alpn: ["h3"]
    pinSHA256: \${cert_pin}
EOF_YAML
fi

if [ -n "\$v6" ]; then
    echo "hysteria2://\${hy2_pass}@[\${v6}]:\${hy2_port}?alpn=h3&pinSHA256=\${cert_pin}#Hy2-v6-Backup" >> nodes.txt
    cat >> clash.yaml << 'EOF_YAML'

  - name: "Hy2-v6-Backup"
    type: hysteria2
    server: \${v6}
    port: \${hy2_port}
    password: \${hy2_pass}
    alpn: ["h3"]
    pinSHA256: \${cert_pin}
EOF_YAML
fi

base64 -w 0 nodes.txt > sub.txt 2>/dev/null || base64 nodes.txt | tr -d '\\n' > sub.txt
sub_token=\$(cat /etc/suoha_sub_token 2>/dev/null || echo "sub-default")
secure_web_dir="/var/www/suoha_sub/\$sub_token"
mkdir -p "\$secure_web_dir"
cp -f sub.txt "\$secure_web_dir/sub.txt"
cp -f clash.yaml "\$secure_web_dir/clash.yaml"
cp -f nodes.txt "\$secure_web_dir/nodes.txt"
# --- HY2 CONFIG END ---
EOT

    echo "=========================================================="
    echo "✅ Hysteria 2 备用节点部署成功！已彻底解决重启失效与指纹丢失问题。"
    echo -e "📌 生成结果汇总:${links_summary}"
    echo "=========================================================="
    read -p "按回车键返回主菜单..."
}

configure_warp_routing() {
    local xray_dir="/opt/suoha_quick"
    local cfg_json="/opt/suoha_quick/xray/config.json"
    
    if [ ! -f "$cfg_json" ]; then
        echo "[错误] 未找到 Xray 配置文件: $cfg_json，请先运行梭哈模式！"
        read -p "按回车键返回主菜单..."
        return
    fi

    if ! command -v warp-cli &>/dev/null; then
        echo "=========================================================="
        echo "正在首次安装并配置 Cloudflare WARP 客户端..."
        echo "=========================================================="
        apt update && apt install -y curl gnupg lsb-release >/dev/null 2>&1
        mkdir -p /usr/share/keyrings

        if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg -o /usr/share/keyrings/cloudflare-warp-archive-keyring.asc; then
            echo "[错误] 无法下载 Cloudflare GPG 密钥！"
            read -p "按回车键返回主菜单..."
            return
        fi

        if [ ! -f "/usr/share/keyrings/cloudflare-warp-archive-keyring.asc" ]; then
            echo "[错误] GPG 密钥文件保存失败！"
            read -p "按回车键返回主菜单..."
            return
        fi

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.asc] https://pkg.cloudflareclient.com $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/cloudflare-warp.list >/dev/null
        
        apt update && apt install -y cloudflare-warp || {
            echo "[错误] WARP 客户端包安装失败！"
            read -p "按回车键返回主菜单..."
            return
        }
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
        echo "1. 自定义添加指定域名/应用走 WARP (交互式输入)"
        echo "2. 切换为【全局模式】：所有外网流量强制走 WARP"
        echo "3. 查看当前 WARP 路由状态"
        echo "4. 关闭并停用 WARP 代理（恢复默认直连路由）"
        echo "0. 返回上级主菜单"
        echo "=========================================================="
        read -p "请选择操作 [0-4]: " warp_choice

        case "$warp_choice" in
            1)
                echo ""
                echo "请输入需要走 WARP 的域名或关键字（多个域名请用空格隔开）"
                echo "例如: openai.com chatgpt.com claude.ai t.me"
                read -p "输入域名: " user_domains
                
                if [ -z "$user_domains" ]; then
                    echo "输入为空，取消操作。"
                    sleep 1
                    continue
                fi

                python3 -c "
import json
cfg_file = '$cfg_json'
with open(cfg_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

outbounds = data.get('outbounds', [])
if not any(ob.get('tag') == 'warp-out' for ob in outbounds):
    outbounds.append({
        'tag': 'warp-out',
        'protocol': 'socks',
        'settings': {'servers': [{'address': '127.0.0.1', 'port': 40000}]}
    })
data['outbounds'] = outbounds

routing = data.get('routing', {'domainStrategy': 'AsIs', 'rules': []})
rules = routing.get('rules', [])

custom_rule = None
for r in rules:
    if r.get('tag') == 'custom-warp-rule':
        custom_rule = r
        break

new_domains = '$user_domains'.split()
if not custom_rule:
    custom_rule = {
        'type': 'field',
        'outboundTag': 'warp-out',
        'domain': new_domains,
        'tag': 'custom-warp-rule'
    }
    rules.insert(0, custom_rule)
else:
    existing_domains = custom_rule.get('domain', [])
    for d in new_domains:
        if d not in existing_domains:
            existing_domains.append(d)
    custom_rule['domain'] = existing_domains

routing['rules'] = rules
data['routing'] = routing

with open(cfg_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
                pkill -f xray || true
                nohup "${xray_dir}/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
                echo $! > "${xray_dir}/xray.pid"
                echo "✅ 自定义域名规则已成功注入并生效！"
                read -p "按回车键继续..."
                ;;
            2)
                echo "正在切换为全局 WARP 模式..."
                python3 -c "
import json
cfg_file = '$cfg_json'
with open(cfg_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

outbounds = data.get('outbounds', [])
if not any(ob.get('tag') == 'warp-out' for ob in outbounds):
    outbounds.append({
        'tag': 'warp-out',
        'protocol': 'socks',
        'settings': {'servers': [{'address': '127.0.0.1', 'port': 40000}]}
    })
data['outbounds'] = outbounds

routing = {
    'domainStrategy': 'AsIs',
    'rules': [
        { 'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:private', 'geoip:cn'] },
        { 'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:cn'] },
        { 'type': 'field', 'outboundTag': 'warp-out', 'network': 'tcp,udp' }
    ]
}
data['routing'] = routing

with open(cfg_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
                pkill -f xray || true
                nohup "${xray_dir}/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
                echo $! > "${xray_dir}/xray.pid"
                echo "✅ 已成功切换为【全局 WARP 模式】（国内直连，其余全走 WARP）！"
                read -p "按回车键继续..."
                ;;
            3)
                echo ""
                echo "📊 当前 WARP 客户端状态："
                warp-cli status
                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                echo "正在关闭 WARP 代理并彻底清理所有相关路由规则..."
                warp-cli disconnect >/dev/null 2>&1 || true
                systemctl stop warp-svc >/dev/null 2>&1 || true
                
                # 增强版彻底清理逻辑：只要 outboundTag 是 warp-out 或标签带 warp，全部抹除
                python3 -c "
import json
cfg_file = '$cfg_json'
try:
    with open(cfg_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    # 1. 彻底清除 outbounds 中的 warp-out
    if 'outbounds' in data:
        data['outbounds'] = [ob for ob in data['outbounds'] if ob.get('tag') != 'warp-out']
    
    # 2. 彻底清除 routing 中所有与 warp 相关的规则
    if 'routing' in data and 'rules' in data['routing']:
        clean_rules = []
        for r in data['routing']['rules']:
            outbound_tag = r.get('outboundTag', '')
            rule_tag = r.get('tag', '')
            # 无论是自定义分流规则、全局兜底规则，只要 outboundTag 是 warp-out 或 tag 包含 warp，统统剔除
            if outbound_tag == 'warp-out' or 'warp' in rule_tag.lower():
                continue
            clean_rules.append(r)
        data['routing']['rules'] = clean_rules
    
    with open(cfg_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
    print('✅ 配置文件清理成功')
except Exception as e:
    print(f'Error: {e}')
"
                # 重启 Xray 核心
                pkill -f xray || true
                nohup "${xray_dir}/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
                echo $! > "${xray_dir}/xray.pid"

                # 从 start.sh 移除自启恢复逻辑
                local start_script="${xray_dir}/start.sh"
                if [ -f "$start_script" ]; then
                    python3 -c "
with open('$start_script', 'r', encoding='utf-8') as f:
    content = f.read()
import re
content = re.sub(r'# --- 自动恢复 WARP 代理服务 ---[\s\S]*?warp-cli connect >/dev/null 2>&1\n?', '', content)
with open('$start_script', 'w', encoding='utf-8') as f:
    f.write(content)
" 2>/dev/null || true
                fi

                echo "✅ WARP 已成功关闭，Xray 路由已完全恢复为纯净直连状态！"
                read -p "按回车键继续..."
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
# ==========================================
# 功能函数 1: 系统初始化与安全加固 (含修改主机名)
# ==========================================
action_init_security() {
    echo -e "\n===================================="
    echo "  开始执行：系统初始化与安全加固"
    echo "===================================="

    # 0. 修改主机名
    echo -e "\n--- [步骤 0/4] 修改主机名 ---"
    read -p "请输入新的主机名 (直接回车保持当前 [$CURRENT_HOSTNAME]): " NEW_HOSTNAME < /dev/tty
    if [ -n "$NEW_HOSTNAME" ]; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        CURRENT_HOSTNAME="$NEW_HOSTNAME"
        echo "[+] 主机名已成功修改为: $NEW_HOSTNAME"
    else
        echo "[+] 保持当前主机名不变: $CURRENT_HOSTNAME"
    fi

    # 1. 创建用户
    echo -e "\n--- [步骤 1/4] 创建系统新用户 ---"
    RANDOM_USER="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    while true; do
        read -p "请输入要创建的新用户名 (直接回车将随机生成 [$RANDOM_USER]): " NEW_USER < /dev/tty
        if [ -z "$NEW_USER" ]; then
            NEW_USER="$RANDOM_USER"
            echo "[+] 已自动随机生成用户名: $NEW_USER"
            break
        elif id "$NEW_USER" &>/dev/null; then
            echo "[-] 用户 '$NEW_USER' 已经存在，请更换一个用户名。"
        else
            break
        fi
    done

    useradd -m -s /bin/bash "$NEW_USER"
    echo "[+] 请为用户 '$NEW_USER' 设置密码："
    passwd "$NEW_USER"
    echo "[+] 用户 '$NEW_USER' 创建成功！"

    # 2. 赋予 sudo 权限
    echo -e "\n--- [步骤 2/4] 配置 Sudo 权限 ---"
    if grep -q "^sudo:" /etc/group; then
        usermod -aG sudo "$NEW_USER"
        echo "[+] 已将 '$NEW_USER' 添加到 sudo 组"
    elif grep -q "^wheel:" /etc/group; then
        usermod -aG wheel "$NEW_USER"
        echo "[+] 已将 '$NEW_USER' 添加到 wheel 组"
    else
        echo "$NEW_USER ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$NEW_USER"
        echo "[+] 已独立写入 sudoers 规则。"
    fi

    # 3. 修改 SSH 端口
    echo -e "\n--- [步骤 3/4] 修改 SSH 远程端口 ---"
    RANDOM_PORT=$((RANDOM % 64512 + 1024))
    while true; do
        read -p "请输入新的 SSH 端口 (1024-65535，直接回车随机生成 [$RANDOM_PORT]): " NEW_SSH_PORT < /dev/tty
        if [ -z "$NEW_SSH_PORT" ]; then
            NEW_SSH_PORT="$RANDOM_PORT"
            echo "[+] 已自动随机生成 SSH 端口: $NEW_SSH_PORT"
            break
        elif [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
            if [ "$NEW_SSH_PORT" -eq 22 ]; then
                echo "[-] 提示：你输入的是默认的 22 端口。"
                read -p "确定要继续使用 22 吗？(y/n): " confirm < /dev/tty
                [ "$confirm" = "y" ] && break
            else
                break
            fi
        else
            echo "[-] 格式错误，请输入 1 到 65535 之间的数字。"
        fi
    done

    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak_$(date +%F_%T)"
    if grep -qE "^#?Port " "$SSHD_CONFIG"; then
        sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
    else
        echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
    fi

    # 4. 禁止 Root 登录
    echo -e "\n--- [步骤 4/4] 禁用 Root 远程登录 ---"
    if grep -qE "^#?PermitRootLogin " "$SSHD_CONFIG"; then
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
    else
        echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    fi

    # 5. 重启 SSH
    if sshd -t; then
        if systemctl list-units --full -all | grep -q "ssh.service"; then
            systemctl restart ssh
        elif systemctl list-units --full -all | grep -q "sshd.service"; then
            systemctl restart sshd
        fi
        echo "[√] SSH 服务重启成功！"
    else
        echo "[-] 错误：SSH 配置文件语法检查未通过！已自动恢复备份。"
        cp "${SSHD_CONFIG}.bak_"* "$SSHD_CONFIG"
        return
    fi
exec bash
    echo -e "\n===================================="
    echo "         安全加固执行完毕！          "
    echo "===================================="
    echo " - 当前主机名   : $CURRENT_HOSTNAME"
    echo " - 新用户名     : $NEW_USER"
    echo " - 新 SSH 端口  : $NEW_SSH_PORT"
    echo " - Root 远程登录: 已禁用"
    echo "------------------------------------"
    echo " 【警告】请立刻新开终端测试新用户登录，切勿关闭当前窗口！"
}

# ==========================================
# 功能函数 9: BBR 管理功能模块
# ==========================================
_bbr_check() {
    local result
    result=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    [ "$result" = "bbr" ]
}
_bbr_zhenjia(){
        if _bbr_check; then
            echo " - bbr当前状态  : [ 🔥 BBR 已开启 ]"
        else
            echo " - bbr当前状态  : [ ⏳ BBR 未开启 ]"
        fi
}
_bbr_enable() {
    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    echo "----------------------------------------"
    echo "正在检查系统内核版本与模块支持..."
    local kernel_version
    kernel_version=$(uname -r | awk -F. '{print $1*100 + $2}')
    
    if [ "$kernel_version" -lt 409 ]; then
        echo "❌ 错误：当前内核版本低于 4.9，系统不支持原生 BBR！"
        return 1
    fi

    if ! modprobe tcp_bbr 2>/dev/null; then
        echo "⚠️ 警告：无法动态加载 tcp_bbr 模块，请检查内核是否编译了 BBR 支持。"
    fi

    if [ -d /etc/modules-load.d ]; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    else
        if ! grep -Fxq "tcp_bbr" /etc/modules 2>/dev/null; then
            echo "tcp_bbr" >> /etc/modules
        fi
    fi

    mkdir -p /etc/sysctl.d
    cat > "$sysctl_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1
    
    if _bbr_check; then
        echo "✅ 成功：BBR 已成功开启并即时生效！"
    else
        echo "❌ 警告：配置已写入，但当前未能实时生效，建议重启系统后再次检查。"
    fi
    echo "----------------------------------------"
}

_bbr_disable() {
    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    echo "----------------------------------------"
    echo "正在关闭 BBR 并清理配置..."
    
    # 1. 清理配置文件和自启模块
    [ -f "$sysctl_file" ] && rm -f "$sysctl_file"
    [ -f /etc/modules-load.d/bbr.conf ] && rm -f /etc/modules-load.d/bbr.conf
    sed -i '/tcp_bbr/d' /etc/modules 2>/dev/null

    # 2. 写入 cubic 配置
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.tcp_congestion_control=cubic" > "$sysctl_file"
    
    # 3. 实时修改内核参数（移除静默重定向，便于暴露潜在的系统限制错误）
    echo "正在将内核拥塞控制切换为 cubic..."
    if ! sysctl -w net.ipv4.tcp_congestion_control=cubic; then
        echo "⚠️ 提示：实时修改内核参数失败，可能当前系统环境（如部分受限容器或特殊虚拟化VPS）不支持修改。"
    fi

    # 4. 重新加载系统 sysctl 配置
    sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1
    
    # 5. 严格校验关闭结果
    if _bbr_check; then
        echo "❌ 警告：BBR 关闭失败，当前内核状态仍为 bbr！"
        echo "💡 提示：部分特殊内核（如强制编译启用的定制内核）可能无法直接在运行时关闭 BBR。"
    else
        echo "🔒 成功：BBR 已彻底关闭，当前已恢复为系统默认 cubic 算法。"
    fi
    echo "----------------------------------------"
}
manage_bbr() {
    # 权限校验
    if [ $EUID -ne 0 ]; then
       echo "❌ 错误：请使用 root 权限运行此功能！"
       return 1
    fi

    # 子菜单循环
    while true; do
        clear
        echo "========================================"
        echo "           BBR 拥塞控制管理             "
        echo "========================================"
        if _bbr_check; then
            echo "当前状态: [ 🔥 BBR 已开启 ]"
        else
            echo "当前状态: [ ⏳ BBR 未开启 ]"
        fi
        echo "----------------------------------------"
        echo "1. 开启 BBR (检测并尝试启用)"
        echo "2. 关闭 BBR (恢复系统默认)"
        echo "3. 返回上一级菜单"
        echo "========================================"
        read -p "请输入选项 [1-3]: " sub_choice
        
        case "$sub_choice" in
            1)
                _bbr_enable
                read -p "按回车键继续..." < /dev/tty
                ;;
            2)
                _bbr_disable
                read -p "按回车键继续..." < /dev/tty
                ;;
            3)
                break
                ;;
            *)
                echo "❌ 无效选项，请重新输入。"
                sleep 1
                ;;
        esac
    done
}

function installtunnel(){
mkdir -p /opt/suoha/ >/dev/null 2>&1
cd /opt/suoha
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
    echo arm64
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
    ;;
    armv7l )
    curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux
    ;;
    * )
    echo "当前架构$(uname -m)没有适配"
    exit
    ;;
esac
mkdir xray
unzip -d xray xray.zip
chmod +x cloudflared-linux xray/xray
mv xray/xray /opt/suoha/
rm -rf xray xray.zip

uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath_vless="vl-$(echo $uuid | awk -F- '{print $1}')"
urlpath_trojan="tr-$(echo $uuid | awk -F- '{print $1}')"
port_vless=$[$RANDOM+10000]
port_trojan=$[$port_vless+1]

cat>/opt/suoha/config.json<<EOF
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

clear
echo "复制下面的链接,用浏览器打开并授权需要绑定的域名"
echo "在网页中授权完毕后会继续进行下一步设置"
/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel login
clear
/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel list >argo.log 2>&1
echo -e "ARGO TUNNEL当前已经绑定的服务如下\n"
sed 1,2d argo.log | awk '{print $2}'
echo -e "\n自定义一个完整二级域名,例如 xxx.example.com"
echo "必须是网页里面绑定授权的域名才生效,不能乱输入"
read -p "输入绑定域名的完整二级域名: " domain
if [ -z "$domain" ]
then
    echo "没有设置域名"
    exit
elif [ $(echo $domain | grep "\." | wc -l) == 0 ]
then
    echo "域名格式不正确"
    exit
fi
name=$(echo $domain | awk -F\. '{print $1}')
if [ $(sed 1,2d argo.log | awk '{print $2}' | grep -w $name | wc -l) == 0 ]
then
    echo "创建TUNNEL $name"
    /opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel create $name >argo.log 2>&1
    echo "TUNNEL $name 创建成功"
else
    echo "TUNNEL $name 已经存在"
    if [ ! -f "/root/.cloudflared/$(sed 1,2d argo.log | awk '{print $1" "$2}' | grep -w $name | awk '{print $1}').json" ]
    then
        echo "/root/.cloudflared/$(sed 1,2d argo.log | awk '{print $1" "$2}' | grep -w $name | awk '{print $1}').json 文件不存在"
        echo "清理TUNNEL $name"
        /opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel cleanup $name >argo.log 2>&1
        echo "删除TUNNEL $name"
        /opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel delete $name >argo.log 2>&1
        echo "重建TUNNEL $name"
        /opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel create $name >argo.log 2>&1
    else
        echo "清理TUNNEL $name"
        /opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel cleanup $name >argo.log 2>&1
    fi
fi
echo "绑定 TUNNEL $name 到域名 $domain"
/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel route dns --overwrite-dns $name $domain >argo.log 2>&1
echo "$domain 绑定成功"
tunneluuid=$(cut -d= -f2 argo.log)

node_tag=$(echo $isp | sed -e 's/_/%20/g' -e 's/,/%2C/g')
if [[ -z "$node_tag" || "$node_tag" == "--" ]]; then
    node_tag="Argo_Node"
fi

domains=("$domain" "cf.090227.xyz" "cloudflare.182682.xyz")
labels=("自定域名" "优选cf.090227" "优选182682")

> /opt/suoha/nodes.txt

cat>/opt/suoha/clash.yaml<<EOF
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
    echo "$vless_tls" >> /opt/suoha/nodes.txt
    proxy_names+=("${node_tag}-VLESS-${l}-443")
    cat>>/opt/suoha/clash.yaml<<EOF
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
    echo "$trojan_tls" >> /opt/suoha/nodes.txt
    proxy_names+=("${node_tag}-Trojan-${l}-443")
    cat>>/opt/suoha/clash.yaml<<EOF
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

cat>>/opt/suoha/clash.yaml<<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
EOF

for pname in "${proxy_names[@]}"; do
    echo "      - \"${pname}\"" >> /opt/suoha/clash.yaml
done

cat>>/opt/suoha/clash.yaml<<EOF
rules:
  - MATCH,PROXY
EOF

if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
then
    base64 /opt/suoha/nodes.txt | tr -d '\n' > /opt/suoha/sub.txt
else
    base64 -w 0 /opt/suoha/nodes.txt > /opt/suoha/sub.txt
fi

server_ip=$(get_server_ip)
if [ -z "$server_ip" ]; then
    server_ip="$domain"
fi

sub_port=$(get_or_create_sub_port)
sync_to_static_web "/opt/suoha"
start_sub_server "/var/www/suoha_sub" "$sub_port"

sub_online_url="http://${server_ip}:${sub_port}/sub.txt"
clash_online_url="http://${server_ip}:${sub_port}/clash.yaml"

cat>/opt/suoha/v2ray.txt<<EOF
======================== 节点连接信息 ========================
$(cat /opt/suoha/nodes.txt)

端口说明:
443 端口可根据需要改为 CF 其它 TLS 端口: 2053, 2083, 2087, 2096, 8443

======================== 客户端订阅及导入链接 ========================
本机固定订阅服务端口: ${sub_port} (已永久保存，重新部署无需重新导入客户端)

1. 通用在线订阅链接 (适用于 v2rayN / NekoBox / Shadowrocket):
${sub_online_url}

2. v2rayN / NekoBox 一键导入协议链接:
sub://${sub_online_url}

3. Clash / Clash.Meta / Mihomo 一键导入配置:
clash://install-config?url=${clash_online_url}

4. Clash 在线配置文件直链:
${clash_online_url}

持久订阅存储目录: /var/www/suoha_sub/
==============================================================
EOF

rm -rf argo.log

cat>/opt/suoha/config.yaml<<EOF
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

if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
then
cat>/etc/local.d/cloudflared.start<<EOF
/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/suoha/config.yaml run $name &
EOF
cat>/etc/local.d/xray.start<<EOF
/opt/suoha/xray run -config /opt/suoha/config.json &
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
ExecStart=/opt/suoha/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --config /opt/suoha/config.yaml run $name
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
ExecStart=/opt/suoha/xray run -config /opt/suoha/config.json
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

if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
then
cat>/opt/suoha/suoha.sh<<EOF
#!/bin/bash
while true
do
if [ \$(ps -ef | grep cloudflared-linux | grep -v grep | wc -l) == 0 ]
then
    argostatus=stop
else
    argostatus=running
fi
if [ \$(ps -ef | grep xray | grep -v grep | wc -l) == 0 ]
then
    xraystatus=stop
else
    xraystatus=running
fi
echo argo \$argostatus
echo xray \$xraystatus
echo 1.管理TUNNEL
echo 2.启动服务
echo 3.停止服务
echo 4.重启服务
echo 5.卸载服务
echo 6.查看当前订阅与节点链接
echo 0.退出
read -p "请选择菜单(默认0): " menu
if [ -z "\$menu" ]
then
    menu=0
fi
if [ \$menu == 1 ]
then
    clear
    while true
    do
        echo ARGO TUNNEL当前已经绑定的服务如下
        /opt/suoha/cloudflared-linux tunnel list
        echo 1.删除TUNNEL
        echo 0.退出
        read -p "请选择菜单(默认0): " tunneladmin
        if [ -z "\$tunneladmin" ]
        then
            tunneladmin=0
        fi
        if [ \$tunneladmin == 1 ]
        then
            read -p "请输入要删除的TUNNEL NAME: " tunnelname
            echo 断开TUNNEL \$tunnelname
            /opt/suoha/cloudflared-linux tunnel cleanup \$tunnelname
            echo 删除TUNNEL \$tunnelname
            /opt/suoha/cloudflared-linux tunnel delete \$tunnelname
        else
            break
        fi
    done
elif [ \$menu == 2 ]
then
    kill -9 \$(ps -ef | grep xray | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    kill -9 \$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    /etc/local.d/cloudflared.start >/dev/null 2>&1
    /etc/local.d/xray.start >/dev/null 2>&1
    clear
    sleep 1
elif [ \$menu == 3 ]
then
    kill -9 \$(ps -ef | grep xray | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    kill -9 \$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    clear
    sleep 2
elif [ \$menu == 4 ]
then
    kill -9 \$(ps -ef | grep xray | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    kill -9 \$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    /etc/local.d/cloudflared.start >/dev/null 2>&1
    /etc/local.d/xray.start >/dev/null 2>&1
    clear
    sleep 1
elif [ \$menu == 5 ]
then
    kill -9 \$(ps -ef | grep xray | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    kill -9 \$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print \$1}') >/dev/null 2>&1
    pkill -f "http.server" >/dev/null 2>&1
    rm -rf /opt/suoha /opt/suoha_quick /etc/local.d/cloudflared.start /etc/local.d/xray.start /usr/bin/suoha ~/.cloudflared /etc/suoha_sub_port /var/www/suoha_sub
    echo 所有服务都卸载完成
    echo 彻底删除授权记录
    echo 请访问 https://dash.cloudflare.com/profile/api-tokens
    echo 删除授权的 Argo Tunnel API Token 即可
    exit
elif [ \$menu == 6 ]
then
    clear
    cat /opt/suoha/v2ray.txt
elif [ \$menu == 0 ]
then
    echo 退出成功
    exit
fi
done
EOF
else
cat>/opt/suoha/suoha.sh<<EOF
#!/bin/bash
clear
while true
do
echo argo \$(systemctl status cloudflared.service | sed -n '3p')
echo xray \$(systemctl status xray.service | sed -n '3p')
echo 1.管理TUNNEL
echo 2.启动服务
echo 3.停止服务
echo 4.重启服务
echo 5.卸载服务
echo 6.查看当前订阅与节点链接
echo 0.退出
read -p "请选择菜单(默认0): " menu
if [ -z "\$menu" ]
then
    menu=0
fi
if [ \$menu == 1 ]
then
    clear
    while true
    do
        echo ARGO TUNNEL当前已经绑定的服务如下
        /opt/suoha/cloudflared-linux tunnel list
        echo 1.删除TUNNEL
        echo 0.退出
        read -p "请选择菜单(默认0): " tunneladmin
        if [ -z "\$tunneladmin" ]
        then
            tunneladmin=0
        fi
        if [ \$tunneladmin == 1 ]
        then
            read -p "请输入要删除的TUNNEL NAME: " tunnelname
            echo 断开TUNNEL \$tunnelname
            /opt/suoha/cloudflared-linux tunnel cleanup \$tunnelname
            echo 删除TUNNEL \$tunnelname
            /opt/suoha/cloudflared-linux tunnel delete \$tunnelname
        else
            break
        fi
    done
elif [ \$menu == 2 ]
then
    systemctl start cloudflared.service
    systemctl start xray.service
    clear
elif [ \$menu == 3 ]
then
    systemctl stop cloudflared.service
    systemctl stop xray.service
    clear
elif [ \$menu == 4 ]
then
    systemctl restart cloudflared.service
    systemctl restart xray.service
    clear
elif [ \$menu == 5 ]
then
    systemctl stop cloudflared.service
    systemctl stop xray.service
    systemctl disable cloudflared.service
    systemctl disable xray.service
    kill -9 \$(ps -ef | grep xray | grep -v grep | awk '{print \$2}') >/dev/null 2>&1
    kill -9 \$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print \$2}') >/dev/null 2>&1
    pkill -f "http.server" >/dev/null 2>&1
    rm -rf /opt/suoha /opt/suoha_quick /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha ~/.cloudflared /etc/suoha_sub_port /var/www/suoha_sub
    systemctl --system daemon-reload
    echo 所有服务都卸载完成
    echo 彻底删除授权记录
    echo 请访问 https://dash.cloudflare.com/profile/api-tokens
    echo 删除授权的 Argo Tunnel API Token 即可
    exit
elif [ \$menu == 6 ]
then
    clear
    cat /opt/suoha/v2ray.txt
elif [ \$menu == 0 ]
then
    echo 退出成功
    exit
fi
done
EOF
fi
chmod +x /opt/suoha/suoha.sh
ln -sf /opt/suoha/suoha.sh /usr/bin/suoha
}

clear
echo "梭哈模式不需要自己提供域名,使用CF ARGO QUICK TUNNEL创建快速链接"
echo "梭哈模式在重启或者脚本再次运行后失效,如果需要使用需要再次运行创建"
echo "安装服务模式,需要有CF托管域名,并且需要按照提示手动绑定ARGO服务"
echo "首次绑定ARGO服务后如果不想再次跳转网页绑定"
echo "将已经绑定的系统目录下的 /root/.cloudflared 文件夹以及内容"
echo "拷贝至新系统下同样的目录,会自动跳过登录验证"
echo '域名注册使用这个测试版 bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/acme.sh)'
echo -e "\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n"
echo "1.梭哈模式 (自动生成 VLESS+Trojan 443 TLS 优选节点)"
echo "2.安装服务 (自定义域名绑定固定隧道)"
echo "3.卸载服务"
echo "4.清空缓存"
echo "5.额外增加ipv6 ss 共存部署"
echo "6.额外增加 Hysteria 2 直连备用节点 (含 Clash 同步)"
echo "7.配置 Cloudflare WARP 灵活路由与分流"
echo "8.加固vps主机"
echo "9.开启bbr加速"
echo -e "0.退出脚本\n"
read -p "请选择模式(默认1):" mode
if [ -z "$mode" ]
then
    mode=1
fi
if [ $mode == 1 ]
then
    read -p "请选择argo连接模式IPV4或者IPV6(输入4或6,默认4):" ips
    if [ -z "$ips" ]
    then
        ips=4
    fi
    if [ $ips != 4 ] && [ $ips != 6 ]
    then
        echo "请输入正确的argo连接模式"
        exit
    fi
    isp=$(curl -$ips -s --connect-timeout 2 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')
    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
    then
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    else
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $2}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}') >/dev/null 2>&1
    fi
    quicktunnel
elif [ $mode == 2 ]
then
    read -p "请选择argo连接模式IPV4或者IPV6(输入4或6,默认4):" ips
    if [ -z "$ips" ]
    then
        ips=4
    fi
    if [ $ips != 4 ] && [ $ips != 6 ]
    then
        echo "请输入正确的argo连接模式"
        exit
    fi
    isp=$(curl -$ips -s --connect-timeout 2 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')
    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
    then
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
        rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha
    else
        systemctl stop cloudflared.service
        systemctl stop xray.service
        systemctl disable cloudflared.service
        systemctl disable xray.service
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $2}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}') >/dev/null 2>&1
        rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha
        systemctl --system daemon-reload
    fi
    installtunnel
    cat /opt/suoha/v2ray.txt
    echo "服务安装完成,管理服务请运行命令 suoha"
elif [ $mode == 3 ]
then
    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
    then
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
        pkill -f "http.server" >/dev/null 2>&1
        rm -rf /opt/suoha /opt/suoha_quick /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha /etc/suoha_sub_port /var/www/suoha_sub
    else
        systemctl stop cloudflared.service
        systemctl stop xray.service
        systemctl disable cloudflared.service
        systemctl disable xray.service
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $2}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}') >/dev/null 2>&1
        pkill -f "http.server" >/dev/null 2>&1
        rm -rf /opt/suoha /opt/suoha_quick /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha ~/.cloudflared /etc/suoha_sub_port /var/www/suoha_sub
        systemctl --system daemon-reload
    fi
    clear
    echo "所有服务都卸载完成"
    echo "彻底删除授权记录"
    echo "请访问 https://dash.cloudflare.com/profile/api-tokens"
    echo "删除授权的 Argo Tunnel API Token 即可"
elif [ $mode == 4 ]
then
    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
    then
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
    else
        kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $2}') >/dev/null 2>&1
        kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}') >/dev/null 2>&1
    fi
    pkill -f "http.server" >/dev/null 2>&1
    rm -rf /opt/suoha_quick/nodes.txt /opt/suoha_quick/sub.txt /opt/suoha_quick/clash.yaml
elif [ $mode == 5 ]
then
    install_ipv6_ss
elif [ $mode == 6 ]
then
    install_hy2_direct
elif [ $mode == 7 ]
then
    configure_warp_routing
elif [ $mode == 8 ]
then
    action_init_security    
elif [ $mode == 9 ]
then
    manage_bbr
else
    echo "退出成功"
    exit
fi
