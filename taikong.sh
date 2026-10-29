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
# 辅助函数: 获取 sing-box 版本与检查状态
# ==========================================
get_singbox_version_info() {
    # 1. 获取本地版本
    if command -v sing-box &>/dev/null; then
        LOCAL_SB_VER=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        [ -z "$LOCAL_SB_VER" ] && LOCAL_SB_VER="已知晓但版本未知"
    else
        LOCAL_SB_VER="未安装"
    fi

    # 2. 获取远程最新版本 (限制超时时间为 2 秒，避免菜单卡顿)
    REMOTE_TAG=$(curl -sSL --max-time 2 https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$REMOTE_TAG" ] && REMOTE_TAG="获取失败"

    if [ "$REMOTE_TAG" = "获取失败" ]; then
        REMOTE_SB_VER="获取失败"
        CLEAN_REMOTE=""
    else
        REMOTE_SB_VER="$REMOTE_TAG"
        # 剥离前缀 v 或 V 用于精准比对
        CLEAN_REMOTE="${REMOTE_TAG#[vV]}"
    fi

    CLEAN_LOCAL="${LOCAL_SB_VER#[vV]}"

    # 3. 对比状态判定 (基于剥离 v 后的纯净版本号比对)
    if [ "$LOCAL_SB_VER" = "未安装" ]; then
        SB_CHECK_STATUS="[-] 请前往选项 2 安装"
    elif [ "$REMOTE_SB_VER" = "获取失败" ]; then
        SB_CHECK_STATUS="[!] 无法连接 GitHub (网络超时)"
    elif [ "$CLEAN_LOCAL" = "$CLEAN_REMOTE" ]; then
        SB_CHECK_STATUS="[√] 已是最新版本"
    else
        SB_CHECK_STATUS="[!] 发现新版本，可前往更新"
    fi
}

# ==========================================
# 功能函数 1: 系统初始化与安全加固 (含修改主机名)
# ==========================================
action_init_security() {
    echo -e "\n===================================="
    echo "  开始执行：系统初始化与安全加固"
    echo "===================================="

    # 0. 修改主机名
    echo -e "\n--- [步骤 0/4] 修改主机名 ---"
    read -p "请输入新的主机名 (直接回车保持当前 [$CURRENT_HOSTNAME]): " NEW_HOSTNAME < /dev/tty
    if [ -n "$NEW_HOSTNAME" ]; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        CURRENT_HOSTNAME="$NEW_HOSTNAME"
        echo "[+] 主机名已成功修改为: $NEW_HOSTNAME"
    else
        echo "[+] 保持当前主机名不变: $CURRENT_HOSTNAME"
    fi

    # 1. 创建用户
    echo -e "\n--- [步骤 1/4] 创建系统新用户 ---"
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
    echo -e "\n--- [步骤 2/4] 配置 Sudo 权限 ---"
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
    echo -e "\n--- [步骤 3/4] 修改 SSH 远程端口 ---"
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
    echo -e "\n--- [步骤 4/4] 禁用 Root 远程登录 ---"
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
    echo "         安全加固执行完毕！          "
    echo "===================================="
    echo " - 当前主机名   : $CURRENT_HOSTNAME"
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
        
        CLEAN_LOCAL_V="${LOCAL_VERSION#[vV]}"
        CLEAN_LATEST_V="${LATEST_TAG#[vV]}"

        if [ "$LATEST_TAG" != "未知" ] && [ "$CLEAN_LOCAL_V" = "$CLEAN_LATEST_V" ]; then
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
            echo "[-] 错误：在解压后的文件中没有找到 sing-box 二进制程序."
        fi
        
        rm -rf "$TEMP_FILE" /tmp/sing-box-extract
    else
        echo "[-] 错误：下载文件失败！"
    fi
}

# ==========================================
# 功能函数 3: 查看 sing-box 运行状态与日志
# ==========================================
action_view_singbox_status_logs() {
    echo -e "\n===================================="
    echo "      查看 sing-box 运行状态与日志"
    echo "===================================="

    if ! command -v sing-box &>/dev/null; then
        echo "[-] 提示：系统未安装 sing-box 程序。"
        return
    fi

    # 检查是否存在 systemd 服务
    if systemctl list-unit-files | grep -q "sing-box.service" || [ -f /etc/systemd/system/sing-box.service ] || [ -f /lib/systemd/system/sing-box.service ]; then
        echo "[+] 检测到 sing-box 系统服务 (systemd)："
        echo "------------------------------------"
        systemctl status sing-box --no-pager
        echo "------------------------------------"
        echo "[+] 最近 50 行运行日志："
        echo "------------------------------------"
        journalctl -u sing-box -n 50 --no-pager
    else
        echo "[!] 提示：未检测到标准的 systemd 服务（sing-box.service）。"
        echo "[+] 正在检查当前系统中的 sing-box 进程运行状态："
        echo "------------------------------------"
        if pgrep -x "sing-box" > /dev/null; then
            echo "[√] sing-box 进程正在运行中："
            ps aux | grep "[s]ing-box"
        else
            echo "[-] 当前没有检测到运行中的 sing-box 进程。"
        fi
    fi
}
# ==========================================
# 辅助函数: 检查端口是否被占用
# ==========================================
is_port_in_use() {
    local p=$1
    if command -v ss &>/dev/null; then
        ss -tuln | grep -qE ":$p\b"
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -qE ":$p\b"
    else
        false
    fi
}

# ==========================================
# 辅助函数: 获取未被占用的随机端口
# ==========================================
get_random_port() {
    while true; do
        local rand_port=$((RANDOM % 40001 + 20000))
        if ! is_port_in_use "$rand_port"; then
            echo "$rand_port"
            return
        fi
    done
}

# ==========================================
# 基础生成函数: Hysteria2 及通用自签证书
# ==========================================
action_gen_hy2_cert() {
    mkdir -p /etc/sing-box/ziqian
    if [ ! -f /etc/sing-box/ziqian/private.key ] || [ ! -f /etc/sing-box/ziqian/cert.pem ]; then
        echo "[+] 正在生成 sing-box 默认自签证书..."
        openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/ziqian/private.key &>/dev/null
        openssl req -new -x509 -days 36500 -key /etc/sing-box/ziqian/private.key -out /etc/sing-box/ziqian/cert.pem -subj "/CN=www.bing.com" &>/dev/null
    fi
}

# ==========================================
# 证书状态全局检测函数
# ==========================================
check_certificates_status() {
    echo -e "\n===================================="
    echo "       TLS 证书环境状态检测         "
    echo "===================================="
    
    # 检查自签证书
    if [ -f /etc/sing-box/ziqian/cert.pem ] && [ -f /etc/sing-box/ziqian/private.key ]; then
        echo "[√] 自签证书状态: 已就绪 (/etc/sing-box/ziqian/)"
    else
        echo "[!] 自签证书不存在，正在自动生成..."
        action_gen_hy2_cert
        echo "[√] 自签证书状态: 已生成完成"
    fi

    # 检查域名证书
    if [ -f /root/ygkkkca/cert.crt ] && [ -f /root/ygkkkca/private.key ]; then
        echo "[√] 域名证书状态: 检测到有效证书 (/root/ygkkkca/cert.crt)"
        HAS_DOMAIN_CERT=1
    else
        echo "[x] 域名证书状态: 未在 /root/ygkkkca/ 检测到完整域名证书 (将默认使用自签证书或需手动准备)"
        HAS_DOMAIN_CERT=0
    fi
    echo "===================================="
}

# ==========================================
# 功能函数 4: 9 节点完整交互式配置向导
# ==========================================
action_node_wizard() {
    echo -e "\n===================================="
    echo "  开始执行：sing-box 9 节点完整配置向导"
    echo "===================================="

    mkdir -p /etc/sing-box/value
    mkdir -p /etc/sing-box/ziqian
    
    # 运行证书检测
    check_certificates_status

    # -------------------------------- 1. anytls-01-bing --------------------------------
    echo -e "\n--- [1/9] 配置协议: anytls-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/anytls-01-bing_port ] && cat /etc/sing-box/value/anytls-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/anytls-01-bing_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/anytls-01-bing_password

    echo -e "\n[证书选择提示]"
    echo "  1) 自签证书路径: /etc/sing-box/ziqian/cert.pem (默认推荐)"
    if [ "$HAS_DOMAIN_CERT" -eq 1 ]; then
        echo "  2) 域名证书路径: /root/ygkkkca/cert.crt (检测到已存在)"
        read -p "请选择证书类型 [1. 自签证书(默认) 2. 域名证书]: " cert_choice < /dev/tty
        if [ "$cert_choice" = "2" ]; then
            echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/anytls-01-bing_cert
            echo "/root/ygkkkca/private.key" > /etc/sing-box/value/anytls-01-bing_key
            echo "[√] 已为您绑定: 域名证书"
        else
            echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/anytls-01-bing_cert
            echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/anytls-01-bing_key
            echo "[√] 已为您绑定: 自签证书"
        fi
    else
        echo "  [i] 未检测到可用域名证书，自动为您采用自签证书。"
        echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/anytls-01-bing_cert
        echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/anytls-01-bing_key
    fi

    # -------------------------------- 2. anytls-02-reality --------------------------------
    echo -e "\n--- [2/9] 配置协议: anytls-02-reality ---"
    p_def=$([ -f /etc/sing-box/value/anytls-02-reality_port ] && cat /etc/sing-box/value/anytls-02-reality_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/anytls-02-reality_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/anytls-02-reality_password

    read -p "请输入 server_name 与 server 地址 (回车默认 gateway.icloud.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="gateway.icloud.com"
    echo "$sname" > /etc/sing-box/value/anytls-02-reality_server

    if command -v sing-box &>/dev/null; then
        kp_output=$(sing-box generate reality-keypair 2>/dev/null)
        pri=$(echo "$kp_output" | grep -i "PrivateKey" | awk '{print $NF}')
        pub=$(echo "$kp_output" | grep -i "PublicKey" | awk '{print $NF}')
        [ -z "$pri" ] && pri=$(echo "$kp_output" | head -n 1 | awk '{print $NF}')
        [ -z "$pub" ] && pub=$(echo "$kp_output" | tail -n 1 | awk '{print $NF}')
    else
        pri="gKPwgyITTWk1lrlGF19jTZGFrkTDJ4W7vD2jSs2K6Uk"
        pub="dummy_public_key_anytls"
    fi
    echo "$pri" > /etc/sing-box/value/anytls-02-reality_pri
    echo "$pub" > /etc/sing-box/value/anytls-02-reality_pub
    sid=$(openssl rand -hex 4 2>/dev/null || echo "d1df3e44")
    echo "$sid" > /etc/sing-box/value/anytls-02-reality_sid
    echo "[+] anytls-02-reality 独立密钥对已生成:"
    echo "    -> PrivateKey: $pri"
    echo "    -> PublicKey : $pub"
    echo "    -> Short ID  : $sid"

    # -------------------------------- 3. hysteria2-01-bing --------------------------------
    echo -e "\n--- [3/9] 配置协议: hysteria2-01-bing (自签证书) ---"
    p_def=$([ -f /etc/sing-box/value/hysteria2-01-bing_port ] && cat /etc/sing-box/value/hysteria2-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/hysteria2-01-bing_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/hysteria2-01-bing_password
    echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/hysteria2-01-bing_cert
    echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/hysteria2-01-bing_key
    echo "[√] 已绑定默认自签证书: /etc/sing-box/ziqian/cert.pem"

    # -------------------------------- 4. hysteria2-02-yuming --------------------------------
    echo -e "\n--- [4/9] 配置协议: hysteria2-02-yuming (域名证书) ---"
    p_def=$([ -f /etc/sing-box/value/hysteria2-02-yuming_port ] && cat /etc/sing-box/value/hysteria2-02-yuming_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/hysteria2-02-yuming_port

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/hysteria2-02-yuming_password

    if [ "$HAS_DOMAIN_CERT" -eq 1 ]; then
        echo "[√] 检测到域名证书可用，自动指定为 /root/ygkkkca/cert.crt"
        echo "/root/ygkkkca/cert.crt" > /etc/sing-box/value/hysteria2-02-yuming_cert
        echo "/root/ygkkkca/private.key" > /etc/sing-box/value/hysteria2-02-yuming_key
    else
        echo "[!] 未检测到标准域名证书，是否输入自定义证书路径？(直接回车默认使用自签证书)"
        read -p "请输入证书路径 (回车使用自签证书): " custom_cert < /dev/tty
        if [ -n "$custom_cert" ] && [ -f "$custom_cert" ]; then
            echo "$custom_cert" > /etc/sing-box/value/hysteria2-02-yuming_cert
            read -p "请输入私钥路径: " custom_key < /dev/tty
            echo "${custom_key:-/root/ygkkkca/private.key}" > /etc/sing-box/value/hysteria2-02-yuming_key
        else
            echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/hysteria2-02-yuming_cert
            echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/hysteria2-02-yuming_key
            echo "[i] 已回退使用自签证书路径。"
        fi
    fi

    # -------------------------------- 5. vless-reality-vision --------------------------------
    echo -e "\n--- [5/9] 配置协议: vless-reality-vision ---"
    p_def=$([ -f /etc/sing-box/value/vless-reality-vision_port ] && cat /etc/sing-box/value/vless-reality-vision_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/vless-reality-vision_port

    uuid_def=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    read -p "请输入 UUID (回车随机生成 [$uuid_def]): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid="$uuid_def"
    echo "$uuid" > /etc/sing-box/value/vless-reality-vision_uuid

    read -p "请输入 server_name 与 server (回车默认 dl.delivery.mp.microsoft.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="dl.delivery.mp.microsoft.com"
    echo "$sname" > /etc/sing-box/value/vless-reality-vision_server

    if command -v sing-box &>/dev/null; then
        kp_output=$(sing-box generate reality-keypair 2>/dev/null)
        pri=$(echo "$kp_output" | grep -i "PrivateKey" | awk '{print $NF}')
        pub=$(echo "$kp_output" | grep -i "PublicKey" | awk '{print $NF}')
        [ -z "$pri" ] && pri=$(echo "$kp_output" | head -n 1 | awk '{print $NF}')
        [ -z "$pub" ] && pub=$(echo "$kp_output" | tail -n 1 | awk '{print $NF}')
    else
        pri="aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"
        pub="dummy_public_key_vless_vis"
    fi
    echo "$pri" > /etc/sing-box/value/vless-reality-vision_pri
    echo "$pub" > /etc/sing-box/value/vless-reality-vision_pub
    sid_vvr=$(openssl rand -hex 8 2>/dev/null || echo "27dfe873147095d1")
    echo "$sid_vvr" > /etc/sing-box/value/vless-reality-vision_sid
    echo "[+] vless-reality-vision 独立密钥对已生成:"
    echo "    -> PrivateKey: $pri"
    echo "    -> PublicKey : $pub"
    echo "    -> Short ID  : $sid_vvr"

    # -------------------------------- 6. vless-xhttp-reality --------------------------------
    echo -e "\n--- [6/9] 配置协议: vless-xhttp-reality ---"
    p_def=$([ -f /etc/sing-box/value/vless-xhttp-reality_port ] && cat /etc/sing-box/value/vless-xhttp-reality_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/vless-xhttp-reality_port

    uuid_def=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "3179dce2-2ff9-413c-85b4-c1d53ed41668")
    read -p "请输入 UUID (回车随机生成 [$uuid_def]): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid="$uuid_def"
    echo "$uuid" > /etc/sing-box/value/vless-xhttp-reality_uuid

    read -p "请输入 server_name 与 server (回车默认 intl.cloud.tencent.com): " sname < /dev/tty
    [ -z "$sname" ] && sname="intl.cloud.tencent.com"
    echo "$sname" > /etc/sing-box/value/vless-xhttp-reality_server

    if command -v sing-box &>/dev/null; then
        kp_output=$(sing-box generate reality-keypair 2>/dev/null)
        pri_vxr=$(echo "$kp_output" | grep -i "PrivateKey" | awk '{print $NF}')
        pub_vxr=$(echo "$kp_output" | grep -i "PublicKey" | awk '{print $NF}')
        [ -z "$pri_vxr" ] && pri_vxr=$(echo "$kp_output" | head -n 1 | awk '{print $NF}')
        [ -z "$pub_vxr" ] && pub_vxr=$(echo "$kp_output" | tail -n 1 | awk '{print $NF}')
    else
        pri_vxr="bEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg"
        pub_vxr="dummy_public_key_vless_xhttp"
    fi
    echo "$pri_vxr" > /etc/sing-box/value/vless-xhttp-reality_pri
    echo "$pub_vxr" > /etc/sing-box/value/vless-xhttp-reality_pub
    sid_vxr=$(openssl rand -hex 8 2>/dev/null || echo "27dfe873147095d2")
    echo "$sid_vxr" > /etc/sing-box/value/vless-xhttp-reality_sid
    echo "[+] vless-xhttp-reality 独立密钥对已生成:"
    echo "    -> PrivateKey: $pri_vxr"
    echo "    -> PublicKey : $pub_vxr"
    echo "    -> Short ID  : $sid_vxr"

    # -------------------------------- 7. tuicv5-01-bing --------------------------------
    echo -e "\n--- [7/9] 配置协议: tuicv5-01-bing ---"
    p_def=$([ -f /etc/sing-box/value/tuicv5-01-bing_port ] && cat /etc/sing-box/value/tuicv5-01-bing_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/tuicv5-01-bing_port

    read -p "请输入 UUID (回车默认与 vless 相同): " uuid < /dev/tty
    [ -z "$uuid" ] && uuid=$(cat /etc/sing-box/value/vless-reality-vision_uuid 2>/dev/null || echo "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    echo "$uuid" > /etc/sing-box/value/tuicv5-01-bing_uuid

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/tuicv5-01-bing_password
    echo "/etc/sing-box/ziqian/cert.pem" > /etc/sing-box/value/tuicv5-01-bing_cert
    echo "/etc/sing-box/ziqian/private.key" > /etc/sing-box/value/tuicv5-01-bing_key

    # -------------------------------- 8. mieru-01-tcp --------------------------------
    echo -e "\n--- [8/9] 配置协议: mieru-01-tcp ---"
    p_def=$([ -f /etc/sing-box/value/mieru-01-tcp_port ] && cat /etc/sing-box/value/mieru-01-tcp_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/mieru-01-tcp_port

    uname_def="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
    read -p "请输入用户名/name (回车随机生成 [$uname_def]): " uname < /dev/tty
    [ -z "$uname" ] && uname="$uname_def"
    echo "$uname" > /etc/sing-box/value/mieru-01-tcp_username

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/mieru-01-tcp_password

    # -------------------------------- 9. mieru-02-udp --------------------------------
    echo -e "\n--- [9/9] 配置协议: mieru-02-udp ---"
    p_def=$([ -f /etc/sing-box/value/mieru-02-udp_port ] && cat /etc/sing-box/value/mieru-02-udp_port || get_random_port)
    read -p "请输入端口 (回车采用 [$p_def]): " port < /dev/tty
    [ -z "$port" ] && port="$p_def"
    echo "$port" > /etc/sing-box/value/mieru-02-udp_port

    uname_def2="user_$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
    read -p "请输入用户名/name (回车随机生成 [$uname_def2]): " uname < /dev/tty
    [ -z "$uname" ] && uname="$uname_def2"
    echo "$uname" > /etc/sing-box/value/mieru-02-udp_username

    pwd_def=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 30)
    read -p "请输入密码 (回车随机生成 [$pwd_def]): " password < /dev/tty
    [ -z "$password" ] && password="$pwd_def"
    echo "$password" > /etc/sing-box/value/mieru-02-udp_password

    echo "[√] 所有 9 个协议节点向导配置及独立密钥对/参数保存完毕！"
}

# ==========================================
# 功能函数 5: 防火墙检测、安装与端口放行
# ==========================================
action_setup_firewall() {
    echo -e "\n===================================="
    echo "  开始配置：防火墙检测、安装与端口放行"
    echo "===================================="

    if command -v apt-get &>/dev/null; then
        OS_FAMILY="debian"
    else
        OS_FAMILY="redhat"
    fi

    HAS_UFW=0
    HAS_FIREWALLD=0
    command -v ufw &>/dev/null && HAS_UFW=1
    command -v firewall-cmd &>/dev/null && HAS_FIREWALLD=1

    if [ "$OS_FAMILY" = "debian" ]; then
        [ "$HAS_FIREWALLD" -eq 1 ] && { systemctl stop firewalld &>/dev/null; apt-get purge -y firewalld &>/dev/null; }
        [ "$HAS_UFW" -eq 0 ] && { apt-get update -y &>/dev/null; apt-get install -y ufw &>/dev/null; }
        ACTIVE_FW="ufw"
    else
        [ "$HAS_UFW" -eq 1 ] && { systemctl stop ufw &>/dev/null; yum remove -y ufw &>/dev/null; }
        [ "$HAS_FIREWALLD" -eq 0 ] && { yum install -y firewalld &>/dev/null || dnf install -y firewalld &>/dev/null; }
        ACTIVE_FW="firewalld"
    fi

    SSH_PORT=$(grep -E "^[#\s]*Port\s+[0-9]+" /etc/ssh/sshd_config | awk '{print $2}' | tail -n 1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    nodes=(
        "hysteria2-01-bing"
        "hysteria2-02-yuming"
        "anytls-01-bing"
        "anytls-02-reality"
        "vless-reality-vision"
        "vless-xhttp-reality"
        "tuicv5-01-bing"
        "mieru-01-tcp"
        "mieru-02-udp"
    )

    if [ "$ACTIVE_FW" = "ufw" ]; then
        ufw --force enable &>/dev/null
        ufw allow "$SSH_PORT"/tcp comment "ssh端口" &>/dev/null
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/${node}_port"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                case "$node" in
                    "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                        ufw allow "$p"/udp comment "$node" &>/dev/null ;;
                    *)
                        ufw allow "$p"/tcp comment "$node" &>/dev/null ;;
                esac
            fi
        done
        ufw reload &>/dev/null
        echo "[√] UFW 防火墙端口放行完成！"
    else
        systemctl start firewalld &>/dev/null
        systemctl enable firewalld &>/dev/null
        firewall-cmd --permanent --add-port="$SSH_PORT"/tcp &>/dev/null
        for node in "${nodes[@]}"; do
            f="/etc/sing-box/value/${node}_port"
            if [ -f "$f" ]; then
                p=$(cat "$f")
                case "$node" in
                    "hysteria2-01-bing"|"hysteria2-02-yuming"|"tuicv5-01-bing"|"mieru-02-udp")
                        firewall-cmd --permanent --add-port="$p"/udp &>/dev/null ;;
                    *)
                        firewall-cmd --permanent --add-port="$p"/tcp &>/dev/null ;;
                esac
            fi
        done
        firewall-cmd --reload &>/dev/null
        echo "[√] Firewalld 防火墙端口放行完成！"
    fi
}

# ==========================================
# 功能函数 7: 生成 /etc/sing-box/config.json
# ==========================================
action_generate_config_json() {
    echo -e "\n===================================="
    echo "  正在组装并写入 /etc/sing-box/config.json"
    echo "===================================="

    read_val() {
        local file="/etc/sing-box/value/$1"
        [ -f "$file" ] && cat "$file" || echo "$2"
    }

    # 1. 读取各项参数
    p_any1=$(read_val "anytls-01-bing_port" "38559")
    pw_any1=$(read_val "anytls-01-bing_password" "dfgdfgerterterdfg234234")
    cert_any1=$(read_val "anytls-01-bing_cert" "/etc/sing-box/cert.pem")
    key_any1=$(read_val "anytls-01-bing_key" "/etc/sing-box/private.key")

    p_any2=$(read_val "anytls-02-reality_port" "49115")
    pw_any2=$(read_val "anytls-02-reality_password" "sdfsfsf2345dsf32r4rwer")
    srv_any2=$(read_val "anytls-02-reality_server" "gateway.icloud.com")
    pri_any2=$(read_val "anytls-02-reality_pri" "gKPwgyITTWk1lrlGF19jTZGFrkTDJ4W7vD2jSs2K6Uk")
    sid_any2=$(read_val "anytls-02-reality_sid" "d1df3e44")

    p_hy1=$(read_val "hysteria2-01-bing_port" "45688")
    pw_hy1=$(read_val "hysteria2-01-bing_password" "hgjghj56456ght45ty45y45y")
    cert_hy1=$(read_val "hysteria2-01-bing_cert" "/etc/sing-box/cert.pem")
    key_hy1=$(read_val "hysteria2-01-bing_key" "/etc/sing-box/private.key")

    p_hy2=$(read_val "hysteria2-02-yuming_port" "49115")
    pw_hy2=$(read_val "hysteria2-02-yuming_password" "asdweqwerwerdfgd23423")
    cert_hy2=$(read_val "hysteria2-02-yuming_cert" "/root/ygkkkca/cert.crt")
    key_hy2=$(read_val "hysteria2-02-yuming_key" "/root/ygkkkca/private.key")

    p_vvr=$(read_val "vless-reality-vision_port" "28911")
    uuid_vvr=$(read_val "vless-reality-vision_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    srv_vvr=$(read_val "vless-reality-vision_server" "dl.delivery.mp.microsoft.com")
    pri_vvr=$(read_val "vless-reality-vision_pri" "aEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg")
    sid_vvr=$(read_val "vless-reality-vision_sid" "27dfe873147095d1")

    p_vxr=$(read_val "vless-xhttp-reality_port" "56433")
    uuid_vxr=$(read_val "vless-xhttp-reality_uuid" "3179dce2-2ff9-413c-85b4-c1d53ed41668")
    srv_vxr=$(read_val "vless-xhttp-reality_server" "intl.cloud.tencent.com")
    pri_vxr=$(read_val "vless-xhttp-reality_pri" "bEjTOLv8hSboBxvgt5drG-zoQAEkMHBrVwQspV-sZHg")
    sid_vxr=$(read_val "vless-xhttp-reality_sid" "27dfe873147095d2")

    p_tuic=$(read_val "tuicv5-01-bing_port" "35688")
    uuid_tuic=$(read_val "tuicv5-01-bing_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    pw_tuic=$(read_val "tuicv5-01-bing_password" "3r34r34r34r34reffsfs")
    cert_tuic=$(read_val "tuicv5-01-bing_cert" "/etc/sing-box/cert.pem")
    key_tuic=$(read_val "tuicv5-01-bing_key" "/etc/sing-box/private.key")

    p_m1=$(read_val "mieru-01-tcp_port" "32498")
    u_m1=$(read_val "mieru-01-tcp_username" "y64rtyty")
    pw_m1=$(read_val "mieru-01-tcp_password" "asdade32rew23r2234r24")

    p_m2=$(read_val "mieru-02-udp_port" "46587")
    u_m2=$(read_val "mieru-02-udp_username" "3r33r3fs")
    pw_m2=$(read_val "mieru-02-udp_password" "a32e4r34rttfg5t5t53t3")

    # 2. 写入完整的 JSON 配置文件
    cat << EOF > /etc/sing-box/config.json
{
    "log": {
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "anytls",
            "tag": "anytls-01-bing",
            "listen": "::",
            "listen_port": $p_any1,
            "users": [
                {
                    "password": "$pw_any1"
                }
            ],
            "padding_scheme": [
                "stop=10",
                "0=30-30",
                "1=100-400,c,10-10",
                "2=200-300,c,200-300,c,200-300",
                "3=9-9",
                "4-9=50-100"
            ],
            "tls": {
                "enabled": true,
                "certificate_path": "$cert_any1",
                "key_path": "$key_any1"
            }
        },
        {
            "type": "anytls",
            "tag": "anytls-02-reality",
            "listen": "::",
            "listen_port": $p_any2,
            "users": [
                {
                    "password": "$pw_any2"
                }
            ],
            "padding_scheme": [],
            "tls": {
                "enabled": true,
                "server_name": "$srv_any2",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$srv_any2",
                        "server_port": 443
                    },
                    "private_key": "$pri_any2",
                    "short_id": [
                        "$sid_any2"
                    ]
                }
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-01-bing",
            "listen": "::",
            "listen_port": $p_hy1,
            "users": [
                {
                    "password": "$pw_hy1"
                }
            ],
            "ignore_client_bandwidth": false,
            "tls": {
                "enabled": true,
                "alpn": [
                    "h3"
                ],
                "certificate_path": "$cert_hy1",
                "key_path": "$key_hy1"
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-02-yuming",
            "listen": "::",
            "listen_port": $p_hy2,
            "users": [
                {
                    "password": "$pw_hy2"
                }
            ],
            "ignore_client_bandwidth": false,
            "tls": {
                "enabled": true,
                "alpn": [
                    "h3"
                ],
                "certificate_path": "$cert_hy2",
                "key_path": "$key_hy2"
            }
        },
        {
            "type": "vless",
            "tag": "vless-reality-vision",
            "listen": "::",
            "listen_port": $p_vvr,
            "users": [
                {
                    "uuid": "$uuid_vvr",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$srv_vvr",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$srv_vvr",
                        "server_port": 443
                    },
                    "private_key": "$pri_vvr",
                    "short_id": [
                        "$sid_vvr"
                    ]
                }
            }
        },
        {
            "type": "vless",
            "tag": "vless-xhttp-reality",
            "listen": "::",
            "listen_port": $p_vxr,
            "users": [
                {
                    "uuid": "$uuid_vxr",
                    "flow": ""
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$srv_vxr",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "$srv_vxr",
                        "server_port": 443
                    },
                    "private_key": "$pri_vxr",
                    "short_id": [
                        "$sid_vxr"
                    ]
                }
            },
            "transport": {
                "type": "xhttp",
                "path": "/",
                "mode": "auto",
                "x_padding_bytes": "100-1000"
            }
        },
        {
            "type": "tuic",
            "tag": "tuicv5-01-bing",
            "listen": "::",
            "listen_port": $p_tuic,
            "users": [
                {
                    "uuid": "$uuid_tuic",
                    "password": "$pw_tuic"
                }
            ],
            "congestion_control": "cubic",
            "auth_timeout": "3s",
            "zero_rtt_handshake": false,
            "heartbeat": "10s",
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "alpn": [
                    "h3"
                ],
                "certificate_path": "$cert_tuic",
                "key_path": "$key_tuic"
            }
        },
        {
            "type": "mieru",
            "tag": "mieru-01-tcp",
            "listen_port": $p_m1,
            "transport": "TCP",
            "users": [
                {
                    "name": "$u_m1",
                    "password": "$pw_m1"
                }
            ],
            "traffic_pattern": "GgQIARAK",
            "mtu": 1400
        },
        {
            "type": "mieru",
            "tag": "mieru-02-udp",
            "listen_port": $p_m2,
            "transport": "UDP",
            "users": [
                {
                    "name": "$u_m2",
                    "password": "$pw_m2"
                }
            ],
            "traffic_pattern": "GgQIARAK",
            "mtu": 1400
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "endpoints": [
        {
            "type": "wireguard",
            "tag": "warp-out",
            "address": [
                "172.16.0.2/32",
                "2606:4700:110:8701:8c03:4abe:4756:1a71/128"
            ],
            "private_key": "CEfHC7QzBIo62pLZQMIEPchSXKoXW93XfKAwOIOATWE=",
            "peers": [
                {
                    "address": "162.159.193.10",
                    "port": 2408,
                    "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                    "allowed_ips": [
                        "0.0.0.0/0",
                        "::/0"
                    ]
                }
            ]
        }
    ],
    "route": {
        "rules": [
            {
                "action": "sniff"
            },
            {
                "domain": [
                    "gemini.google.com",
                    "generativelanguage.googleapis.com",
                    "aistudio.google.com",
                    "alkaliminer-pa.googleapis.com",
                    "accounts.google.com",
                    "ssl.gstatic.com",
                    "www.gstatic.com",
                    "fonts.gstatic.com",
                    "apis.google.com",
                    "openai.com",
                    "chat.openai.com",
                    "auth0.openai.com",
                    "cdn.openai.com",
                    "api.openai.com",
                    "auth0.com"
                ],
                "action": "route",
                "outbound": "warp-out"
            },
            {
                "outbound": "direct",
                "network": "udp,tcp"
            }
        ],
        "final": "direct"
    }
}
EOF

    echo "[√] 配置文件已成功写入 /etc/sing-box/config.json！"
}
# ==========================================
# 功能函数 8: 创建系统服务并启动 sing-box
# ==========================================
action_start_singbox() {
    echo -e "\n===================================="
    echo "  正在创建 systemd 服务并启动 sing-box"
    echo "===================================="

    local SB_BIN=""
    if command -v sing-box &>/dev/null; then
        SB_BIN=$(command -v sing-box)
    elif [ -f /usr/local/bin/sing-box ]; then
        SB_BIN="/usr/local/bin/sing-box"
    elif [ -f /usr/bin/sing-box ]; then
        SB_BIN="/usr/bin/sing-box"
    else
        echo "[-] 错误：未检测到 sing-box 程序，请确认核心是否已安装！"
        return 1
    fi

    cat << EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SB_BIN run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box

    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo "[√] sing-box 服务已成功启动并设置为开机自启！"
        systemctl status sing-box --no-pager
    else
        echo "[-] 错误：sing-box 启动失败，请检查以下运行日志："
        journalctl -u sing-box -n 25 --no-pager
    fi
}

# ==========================================
# 功能函数 8: 生成客户端配置与订阅地址
# ==========================================
action_generate_client_configs() {
    echo -e "\n===================================="
    echo "  正在生成客户端配置与 9 节点订阅合计"
    echo "===================================="

    mkdir -p /etc/sing-box/kehu

    # 获取公网 IP（默认项）
    PUBLIC_IP=$(curl -s ifconfig.me || curl -s api.ipify.org || hostname -I | awk '{print $1}')
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"

    # 智能检查是否有域名证书（若有则提取 CN 域名作为域名节点的连接地址）
    HY2_DOMAIN_SERVER="$PUBLIC_IP"
    if [ -f /root/ygkkkca/cert.crt ]; then
        local extracted_domain=$(openssl x509 -noout -subject -in /root/ygkkkca/cert.crt 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p')
        [ -n "$extracted_domain" ] && HY2_DOMAIN_SERVER="$extracted_domain"
    fi

    read_val() {
        local file="/etc/sing-box/value/$1"
        [ -f "$file" ] && cat "$file" || echo "$2"
    }

    # 读取各项配置值
    p_any1=$(read_val "anytls-01-bing_port" "38559")
    pw_any1=$(read_val "anytls-01-bing_password" "dfgdfgerterterdfg234234")

    p_any2=$(read_val "anytls-02-reality_port" "49115")
    pw_any2=$(read_val "anytls-02-reality_password" "sdfsfsf2345dsf32r4rwer")
    srv_any2=$(read_val "anytls-02-reality_server" "gateway.icloud.com")
    pub_any2=$(read_val "anytls-02-reality_pub" "dummy_pub")
    sid_any2=$(read_val "anytls-02-reality_sid" "d1df3e44")

    p_hy1=$(read_val "hysteria2-01-bing_port" "45688")
    pw_hy1=$(read_val "hysteria2-01-bing_password" "hgjghj56456ght45ty45y45y")

    p_hy2=$(read_val "hysteria2-02-yuming_port" "49115")
    pw_hy2=$(read_val "hysteria2-02-yuming_password" "asdweqwerwerdfgd23423")

    p_vvr=$(read_val "vless-reality-vision_port" "28911")
    uuid_vvr=$(read_val "vless-reality-vision_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    srv_vvr=$(read_val "vless-reality-vision_server" "dl.delivery.mp.microsoft.com")
    pub_vvr=$(read_val "vless-reality-vision_pub" "dummy_pub")
    sid_vvr=$(read_val "vless-reality-vision_sid" "27dfe873147095d1")

    p_vxr=$(read_val "vless-xhttp-reality_port" "56433")
    uuid_vxr=$(read_val "vless-xhttp-reality_uuid" "3179dce2-2ff9-413c-85b4-c1d53ed41668")
    srv_vxr=$(read_val "vless-xhttp-reality_server" "intl.cloud.tencent.com")
    pub_vxr=$(read_val "vless-xhttp-reality_pub" "dummy_pub")
    sid_vxr=$(read_val "vless-xhttp-reality_sid" "27dfe873147095d2")

    p_tuic=$(read_val "tuicv5-01-bing_port" "35688")
    uuid_tuic=$(read_val "tuicv5-01-bing_uuid" "09c28c16-a8be-44e4-af7c-2e71cca5558e")
    pw_tuic=$(read_val "tuicv5-01-bing_password" "3r34r34r34r34reffsfs")

    p_m1=$(read_val "mieru-01-tcp_port" "32498")
    u_m1=$(read_val "mieru-01-tcp_username" "y64rtyty")
    pw_m1=$(read_val "mieru-01-tcp_password" "asdade32rew23r2234r24")

    p_m2=$(read_val "mieru-02-udp_port" "46587")
    u_m2=$(read_val "mieru-02-udp_username" "3r33r3fs")
    pw_m2=$(read_val "mieru-02-udp_password" "a32e4r34rttfg5t5t53t3")

    # 1. 生成 V2Ray/通用客户端的 9 协议订阅合计链接文件 (/etc/sing-box/kehu/v2ray_links.txt)
    cat << EOF > /etc/sing-box/kehu/v2ray_links.txt
==================================================
 sing-box 9 节点客户端分享与订阅合计
 服务器IP: $PUBLIC_IP (域名节点: $HY2_DOMAIN_SERVER)
==================================================

1. anytls-01-bing (Port: $p_any1)
anytls://$pw_any1@$PUBLIC_IP:$p_any1?security=tls&sni=www.bing.com&allowInsecure=1#anytls-01-bing

2. anytls-02-reality (Port: $p_any2)
anytls://$pw_any2@$PUBLIC_IP:$p_any2?security=tls&sni=$srv_any2&pbk=$pub_any2&sid=$sid_any2#anytls-02-reality

3. hysteria2-01-bing (Port: $p_hy1)
hysteria2://$pw_hy1@$PUBLIC_IP:$p_hy1?insecure=1&sni=www.bing.com#hysteria2-01-bing

4. hysteria2-02-yuming (Port: $p_hy2)
hysteria2://$pw_hy2@$HY2_DOMAIN_SERVER:$p_hy2?insecure=1&sni=$HY2_DOMAIN_SERVER#hysteria2-02-yuming

5. vless-reality-vision (Port: $p_vvr)
vless://$uuid_vvr@$PUBLIC_IP:$p_vvr?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$srv_vvr&pbk=$pub_vvr&sid=$sid_vvr&type=tcp#vless-reality-vision

6. vless-xhttp-reality (Port: $p_vxr)
vless://$uuid_vxr@$PUBLIC_IP:$p_vxr?encryption=none&security=reality&sni=$srv_vxr&pbk=$pub_vxr&sid=$sid_vxr&type=xhttp&path=/#vless-xhttp-reality

7. tuicv5-01-bing (Port: $p_tuic)
tuic://$uuid_tuic:$pw_tuic@$PUBLIC_IP:$p_tuic?congestion_control=cubic&sni=www.bing.com&allow_insecure=1#tuicv5-01-bing

8. mieru-01-tcp (Port: $p_m1)
mieru://$u_m1:$pw_m1@$PUBLIC_IP:$p_m1?transport=TCP#mieru-01-tcp

9. mieru-02-udp (Port: $p_m2)
mieru://$u_m2:$pw_m2@$PUBLIC_IP:$p_m2?transport=UDP#mieru-02-udp
==================================================
EOF

    # 2. 生成 Mihomo 客户端配置 (/etc/sing-box/kehu/mihomo.yaml)
    cat << EOF > /etc/sing-box/kehu/mihomo.yaml
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
proxies:
  - name: "anytls-01-bing"
    type: anytls
    server: $PUBLIC_IP
    port: $p_any1
    password: "$pw_any1"
    tls: true
    sni: "www.bing.com"
    skip-cert-verify: true

  - name: "anytls-02-reality"
    type: anytls
    server: $PUBLIC_IP
    port: $p_any2
    password: "$pw_any2"
    tls: true
    sni: "$srv_any2"
    reality-opts:
      public-key: "$pub_any2"
      short-id: "$sid_any2"

  - name: "hysteria2-01-bing"
    type: hysteria2
    server: $PUBLIC_IP
    port: $p_hy1
    password: "$pw_hy1"
    sni: "www.bing.com"
    skip-cert-verify: true

  - name: "hysteria2-02-yuming"
    type: hysteria2
    server: $HY2_DOMAIN_SERVER
    port: $p_hy2
    password: "$pw_hy2"
    sni: "$HY2_DOMAIN_SERVER"
    skip-cert-verify: true

  - name: "vless-reality-vision"
    type: vless
    server: $PUBLIC_IP
    port: $p_vvr
    uuid: "$uuid_vvr"
    flow: "xtls-rprx-vision"
    tls: true
    servername: "$srv_vvr"
    reality-opts:
      public-key: "$pub_vvr"
      short-id: "$sid_vvr"

  - name: "vless-xhttp-reality"
    type: vless
    server: $PUBLIC_IP
    port: $p_vxr
    uuid: "$uuid_vxr"
    tls: true
    servername: "$srv_vxr"
    network: xhttp
    reality-opts:
      public-key: "$pub_vxr"
      short-id: "$sid_vxr"
    xhttp-opts:
      path: "/"

  - name: "tuicv5-01-bing"
    type: tuic
    server: $PUBLIC_IP
    port: $p_tuic
    uuid: "$uuid_tuic"
    password: "$pw_tuic"
    sni: "www.bing.com"
    skip-cert-verify: true
    congestion-control: cubic

  - name: "mieru-01-tcp"
    type: mieru
    server: $PUBLIC_IP
    port: $p_m1
    username: "$u_m1"
    password: "$pw_m1"
    transport: TCP
    mtu: 1400

  - name: "mieru-02-udp"
    type: mieru
    server: $PUBLIC_IP
    port: $p_m2
    username: "$u_m2"
    password: "$pw_m2"
    transport: UDP
    mtu: 1400

rule-providers: {}
rules:
  - MATCH,DIRECT
EOF

    # 3. 生成 Sing-box 客户端配置 (/etc/sing-box/kehu/client_config.json) - 完整包含 9 个协议
    cat << EOF > /etc/sing-box/kehu/client_config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "outbounds": [
    {
      "type": "anytls",
      "tag": "anytls-01-bing",
      "server": "$PUBLIC_IP",
      "server_port": $p_any1,
      "password": "$pw_any1",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "www.bing.com"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-02-reality",
      "server": "$PUBLIC_IP",
      "server_port": $p_any2,
      "password": "$pw_any2",
      "tls": {
        "enabled": true,
        "server_name": "$srv_any2",
        "reality": {
          "enabled": true,
          "public_key": "$pub_any2",
          "short_id": "$sid_any2"
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-01-bing",
      "server": "$PUBLIC_IP",
      "server_port": $p_hy1,
      "password": "$pw_hy1",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "www.bing.com"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-02-yuming",
      "server": "$HY2_DOMAIN_SERVER",
      "server_port": $p_hy2,
      "password": "$pw_hy2",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "$HY2_DOMAIN_SERVER"
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-vision",
      "server": "$PUBLIC_IP",
      "server_port": $p_vvr,
      "uuid": "$uuid_vvr",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$srv_vvr",
        "reality": {
          "enabled": true,
          "public_key": "$pub_vvr",
          "short_id": "$sid_vvr"
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-xhttp-reality",
      "server": "$PUBLIC_IP",
      "server_port": $p_vxr,
      "uuid": "$uuid_vxr",
      "tls": {
        "enabled": true,
        "server_name": "$srv_vxr",
        "reality": {
          "enabled": true,
          "public_key": "$pub_vxr",
          "short_id": "$sid_vxr"
        }
      },
      "transport": {
        "type": "xhttp",
        "mode": "auto",
        "host": "$srv_vxr",
        "path": "/",
        "x_padding_bytes": "100-1000",
        "download": {
          "host": "$srv_vxr",
          "path": "/",
          "x_padding_bytes": "100-1000",
          "tls": {
            "enabled": true,
            "server_name": "$srv_vxr"
          }
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuicv5-01-bing",
      "server": "$PUBLIC_IP",
      "server_port": $p_tuic,
      "uuid": "$uuid_tuic",
      "password": "$pw_tuic",
      "congestion_control": "cubic",
      "tls": {
        "enabled": true,
        "insecure": true,
        "server_name": "www.bing.com"
      }
    },
    {
      "type": "mieru",
      "tag": "mieru-01-tcp",
      "server": "$PUBLIC_IP",
      "server_port": $p_m1,
      "transport": "TCP",
      "username": "$u_m1",
      "password": "$pw_m1",
      "multiplexing": "MULTIPLEXING_LOW",
      "traffic_pattern": "GgQIARAK",
      "mtu": 1400,
      "handshake_mode": "HANDSHAKE_STANDARD"
    },
    {
      "type": "mieru",
      "tag": "mieru-02-udp",
      "server": "$PUBLIC_IP",
      "server_port": $p_m2,
      "transport": "UDP",
      "username": "$u_m2",
      "password": "$pw_m2",
      "multiplexing": "MULTIPLEXING_LOW",
      "traffic_pattern": "GgQIARAK",
      "mtu": 1400,
      "handshake_mode": "HANDSHAKE_STANDARD"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    echo "[√] 所有客户端配置已成功保存至 /etc/sing-box/kehu/ 目录！"
    echo "=================================================="
    echo "📄 订阅与配置文件列表："
    echo "  1. 链接汇总: /etc/sing-box/kehu/v2ray_links.txt"
    echo "  2. Mihomo:   /etc/sing-box/kehu/mihomo.yaml"
    echo "  3. Sing-box: /etc/sing-box/kehu/client_config.json"
    echo "=================================================="
    echo "💡 节点链接预览（部分）:"
    cat /etc/sing-box/kehu/v2ray_links.txt | head -n 15
    echo "......（更多链接请查看 /etc/sing-box/kehu/v2ray_links.txt 文件）"
}
# ==========================================
# 功能函数 9: BBR 管理功能模块
# ==========================================
manage_bbr() {
    local sysctl_file="/etc/sysctl.d/99-bbr.conf"

    # 内部状态检测
    _check_bbr() {
        local result
        result=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
        [ "$result" = "bbr" ]
    }

    # 内部开启 BBR
    _enable_bbr() {
        echo "----------------------------------------"
        echo "正在检查系统内核版本与模块支持..."
        local kernel_version
        kernel_version=$(uname -r | awk -F. '{print $1*100 + $2}')
        
        if [ "$kernel_version" -lt 409 ]; then
            echo "❌ 错误：当前内核版本低于 4.9，系统不支持原生 BBR！"
            return 1
        }

        if ! modprobe tcp_bbr 2>/dev/null; then
            echo "⚠️ 警告：无法动态加载 tcp_bbr 模块，请检查内核是否编译了 BBR 支持。"
        fi

        if [ -d /etc/modules-load.d ]; then
            echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        else
            if ! grep -Fxq "tcp_bbr" /etc/modules 2>/dev/null; then
                echo "tcp_bbr" >> /etc/modules
            fi
        fi

        mkdir -p /etc/sysctl.d
        cat > "$sysctl_file" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1
        
        if _check_bbr; then
            echo "✅ 成功：BBR 已成功开启并即时生效！"
        else
            echo "❌ 警告：配置已写入，但当前未能实时生效，建议重启系统后再次检查。"
        fi
        echo "----------------------------------------"
    }

    # 内部关闭 BBR
    _disable_bbr() {
        echo "----------------------------------------"
        echo "正在关闭 BBR 并清理配置..."
        [ -f "$sysctl_file" ] && rm -f "$sysctl_file"
        [ -f /etc/modules-load.d/bbr.conf ] && rm -f /etc/modules-load.d/bbr.conf
        sed -i '/tcp_bbr/d' /etc/modules 2>/dev/null

        mkdir -p /etc/sysctl.d
        echo "net.ipv4.tcp_congestion_control=cubic" > "$sysctl_file"
        sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1
        
        echo "🔒 BBR 已关闭，当前已恢复为系统默认 cubic 算法。"
        echo "----------------------------------------"
    }

    # 权限校验
    if [ $EUID -ne 0 ]; then
       echo "❌ 错误：请使用 root 权限运行此功能！"
       return 1
    fi

    # 子菜单循环
    while true; do
        clear
        echo "========================================"
        echo "           BBR 拥塞控制管理             "
        echo "========================================"
        if _check_bbr; then
            echo "当前状态: [ 🔥 BBR 已开启 ]"
        else
            echo "当前状态: [ ⏳ BBR 未开启 ]"
        fi
        echo "----------------------------------------"
        echo "1. 开启 BBR (检测并尝试启用)"
        echo "2. 关闭 BBR (恢复系统默认)"
        echo "3. 返回上一级菜单"
        echo "========================================"
        read -p "请输入选项 [1-3]: " sub_choice
        
        case "$sub_choice" in
            1)
                _enable_bbr
                read -p "按回车键继续..."
                ;;
            2)
                _disable_bbr
                read -p "按回车键继续..."
                ;;
            3)
                break
                ;;
            *)
                echo "❌ 无效选项，请重新输入。"
                sleep 1
                ;;
        esac
    done
}
# ==========================================
# 主菜单循环
# ==========================================
show_menu() {
    clear
    get_singbox_version_info

    echo "=================================================="
    echo "      Linux VPS 自动化运维与管理工具箱          "
    echo "=================================================="
    echo " [VPS 硬件与系统环境检测]"
    echo " - 系统发行版   : $OS_NAME $OS_VERSION"
    echo " - CPU 架构     : $CPU_ARCH"
    echo " - CPU 指令级别 : $CPU_V_LEVEL"
    echo " - 当前主机名   : $CURRENT_HOSTNAME"
    echo " - Root 远程登录: $ROOT_LOGIN_STATUS"
    echo "--------------------------------------------------"
    echo " [sing-box 版本与状态检查]"
    echo " - 本地安装版本 : $LOCAL_SB_VER"
    echo " - 远程最新版本 : $REMOTE_SB_VER"
    echo " - 版本检查状态 : $SB_CHECK_STATUS"
    if command -v sing-box &>/dev/null; then
        echo "    -> 程序安装路径 : /usr/local/bin/sing-box"
        echo "    -> 配置文件目录 : /etc/sing-box/"
    fi
    echo "=================================================="
    echo " 请选择要执行的功能操作："
    echo "    1. 执行系统初始化与安全加固 (改主机名/建用户/改端口/禁Root)"
    echo "    2. 检查/安装/更新 sing-box (shtorm-7 扩展版)"
    echo "    3. 查看 sing-box 运行状态与日志"
    echo "    4. 运行完整 9 节点交互式配置向导 (含证书检测与独立密钥)"
    echo "    5. 检测/安装防火墙并自动按需放行端口 (带备注)"
    echo "    6. 自动组装并写入 /etc/sing-box/config.json"
    echo "    7. 创建并启动 sing-box 系统服务 (Systemd)"
    echo "    8. 生成客户端配置与 9 节点订阅合计 (保存至kehu目录)"
    echo "    9. 开启关闭bbr功能"
    echo "    0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-6]: " choice < /dev/tty

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
            action_view_singbox_status_logs
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        4)
            action_node_wizard
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        5)
            action_setup_firewall
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        6)
            action_generate_config_json
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        7)
            action_start_singbox
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        8)
            action_generate_client_configs
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        9)
            manage_bbr
            echo ""
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
