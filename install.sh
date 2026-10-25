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

# 检测 x86_64 的微架构级别，并做好通用架构兜底
CPU_V_LEVEL="不适用 (非 x86_64)"
SINGBOX_CPU_SUFFIX="amd64" # 默认兜底为通用 amd64

if [ "$CPU_ARCH" = "x86_64" ]; then
    if grep -q "avx512f" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v4 (支持 AVX-512)"
        SINGBOX_CPU_SUFFIX="amd64-v4"
    elif grep -q "avx2" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v3 (支持 AVX2, 主流高性能)"
        SINGBOX_CPU_SUFFIX="amd64-v3"
    elif grep -q "sse4_2" /proc/cpuinfo; then
        CPU_V_LEVEL="x86-64-v2 (支持 SSE4.2)"
        SINGBOX_CPU_SUFFIX="amd64-v2"
    else
        CPU_V_LEVEL="x86-64-v1 (基础兼容版，使用通用架构)"
        SINGBOX_CPU_SUFFIX="amd64"
    fi
elif [ "$CPU_ARCH" = "aarch64" ]; then
    CPU_V_LEVEL="ARM64 (aarch64)"
    SINGBOX_CPU_SUFFIX="arm64"
else
    SINGBOX_CPU_SUFFIX="$CPU_ARCH"
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
# 辅助函数: 检查本地 sing-box 状态与版本
# ==========================================
get_local_singbox_status() {
    if command -v sing-box &>/dev/null; then
        LOCAL_SB_VERSION=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        [ -z "$LOCAL_SB_VERSION" ] && LOCAL_SB_VERSION="已知晓但版本未知"
        echo "已安装 ($LOCAL_SB_VERSION)"
    else
        echo "未安装"
    fi
}

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
        read -p "请输入要创建的新用户名 (直接回车将随机生成 [$RANDOM_USER]): " NEW_USER < /dev/tty
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
        read -p "请输入新的 SSH 端口 (1024-65535，直接回车随机生成 [$RANDOM_PORT]): " NEW_SSH_PORT < /dev/tty
        if [ -z "$NEW_SSH_PORT" ]; then
            NEW_SSH_PORT="$RANDOM_PORT"
            echo "[+] 已自动随机生成 SSH 端口: $NEW_SSH_PORT"
            break
        elif [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
            if [ "$NEW_SSH_PORT" -eq 22 ]; then
                echo "[-] 提示：你输入的是默认的 22 端口。"
                read -p "确定要继续使用 22 吗？(y/n): " confirm < /dev/tty
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
# 功能函数 2: 管理与安装 sing-box (带通用架构降级兜底)
# ==========================================
action_manage_singbox() {
    echo -e "\n===================================="
    echo "  正在检查 sing-box 版本与远程更新..."
    echo "===================================="

    LATEST_TAG=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$LATEST_TAG" ]; then
        echo "[-] 警告：无法连接 GitHub API 获取最新版本信息，请检查网络。"
        LATEST_TAG="未知"
    else
        echo "[+] 远程仓库最新版本 : $LATEST_TAG"
    fi

    if command -v sing-box &>/dev/null; then
        LOCAL_VERSION=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        echo "[+] 本地系统已安装版本 : ${LOCAL_VERSION:-未知}"
        
        if [ "$LATEST_TAG" != "未知" ] && [ "$LOCAL_VERSION" = "$LATEST_TAG" ]; then
            echo "[√] 状态：当前已是最新版本 ($LATEST_TAG)"
        else
            echo "[!] 状态：版本不一致或需要更新。"
            echo "    -> 当前本地版本: ${LOCAL_VERSION:-未知}"
            echo "    -> 远程最新版本: $LATEST_TAG"
        fi

        read -p "是否需要重新下载并覆盖安装最新版？(y/n): " reinstall < /dev/tty
        [ "$reinstall" != "y" ] && return
    else
        echo "[-] 本地状态：系统未安装 sing-box。"
        read -p "是否立即从 shtorm-7/sing-box-extended 下载并安装最新版？(y/n): " do_install < /dev/tty
        [ "$do_install" != "y" ] && return
    fi

    echo "[+] 正在匹配您的 CPU 架构首选项 ($SINGBOX_CPU_SUFFIX) 准备下载..."
    
    DOWNLOAD_URL=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep "browser_download_url" | grep -E "linux-$SINGBOX_CPU_SUFFIX" | head -n 1 | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ] && [[ "$SINGBOX_CPU_SUFFIX" =~ ^amd64 ]]; then
        echo "[!] 未能匹配到专属优化架构包，正在自动降级尝试下载【通用标准 amd64】版本..."
        SINGBOX_CPU_SUFFIX="amd64"
        DOWNLOAD_URL=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep "browser_download_url" | grep -E "linux-amd64" | head -n 1 | cut -d '"' -f 4)
    elif [ -z "$DOWNLOAD_URL" ] && [[ "$SINGBOX_CPU_SUFFIX" =~ ^arm64 ]]; then
        echo "[!] 未能匹配到专属优化架构包，正在自动降级尝试下载【通用标准 arm64】版本..."
        SINGBOX_CPU_SUFFIX="arm64"
        DOWNLOAD_URL=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep "browser_download_url" | grep -E "linux-arm64" | head -n 1 | cut -d '"' -f 4)
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "[-] 错误：未能从 Release 中匹配到任何可用的 Linux 架构安装包链接！"
        return
    fi

    echo "[+] 最终确定的下载地址: $DOWNLOAD_URL"
    TEMP_FILE="/tmp/sing-box-extended.tar.gz"
    
    echo "[+] 正在下载安装包..."
    if curl -sSL "$DOWNLOAD_URL" -o "$TEMP_FILE"; then
        echo "[+] 下载完成，正在解压并安装..."
        mkdir -p /tmp/sing-box-extract
        tar -xzf "$TEMP_FILE" -C /tmp/sing-box-extract --strip-components=1 2>/dev/null || tar -xzf "$TEMP_FILE" -C /tmp/sing-box-extract
        
        SB_BINARY=$(find /tmp/sing-box-extract -type f -name "sing-box" | head -n 1)
        if [ -n "$SB_BINARY" ]; then
            cp -f "$SB_BINARY" /usr/local/bin/sing-box
            chmod +x /usr/local/bin/sing-box
            
            # 创建默认配置目录
            mkdir -p /etc/sing-box
            
            echo "[√] sing-box 安装/更新成功！"
            echo "--------------------------------------------------"
            echo " 【安装路径与配置指南】"
            echo " - 程序二进制文件路径 : /usr/local/bin/sing-box"
            echo " - 默认配置文件目录   : /etc/sing-box/ (可在此放置 config.json)"
            echo "--------------------------------------------------"
            sing-box version
        else
            echo "[-] 错误：在解压后的文件中没有找到 sing-box 二进制程序。"
        end
        
        rm -rf "$TEMP_FILE" /tmp/sing-box-extract
    else
        echo "[-] 错误：下载文件失败！"
    fi
}

