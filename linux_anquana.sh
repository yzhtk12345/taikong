#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

clear
echo -e "${CYAN}==============================================================${NC}"
echo -e "${CYAN}          VPS 系统初始化与安全加固模块                        ${NC}"
echo -e "${CYAN}==============================================================${NC}"

# 1. 检查当前系统信息
current_host=$(hostname)
current_user=$(whoami)
current_port=$(ss -tlnp | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
[ -z "$current_port" ] && current_port=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
[ -z "$current_port" ] && current_port="22"

# 检查 Root 登录状态并转换为中文含义
raw_root_login=$(grep -i "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
if [[ "$raw_root_login" =~ ^([nN][oO]|false|without-password|prohibit-password)$ ]]; then
    root_login_desc="${GREEN}已禁用 (安全)${NC}"
elif [[ "$raw_root_login" =~ ^([yY][eE][sS]|true)$ ]]; then
    root_login_desc="${RED}允许登录 (存在风险)${NC}"
else
    root_login_desc="${YELLOW}未明确配置 (默认由系统决定)${NC}"
fi

# 检查当前系统防火墙安装与运行状态
fw_status="无"
fw_name="未安装"
if command -v ufw &>/dev/null; then
    fw_status="有"
    if systemctl is-active --quiet ufw 2>/dev/null; then
        fw_name="${GREEN}UFW (已运行)${NC}"
    else
        fw_name="${YELLOW}UFW (未运行)${NC}"
    fi
elif command -v firewall-cmd &>/dev/null; then
    fw_status="有"
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        fw_name="${GREEN}Firewalld (已运行)${NC}"
    else
        fw_name="${YELLOW}Firewalld (未运行)${NC}"
    fi
elif command -v iptables &>/dev/null; then
    fw_status="有"
    fw_name="${YELLOW}iptables${NC}"
else
    fw_status="${RED}无${NC}"
    fw_name="未检测到标准防火墙"
fi

echo -e " 🖥️  当前主机名   : ${current_host}"
echo -e " 👤 当前用户     : ${current_user}"
echo -e " 🔌 当前 SSH 端口: ${current_port}"
echo -e " 🔒 Root 登录状态: ${root_login_desc}"
echo -e " 🛡️  防火墙状态   : ${fw_status} (类型: ${fw_name})"
echo -e "${CYAN}--------------------------------------------------------------${NC}"

# 检查系统发行版类型
if [ -f /etc/debian_version ]; then
    OS_FAMILY="debian"
    echo -e " 📦 系统架构类型 : Debian / Ubuntu 系"
elif [ -f /etc/redhat-release ] || grep -qi "rhel" /etc/os-release || grep -qi "centos" /etc/os-release || grep -qi "fedora" /etc/os-release; then
    OS_FAMILY="rhel"
    echo -e " 📦 系统架构类型 : RedHat / CentOS / Fedora / RHEL 系"
else
    OS_FAMILY="debian"
    echo -e " 📦 系统架构类型 : ${YELLOW}未知系 (默认按 Debian 处理)${NC}"
fi
echo -e "${CYAN}==============================================================${NC}\n"

# 2. 设置主机名
random_host="vps-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
read -p "请输入新的主机名 (直接回车随机生成 [$random_host]): " new_host < /dev/tty
if [ -z "$new_host" ]; then
    new_host="$random_host"
fi
hostnamectl set-hostname "$new_host"
echo -e "${GREEN}[+] 主机名已成功更新为: $new_host${NC}\n"

# 3. 设置新用户名
random_user="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
while true; do
    read -p "请输入要创建的新用户名 (直接回车随机生成 [$random_user]): " new_user < /dev/tty
    if [ -z "$new_user" ]; then
        new_user="$random_user"
        echo -e "${GREEN}[+] 已自动选择随机用户名: $new_user${NC}"
        break
    elif id "$new_user" &>/dev/null; then
        echo -e "${RED}[-] 用户 '$new_user' 已存在，请重新输入。${NC}"
    else
        break
    fi
done

useradd -m -s /bin/bash "$new_user"
echo -e "${CYAN}请为新用户 '$new_user' 设置密码：${NC}"
passwd "$new_user"

# 赋予 sudo 权限
if grep -q "^sudo:" /etc/group; then
    usermod -aG sudo "$new_user"
elif grep -q "^wheel:" /etc/group; then
    usermod -aG wheel "$new_user"
else
    echo "$new_user ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$new_user"
fi
echo -e "${GREEN}[+] 用户 '$new_user' 创建成功并已赋予管理员权限！${NC}\n"

# 4. 设置 SSH 端口 (3000-10000 随机，占用时提示但允许强制使用)
while true; do
    random_port=$((RANDOM % 7001 + 3000))
    read -p "请输入新的 SSH 端口 (3000-10000，直接回车随机生成 [$random_port]): " new_port < /dev/tty
    if [ -z "$new_port" ]; then
        new_port="$random_port"
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}[-] 端口格式错误，请输入 1-65535 之间的数字。${NC}"
        continue
    fi

    # 检查端口是否被占用
    if ss -tuln | grep -q ":$new_port " || netstat -tuln 2>/dev/null | grep -q ":$new_port "; then
        echo -e "${YELLOW}[!] 警告：检测到端口 $new_port 当前已被占用！${NC}"
        read -p "该端口已被占用，是否仍要强制使用它？[y/N]: " force_use < /dev/tty
        if [[ "$force_use" =~ ^[yY]$ ]]; then
            echo -e "${YELLOW}[+] 已选择强制使用被占用端口: $new_port${NC}"
            break
        else
            echo -e "${CYAN}请重新选择端口。${NC}"
            continue
        fi
    else
        echo -e "${GREEN}[+] 端口 $new_port 可用。${NC}"
        break
    fi
done

# 5. 修改 SSH 配置文件 (设置新端口并禁用 Root 登录)
sshd_config="/etc/ssh/sshd_config"
cp "$sshd_config" "${sshd_config}.bak_$(date +%F_%T)"

if grep -qE "^#?Port " "$sshd_config"; then
    sed -i "s/^#\?Port .*/Port $new_port/" "$sshd_config"
else
    echo "Port $new_port" >> "$sshd_config"
fi

if grep -qE "^#?PermitRootLogin " "$sshd_config"; then
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$sshd_config"
else
    echo "PermitRootLogin no" >> "$sshd_config"
fi

if sshd -t; then
    if systemctl list-units --full -all | grep -q "ssh.service"; then
        systemctl restart ssh
    elif systemctl list-units --full -all | grep -q "sshd.service"; then
        systemctl restart sshd
    fi
    echo -e "${GREEN}[√] SSH 配置修改成功 (端口: $new_port, Root 远程登录已禁用)${NC}\n"
else
    echo -e "${RED}[-] 错误：SSH 配置语法检查未通过，已自动恢复备份！${NC}"
    cp "${sshd_config}.bak_"* "$sshd_config"
    read -p "按回车键返回..."
    exit 1
fi

# 6. 防火墙检查、清理与配置
echo -e "${CYAN}正在检查并配置防火墙...${NC}"
if [ "$OS_FAMILY" = "debian" ]; then
    if systemctl is-active --quiet firewalld 2>/dev/null || dpkg -l | grep -q firewalld; then
        echo -e "${YELLOW}[!] 检测到冲突的 firewalld，正在卸载...${NC}"
        systemctl stop firewalld >/dev/null 2>&1
        systemctl disable firewalld >/dev/null 2>&1
        apt-get purge -y firewalld >/dev/null 2>&1
    fi
    
    if ! command -v ufw &>/dev/null; then
        apt-get update >/dev/null 2>&1
        apt-get install -y ufw >/dev/null 2>&1
    fi
    
    systemctl enable --now ufw >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ufw allow "$new_port"/tcp comment 'SSH Port' >/dev/null 2>&1
    echo -e "${GREEN}[√] UFW 防火墙已安装并启用，已成功开放端口 $new_port (带备注)${NC}"

elif [ "$OS_FAMILY" = "rhel" ]; then
    if systemctl is-active --quiet ufw 2>/dev/null || rpm -q ufw &>/dev/null; then
        echo -e "${YELLOW}[!] 检测到冲突的 ufw，正在卸载...${NC}"
        systemctl stop ufw >/dev/null 2>&1
        systemctl disable ufw >/dev/null 2>&1
        yum remove -y ufw >/dev/null 2>&1 || dnf remove -y ufw >/dev/null 2>&1
    fi

    if ! command -v firewall-cmd &>/dev/null; then
        yum install -y firewalld >/dev/null 2>&1 || dnf install -y firewalld >/dev/null 2>&1
    fi

    systemctl enable --now firewalld >/dev/null 2>&1
    firewall-cmd --permanent --add-port="$new_port"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    echo -e "${GREEN}[√] Firewalld 防火墙已安装并运行，已成功开放端口 $new_port${NC}"
fi

echo -e "\n==============================================================="
echo -e "                 🎉 VPS 安全加固全部完成！                     "
echo -e "==============================================================="
echo -e " - 新主机名     : ${new_host}"
echo -e " - 新用户名     : ${new_user}"
echo -e " - 新 SSH 端口  : ${new_port}"
echo -e " - Root 远程登录: 已禁用 (安全)"
echo -e "---------------------------------------------------------------"
echo -e " ${RED}【警告】请务必另开一个终端窗口，使用新用户和新端口测试登录成功${NC}"
echo -e " ${RED}        后再关闭当前窗口，切勿直接退出当前会话！${NC}"
echo -e "==============================================================="
read -p "按回车键退出..." < /dev/tty
