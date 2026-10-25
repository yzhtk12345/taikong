
#!/usr/bin/env bash

# Taikong VPS Manager
# User and Privilege Management
# Phase 1: Read-only inspection

user_manager_menu() {
    while true; do
        echo
        echo "========== 管理账号与权限 =========="
        echo "1) 查看当前登录账号"
        echo "2) 查看现有用户账号"
        echo "3) 检查管理员权限配置"
        echo "0) 返回主菜单"
        echo "===================================="

        local choice
        read -r -p "请输入选项 [0-3]: " choice || choice=0

        case "$choice" in
            1)
                user_manager_show_current
                ;;
            2)
                user_manager_list_users
                ;;
            3)
                user_manager_check_privileges
                ;;
            0)
                return 0
                ;;
            *)
                echo "[错误] 输入无效，请输入 0、1、2 或 3。"
                ;;
        esac
    done
}

user_manager_show_current() {
    echo
    echo "========== 当前登录账号 =========="
    echo "当前用户：$(id -un 2>/dev/null || echo 未知)"
    echo "用户 UID：$(id -u 2>/dev/null || echo 未知)"
    echo "用户组："
    id -Gn 2>/dev/null || echo "无法读取用户组信息"

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        echo "当前权限：root"
    else
        echo "当前权限：普通用户"
    fi

    echo "==================================="
}

user_manager_list_users() {
    echo
    echo "========== 本地用户账号 =========="

    if [[ ! -r /etc/passwd ]]; then
        echo "[错误] 无法读取 /etc/passwd。"
        return 1
    fi

    if command -v awk >/dev/null 2>&1; then
        awk -F: '
            $3 == 0 {
                printf "UID=%s  用户=%s  类型=root权限账号\n", $3, $1
                next
            }
            $3 >= 1000 && $3 < 65534 {
                printf "UID=%s  用户=%s  类型=普通用户候选\n", $3, $1
            }
        ' /etc/passwd
    else
        echo "[错误] 未找到 awk，无法列出账号。"
        return 1
    fi

    echo
    echo "[说明] UID 范围只是常见分类，不代表账号一定能登录。"
    echo "=================================="
}

user_manager_check_privileges() {
    echo
    echo "========== 管理员权限检查 =========="

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        echo "[信息] 当前程序以 root 权限运行。"
    else
        echo "[信息] 当前程序不是以 root 权限运行。"
    fi

    if command -v sudo >/dev/null 2>&1; then
        echo "[通过] 已安装 sudo：$(command -v sudo)"

        if sudo -n -l >/dev/null 2>&1; then
            echo "[信息] 当前用户可在无需交互输入密码的情况下执行至少一项 sudo 检查。"
        else
            echo "[提示] 无法通过非交互方式确认当前用户的 sudo 权限。"
            echo "[说明] 这不一定代表用户没有 sudo 权限，可能需要密码或受到策略限制。"
        fi
    else
        echo "[提示] 系统未找到 sudo 命令。"
    fi

    if getent group sudo >/dev/null 2>&1; then
        echo "[信息] sudo 组存在："
        getent group sudo
    else
        echo "[信息] 未发现 sudo 组。"
    fi

    if getent group wheel >/dev/null 2>&1; then
        echo "[信息] wheel 组存在："
        getent group wheel
    else
        echo "[信息] 未发现 wheel 组。"
    fi

    echo
    echo "[安全说明] 本阶段只读取信息，不创建账号、不修改用户组或权限。"
    echo "===================================="
}

# 直接运行本文件时进入菜单；
# 被其他模块 source 时不自动启动菜单。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    user_manager_menu
fi
