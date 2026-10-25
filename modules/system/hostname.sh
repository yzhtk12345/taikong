
#!/usr/bin/env bash

# Taikong - Hostname Management
# Supports Debian/Ubuntu and RHEL-family Linux.

hostname_menu() {
    while true; do
        local current_hostname
        current_hostname="$(hostname 2>/dev/null || true)"

        echo
        echo "========== 主机名管理 =========="
        echo "当前主机名：${current_hostname:-未知}"
        echo "1) 查看主机名详细信息"
        echo "2) 修改主机名"
        echo "0) 返回主菜单"
        echo "================================"

        local choice
        read -r -p "请选择 [0-2]: " choice

        case "$choice" in
            1)
                hostname
                hostnamectl status 2>/dev/null || true
                ;;
            2)
                hostname_change
                ;;
            0)
                return 0
                ;;
            *)
                echo "[错误] 无效选项，请输入 0、1 或 2。"
                ;;
        esac
    done
}

hostname_change() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "[错误] 修改主机名需要 root 权限。"
        return 1
    fi

    if ! command -v hostnamectl >/dev/null 2>&1; then
        echo "[错误] 未找到 hostnamectl，暂不支持自动修改。"
        return 1
    fi

    local new_hostname
    read -r -p "请输入新主机名（例如 hkg-server-01）: " new_hostname

    # Linux 主机名采用 DNS 标签形式校验。
    if [[ ! "$new_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        echo "[错误] 主机名格式不合法。请使用字母、数字和连字符，且不能以连字符开头或结尾。"
        return 1
    fi

    if [[ "${#new_hostname}" -gt 63 ]]; then
        echo "[错误] 主机名不能超过 63 个字符。"
        return 1
    fi

    echo
    echo "即将把主机名从：$(hostname)"
    echo "修改为：$new_hostname"
    echo "此操作会修改系统主机名，但不会重启 VPS。"

    local confirm
    read -r -p "确认修改吗？请输入 yes 继续: " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo "[信息] 已取消修改。"
        return 0
    fi

    if hostnamectl set-hostname "$new_hostname"; then
        local actual_hostname
        actual_hostname="$(hostname)"

        if [[ "$actual_hostname" == "$new_hostname" ]]; then
            echo "[成功] 主机名已修改为：$actual_hostname"
        else
            echo "[警告] 命令已执行，但验证结果不一致：$actual_hostname"
            return 1
        fi
    else
        echo "[错误] 主机名修改失败，请检查 systemd 状态。"
        return 1
    fi
}
