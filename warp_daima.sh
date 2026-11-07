#!/bin/bash

# ==============================================================
# Cloudflare WARP 原生 WireGuard (wgcf) 完美替代模块 (warp_daima.sh)
# 路径严格统一至 /etc/yuzhou/
# ==============================================================

YUZHOU_DIR="/etc/yuzhou"
WG_DIR="${YUZHOU_DIR}/wireguard"
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
elif [ -f "${YUZHOU_DIR}/service/config.json" ]; then
    xray_dir="${YUZHOU_DIR}/service"
    cfg_json="${YUZHOU_DIR}/service/config.json"
else
    clear
    echo -e "${RED}[错误] 未在 /etc/yuzhou/ 下找到正在运行的 Xray 配置文件！${NC}"
    read -p "按回车键返回..." < /dev/tty
    exit 1
fi

# 2. 清理并卸载有问题的官方 warp-cli 客户端，安装原生 WireGuard 工具
if command -v warp-cli &>/dev/null; then
    echo -e "${YELLOW}正在清理并卸载冲突的官方 warp-cli 客户端...${NC}"
    systemctl stop warp-svc >/dev/null 2>&1
    apt purge -y cloudflare-warp >/dev/null 2>&1
fi

if ! command -v wg &>/dev/null || ! command -v wg-quick &>/dev/null; then
    echo -e "${CYAN}正在安装系统原生 WireGuard 及相关依赖...${NC}"
    apt update && apt install -y wireguard wireguard-tools resolvconf curl jq >/dev/null 2>&1
fi

# 3. 核心：下载或生成 wgcf 配置文件（无需官方客户端，直接对接 Cloudflare 节点）
cd "$WG_DIR" || exit

if [ ! -f "wgcf-profile.conf" ]; then
    echo -e "${CYAN}正在通过 wgcf 申请 Cloudflare WARP 账号并生成底层配置...${NC}"
    
    # 自动判断系统架构下载对应的 wgcf 工具
    arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        wgcf_arch="linux_amd64"
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        wgcf_arch="linux_arm64"
    else
        wgcf_arch="linux_amd64"
    fi

    curl -sL "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_${wgcf_arch}" -o wgcf
    chmod +x wgcf

    # 注册账号并生成配置
    ./wgcf register --accept-tos >/dev/null 2>&1
    ./wgcf generate >/dev/null 2>&1
    
    if [ ! -f "wgcf-profile.conf" ]; then
        echo -e "${RED}[错误] 申请 WARP 账号失败，请检查网络或稍后重试！${NC}"
        read -p "按回车键返回..." < /dev/tty
        exit 1
    fi
fi

# 4. 路由分流交互菜单
while true; do
    clear
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}   Cloudflare WARP 原生分流管理 (WireGuard 模式)             ${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo "1. 启动并连接 WARP (全局接管外网流量，突破IP限制并隐藏本地IP)"
    echo "2. 查看当前 WARP 连接状态与隐藏后的出口 IP"
    echo "3. 关闭并停用 WARP（恢复服务器默认本地 IP）"
    echo "0. 返回上级主菜单"
    echo -e "${CYAN}==============================================================${NC}"
    read -p "请选择操作 [0-3]: " warp_choice < /dev/tty

    case "$warp_choice" in
        1)
            echo -e "${YELLOW}正在启动 WARP 虚拟网卡并接管外网流量...${NC}"
            
            # 停止旧的 wg0 接口防止冲突
            wg-quick down wg0 >/dev/null 2>&1 || true
            
            # 将生成的配置软链接到系统的 wireguard 目录
            cp -f wgcf-profile.conf /etc/wireguard/wg0.conf
            
            # 启动 wg0 网卡
            systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
            wg-quick up wg0 >/dev/null 2>&1 || true

            # 同时修改 Xray 路由，确保所有代理节点和外网出口干净走 WARP
            python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    d = json.load(f)
d['inbounds'] = d.get('inbounds', [])
# 确保直连 outbound 存在
obs = [o for o in d.get('outbounds', []) if o.get('tag') != 'direct']
obs.append({'tag': 'direct', 'protocol': 'freedom', 'settings': {}})
d['outbounds'] = obs
# 设置全局路由：国内直连，其余全部通过系统默认网卡（此时已被 wg0 接管）走 WARP
d['routing'] = {
    'domainStrategy': 'IPIfNonMatch',
    'rules': [
        { 'type': 'field', 'outboundTag': 'direct', 'ip': ['127.0.0.0/8', '::1/128', 'geoip:private', 'geoip:cn'] },
        { 'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:cn'] }
    ]
}
with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=4, ensure_ascii=False)
"
            pkill -f xray || true
            xray_bin_path="${xray_dir}/xray/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &
            
            echo -e "${GREEN}✅ WARP 全局接管已成功启用！您的本地真实 IP 已被完全伪装。${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        2)
            echo ""
            echo -e "${CYAN}📊 WireGuard 网卡运行状态：${NC}"
            wg show wg0 2>/dev/null || echo -e "${RED}WARP 网卡未启动！${NC}"
            echo ""
            echo -e "🔍 当前服务器对外显示的真实出口 IPv4: ${GREEN}$(curl -s4 https://api.ip.sb 2>/dev/null || echo "获取失败")${NC}"
            echo -e "🔍 当前服务器对外显示的真实出口 IPv6: ${GREEN}$(curl -s6 https://api6.ip.sb 2>/dev/null || echo "获取失败")${NC}"
            echo ""
            read -p "按回车键继续..." < /dev/tty
            ;;
        3)
            echo -e "${YELLOW}正在关闭 WARP 并恢复默认网络...${NC}"
            systemctl disable --now wg-quick@wg0 >/dev/null 2>&1
            wg-quick down wg0 >/dev/null 2>&1 || true
            
            # 清理 Xray 路由
            python3 -c "
import json
with open('$cfg_json', 'r', encoding='utf-8') as f:
    d = json.load(f)
if 'routing' in d:
    del d['routing']
with open('$cfg_json', 'w', encoding='utf-8') as f:
    json.dump(d, f, indent=4, ensure_ascii=False)
"
            pkill -f xray || true
            xray_bin_path="${xray_dir}/xray/xray"
            [ ! -f "$xray_bin_path" ] && xray_bin_path="${xray_dir}/xray"
            nohup "$xray_bin_path" run -config "$cfg_json" >/dev/null 2>&1 &
            
            echo -e "${GREEN}✅ WARP 已关闭，网络已完全恢复直连状态！${NC}"
            read -p "按回车键继续..." < /dev/tty
            ;;
        0)
            break
            ;;
    esac
done
