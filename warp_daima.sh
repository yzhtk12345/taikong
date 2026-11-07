#!/bin/bash

# ==============================================================
# Cloudflare WARP 原生 WireGuard (wgcf) 自动注册与分流模块 (warp_daima.sh)
# 路径严格统一至 /etc/yuzhou/
# 优势：不依赖官方 warp-cli 客户端，内核级 WireGuard 极速连通
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
WG_DIR="${YUZHOU_DIR}/wireguard"
LAST_WARP_PORT_FILE="${YUZHOU_DIR}/last_warp_port.txt"
mkdir -p "$WG_DIR"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# 1. 检测 Xray 配置文件及路径
xray_dir=""
cfg_json=""

if [ -f "${YUZHOU_DIR}/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/xray"
    cfg_json="${YUZHOU_DIR}/xray/config.json"
elif [ -f "${YUZHOU_DIR}/quick/xray/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/quick"
    cfg_json="${YUZHOU_DIR}/quick/xray/config.json"
elif [ -f "/opt/suoha_quick/xray/config.json" ]; then
    xray_dir="/opt/suoha_quick/xray"
    cfg_json="/opt/suoha_quick/xray/config.json"
else
    clear
    echo -e "${RED}[错误] 未找到正在运行的 Xray 配置文件，请先执行主菜单的节点部署！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

# 2. 清理有问题的官方 warp-cli，安装 WireGuard 环境
if command -v warp-cli &>/dev/null; then
    echo -e "${YELLOW}正在停用并清理旧的官方 warp-cli 服务...${NC}"
    systemctl stop warp-svc >/dev/null 2>&1
    systemctl disable warp-svc >/dev/null 2>&1
fi

if ! command -v wg &>/dev/null || ! command -v wg-quick &>/dev/null; then
    echo -e "${CYAN}正在安装 Linux 原生 WireGuard 内核组件...${NC}"
    apt update && apt install -y wireguard wireguard-tools resolvconf curl jq >/dev/null 2>&1
fi

# 3. 在本地全自动通过 wgcf 获取底层配置文件
cd "$WG_DIR" || exit

if [ ! -f "wgcf-profile.conf" ]; then
    echo -e "${CYAN}正在为您向 Cloudflare 自动申请原生 WARP WireGuard 配置...${NC}"
    
    arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        wgcf_arch="linux_amd64"
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        wgcf_arch="linux_arm64"
    else
        wgcf_arch="linux_amd64"
    fi

    # 优先下载 wgcf 工具
    if [ ! -f "wgcf" ]; then
        curl -sL "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_${wgcf_arch}" -o wgcf
        chmod +x wgcf
    fi

    # 循环尝试注册，解决网络超时问题
    for retry in {1..3}; do
        echo -e "${YELLOW}尝试向 API 注册账号 (第 $retry 次)...${NC}"
        ./wgcf register --accept-tos >/dev/null 2>&1
        ./wgcf generate >/dev/null 2>&1
        [ -f "wgcf-profile.conf" ] && break
        sleep 2
    done

    if [ ! -f "wgcf-profile.conf" ]; then
        echo -e "${RED}[错误] 自动申请失败！请检查 VPS 连接外网的 API 连通性。${NC}"
        read -p "按回车键返回..." < /dev/tty
        exit 1
    fi
fi

# 4. 保持您的特色：动态随机生成 SOCKS 端口 (用于状态检测与局部分流)
while true; do
    warp_local_port=$((RANDOM % 20000 + 30000))
    if ! ss -tlnp | grep -q ":${warp_local_port} "; then
        break
    fi
done
echo "$warp_local_port" > "$LAST_WARP_PORT_FILE"

# 交互菜单
while true; do
    clear
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}   Cloudflare WARP 原生 WireGuard 分流管理 (全自动版)         ${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo "1. 自定义添加指定域名走 WARP"
    echo "2. 切换为【全局双栈模式】：所有外网流量强制走 WARP (伪装IP+解封)"
    echo "3. 查看当前 WARP 状态与出口 IP"
    echo "4. 关闭并停用 WARP 代理（恢复默认直连）"
    echo "0. 返回上级主菜单"
    echo -e "${CYAN}==============================================================${NC}"
    read -p "请选择操作 [0-4]: " warp_choice < /dev/tty

    case "$warp_choice" in
        1)
            echo ""
            read -p "请输入需要走 WARP 的域名 (多个空格隔开): " user_domains < /dev/tty
            [ -z "$user_domains" ] && continue

            # 启动 WireGuard 虚拟网卡
            cp -f wgcf-profile.conf /etc/wireguard/wg0.conf
            systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
            wg-quick up wg0 >/dev/null 2>&1 || true

            python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    data = json.load(f)

routing = data.get('routing', {'domainStrategy': 'AsIs', 'rules': []})
rules = routing.get('rules', [])

custom_rule = next((r for r in rules if r.get('tag') == 'custom-warp-rule'), None)
new_domains = '$user_domains'.split()

if not custom_rule:
    rules.insert(0, {'type': 'field', 'outboundTag': 'direct', 'domain': new_domains, 'tag': 'custom-warp-rule'})
else:
    custom_rule['domain'] = list(set(custom_rule.get('domain', []) + new_domains))

routing['rules'] = rules
data['routing'] = routing
with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
            pkill -f xray || true
            xray_bin_path="${xray_dir}/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/../xray/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &
            
            echo -e "${GREEN}✅ 自定义域名 WARP 分流已成功生效！${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        2)
            echo -e "${YELLOW}正在启动原生 WireGuard 并切换为全局双栈 WARP...${NC}"
            
            cp -f wgcf-profile.conf /etc/wireguard/wg0.conf
            systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
            wg-quick up wg0 >/dev/null 2>&1 || true

            # 设置 Xray 基础路由，防止冲突
            python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    data = json.load(f)

data['routing'] = {
    'domainStrategy': 'AsIs',
    'rules': [
        { 'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:private', 'geoip:cn'] },
        { 'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:cn'] }
    ]
}

with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
"
            pkill -f xray || true
            xray_bin_path="${xray_dir}/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/../xray/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &
            
            echo -e "${GREEN}✅ 已成功切换为【全局双栈 WARP 模式】！系统出口 IP 已被成功伪装。${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        3)
            echo ""
            echo -e "${CYAN}📊 WireGuard 网卡运行状态：${NC}"
            wg show wg0 2>/dev/null || echo -e "${RED}WARP 网卡未启动！${NC}"
            echo ""
            echo -e "🔍 当前伪装后的真实出口 IPv4: ${GREEN}$(curl -s4 --connect-timeout 3 https://api.ip.sb 2>/dev/null || echo "获取失败")${NC}"
            echo -e "🔍 当前伪装后的真实出口 IPv6: ${GREEN}$(curl -s6 --connect-timeout 3 https://api6.ip.sb 2>/dev/null || echo "获取失败")${NC}"
            echo ""
            read -p "按回车键继续..." < /dev/tty
            ;;
        4)
            echo -e "${YELLOW}正在停用 WARP 虚拟网卡并恢复默认直连...${NC}"
            systemctl disable --now wg-quick@wg0 >/dev/null 2>&1
            wg-quick down wg0 >/dev/null 2>&1 || true
            
            python3 -c "
import json
cfg_file = '$cfg_json'
try:
    with open(cfg_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if 'routing' in data:
        del data['routing']
    with open(cfg_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
except Exception:
    pass
"
            pkill -f xray || true
            xray_bin_path="${xray_dir}/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/../xray/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &

            echo -e "${GREEN}✅ WARP 已成功停用，网络已完全恢复直连！${NC}"
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
