#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误：请使用 root 权限运行此脚本！"
  exit 1
fi

# ==========================================
# 步骤 1: 启动时自动检测系统与 CPU 硬件特性
# ==========================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$(echo "${NAME:-Linux}" | tr -d '\0')
    OS_VERSION=$(echo "${VERSION_ID:-Unknown}" | tr -d '\0')
else
    OS_NAME=$(uname -s | tr -d '\0')
    OS_VERSION=$(uname -r | tr -d '\0')
fi
CPU_ARCH=$(uname -m | tr -d '\0')

# 检测 x86_64 的微架构级别 (v2 / v3 / v4)
CPU_V_LEVEL="不适用 (非 x86_64)"
if [ "$CPU_ARCH" = "x86_64" ]; then
    if grep -q "avx512f" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v4 (支持 AVX-512)"
    elif grep -q "avx2" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v3 (支持 AVX2, 主流高性能)"
    elif grep -q "sse4_2" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v2 (支持 SSE4.2)"
    else
        CPU_V_LEVEL="x86-64-v1 (基础兼容版)"
    fi
elif [ "$CPU_ARCH" = "aarch64" ]; then
    CPU_V_LEVEL="ARM64 (aarch64)"
fi

CURRENT_HOSTNAME=$(hostname)

# 获取当前 Root 远程登录状态
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -qE "^PermitRootLogin\s+no" "$SSHD_CONFIG" 2>/dev/null; then
    ROOT_LOGIN_STATUS="已禁用"
else
    ROOT_LOGIN_STATUS="未禁用 (或未配置)"
fi

# ==========================================
# 功能函数 1: 系统初始化与安全加固
# ==========================================
action_init_security() {
    echo -e "\n===================================="
    echo "  开始执行：系统初始化与安全加固"
    echo "===================================="

    # 1. 创建用户
    RANDOM_USER="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    while true; do
        read -p "请输入要创建的新用户名 (直接回车将随机生成 [$RANDOM_USER]): " NEW_USER
        if [ -z "$NEW_USER" ]; then
            NEW_USER="$RANDOM_USER"
            echo "[+] 已自动随机生成用户名: $NEW_USER"
            break
        elif id "$NEW_USER" &>/dev/null; then
            echo "[-] 用户 '$NEW_USER' 已经存在，请更换一个用户名。"
        else
            break
        fi
    done

    useradd -m -s /bin/bash "$NEW_USER"
    echo "[+] 请为用户 '$NEW_USER' 设置密码："
    passwd "$NEW_USER"
    echo "[+] 用户 '$NEW_USER' 创建成功！"

    # 2. 赋予 sudo 权限
    if grep -q "^sudo:" /etc/group; then
        usermod -aG sudo "$NEW_USER"
        echo "[+] 已将 '$NEW_USER' 添加到 sudo 组"
    elif grep -q "^wheel:" /etc/group; then
        usermod -aG wheel "$NEW_USER"
        echo "[+] 已将 '$NEW_USER' 添加到 wheel 组"
    else
        echo "$NEW_USER ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$NEW_USER"
        echo "[+] 已独立写入 sudoers 规则。"
    fi

    # 3. 修改 SSH 端口
    RANDOM_PORT=$((RANDOM % 64512 + 1024))
    while true; do
        read -p "请输入新的 SSH 端口 (1024-65535，直接回车随机生成 [$RANDOM_PORT]): " NEW_SSH_PORT
        if [ -z "$NEW_SSH_PORT" ]; then
            NEW_SSH_PORT="$RANDOM_PORT"
            echo "[+] 已自动随机生成 SSH 端口: $NEW_SSH_PORT"
            break
        elif [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
            if [ "$NEW_SSH_PORT" -eq 22 ]; then
                echo "[-] 提示：你输入的是默认的 22 端口。"
                read -p "确定要继续使用 22 吗？(y/n): " confirm
                [ "$confirm" = "y" ] && break
            else
                break
            fi
        else
            echo "[-] 格式错误，请输入 1 到 65535 之间的数字。"
        fi
    done

    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak_$(date +%F_%T)"
    if grep -qE "^#?Port " "$SSHD_CONFIG"; then
        sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
    else
        echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
    fi

    # 4. 禁止 Root 登录
    if grep -qE "^#?PermitRootLogin " "$SSHD_CONFIG"; then
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
    else
        echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    fi

    # 5. 重启 SSH
    if sshd -t; then
        if systemctl list-units --full -all | grep -q "ssh.service"; then
            systemctl restart ssh
        elif systemctl list-units --full -all | grep -q "sshd.service"; then
            systemctl restart sshd
        fi
        echo "[√] SSH 服务重启成功！"
    else
        echo "[-] 错误：SSH 配置文件语法检查未通过！已自动恢复备份。"
        cp "${SSHD_CONFIG}.bak_"* "$SSHD_CONFIG"
        return
    fi

    echo -e "\n===================================="
    echo "         安全加固执行完毕！         "
    echo "===================================="
    echo " - 新用户名     : $NEW_USER"
    echo " - 新 SSH 端口  : $NEW_SSH_PORT"
    echo " - Root 远程登录: 已禁用"
    echo "------------------------------------"
    echo " 【警告】请立刻新开终端测试新用户登录，切勿关闭当前窗口！"
}

# ==========================================
# 主菜单循环
# ==========================================
show_menu() {
    clear
    echo "=================================================="
    echo "      Linux VPS 自动化运维与管理工具箱          "
    echo "=================================================="
    echo " [VPS 硬件与系统环境检测]"
    echo " - 系统发行版   : $OS_NAME $OS_VERSION"
    echo " - CPU 架构     : $CPU_ARCH"
    echo " - CPU 指令级别 : $CPU_V_LEVEL"
    echo " - 当前主机名   : $CURRENT_HOSTNAME"
    echo " - Root 远程登录: $ROOT_LOGIN_STATUS"
    echo "=================================================="
    echo " 请选择要执行的功能操作："
    echo "   1. 执行系统初始化与安全加固 (建用户/改端口/禁Root)"
    echo "   2. [预留扩展] 第二个功能 (等你来定)"
    echo "   3. [预留扩展] 第三个功能 (等你来定)"
    echo "   0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-3]: " choice

    case "$choice" in
        1)
            action_init_security
            echo ""
            read -p "按回车键返回主菜单..." 
            ;;
        2)
            echo -e "\n[!] 提示：第二个功能正在构思中，敬请期待..."
            read -p "按回车键返回主菜单..." 
            ;;
        3)
            echo -e "\n[!] 提示：第三个功能正在构思中，敬请期待..."
            read -p "按回车键返回主菜单..." 
            ;;
        0)
            echo "感谢使用，再见！"
            exit 0
            ;;
        *)
            echo "[-] 无效的选择，请重新输入！"
            sleep 1
            ;;
    esac
}

# 保持菜单循环
while true; do
    show_menu
done
