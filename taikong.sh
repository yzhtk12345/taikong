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
# 步骤 1: 检查系统版本与 CPU 架构
# ==========================================
echo -e "\n[1/6] 正在检查系统版本和 CPU 架构..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$NAME
    OS_VERSION=$VERSION_ID
else
    OS_NAME=$(uname -s)
    OS_VERSION=$(uname -r)
fi
CPU_ARCH=$(uname -m)

echo "--------------------------------------------------"
echo "[+] 检测到系统发行版: $OS_NAME (版本: ${OS_VERSION:-未知})"
echo "[+] 检测到 CPU 架构: $CPU_ARCH"
echo "--------------------------------------------------"

# ==========================================
# 步骤 2: 设置 Linux 主机名
# ==========================================
echo -e "\n[2/6] 设置主机名 (Hostname)..."
read -p "请输入新的主机名: " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # 同步修改 /etc/hosts 避免某些服务报错
    sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts 2>/dev/null || echo "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    echo "[+] 主机名已成功修改为: $NEW_HOSTNAME"
else
    echo "[-] 输入为空，跳过主机名修改。"
fi

# ==========================================
# 步骤 3: 设置系统账号与密码
# ==========================================
echo -e "\n[3/6] 创建新的系统普通账号..."
while true; do
    read -p "请输入要创建的新用户名: " NEW_USER
    if id "$NEW_USER" &>/dev/null; then
        echo "[-] 用户 '$NEW_USER' 已经存在，请更换一个用户名。"
    elif [ -n "$NEW_USER" ]; then
        break
    else
        echo "[-] 用户名不能为空。"
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
    echo "[+] 已将 '$NEW_USER' 添加到 sudo 组 (Debian/Ubuntu 风格)"
elif grep -q "^wheel:" /etc/group; then
    usermod -aG wheel "$NEW_USER"
    echo "[+] 已将 '$NEW_USER' 添加到 wheel 组 (RHEL/CentOS 风格)"
else
    echo "[-] 未找到标准的 sudo 或 wheel 组，尝试直接赋予全权限..."
    echo "$NEW_USER ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$NEW_USER"
fi
echo "[+] 权限升级完成。"

# ==========================================
# 步骤 5: 修改 SSH 默认端口
# ==========================================
echo -e "\n[5/6] 修改 SSH 默认端口..."
while true; do
    read -p "请输入新的 SSH 端口 (建议 1024-65535): " NEW_SSH_PORT
    if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
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
# 完成提示
# ==========================================
echo ""
echo "=================================================="
echo "      所有初始化与安全加固步骤已顺利完成！        "
echo "=================================================="
echo " 摘要信息："
echo " - 主机名: $NEW_HOSTNAME"
echo " - 新用户名: $NEW_USER"
echo " - 新 SSH 端口: $NEW_SSH_PORT"
echo " - Root 远程登录: 已禁用"
echo "--------------------------------------------------"
echo " 【安全警告与切记】"
echo " 请**千万不要**立刻关闭当前的终端窗口！"
echo " 请立刻**新开一个终端**，尝试用新用户 [$NEW_USER]"
echo " 通过新端口 [$NEW_SSH_PORT] 进行 SSH 登录，"
echo " 并输入 'sudo whoami' 验证管理员权限是否正常。"
echo " 确认一切完全正常后，再退出当前 root 窗口。"
echo "=================================================="
