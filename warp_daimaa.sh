#!/bin/bash

# ==============================================================
# Cloudflare WARP 安装部署与动态本地端口分流管理模块 (warp_daima.sh)
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
LAST_WARP_PORT_FILE="${YUZHOU_DIR}/last_warp_port.txt"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# 1. 检测现有的 Xray 配置文件及路径
xray_dir=""
cfg_json=""

if [ -f "${YUZHOU_DIR}/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/xray"
    cfg_json="${YUZHOU_DIR}/xray/config.json"
elif [ -f "${YUZHOU_DIR}/quick/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/quick"
    cfg_json="${YUZHOU_DIR}/quick/xray/config.json"
elif [ -f "/opt/suoha/config.json" ]; then
    xray_dir="/opt/suoha"
    cfg_json="/opt/suoha/config.json"
elif [ -f "/opt/suoha_quick/xray/config.json" ]; then
    xray_dir="/opt/suoha_quick"
    cfg_json="/opt/suoha_quick/xray/config.json"
else
    clear
    echo -e "${RED}[错误] 未找到正在运行的 Xray 配置文件，请先执行主菜单【梭哈模式】或【安装服务】！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

# 2. 检查并安装 Cloudflare WARP 客户端
if ! command -v warp-cli &>/dev/null; then
    clear
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}          正在首次安装并配置 Cloudflare WARP 客户端           ${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    
    apt update && apt install -y curl gnupg lsb-release >/dev/null 2>&1
    mkdir -p /usr/share/keyrings

    if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg -o /usr/share/keyrings/cloudflare-warp-archive-keyring.asc; then
        echo -e "${RED}[错误] 无法下载 Cloudflare GPG 密钥！${NC}"
        read -p "按回车键返回..." < /dev/tty
        exit 1
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.asc] https://pkg.cloudflareclient.com $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/cloudflare-warp.list >/dev/null
    
    apt update && apt install -y cloudflare-warp || {
        echo -e "${RED}[错误] WARP 客户端包安装失败！${NC}"
        read -p "按回车键返回..." < /dev/tty
        exit 1
    }
fi

systemctl enable --now warp-svc >/dev/null 2>&1
sleep 2

# 检测并解决 Registration Missing 问题
if warp-cli status 2>/dev/null | grep -q "Registration Missing"; then
    warp-cli registration new >/dev/null 2>&1 || true
    sleep 2
fi

warp-cli mode proxy >/dev/null 2>&1

# 3. 动态随机生成本地 SOCKS 端口并检查占用（避开已有占用）
while true; do
    warp_local_port=$((RANDOM % 20000 + 30000))
    if ! ss -tlnp | grep -q ":${warp_local_port} " && ! ss -ulnp | grep -q ":${warp_local_port} "; then
        break
    fi
done

# 设置 warp-cli 本地代理端口并连接
warp-cli proxy port "$warp_local_port" >/dev/null 2>&1
warp-cli connect >/dev/null 2>&1

echo -e "${GREEN}✅ WARP 本地代理端口已成功分配并启动: ${CYAN}$warp_local_port${NC}"
echo "$warp_local_port" > "$LAST_WARP_PORT_FILE"

# 路由分流交互菜单
while true; do
    clear
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}        Cloudflare WARP 灵活路由与分流管理菜单 (warp_daima.sh) ${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo "1. 自定义添加指定域名/应用走 WARP (交互式输入)"
    echo "2. 切换为【全局模式】：所有外网流量强制走 WARP"
    echo "3. 查看当前 WARP 路由状态"
    echo "4. 关闭并停用 WARP 代理（恢复默认直连路由）"
    echo "0. 返回上级主菜单"
    echo -e "${CYAN}==============================================================${NC}"
    read -p "请选择操作 [0-4]: " warp_choice < /dev/tty

    case "$warp_choice" in
        1)
            echo ""
            echo "请输入需要走 WARP 的域名或关键字（多个域名请用空格隔开）"
            echo "例如: openai.com chatgpt.com claude.ai t.me"
            read -p "输入域名: " user_domains < /dev/tty
            
            if [ -z "$user_domains" ]; then
                echo -e "${YELLOW}输入为空，取消操作。${NC}"
                sleep 1
                continue
            fi

            python3 -c "
import json
cfg_file = '${cfg_json}'
with open(cfg_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

outbounds = data.get('outbounds', [])
outbounds = [ob for ob in outbounds if ob.get('tag') != 'warp-out']
outbounds.append({
    'tag': 'warp-out',
    'protocol': 'socks',
    'settings': {'servers': [{'address': '127.0.0.1', 'port': int('${warp_local_port}')}]}
})
data['outbounds'] = outbounds

routing = data.get('routing', {'domainStrategy': 'AsIs', 'rules': []})
rules = routing.get('rules', [])

custom_rule = None
for r in rules:
    if r.get('tag') == 'custom-warp-rule':
        custom_rule = r
        break

new_domains = '${user_domains}'.split()
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
            echo -e "${GREEN}✅ 自定义域名规则已成功注入并生效（使用本地端口: $warp_local_port）！${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        2)
            echo -e "${YELLOW}正在切换为全局 WARP 模式...${NC}"
            python3 -c "
import json
cfg_file = '${cfg_json}'
with open(cfg_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

outbounds = data.get('outbounds', [])
outbounds = [ob for ob in outbounds if ob.get('tag') != 'warp-out']
outbounds.append({
    'tag': 'warp-out',
    'protocol': 'socks',
    'settings': {'servers': [{'address': '127.0.0.1', 'port': int('${warp_local_port}')}]}
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
            echo -e "${GREEN}✅ 已成功切换为【全局 WARP 模式】（本地端口: $warp_local_port）！${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        3)
            echo ""
            echo -e "${CYAN}📊 当前 WARP 客户端状态：${NC}"
            warp-cli status
            echo -e "📌 当前本地 SOCKS 代理监听端口: ${GREEN}$warp_local_port${NC}"
            echo ""
            read -p "按回车键继续..." < /dev/tty
            ;;
        4)
            echo -e "${YELLOW}正在关闭 WARP 代理并彻底清理所有相关路由规则...${NC}"
            warp-cli disconnect >/dev/null 2>&1 || true
            systemctl stop warp-svc >/dev/null 2>&1 || true
            [ -f "$LAST_WARP_PORT_FILE" ] && rm -f "$LAST_WARP_PORT_FILE"
            
            python3 -c "
import json
cfg_file = '${cfg_json}'
try:
    with open(cfg_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    if 'outbounds' in data:
        data['outbounds'] = [ob for ob in data['outbounds'] if ob.get('tag') != 'warp-out']
    
    if 'routing' in data and 'rules' in data['routing']:
        clean_rules = []
        for r in data['routing']['rules']:
            outbound_tag = r.get('outboundTag', '')
            rule_tag = r.get('tag', '')
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
            pkill -f xray || true
            nohup "${xray_dir}/xray/xray" run -config "$cfg_json" >/dev/null 2>&1 &
            echo $! > "${xray_dir}/xray.pid"

            echo -e "${GREEN}✅ WARP 已成功关闭，Xray 路由已完全恢复为纯净直连状态！${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        0)
            break
            ;;
        *)
            echo -e "${RED}无效选项，请重新选择。${NC}"
            sleep 1
            ;;
    esac
done
