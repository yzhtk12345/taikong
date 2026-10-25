#!/bin/bash

# 确保以 root 运行
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
SINGBOX_CPU_SUFFIX="amd64"

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

SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -qE "^PermitRootLogin\s+no" "$SSHD_CONFIG" 2>/dev/null; then
    ROOT_LOGIN_STATUS="已禁用"
else
    ROOT_LOGIN_STATUS="未禁用 (或未配置)"
fi

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

    if grep -qE "^#?PermitRootLogin " "$SSHD_CONFIG"; then
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
    else
        echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    fi

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
# 功能函数 2: 管理与安装 sing-box
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
        SINGBOX_CPU_SUFFIX="amd64"
        DOWNLOAD_URL=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep "browser_download_url" | grep -E "linux-amd64" | head -n 1 | cut -d '"' -f 4)
    elif [ -z "$DOWNLOAD_URL" ] && [[ "$SINGBOX_CPU_SUFFIX" =~ ^arm64 ]]; then
        SINGBOX_CPU_SUFFIX="arm64"
        DOWNLOAD_URL=$(curl -sSL https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest | grep "browser_download_url" | grep -E "linux-arm64" | head -n 1 | cut -d '"' -f 4)
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "[-] 错误：未能从 Release 中匹配到任何可用的 Linux 架构安装包链接！"
        return
    fi

    TEMP_FILE="/tmp/sing-box-extended.tar.gz"
    if curl -sSL "$DOWNLOAD_URL" -o "$TEMP_FILE"; then
        mkdir -p /tmp/sing-box-extract
        tar -xzf "$TEMP_FILE" -C /tmp/sing-box-extract --strip-components=1 2>/dev/null || tar -xzf "$TEMP_FILE" -C /tmp/sing-box-extract
        
        SB_BINARY=$(find /tmp/sing-box-extract -type f -name "sing-box" | head -n 1)
        if [ -n "$SB_BINARY" ]; then
            cp -f "$SB_BINARY" /usr/local/bin/sing-box
            chmod +x /usr/local/bin/sing-box
            mkdir -p /etc/sing-box
            echo "[√] sing-box 安装/更新成功！"
            sing-box version
        else
            echo "[-] 错误：在解压后的文件中没有找到 sing-box 二进制程序。"
        fi
        rm -rf "$TEMP_FILE" /tmp/sing-box-extract
    else
        echo "[-] 错误：下载文件失败！"
    fi
}

