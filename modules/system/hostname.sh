
#!/usr/bin/env bash

# Taikong VPS Manager
# Hostname Management Module
# Supports systemd-based Linux distributions.

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
        read -r -p "请输入选项 [0-2]: " choice || choice=0

        case "$choice" in
            1)
                hostname_show
                ;;
            2)
                hostname_change
                ;;
            0)
                return 0
                ;;
            *)
                echo "[错误] 输入无效，请输入 0、1 或 2。"
                ;;
        esac
    done
}

hostname_show() {
    echo
    echo "========== 主机名详细信息 =========="

    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl status 2>&1 || {
            echo "[警告] hostnamectl 无法读取完整信息。"
            echo "[信息] 当前主机名：$(hostname 2>/dev/null || echo 未知)"
        }
    else
        echo "当前主机名：$(hostname 2>/dev/null || echo 未知)"
        echo "[提示] 当前系统没有安装 hostnamectl。"
    fi

    echo "===================================="
}

hostname_validate() {
    local name="$1"
    local length=${#name}

    if [[ -z "$name" ]]; then
        echo "[错误] 主机名不能为空。"
        return 1
    fi

    if (( length > 63 )); then
        echo "[错误] 主机名长度为 ${length} 个字符，超过 63 个字符的限制。"
        return 1
    fi

    if [[ "$name" == -* ]]; then
        echo "[错误] 主机名不能以连字符（-）开头。"
        return 1
    fi

    if [[ "$name" == *- ]]; then
        echo "[错误] 主机名不能以连字符（-）结尾。"
        return 1
    fi

    if [[ "$name" == *[!a-zA-Z0-9-]* ]]; then
        echo "[错误] 主机名包含不允许的字符。"
        echo "[原因] 只允许英文字母、数字和连字符（-）。"
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9] ]]; then
        echo "[错误] 主机名必须以英文字母或数字开头。"
        return 1
    fi

    echo "[验证通过] 主机名格式合法。"
    return 0
}

hostname_change() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "[错误] 修改系统主机名需要 root 权限。"
        return 1
    fi

    if ! command -v hostnamectl >/dev/null 2>&1; then
        echo "[错误] 未找到 hostnamectl，无法通过当前方式修改主机名。"
        echo "[建议] 请确认系统使用 systemd，并检查 hostnamectl 是否可用。"
        return 1
    fi

    echo
    echo "========== 修改系统主机名 =========="
    echo
    echo "【合法规则】"
    echo "  1. 只能使用英文字母 a-z、A-Z、数字 0-9 和连字符（-）。"
    echo "  2. 必须以英文字母或数字开头。"
    echo "  3. 必须以英文字母或数字结尾。"
    echo "  4. 长度为 1 至 63 个字符。"
    echo "  5. 不允许空格、下划线、点号或其他特殊符号。"
    echo
    echo "【合法示例】"
    echo "  hkg-server-01"
    echo "  debian12"
    echo "  vps-01"
    echo
    echo "【不合法示例】"
    echo "  -hkg-server    以连字符开头"
    echo "  hkg-server-    以连字符结尾"
    echo "  hk1.95t        包含点号"
    echo "  my_server      包含下划线"
    echo "  my server      包含空格"
    echo
    echo "输入错误时会重新提示，不会修改系统主机名。"
    echo "===================================="

    local new_hostname

    while true; do
        if ! read -r -p "请输入新主机名: " new_hostname; then
            echo
            echo "[信息] 输入已中断，取消修改。"
            return 0
        fi

        if hostname_validate "$new_hostname"; then
            break
        fi

        echo "[提示] 请根据上方规则重新输入。"
        echo
    done

    local old_hostname
    old_hostname="$(hostname 2>/dev/null || true)"

    echo
    echo "========== 主机名修改确认 =========="
    echo "当前主机名：${old_hostname:-未知}"
    echo "新主机名：  $new_hostname"
    echo
    echo "【修改说明】"
    echo "  1. 将修改 Linux 系统主机名。"
    echo "  2. 本工具不会主动重启 VPS。"
    echo "  3. 不会自动修改 /etc/hosts 文件。"
    echo "  4. 依赖旧主机名的应用、监控或服务可能需要检查。"
    echo "  5. 请确认新名称不会影响现有服务后再继续。"
    echo
    echo "【如何选择】"
    echo "  直接按回车：确认修改（默认）"
    echo "  输入 y 或 Y：确认修改"
    echo "  输入 n 或 N：取消修改"
    echo "  其他输入：重新提示"
    echo "===================================="

    local confirm

    while true; do
        if ! read -r -p "请输入 [Y/n]: " confirm; then
            echo
            echo "[信息] 输入已中断，取消修改。"
            return 0
        fi

        case "$confirm" in
            ""|y|Y|yes|YES|Yes)
                break
                ;;
            n|N|no|NO|No)
                echo "[信息] 已取消修改，系统主机名保持不变。"
                return 0
                ;;
            *)
                echo "[提示] 输入无效。请直接按回车或输入 y 确认，输入 n 取消。"
                ;;
        esac
    done

    echo
    echo "[信息] 正在修改系统主机名..."

    if ! hostnamectl set-hostname "$new_hostname"; then
        echo "[错误] 主机名修改失败。"
        echo "[建议] 请检查 systemd 状态、系统权限和系统日志。"
        return 1
    fi

    local actual_hostname
    actual_hostname="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"

    if [[ "$actual_hostname" == "$new_hostname" ]]; then
        echo
        echo "[成功] 系统主机名修改成功。"
        echo "原主机名：${old_hostname:-未知}"
        echo "新主机名：$actual_hostname"
        echo
        echo "[说明] 本工具没有主动重启 VPS。"
        echo "[建议] 请检查 /etc/hosts 以及依赖主机名的应用配置。"
    else
        echo
        echo "[警告] 命令已执行，但主机名验证未通过。"
        echo "预期主机名：$new_hostname"
        echo "实际主机名：${actual_hostname:-无法读取}"
        echo "[建议] 请运行 hostnamectl status 检查系统状态。"
        return 1
    fi
}
