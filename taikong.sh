#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误：请使用 root 权限运行此脚本！"
  exit 1
fi

clear
echo "=================================================="
echo "      Linux 系统自动化初始化与安全加固脚本        "
echo "=================================================="

# ==========================================
# 步骤 1: 检查系统版本、CPU 架构与微架构级别 (v几代)
# ==========================================
echo -e "\n[1/6] 正在深度检测系统与 CPU 硬件特性..."
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

echo "--------------------------------------------------"
echo "[+] 系统发行版    : $OS_NAME $OS_VERSION"
echo "[+] CPU 架构      : $CPU_ARCH"
echo "[+] CPU 指令级别  : $CPU_V_LEVEL"
echo "--------------------------------------------------"
read -p "请确认以上信息，按回车键继续执行后续步骤..." temp

# ==========================================
# 步骤 2: 显示当前正在使用的主机名
# ==========================================
echo -e "\n[2/6] 获取当前主机名..."
CURRENT_HOSTNAME=$(hostname)
echo "[+] 当前正在使用的主机名: $CURRENT_HOSTNAME"

# ==========================================
# 步骤 3: 设置系统账号与密码 (支持直接回车随机生成)
# ==========================================
echo -e "\n[3/6] 创建新的系统普通账号..."
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

# 创建用户并指定家目录和 bash
useradd -m -s /bin/bash "$NEW_USER"
echo "[+] 请为用户 '$NEW_USER' 设置密码："
passwd "$NEW_USER"
echo "[+] 用户 '$NEW_USER' 创建成功！"

# ==========================================
# 步骤 4: 升级账号到 sudo 权限
# ==========================================
echo -e "\n[4/6] 正在将账号 '$NEW_USER' 升级到 sudo 权限..."
if grep -q "^sudo:" /etc/group; then
    usermod -aG sudo "$NEW_USER"
    echo "[+] 已将 '$NEW_USER' 添加到 sudo 组 (Debian/Ubuntu)"
elif grep -q "^wheel:" /etc/group; then
    usermod -aG wheel "$NEW_USER"
    echo "[+] 已将 '$NEW_USER' 添加到 wheel 组 (RHEL/CentOS)"
else
    echo "$NEW_USER ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$NEW_USER"
    echo "[+] 已独立写入 sudoers 规则。"
fi
echo "[+] 权限升级完成。"

# ==========================================
# 步骤 5: 修改 SSH 默认端口 (支持直接回车随机生成)
# ==========================================
echo -e "\n[5/6] 修改 SSH 默认端口..."
RANDOM_PORT=$((RANDOM % 64512 + 1024))

while true; do
    read -p "请输入新的 SSH 端口 (1024-65535，直接回车随机生成 [$RANDOM_PORT]): " NEW_SSH_PORT
    if [ -z "$NEW_SSH_PORT" ]; then
        NEW_SSH_PORT="$RANDOM_PORT"
        echo "[+] 已自动随机生成 SSH 端口: $NEW_SSH_PORT"
        break
    elif [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
        if [ "$NEW_SSH_PORT" -eq 22 ]; then
            echo "[-] 提示：你输入的是默认的 22 端口。建议更换为非标端口以防扫描。"
            read -p "确定要继续使用 22 吗？(y/n): " confirm
            [ "$confirm" = "y" ] && break
        else
            break
        fi
    else
        echo "[-] 格式错误，请输入 1 到 65535 之间的数字。"
    fi
done

# 备份 sshd_config
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak_$(date +%F_%T)"

# 修改或添加 Port
if grep -qE "^#?Port " "$SSHD_CONFIG"; then
    sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
else
    echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
fi
echo "[+] SSH 端口配置已更新为: $NEW_SSH_PORT"

# ==========================================
# 步骤 6: 禁止 Root 账号远程登录
# ==========================================
echo -e "\n[6/6] 配置禁止 Root 账号远程登录..."
if grep -qE "^#?PermitRootLogin " "$SSHD_CONFIG"; then
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
else
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
fi
echo "[+] 已成功设置 PermitRootLogin no"

# 检查 SSH 语法并重启服务
echo -e "\n[+] 正在校验 SSH 配置文件语法..."
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
    exit 1
fi

# ==========================================
# 检查 Root 远程登录状态变量
# ==========================================
if grep -qE "^PermitRootLogin\s+no" "$SSHD_CONFIG"; then
    ROOT_LOGIN_STATUS="已禁用"
else
    ROOT_LOGIN_STATUS="未禁用 (存在风险)"
fi

# ==========================================
# 完成提示 (动态状态展示)
# ==========================================
echo ""
echo "=================================================="
echo "      所有初始化与安全加固步骤已顺利完成！        "
echo "=================================================="
echo " 摘要信息："
echo " - 系统发行版   : $OS_NAME $OS_VERSION"
echo " - CPU 架构     : $CPU_ARCH"
echo " - CPU 指令级别 : $CPU_V_LEVEL"
echo " - 当前主机名   : $CURRENT_HOSTNAME"
echo " - 新用户名     : $NEW_USER"
echo " - 新 SSH 端口  : $NEW_SSH_PORT"
echo " - Root 远程登录: $ROOT_LOGIN_STATUS"
echo "--------------------------------------------------"
echo " 【安全警告与切记】"
echo " 请**千万不要**立刻关闭当前的终端窗口！"
echo " 请立刻**新开一个终端**，尝试用新用户 [$NEW_USER]"
echo " 通过新端口 [$NEW_SSH_PORT] 进行 SSH 登录，"
echo " 并输入 'sudo whoami' 验证管理员权限是否正常。"
echo " 确认一切完全正常后，再退出当前 root 窗口。"
echo "=================================================="
