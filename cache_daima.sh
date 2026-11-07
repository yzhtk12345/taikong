#!/bin/bash

# ==============================================================
# 清空缓存管理模块 (cache_daima.sh)
# 适配 Debian系 与 红帽系 系统
# ==============================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

# 清空缓存核心逻辑
_clear_cache() {
    echo -e "${YELLOW}正在清理临时进程与缓存文件...${NC}"
    
    os_name=$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f2 | awk '{print $1}')
    if [ "$os_name" == "Alpine" ]; then
        pids_xray=$(ps -ef | grep xray | grep -v grep | awk '{print $1}')
        [ -n "$pids_xray" ] && kill -9 $pids_xray >/dev/null 2>&1
        pids_cf=$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $1}')
        [ -n "$pids_cf" ] && kill -9 $pids_cf >/dev/null 2>&1
    else
        pids_xray=$(ps -ef | grep xray | grep -v grep | awk '{print $2}')
        [ -n "$pids_xray" ] && kill -9 $pids_xray >/dev/null 2>&1
        pids_cf=$(ps -ef | grep cloudflared-linux | grep -v grep | awk '{print $2}')
        [ -n "$pids_cf" ] && kill -9 $pids_cf >/dev/null 2>&1
    fi
    pkill -f "http.server" >/dev/null 2>&1
    
    # 清理梭哈模式下的临时缓存文件
    rm -rf /opt/suoha_quick/nodes.txt /opt/suoha_quick/sub.txt /opt/suoha_quick/clash.yaml \
           nodes.txt sub.txt clash.yaml >/dev/null 2>&1
           
    echo -e "${GREEN}✅ 缓存及临时进程已成功清空！${NC}"
}

# 清空缓存管理菜单
manage_cache() {
    if [ "$EUID" -ne 0 ]; then
       echo -e "${RED}❌ 错误：请使用 root 权限运行此功能！${NC}"
       return 1
    fi

    while true; do
        clear
        echo -e "${CYAN}========================================"
        echo -e "             清空缓存管理菜单           "
        echo -e "========================================${NC}"
        echo "1. 确认清空临时运行缓存与节点文件"
        echo "0. 返回上一级菜单"
        echo -e "${CYAN}========================================${NC}"
        read -p "请输入选项 [1, 0]: " sub_choice
        
        case "$sub_choice" in
            1)
                echo ""
                _clear_cache
                read -p "按回车键继续..."
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

manage_cache
