#!/bin/bash

# ==============================================================
# 服务卸载与清理管理模块 (del_daima.sh)
# 适配 Debian系 与 红帽系 系统 (路径已更新至 /etc/yuzhou)
# ==============================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# 卸载核心逻辑
_uninstall_all() {
    echo -e "${YELLOW}正在停止并清理所有相关服务与文件...${NC}"
    
    os_name=$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f2 | awk '{print $1}')
    if [ "$os_name" == "Alpine" ]
    then
        pids_xray=$(ps -ef | grep xray | grep -v grep | awk '{print $1}')
        [ -n "$pids_xray" ] && kill -9 $pids_xray >/dev/null 2>&1
        pids_cf=$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}')
        [ -n "$pids_cf" ] && kill -9 $pids_cf >/dev/null 2>&1
        pkill -f "http.server" >/dev/null 2>&1
        rm -rf /opt/suoha /opt/suoha_quick /etc/yuzhou /etc/local.d/cloudflared.start /etc/local.d/xray.start /usr/bin/suoha /etc/suoha_sub_port /var/www/suoha_sub
    else
        systemctl stop cloudflared.service >/dev/null 2>&1
        systemctl stop xray.service >/dev/null 2>&1
        systemctl disable cloudflared.service >/dev/null 2>&1
        systemctl disable xray.service >/dev/null 2>&1
        
        pids_xray=$(ps -ef | grep xray | grep -v grep | awk '{print $2}')
        [ -n "$pids_xray" ] && kill -9 $pids_xray >/dev/null 2>&1
        pids_cf=$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}')
        [ -n "$pids_cf" ] && kill -9 $pids_cf >/dev/null 2>&1
        pkill -f "http.server" >/dev/null 2>&1
        
        # 核心路径更新：包含 /etc/yuzhou
        rm -rf /opt/suoha /opt/suoha_quick /etc/yuzhou /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha ~/.cloudflared /etc/suoha_sub_port /var/www/suoha_sub
        systemctl --system daemon-reload >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}所有服务及相关文件已卸载完成！${NC}"
    echo -e "${CYAN}提示：如需彻底删除 Cloudflare 授权记录，请访问:${NC}"
    echo -e "https://dash.cloudflare.com/profile/api-tokens"
    echo -e "删除对应的 Argo Tunnel API Token 即可。"
}

# 卸载管理菜单
manage_uninstall() {
    if [ "$EUID" -ne 0 ]; then
       echo -e "${RED}❌ 错误：请使用 root 权限运行此功能！${NC}"
       return 1
    fi

    while true; do
        clear
        echo -e "${CYAN}========================================"
        echo -e "           服务卸载管理菜单             "
        echo -e "========================================${NC}"
        echo "1. 确认卸载并清理所有相关服务和文件"
        echo "0. 返回上一级菜单"
        echo -e "${CYAN}========================================${NC}"
        read -p "请输入选项 [1, 0]: " sub_choice < /dev/tty
        
        case "$sub_choice" in
            1)
                echo ""
                read -p "确定要彻底卸载所有服务吗？[y/N]: " confirm < /dev/tty
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    _uninstall_all
                else
                    echo "已取消卸载操作。"
                fi
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

manage_uninstall
