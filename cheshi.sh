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

/opt/suoha_quick/xray/xray run -config /opt/suoha_quick/xray/config.json >/dev/null 2>&1 &
echo $! > /opt/suoha_quick/xray.pid

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

secure_web_dir="/var/www/suoha_sub/${sub_token}"
mkdir -p "$secure_web_dir" >/dev/null 2>&1
[ -f "/opt/suoha_quick/nodes.txt" ] && cp -f /opt/suoha_quick/nodes.txt "${secure_web_dir}/nodes.txt"
[ -f "/opt/suoha_quick/sub.txt" ] && cp -f /opt/suoha_quick/sub.txt "${secure_web_dir}/sub.txt"
[ -f "/opt/suoha_quick/clash.yaml" ] && cp -f /opt/suoha_quick/clash.yaml "${secure_web_dir}/clash.yaml"

start_sub_server "/var/www/suoha_sub" "$sub_port"

cat > /opt/suoha_quick/start.sh << EOF
#!/bin/bash
cd /opt/suoha_quick || exit
[ -f "xray.pid" ] && kill -9 \$(cat xray.pid) 2>/dev/null
[ -f "cf_vl.pid" ] && kill -9 \$(cat cf_vl.pid) 2>/dev/null
[ -f "cf_tr.pid" ] && kill -9 \$(cat cf_tr.pid) 2>/dev/null
rm -rf argo_vless.log argo_trojan.log

./xray/xray run -config xray/config.json >/dev/null 2>&1 &
echo \$! > xray.pid

./cloudflared-linux tunnel --url http://127.0.0.1:$port_vless --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_vless.log 2>&1 &
echo \$! > /opt/suoha_quick/cf_vl.pid

./cloudflared-linux tunnel --url http://127.0.0.1:$port_trojan --no-autoupdate --edge-ip-version $ips --protocol http2 >argo_trojan.log 2>&1 &
echo \$! > /opt/suoha_quick/cf_tr.pid

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
    
    sub_token=$(cat /etc/suoha_sub_token 2>/dev/null || echo "sub-default")
    secure_web_dir="/var/www/suoha_sub/\$sub_token"
    mkdir -p "\$secure_web_dir"
    cp -f sub.txt "\$secure_web_dir/sub.txt"
    cp -f clash.yaml "\$secure_web_dir/clash.yaml"
fi

python3 -m http.server $sub_port --directory /var/www/suoha_sub >/dev/null 2>&1 &
EOF

chmod +x /opt/suoha_quick/start.sh

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
        read -p "按回车键返回主菜单..." < /dev/tty
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
        echo "未检测到正在运行的 Xray 服务，请先执行【2.梭哈模式】或【3.安装服务】！"
        read -p "按回车键返回主菜单..." < /dev/tty
        return
    fi

    local ss_port=$[$RANDOM%10000+30000]
    local ss_password=$(cat /proc/sys/kernel/random/uuid | awk -F- '{print $1$2}')
    local ss_method="aes-128-gcm"

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
        echo "注入 Xray 配置失败，请检查 python3 环境！"
        read -p "按回车键返回主菜单..." < /dev/tty
        return
    fi

    if [ $is_installed_mode -eq 1 ]; then
        if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
        then
            /etc/local.d/xray.start >/dev/null 2>&1
        else
            systemctl restart xray.service >/dev/null 2>&1
        fi
    else
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

    local work_nodes="${xray_dir}/nodes.txt"
    touch "$work_nodes"
    sed -i '/IPv6-SS-Direct/d' "$work_nodes"
    echo "$ss_link" >> "$work_nodes"

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

    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
    then
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

    if [ $is_installed_mode -eq 0 ] && [ -f "/opt/suoha_quick/start.sh" ]; then
        if ! grep -q "IPv6-SS-Direct" /opt/suoha_quick/start.sh; then
            cat >> /opt/suoha_quick/start.sh << EOT

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
    base64 -w 0 nodes.txt > sub.txt 2>/dev/null || base64 nodes.txt | tr -d '\\n' > sub.txt
    sub_token=\$(cat /etc/suoha_sub_token 2>/dev/null || echo "sub-default")
    secure_web_dir="/var/www/suoha_sub/\$sub_token"
    mkdir -p "\$secure_web_dir"
    cp -f sub.txt "\$secure_web_dir/sub.txt"
    cp -f clash.yaml "\$secure_web_dir/clash.yaml"