# ==========================================
# 主菜单循环
# ==========================================
show_menu() {
    clear
    SB_MENU_STATUS=$(get_local_singbox_status)

    echo "=================================================="
    echo "      Linux VPS 自动化运维与管理工具箱          "
    echo "=================================================="
    echo " [VPS 硬件与系统环境检测]"
    echo " - 系统发行版   : $OS_NAME $OS_VERSION"
    echo " - CPU 架构     : $CPU_ARCH"
    echo " - CPU 指令级别 : $CPU_V_LEVEL"
    echo " - 当前主机名   : $CURRENT_HOSTNAME"
    echo " - Root 远程登录: $ROOT_LOGIN_STATUS"
    echo " - sing-box状态 : $SB_MENU_STATUS"
    echo "=================================================="
    echo " 请选择要执行的功能操作："
    echo "   1. 执行系统初始化与安全加固 (建用户/改端口/禁Root)"
    echo "   2. 检查/安装/更新 sing-box (shtorm-7 扩展版)"
    echo "   3. [预留扩展] 第三个功能 (等你来定)"
    echo "   0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-3]: " choice < /dev/tty

    case "$choice" in
        1)
            action_init_security
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        2)
            action_manage_singbox
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        3)
            echo -e "\n[!] 提示：第三个功能正在构思中，敬请期待..."
            read -p "按回车键返回主菜单..." < /dev/tty
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
