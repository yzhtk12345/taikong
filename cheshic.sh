#!/bin/bash

# ==================== 目录及基础配置 ====================
YUZHOU_DIR="/etc/yuzhou"
MODULES_DIR="${YUZHOU_DIR}/modules"
mkdir -p "$MODULES_DIR"

SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# ==================== 环境检测函数 ====================
check_system_info() {
    cpu_model=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "未知 CPU")
    cores=$(nproc 2>/dev/null || echo "1")
    
    arch=$(uname -m)
    x86_v_level="非 x86_64 架构"
    if [ "$arch" = "x86_64" ]; then
        has_v2=0; has_v3=0; has_v4=0
        grep -q "cx16" /proc/cpuinfo && grep -q "lahf_lm" /proc/cpuinfo && grep -q "popcnt" /proc/cpuinfo && grep -q "sse4_1" /proc/cpuinfo && grep -q "sse4_2" /proc/cpuinfo && grep -q "ssse3" /proc/cpuinfo && has_v2=1
        if [ $has_v2 -eq 1 ]; then
            grep -q "avx" /proc/cpuinfo && grep -q "avx2" /proc/cpuinfo && grep -q "bmi1" /proc/cpuinfo && grep -q "bmi2" /proc/cpuinfo && grep -q "f16c" /proc/cpuinfo && grep -q "fma" /proc/cpuinfo && grep -q "abm" /proc/cpuinfo && grep -q "movbe" /proc/cpuinfo && grep -q "xsave" /proc/cpuinfo && has_v3=1
        fi
        if [ $has_v3 -eq 1 ]; then
            grep -q "avx512f" /proc/cpuinfo && grep -q "avx512bw" /proc/cpuinfo && grep -q "avx512cd" /proc/cpuinfo && grep -q "avx512dq" /proc/cpuinfo && grep -q "avx512vl" /proc/cpuinfo && has_v4=1
        fi

        if [ $has_v4 -eq 1 ]; then
            x86_v_level="x86-64-v4 (AVX-512)"
        elif [ $has_v3 -eq 1 ]; then
            x86_v_level="x86-64-v3 (AVX2)"
        elif [ $has_v2 -eq 1 ]; then
            x86_v_level="x86-64-v2 (SSE4.2)"
        else
            x86_v_level="x86-64-v1 (基础版)"
        fi
    fi

    if [ -f /etc/os-release ]; then
        os_version=$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)
    else
        os_version="未知系统"
    fi
    kernel_version=$(uname -r)

    local_v4=$(curl -s4 --connect-timeout 2 https://api.ip.sb 2>/dev/null || curl -s4 --connect-timeout 2 https://ipv4.icanhazip.com 2>/dev/null)
    if [ -n "$local_v4" ]; then
        local_v4_status="${GREEN}${local_v4}${NC}"
    else
        local_v4_status="${RED}无 (未检测到本地IPv4)${NC}"
    fi

    local_v6=$(curl -s6 --connect-timeout 2 https://api6.ip.sb 2>/dev/null || curl -s6 --connect-timeout 2 https://ipv6.icanhazip.com 2>/dev/null)
    if [ -z "$local_v6" ]; then
        local_v6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n 1 2>/dev/null)
    fi
    if [ -n "$local_v6" ]; then
        local_v6_status="${GREEN}${local_v6}${NC}"
    else
        local_v6_status="${YELLOW}无 (未检测到本地IPv6)${NC}"
    fi

    # 读取本地 WARP SOCKS 端口
    warp_socks_port=""
    [ -f "${YUZHOU_DIR}/last_warp_port.txt" ] && warp_socks_port=$(cat "${YUZHOU_DIR}/last_warp_port.txt" 2>/dev/null | tr -d '\n\r ')

    # WARP IPv4 出站检测
    if [ -n "$warp_socks_port" ]; then
        warp_v4=$(curl -s4 --socks5 127.0.0.1:"$warp_socks_port" --connect-timeout 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -i "warp=on")
    else
        warp_v4=$(curl -s4 --connect-timeout 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -i "warp=on")
    fi

    if [ -n "$warp_v4" ]; then
        if [ -n "$warp_socks_port" ]; then
            warp_v4_ip=$(curl -s4 --socks5 127.0.0.1:"$warp_socks_port" --connect-timeout 2 https://api.ip.sb 2>/dev/null)
        else
            warp_v4_ip=$(curl -s4 --connect-timeout 2 https://api.ip.sb 2>/dev/null)
        fi
        warp_v4_status="${GREEN}已激活 (${warp_v4_ip:-WARP-SOCKS5: $warp_socks_port})${NC}"
    else
        warp_v4_status="${YELLOW}未连接/未启用${NC}"
    fi

    # WARP IPv6 出站检测 (双重备用节点检测与降级兼容)
    warp_v6=""
    warp_v6_ip=""
    if [ -n "$warp_socks_port" ]; then
        warp_v6=$(curl -s6 --socks5 127.0.0.1:"$warp_socks_port" --connect-timeout 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -i "warp=on")
        if [ -z "$warp_v6" ]; then
            warp_v6_ip=$(curl -s6 --socks5 127.0.0.1:"$warp_socks_port" --connect-timeout 2 https://api6.ip.sb 2>/dev/null || curl -s --socks5 127.0.0.1:"$warp_socks_port" --connect-timeout 2 https://v6.ident.me 2>/dev/null)
        else
            warp_v6_ip=$(curl -s6 --socks5 127.0.0.1:"$warp_socks_port" --connect-timeout 2 https://api6.ip.sb 2>/dev/null)
        fi
    else
        warp_v6=$(curl -s6 --connect-timeout 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -i "warp=on")
        [ -n "$warp_v6" ] && warp_v6_ip=$(curl -s6 --connect-timeout 2 https://api6.ip.sb 2>/dev/null)
    fi

    if [ -n "$warp_v6_ip" ] || [ -n "$warp_v6" ]; then
        warp_v6_status="${GREEN}已激活 (${warp_v6_ip:-WARP-IPv6-Active})${NC}"
    else
        warp_v6_status="${YELLOW}未连接/未启用${NC}"
    fi

    bbr_result=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "$bbr_result" = "bbr" ]; then
        bbr_status="${GREEN}已开启 (BBR)${NC}"
    else
        bbr_status="${YELLOW}未开启 ($bbr_result)${NC}"
    fi

    # 完美对齐 /etc/yuzhou/ 下的 Xray 安装路径
    xray_path=""
    xray_ver=""
    if [ -f "${YUZHOU_DIR}/quick/xray/xray" ]; then
        xray_path="${YUZHOU_DIR}/quick/xray/xray"
    elif [ -f "${YUZHOU_DIR}/xray/xray" ]; then
        xray_path="${YUZHOU_DIR}/xray/xray"
    elif [ -f "${YUZHOU_DIR}/service/xray/xray" ]; then
        xray_path="${YUZHOU_DIR}/service/xray/xray"
    elif command -v xray &>/dev/null; then
        xray_path=$(command -v xray)
    fi

    if [ -n "$xray_path" ] && [ -x "$xray_path" ]; then
        xray_ver=$($xray_path version 2>/dev/null | head -n 1 | awk '{print $2}')
        xray_status="${GREEN}已安装${NC} (路径: $xray_path, 版本: ${xray_ver:-未知})"
    else
        xray_status="${RED}未安装${NC}"
    fi

    if command -v warp-cli &>/dev/null && systemctl is-active --quiet warp-svc 2>/dev/null; then
        warp_svc_status="${GREEN}已安装并运行${NC}"
    elif command -v warp-cli &>/dev/null; then
        warp_svc_status="${YELLOW}已安装但未运行${NC}"
    else
        warp_svc_status="${RED}未安装${NC}"
    fi

    if [ -f "/root/.acme.sh/acme.sh" ] || [ -d "${YUZHOU_DIR}/domain" ]; then
        domain_check_status="${GREEN}已配置/绑定域名${NC}"
    else
        domain_check_status="${YELLOW}未绑定自定义域名${NC}"
    fi

    argo_pid=$(pgrep -f "cloudflared" 2>/dev/null)
    if [ -n "$argo_pid" ] || systemctl is-active --quiet cloudflared.service 2>/dev/null || systemctl is-active --quiet suoha-quick.service 2>/dev/null; then
        argo_check_status="${GREEN}已运行 (Argo隧道活跃)${NC}"
    elif [ -f "/root/.cloudflared/cert.pem" ] || ([ -d "/root/.cloudflared" ] && [ "$(ls -A /root/.cloudflared 2>/dev/null)" ]); then
        argo_check_status="${GREEN}已授权/有Argo缓存${NC}"
    else
        argo_check_status="${YELLOW}未运行/未授权${NC}"
    fi
}

# ==================== 主菜单界面 ====================
show_menu() {
    clear
    check_system_info
    
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}        yuzhou的vps快捷xray脚本 (主控菜单)                  ${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo -e " 🖥️  CPU 型号     : $cpu_model"
    echo -e " ⚙️  CPU 核心数   : $cores 核心"
    echo -e " 🏗️  CPU 架构     : $arch ($x86_v_level)"
    echo -e " 📦  系统版本     : $os_version"
    echo -e " 🐧  系统内核     : $kernel_version"
    echo -e " 🌐  本地 IPv4    : $local_v4_status"
    echo -e " 🌐  本地 IPv6    : $local_v6_status"
    echo -e " ☁️  WARP 客户端  : $warp_svc_status"
    echo -e " 🛡️  WARP 出站v4  : $warp_v4_status"
    echo -e " 🛡️  WARP 出站v6  : $warp_v6_status"
    echo -e " 🚀  BBR 加速     : $bbr_status"
    echo -e " 📦  Xray 状态    : $xray_status"
    echo -e " 🚇  Argo 状态    : $argo_check_status"
    echo -e " 🏷️  域名状态      : $domain_check_status"
    echo -e " 📂  脚本主目录    : ${GREEN}${YUZHOU_DIR}${NC}"
    echo -e " 📁  当前脚本位置  : ${GREEN}${SCRIPT_PATH}${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    echo -e " 1. 加固 VPS 主机系统 (修改端口/用户/禁用Root/安装防火墙)"
    echo -e " 2. argo 6节点 (自动生成 VLESS + Trojan 443 优选节点)"
    echo -e " 3. 固定 Argo 隧道(没做，以后或许会做)"
    echo -e " 4. 卸载服务与清理"
    echo -e " 5. 清空当前节点缓存"
    echo -e " 6. 额外增加 IPv6 SS 共存部署"
    echo -e " 7. 额外增加 Hysteria 2 直连备用节点"
    echo -e " 8. 配置 Cloudflare WARP 灵活路由与分流"
    echo -e " 9. 开启/管理 BBR 加速"
    echo -e " 10.绑定域名 / 申请 SSL 证书 勇哥acme改"
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
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/linux_anquan.sh)
            read -p "按回车返回..."
            ;;
        2)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/argo_jiedian.sh)
            read -p "按回车返回..."
            ;;
        3)
            echo "正在执行第 3 项: 安装固定 Argo 服务...还没有做"
            read -p "按回车返回..."
            ;;
        4)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/del_daima.sh)
            read -p "按回车返回..."
            ;;
        5)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/cache_daima.sh)
            read -p "按回车返回..."
            ;;
        6)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/ss_jiedian.sh)
            read -p "按回车返回..."
            ;;
        7)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/hy2_jiedian.sh)
            read -p "按回车返回..."
            ;;
        8)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/warp_daima.sh)
            read -p "按回车返回..."
            ;;
        9)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/bbr_daima.sh)
            read -p "按回车返回..."
            ;;
        10)
            bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/yzhtk12345/taikong/refs/heads/main/acme.sh)
            read -p "按回车返回..."
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