fi
EOT
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
    echo "订阅地址: ${sub_online_url}"
    echo "=========================================================="
    read -p "按回车键返回主菜单..." < /dev/tty
}

install_hy2_direct() {
    echo "=========================================================="
    echo "正在部署 Hysteria 2 直连备用节点..."
    echo "=========================================================="

    local xray_dir="/opt/suoha_quick"
    local xray_sub_dir="/opt/suoha_quick/xray"
    local cfg_json="/opt/suoha_quick/xray/config.json"
    
    if [ ! -f "$cfg_json" ]; then
        echo "[错误] 未找到 Xray 配置文件: $cfg_json，请先运行梭哈模式！"
        read -p "按回车键返回主菜单..." < /dev/tty
        return
    fi

    local ipv4=""
    local ipv6=""
    ipv4=$(curl -4 -s --connect-timeout 3 ip.sb || ip -4 addr show scope global 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    ipv6=$(curl -6 -s --connect-timeout 3 ip.sb || ip -6 addr show scope global 2>/dev/null | grep inet6 | grep -v 'host' | awk '{print $2}' | cut -d/ -f1 | head -n1)

    local hy2_port=$((RANDOM % 10000 + 10000))
    local hy2_pass=$(cat /proc/sys/kernel/random/uuid)

    mkdir -p "$xray_sub_dir"
    if [ ! -f "${xray_sub_dir}/hy2.crt" ] || [ ! -f "${xray_sub_dir}/hy2.key" ]; then
        openssl ecparam -genkey -name prime256v1 -out "${xray_sub_dir}/hy2.key" 2>/dev/null
        openssl req -new -x509 -days 3650 -key "${xray_sub_dir}/hy2.key" -out "${xray_sub_dir}/hy2.crt" -subj "/CN=bing.com" 2>/dev/null
    fi

    local cert_pin=""
    if [ -f "${xray_sub_dir}/hy2.crt" ]; then
        cert_pin=$(openssl x509 -in "${xray_sub_dir}/hy2.crt" -noout -sha256 -fingerprint 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    fi

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
        'settings': {'version': 2, 'clients': [{'auth': '$hy2_pass'}]},
        'streamSettings': {
            'network': 'hysteria',
            'security': 'tls',
            'hysteriaSettings': {'version': 2},
            'tlsSettings': {
                'alpn': ['h3'],
                'certificates': [{'certificateFile': '/opt/suoha_quick/xray/hy2.crt', 'keyFile': '/opt/suoha_quick/xray/hy2.key'}]
            }
        }
    }
    data['inbounds'].append(hy2_ib)
    with open(cfg_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
except Exception as e:
    sys.exit(1)
"
    if [ -f "/opt/suoha_quick/xray.pid" ]; then
        kill -9 $(cat /opt/suoha_quick/xray.pid) >/dev/null 2>&1
        rm -f /opt/suoha_quick/xray.pid
    else
        kill -9 $(pgrep -f "/opt/suoha_quick/xray/xray") >/dev/null 2>&1
    fi
    nohup /opt/suoha_quick/xray/xray run -config "$cfg_json" >/dev/null 2>&1 &
    echo $! > /opt/suoha_quick/xray.pid

    local work_nodes="${xray_dir}/nodes.txt"
    local clash_file="${xray_dir}/clash.yaml"
    touch "$work_nodes"
    sed -i '/Hy2-v4-Backup/d' "$work_nodes"
    sed -i '/Hy2-v6-Backup/d' "$work_nodes"

    if [ -n "$ipv4" ]; then
        echo "hysteria2://${hy2_pass}@${ipv4}:${hy2_port}?alpn=h3&pinSHA256=${cert_pin}#Hy2-v4-Backup" >> "$work_nodes"
    fi
    if [ -n "$ipv6" ]; then
        echo "hysteria2://${hy2_pass}@[${ipv6}]:${hy2_port}?alpn=h3&pinSHA256=${cert_pin}#Hy2-v6-Backup" >> "$work_nodes"
    fi

    if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]; then
        base64 "$work_nodes" | tr -d '\n' > "${xray_dir}/sub.txt"
    else
        base64 -w 0 "$work_nodes" > "${xray_dir}/sub.txt"
    fi

    sync_to_static_web "$xray_dir"
    echo "Hysteria 2 备用节点部署成功！"
    read -p "按回车键返回..." < /dev/tty
}

configure_warp_routing() {
    local xray_dir="/opt/suoha_quick"
    local cfg_json="/opt/suoha_quick/xray/config.json"
    
    if [ ! -f "$cfg_json" ]; then
        echo "[错误] 未找到 Xray 配置文件: $cfg_json，请先运行梭哈模式！"
        read -p "按回车键返回主菜单..." < /dev/tty
        return
    fi

    if ! command -v warp-cli &>/dev/null; then
        apt update && apt install -y curl gnupg lsb-release >/dev/null 2>&1
        mkdir -p /usr/share/keyrings
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg -o /usr/share/keyrings/cloudflare-warp-archive-keyring.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.asc] https://pkg.cloudflareclient.com $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/cloudflare-warp.list >/dev/null
        apt update && apt install -y cloudflare-warp || true
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
        echo "2. 切换为【全局模式】"
        echo "3. 查看当前 WARP 路由状态"
        echo "4. 关闭并停用 WARP 代理"
        echo "0. 返回上级主菜单"
        echo "=========================================================="
        read -p "请选择操作 [0-4]: " warp_choice

        case "$warp_choice" in
            1)
                read -p "输入域名: " user_domains < /dev/tty
                [ -z "$user_domains" ] && continue
                python3 -c "