# ==========================================
# 功能函数 3: 全协议向导配置生成器 (旗舰版)
# ==========================================
action_generate_config() {
    echo -e "\n===================================="
    echo "   sing-box 旗舰全协议配置文件向导   "
    echo "===================================="
    echo "说明: 依次输入各项配置，直接按回车将自动生成随机值。"
    echo "------------------------------------"

    # 1. 生成默认随机凭证
    DEF_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
    DEF_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    
    # 2. 交互输入各项参数
    read -p "请输入主通用 UUID (直接回车随机生成): " IN_UUID < /dev/tty
    [ -z "$IN_UUID" ] && IN_UUID="$DEF_UUID"

    read -p "请输入通用访问密码/AnyTLS密码 (直接回车随机生成): " IN_PWD < /dev/tty
    [ -z "$IN_PWD" ] && IN_PWD="$DEF_PASSWORD"

    read -p "请输入 VLESS-REALITY 伪装域名 (默认: dl.google.com): " IN_REALITY_SNI < /dev/tty
    [ -z "$IN_REALITY_SNI" ] && IN_REALITY_SNI="dl.google.com"

    read -p "请输入 XHTTP 伪装路径 (默认: /xhttp): " IN_XHTTP_PATH < /dev/tty
    [ -z "$IN_XHTTP_PATH" ] && IN_XHTTP_PATH="/xhttp"

    read -p "请输入 VLESS/XHTTP 绑定的域名 (若有证书，选填): " IN_DOMAIN < /dev/tty
    [ -z "$IN_DOMAIN" ] && IN_DOMAIN="yourdomain.com"

    # 自动生成 Reality 密钥对（如果 sing-box 支持 generate reality-keypair）
    echo "[+] 正在为 REALITY 协议生成临时公私钥..."
    REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null)
    if [ -n "$REALITY_KEYS" ]; then
        R_PRIV=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
        R_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $2}' | tr -d '"')
    else
        R_PRIV="E_xample_Priv_Key_Replace_Me_1234567890"
        R_PUB="E_xample_Pub_Key_Replace_Me_1234567890"
    fi

    echo "[+] 生成参数摘要："
    echo " - UUID        : $IN_UUID"
    echo " - 密码        : $IN_PWD"
    echo " - REALITY SNI : $IN_REALITY_SNI"
    echo " - XHTTP 路径  : $IN_XHTTP_PATH"
    echo "------------------------------------"
    read -p "确认写入配置文件并注册服务？(y/n): " confirm < /dev/tty
    [ "$confirm" != "y" ] && return

    # 3. 写入支持双 IP（:: 和 0.0.0.0）的全协议 JSON 配置文件
    CONFIG_PATH="/etc/sing-box/config.json"
    mkdir -p /etc/sing-box

    cat << EOF > "$CONFIG_PATH"
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "$IN_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_REALITY_SNI",
        "reality": {
          "enabled": true,
          "pubkey": "$R_PUB",
          "privkey": "$R_PRIV"
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-xhttp-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        {
          "uuid": "$IN_UUID",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      },
      "transport": {
        "type": "xhttp",
        "path": "$IN_XHTTP_PATH",
        "mode": "auto"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": 9443,
      "users": [
        {
          "password": "$IN_PWD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 8444,
      "users": [
        {
          "password": "$IN_PWD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": 8445,
      "users": [
        {
          "uuid": "$IN_UUID",
          "password": "$IN_PWD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IN_DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      },
      "congestion_control": "bbr"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

    echo "[+] 配置文件已成功写入: $CONFIG_PATH"

    # 4. 自动注册并配置 Systemd 服务
    SERVICE_FILE="/etc/systemd/system/sing-box.service"
    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=sing-box service (Extended Multi-Protocol)
Documentation=https://github.com/shtorm-7/sing-box-extended
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -C /etc/sing-box
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box
    echo "[√] sing-box 系统服务已成功注册并启动！"
}

# ==========================================
# 功能函数 4: 查看 sing-box 运行状态
# ==========================================
action_check_singbox_status() {
    echo -e "\n===================================="
    echo "       sing-box 运行状态与信息        "
    echo "===================================="

    if ! command -v sing-box &>/dev/null; then
        echo "[-] 提示：系统尚未安装 sing-box，请先通过菜单项 2 进行安装。"
        return
    fi

    LOCAL_VERSION=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    echo "[+] 本地版本 : ${LOCAL_VERSION:-未知}"
    echo "[+] 二进制路径: /usr/local/bin/sing-box"
    echo "[+] 配置文件目录: /etc/sing-box/"
    echo "------------------------------------"

    if systemctl list-unit-files | grep -q "sing-box.service"; then
        echo "[+] Systemd 服务: 已注册"
        SERVICE_STATUS=$(systemctl is-active sing-box)
        if [ "$SERVICE_STATUS" = "active" ]; then
            echo "[√] 运行状态   : 正在运行 (active/running)"
            PID=$(systemctl show -p MainPID --value sing-box)
            if [ "$PID" -gt 0 ] 2>/dev/null; then
                CPU_MEM=$(ps -p "$PID" -o %cpu,%mem,etime --no-headers 2>/dev/null)
                echo "[+] 进程 PID   : $PID"
                echo "[+] 资源占用   : CPU / 内存 / 运行时间"
                echo "               $CPU_MEM"
            fi
        else
            echo "[!] 运行状态   : 未运行 (状态: $SERVICE_STATUS)"
        fi
        echo "------------------------------------"
        echo "[+] 最近服务日志 (journalctl):"
        journalctl -u sing-box -n 5 --no-pager 2>/dev/null || echo "暂无日志或无法读取"
    else
        echo "[!] Systemd 服务: 未注册为系统服务"
    fi
    echo "===================================="
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
    if command -v sing-box &>/dev/null; then
        echo "   -> 程序安装路径 : /usr/local/bin/sing-box"
        echo "   -> 配置文件目录 : /etc/sing-box/"
    fi
    echo "=================================================="
    echo " 请选择要执行的功能操作："
    echo "   1. 执行系统初始化与安全加固 (建用户/改端口/禁Root)"
    echo "   2. 检查/安装/更新 sing-box (shtorm-7 扩展版)"
    echo "   3. 生成/写入 sing-box 全协议配置文件 (向导模式)"
    echo "   4. 查看 sing-box 运行状态与详情信息"
    echo "   0. 退出脚本"
    echo "=================================================="
    read -p "请输入选项数字 [0-4]: " choice < /dev/tty

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
            action_generate_config
            echo ""
            read -p "按回车键返回主菜单..." < /dev/tty
            ;;
        4)
            action_check_singbox_status
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
