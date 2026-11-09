#!/bin/bash

# ==============================================================
# Cloudflare WARP 安装部署与动态双栈端口分流管理模块 (warp_daima.sh)
# 路径严格统一至 /etc/yuzhou/
# 增强功能：20次自动重试拨号 + 完美流量接管分流
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
LAST_WARP_PORT_FILE="${YUZHOU_DIR}/last_warp_port.txt"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# 1. 检测 /etc/yuzhou/ 下的 Xray 配置文件及路径
xray_dir=""
cfg_json=""

if [ -f "${YUZHOU_DIR}/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/xray"
    cfg_json="${YUZHOU_DIR}/xray/config.json"
elif [ -f "${YUZHOU_DIR}/quick/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/quick"
    cfg_json="${YUZHOU_DIR}/quick/xray/config.json"
elif [ -f "${YUZHOU_DIR}/service/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/service"
    cfg_json="${YUZHOU_DIR}/service/config.json"
else
    clear
    echo -e "${RED}[错误] 未在 /etc/yuzhou/ 下找到正在运行的 Xray 配置文件，请先执行主菜单相关节点部署！${NC}"
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

# 3. 动态随机生成本地 SOCKS 端口并检查占用
while true; do
    warp_local_port=$((RANDOM % 20000 + 30000))
    if ! ss -tlnp | grep -q ":${warp_local_port} " && ! ss -ulnp | grep -q ":${warp_local_port} "; then
        break
    fi
done

# ==============================================================
# 💡 强力增强：20 次高强度自动重试拨号逻辑
# ==============================================================
max_retries=20
retry_count=1
connected_success=0

echo -e "${CYAN}开始启动 WARP 自动长效重试连接机制 (最大尝试次数: ${max_retries})...${NC}"

while [ $retry_count -le $max_retries ]; do
    echo -e "${CYAN}[重试 ${retry_count}/${max_retries}] 正在向 Cloudflare 请求设备注册与握手...${NC}"
    
    warp-cli disconnect >/dev/null 2>&1 || true
    warp-cli delete >/dev/null 2>&1 || true
    sleep 1

    warp-cli registration new >/dev/null 2>&1 || true
    sleep 1
    warp-cli accept-tos >/dev/null 2>&1 || true
    warp-cli mode proxy >/dev/null 2>&1
    warp-cli tunnel ip set-dual-stack >/dev/null 2>&1 || true
    warp-cli proxy port "$warp_local_port" >/dev/null 2>&1
    warp-cli connect >/dev/null 2>&1

    for i in {1..4}; do
        if warp-cli status 2>/dev/null | grep -q "Connected"; then
            connected_success=1
            break
        fi
        sleep 1
    done

    if [ $connected_success -eq 1 ]; then
        echo -e "${GREEN}🎉 成功！在第 ${retry_count} 次尝试时成功握手并连通 Cloudflare WARP！${NC}"
        break
    else
        echo -e "${YELLOW}⚠️ 第 ${retry_count} 次握手未响应，正在重新重置并尝试...${NC}"
        retry_count=$((retry_count + 1))
    fi
done

if [ $connected_success -eq 0 ]; then
    echo -e "${RED}[警告] 尝试 20 次后仍未能完成注册连接。建议进入菜单后按选项 3 检查。${NC}"
    sleep 2
fi

echo -e "${GREEN}✅ WARP 双栈本地代理端口已分配并挂载: ${CYAN}$warp_local_port${NC}"
echo "$warp_local_port" > "$LAST_WARP_PORT_FILE"

# 路由分流交互菜单
while true; do
    clear
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}   Cloudflare WARP 双栈路由与灵活分流管理 (warp_daima.sh)     ${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo "1. 自定义添加指定域名/应用走 WARP (交互式输入)"
    echo "2. 切换为【全局双栈模式】：所有节点外网流量强制走 WARP (IPv4+IPv6)"
    echo "3. 查看当前 WARP 路由状态与出口 IP"
    echo "4. 关闭并停用 WARP 代理（恢复默认直连路由）"
    echo "0. 返回上级主菜单"
    echo -e "${CYAN}==============================================================${NC}"
    read -p "请选择操作 [0-4]: " warp_choice < /dev/tty

    case "$warp_choice" in
        1)
            echo ""
            echo "请输入需要走 WARP 的域名或关键字（多个域名请用空格隔开）"
            echo "例如: openai.com chatgpt.com claude.ai t.me ip.sb"
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

# 确保 outbounds 中包含 warp-out 和 direct
outbounds = data.get('outbounds', [])
outbounds = [ob for ob in outbounds if ob.get('tag') not in ['warp-out', 'direct']]
outbounds.append({
    'tag': 'warp-out',
    'protocol': 'socks',
    'settings': {
        'servers': [{'address': '127.0.0.1', 'port': int('${warp_local_port}')}]
    }
})
outbounds.append({'tag': 'direct', 'protocol': 'freedom', 'settings': {}})
data['outbounds'] = outbounds

routing = data.get('routing', {'domainStrategy': 'IPIfNonMatch', 'rules': []})
routing['domainStrategy'] = 'IPIfNonMatch'
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
            xray_bin_path="${xray_dir}/xray/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &
            echo $! > "${xray_dir}/xray.pid"
            echo -e "${GREEN}✅ 自定义域名规则已成功注入并生效（使用本地端口: $warp_local_port）！${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        2)
            echo -e "${YELLOW}正在切换为全局双栈 WARP 模式...${NC}"
            python3 -c "
import json
cfg_file = '${cfg_json}'
with open(cfg_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

# 把 warp-out 强制置于 outbounds 列表的最前端作为默认出口
outbounds = data.get('outbounds', [])
other_obs = [ob for ob in outbounds if ob.get('tag') not in ['warp-out', 'direct']]
warp_ob = {
    'tag': 'warp-out',
    'protocol': 'socks',
    'settings': {
        'servers': [{'address': '127.0.0.1', 'port': int('${warp_local_port}')}]
    }
}
direct_ob = {'tag': 'direct', 'protocol': 'freedom', 'settings': {}}

# 设置 outbounds 顺序: [warp-out, direct, 其他...]
data['outbounds'] = [warp_ob, direct_ob] + other_obs

# 精确路由：把中国大陆流量和私有 IP 排除，其余所有入站（vless-in, trojan-in等）出站强制走 warp-out
routing = {
    'domainStrategy': 'IPIfNonMatch',
    'rules': [
        { 'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:cn'] },
        { 'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:cn', 'geoip:private'] },
        { 'type': 'field', 'outboundTag': 'warp-out', 'network': 'tcp,udp' }
    ]
}
data['routing'] = routing

with open(cfg_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
            pkill -f xray || true
            xray_bin_path="${xray_dir}/xray/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &
            echo $! > "${xray_dir}/xray.pid"
            echo -e "${GREEN}✅ 已成功切换为【全局双栈 WARP 模式】！代理流量已全额接管。${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        3)
            echo ""
            echo -e "${CYAN}📊 当前 WARP 客户端状态：${NC}"
            warp-cli status
            echo -e "📌 当前本地 SOCKS 代理监听端口: ${GREEN}$warp_local_port${NC}"
            echo -e "🔍 测试通过 WARP 的出口 IPv4: ${GREEN}$(curl -s4 --socks5 127.0.0.1:"$warp_local_port" https://api.ip.sb 2>/dev/null || echo "获取失败")${NC}"
            echo -e "🔍 测试通过 WARP 的出口 IPv6: ${GREEN}$(curl -s6 --socks5 127.0.0.1:"$warp_local_port" https://api6.ip.sb 2>/dev/null || echo "获取失败")${NC}"
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
        if not any(ob.get('tag') == 'direct' or ob.get('protocol') == 'freedom' for ob in data['outbounds']):
            data['outbounds'].append({'tag': 'direct', 'protocol': 'freedom', 'settings': {}})
    
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
            xray_bin_path="${xray_dir}/xray/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &
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
```[cite: 21]