import json
cfg_file = '$cfg_json'
with open(cfg_file, 'r', encoding='utf-8') as f:
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
with open(cfg_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
                pkill -f xray || true
                nohup "${xray_dir}/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
                echo "✅ 规则已生效！"
                read -p "按回车键继续..." < /dev/tty
                ;;
            2)
                python3 -c "
import json
cfg_file = '$cfg_json'
with open(cfg_file, 'r', encoding='utf-8') as f:
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
with open(cfg_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
                pkill -f xray || true
                nohup "${xray_dir}/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
                echo "✅ 已切换为全局 WARP 模式！"
                read -p "按回车键继续..." < /dev/tty
                ;;
            3)
                warp-cli status
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
        esac
    done
}

action_init_security() {
    echo "===================================="
    echo "  开始执行：系统初始化与安全加固"
    echo "===================================="
    read -p "请输入新的主机名: " NEW_HOSTNAME < /dev/tty
    [ -n "$NEW_HOSTNAME" ] && hostnamectl set-hostname "$NEW_HOSTNAME"
    read -p "请输入新用户名: " NEW_USER < /dev/tty
    [ -n "$NEW_USER" ] && useradd -m -s /bin/bash "$NEW_USER" && passwd "$NEW_USER"
    read -p "请输入新 SSH 端口: " NEW_SSH_PORT < /dev/tty
    [ -n "$NEW_SSH_PORT" ] && sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    echo "安全加固完成！"
    read -p "按回车键返回主菜单..." < /dev/tty
}

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
        echo "3. 返回上一级菜单"
        echo "========================================"
        read -p "请输入选项 [1-3]: " sub_choice < /dev/tty
        case "$sub_choice" in
            1)
                echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-bbr.conf
                echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
                sysctl --system >/dev/null 2>&1
                echo "BBR 已开启！"
                read -p "按回车键继续..." < /dev/tty
                ;;
            2)
                rm -f /etc/sysctl.d/99-bbr.conf
                sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
                echo "BBR 已关闭。"
                read -p "按回车键继续..." < /dev/tty
                ;;
            3)
                break
                ;;
        esac
    done
}

