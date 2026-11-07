#!/bin/bash

# 定义主目录
YUZHOU_DIR="/etc/yuzhou"
MODULES_DIR="${YUZHOU_DIR}/modules"
mkdir -p "$MODULES_DIR"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# ==================== 环境检测函数 ====================
check_system_info() {
    # 1. CPU 与架构
    cpu_model=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "未知 CPU")
    arch=$(uname -m)
    cores=$(nproc 2>/dev/null || echo "1")
    
    # 2. IP 单双栈检测
    local has_v4=0
    local has_v6=0
    curl -s4 --connect-timeout 2 https://api.ip.sb >/dev/null 2>&1 && has_v4=1
    curl -s6 --connect-timeout 2 https://api6.ip.sb >/dev/null 2>&1 && has_v6=1
    
    if [ $has_v4 -eq 1 ] && [ $has_v6 -eq 1 ]; then
        ip_status="${GREEN}双栈 (IPv4 + IPv6)${NC}"
    elif [ $has_v4 -eq 1 ]; then
        ip_status="${YELLOW}单栈 (仅 IPv4)${NC}"
    elif [ $has_v6 -eq 1 ]; then
        ip_status="${YELLOW}单栈 (仅 IPv6)${NC}"
    else
        ip_status="${RED}无网络连接${NC}"
    fi

    # 3. BBR 状态检测
    bbr_result=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "$bbr_result" = "bbr" ]; then
        bbr_status="${GREEN}已开启 (BBR)${NC}"
    else
        bbr_status="${YELLOW}未开启 ($bbr_result)${NC}"
    fi

    # 4. Xray 状态、版本及路径检测
    xray_path=""
    xray_ver=""
    if [ -f "/opt/suoha/xray/xray" ]; then
        xray_path="/opt/suoha/xray/xray"
    elif [ -f "/opt/suoha_quick/xray/xray" ]; then
        xray_path="/opt/suoha_quick/xray/xray"
    elif command -v xray &>/dev/null; then
        xray_path=$(command -v xray)
    fi

    if [ -n "$xray_path" ] && [ -x "$xray_path" ]; then
        xray_ver=$($xray_path version 2>/dev/null | head -n 1 | awk '{print $2}')
        xray_status="${GREEN}已安装${NC} (路径: $xray_path, 版本: ${xray_ver:-未知})"
    else
        xray_status="${RED}未安装${NC}"
    fi

    # 5. WARP 状态检测
    if command -v warp-cli &>/dev/null && systemctl is-active --quiet warp-svc 2>/dev/null; then
        warp_status="${GREEN}已安装并运行${NC}"
    elif command -v warp-cli &>/dev/null; then
        warp_status="${YELLOW}已安装但未运行${NC}"
    else
        warp_status="${RED}未安装${NC}"
    fi

    # 6. 域名与证书检测
    if [ -f "/root/.cloudflared/cert.pem" ] || [ -d "/root/.cloudflared" ] && [ "$(ls -A /root/.cloudflared 2>/dev/null)" ]; then
        domain_status="${GREEN}已配置 Argo/域名授权${NC}"
    else
        domain_status="${YELLOW}未检测到本地域名/Argo授权缓存${NC}"
    fi
}

# ==================== 主菜单界面 ====================
show_menu() {
    clear
    check_system_info
    
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}          yuzhou的vps快捷xray脚本 (主控菜单)                ${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo -e " 🖥️  CPU 芯片 : $cpu_model ($cores 核心 / 架构: $arch)"
    echo -e " 🌐 IP 栈状态 : $ip_status"
    echo -e " 🚀 BBR 加速  : $bbr_status"
    echo -e " 📦 Xray 状态 : $xray_status"
    echo -e " ☁️  WARP 状态 : $warp_status"
    echo -e " 🏷️  域名/证书 : $domain_status"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    echo -e " 1. 加固 VPS 主机系统 (修改端口/用户/禁用Root)"
    echo -e " 2. 梭哈模式 (自动生成 VLESS + Trojan 443 优选节点)"
    echo -e " 3. 安装服务 (自定义域名绑定固定 Argo 隧道)"
    echo -e " 4. 卸载服务与清理"
    echo -e " 5. 清空当前节点缓存"
    echo -e " 6. 额外增加 IPv6 SS 共存部署"
    echo -e " 7. 额外增加 Hysteria 2 直连备用节点"
    echo -e " 8. 配置 Cloudflare WARP 灵活路由与分流"
    echo -e " 9. 开启/管理 BBR 加速"
    echo -e " 10. 绑定域名 / 申请 SSL 证书 (acme)"
    echo -e " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo -e "${CYAN}==============================================================${NC}"
}

# ==================== 选项分发逻辑 ====================
while true; do
    show_menu
    read -p "请选择操作编号 [0-10]: " choice
    [ -z "$choice" ] && choice=0

    case "$choice" in
        1)
            # 后续可改为调用: bash "${MODULES_DIR}/1_hardening.sh"
            echo "正在执行第 1 项: 加固 VPS 主机..."
            # 预留接口
            read -p "按回车键返回主菜单..."
            ;;
        2)
            echo "正在执行第 2 项: 梭哈模式..."
            read -p "按回车键返回主菜单..."
            ;;
        3)
            echo "正在执行第 3 项: 安装固定 Argo 服务..."
            read -p "按回车键返回主菜单..."
            ;;
        4)
            echo "正在执行第 4 项: 卸载服务..."
            read -p "按回车键返回主菜单..."
            ;;
        5)
            echo "正在执行第 5 项: 清空缓存..."
            read -p "按回车键返回主菜单..."
            ;;
        6)
            echo "正在执行第 6 项: IPv6 SS 部署..."
            read -p "按回车键返回主菜单..."
            ;;
        7)
            echo "正在执行第 7 项: Hysteria 2 部署..."
            read -p "按回车键返回主菜单..."
            ;;
        8)
            echo "正在执行第 8 项: WARP 路由分流..."
            read -p "按回车键返回主菜单..."
            ;;
        9)
            echo "正在执行第 9 项: BBR 管理..."
            read -p "按回车键返回主菜单..."
            ;;
        10)
            echo "正在执行第 10 项: 绑定域名 (acme)..."
            read -p "按回车键返回主菜单..."
            ;;
        0)
            echo -e "${GREEN}已成功退出脚本。${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请重新输入！${NC}"
            sleep 1
            ;;
    esac
done
