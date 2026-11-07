#!/bin/bash

# ==============================================================
# BBR 拥塞控制开关与内核优化管理模块 (bbr_daima.sh)
# 完美适配 Debian系 与 红帽系 系统
# ==============================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# 1. 检查 BBR 是否已开启
_bbr_check() {
    local result
    result=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    [ "$result" = "bbr" ]
}

# 2. 开启 BBR 核心逻辑
_bbr_enable() {
    echo -e "${CYAN}----------------------------------------${NC}"
    echo -e "${YELLOW}正在检查系统内核版本与模块支持...${NC}"
    
    local kernel_version
    kernel_version=$(uname -r | awk -F. '{print $1*100 + $2}')
    
    if [ "$kernel_version" -lt 409 ]; then
        echo -e "${RED}❌ 错误：当前内核版本低于 4.9，系统不支持原生 BBR！${NC}"
        return 1
    fi

    if ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${YELLOW}⚠️ 警告：无法动态加载 tcp_bbr 模块，请检查当前内核是否编译了 BBR 支持。${NC}"
    fi

    if [ -d /etc/modules-load.d ]; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    else
        if ! grep -Fxq "tcp_bbr" /etc/modules 2>/dev/null; then
            echo "tcp_bbr" >> /etc/modules
        fi
    fi

    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    mkdir -p /etc/sysctl.d
    cat > "$sysctl_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1
    
    if _bbr_check; then
        echo -e "${GREEN}✅ 成功：BBR 已成功开启并即时生效！${NC}"
    else
        echo -e "${YELLOW}❌ 警告：配置已写入，但当前未能实时生效，建议重启系统后再次检查。${NC}"
    fi
    echo -e "${CYAN}----------------------------------------${NC}"
}

# 3. 关闭 BBR 核心逻辑 (恢复系统默认 cubic)
_bbr_disable() {
    echo -e "${CYAN}----------------------------------------${NC}"
    echo -e "${YELLOW}正在关闭 BBR 并清理相关配置...${NC}"
    
    local sysctl_file="/etc/sysctl.d/99-bbr.conf"
    
    [ -f "$sysctl_file" ] && rm -f "$sysctl_file"
    [ -f /etc/modules-load.d/bbr.conf ] && rm -f /etc/modules-load.d/bbr.conf
    sed -i '/tcp_bbr/d' /etc/modules 2>/dev/null

    mkdir -p /etc/sysctl.d
    echo "net.ipv4.tcp_congestion_control=cubic" > "$sysctl_file"
    
    echo "正在将内核拥塞控制切换为 cubic..."
    if ! sysctl -w net.ipv4.tcp_congestion_control=cubic; then
        echo -e "${YELLOW}⚠️ 提示：实时修改内核参数失败，可能当前系统环境（如部分受限容器）不支持修改。${NC}"
    fi

    sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1
    
    if _bbr_check; then
        echo -e "${RED}❌ 警告：BBR 关闭失败，当前内核状态仍为 bbr！${NC}"
        echo -e "${YELLOW}💡 提示：部分特殊定制内核可能无法直接在运行时关闭 BBR。${NC}"
    else
        echo -e "${GREEN}🔒 成功：BBR 已彻底关闭，当前已恢复为系统默认 cubic 算法。${NC}"
    fi
    echo -e "${CYAN}----------------------------------------${NC}"
}

# 4. 主菜单与交互界面
manage_bbr() {
    if [ $EUID -ne 0 ]; then
       echo -e "${RED}❌ 错误：请使用 root 权限运行此功能！${NC}"
       return 1
    fi

    while true; do
        clear
        echo -e "${CYAN}========================================"
        echo -e "           BBR 拥塞控制管理             "
        echo -e "========================================${NC}"
        if _bbr_check; then
            echo -e "当前状态: [ ${GREEN}🔥 BBR 已开启${NC} ]"
        else
            echo -e "当前状态: [ ${YELLOW}⏳ BBR 未开启${NC} ]"
        fi
        echo -e "${CYAN}----------------------------------------${NC}"
        echo "1. 开启 BBR (检测内核并启用)"
        echo "2. 关闭 BBR (恢复系统默认 cubic)"
        echo "0. 返回上一级菜单"
        echo -e "${CYAN}========================================${NC}"
        read -p "请输入选项 [1-2, 0]: " sub_choice < /dev/tty
        
        case "$sub_choice" in
            1)
                _bbr_enable
                read -p "按回车键继续..." < /dev/tty
                ;;
            2)
                _bbr_disable
                read -p "按回车键继续..." < /dev/tty
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}❌ 无效选项，请重新输入。${NC}"
                sleep 1
                ;;
        esac
    done
}

# 脚本单独运行时的入口
manage_bbr