function installtunnel(){
mkdir -p /opt/suoha/ >/dev/null 2>&1
cd /opt/suoha
rm -rf xray cloudflared-linux xray.zip
}

while true; do
    clear
    echo "梭哈模式不需要自己提供域名,使用CF ARGO QUICK TUNNEL创建快速链接"
    echo "梭哈模式在重启或者脚本再次运行后失效,如果需要使用需要再次运行创建"
    echo "安装服务模式,需要有CF托管域名,并且需要按照提示手动绑定ARGO服务"
    echo "首次绑定ARGO服务后如果不想再次跳转网页绑定"
    echo "将已经绑定的系统目录下的 /root/.cloudflared 文件夹以及内容"
    echo "拷贝至新系统下同样的目录,会自动跳过登录验证"
    echo '域名注册使用这个测试版 bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/acme.sh)'
    echo -e "\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n"
    echo "1.加固vps主机"
    echo "2.梭哈模式 (自动生成 VLESS+Trojan 443 TLS 优选节点)"
    echo "3.安装服务 (自定义域名绑定固定隧道)"
    echo "4.卸载服务"
    echo "5.清空缓存"
    echo "6.额外增加ipv6 ss 共存部署"
    echo "7.额外增加 Hysteria 2 直连备用节点 (含 Clash 同步)"
    echo "8.配置 Cloudflare WARP 灵活路由与分流"
    echo "9.开启bbr加速"
    echo "10.绑定域名"
    echo -e "0.退出脚本\n"
    read -p "请选择模式(默认1):" mode < /dev/tty
    [ -z "$mode" ] && mode=1

    case "$mode" in
        1)
            action_init_security
            ;;
        2)
            read -p "请选择argo连接模式IPV4或者IPV6(输入4或6,默认4):" ips < /dev/tty
            [ -z "$ips" ] && ips=4
            if [ $ips != 4 ] && [ $ips != 6 ]
            then
                echo "请输入正确的argo连接模式"
                read -p "按回车键返回主菜单..." < /dev/tty
                continue
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
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        3)
            read -p "请选择argo连接模式IPV4或者IPV6(输入4或6,默认4):" ips < /dev/tty
            [ -z "$ips" ] && ips=4
            if [ $ips != 4 ] && [ $ips != 6 ]
            then
                echo "请输入正确的argo连接模式"
                read -p "按回车键返回主菜单..." < /dev/tty
                continue
            fi
            isp=$(curl -$ips -s --connect-timeout 2 https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed -e 's/ /_/g')
            if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
            then
                kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
                kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
                rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha
            else
                systemctl stop cloudflared.service 2>/dev/null || true
                systemctl stop xray.service 2>/dev/null || true
                systemctl disable cloudflared.service 2>/dev/null || true
                systemctl disable xray.service 2>/dev/null || true
                kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $2}') >/dev/null 2>&1
                kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}') >/dev/null 2>&1
                rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha
                systemctl --system daemon-reload
            fi
            installtunnel
            cat /opt/suoha/v2ray.txt 2>/dev/null || true
            echo "服务安装完成,管理服务请运行命令 suoha"
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        4)
            if [ $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') == "Alpine" ]
            then
                kill -9 $(ps -ef | grep xray | grep -v grep | awk '{print $1}') >/dev/null 2>&1
                kill -9 $(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}') >/dev/null 2>&1
                pkill -f "http.server" >/dev/null 2>&1
                rm -rf /opt/suoha /opt/suoha_quick /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha /etc/suoha_sub_port /var/www/suoha_sub
            else
                systemctl stop cloudflared.service 2>/dev/null || true
                systemctl stop xray.service 2>/dev/null || true
                systemctl disable cloudflared.service 2>/dev/null || true
                systemctl disable xray.service 2>/dev/null || true
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
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        5)
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
            echo "缓存已清空！"
            read -p "按回车键返回主菜单..." < /dev/tty
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
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        0)
            echo "退出成功"
            exit 0
            ;;
        *)
            echo "无效选项"
            sleep 1
            ;;
    esac
done
