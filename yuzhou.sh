#!/usr/bin/env bash
# Yuzhou Sing-box Extended Manager
# Uses shtorm-7/sing-box-extended releases; configuration and service paths are independent.
set -Eeuo pipefail
umask 077
export LANG=C.UTF-8

APP_NAME="Yuzhou Sing-box Extended Manager"
APP_DIR="/opt/yuzhou-sbx"
STATE_DIR="/etc/yuzhou-sbx"
WEBROOT="/var/lib/yuzhou-sbx/subscriptions"
BIN="$APP_DIR/sing-box"
CADDY_BIN="$APP_DIR/caddy"
CONF="$STATE_DIR/config.json"
ENV_FILE="$STATE_DIR/credentials.env"
INFO_FILE="$STATE_DIR/node-info.txt"
SERVICE_FILE="/etc/systemd/system/yuzhou-sbx.service"
SUB_SERVICE_FILE="/etc/systemd/system/yuzhou-sbx-subscription.service"
CADDYFILE="$STATE_DIR/Caddyfile"
CERT_FILE="$STATE_DIR/cert.pem"
KEY_FILE="$STATE_DIR/private.key"
ACME="$HOME/.acme.sh/acme.sh"
REPO="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
blue(){ printf '\033[36m%s\033[0m\n' "$*"; }
info(){ printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die(){ red "错误：$*"; exit 1; }
ask(){ local prompt="$1" var="$2" default="${3:-}" val; if [[ -n "$default" ]]; then read -r -p "$prompt [$default]: " val; val="${val:-$default}"; else read -r -p "$prompt: " val; fi; printf -v "$var" '%s' "$val"; }
confirm(){ local prompt="$1" default="${2:-N}" reply; if [[ "$default" == Y ]]; then read -r -p "$prompt [Y/n]: " reply; reply="${reply:-Y}"; else read -r -p "$prompt [y/N]: " reply; reply="${reply:-N}"; fi; [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; }

check_system(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行本脚本：sudo bash $0"
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release，无法识别 Linux 发行版。"
  # 第一步只检测系统版本和 CPU 架构，不做系统更改。
  . /etc/os-release
  export HOME=/root
  ACME="$HOME/.acme.sh/acme.sh"
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
  case "$(uname -m)" in
    x86_64|amd64) CPU="amd64"; PKG_ARCH_DEB="amd64"; PKG_ARCH_RPM="amd64" ;;
    aarch64|arm64) CPU="arm64"; PKG_ARCH_DEB="arm64"; PKG_ARCH_RPM="aarch64" ;;
    *) die "当前 CPU 架构 $(uname -m) 暂无此脚本可直接下载的扩展版发布包；支持 x86_64/amd64 与 aarch64/arm64。" ;;
  esac
  case "$OS_ID" in
    debian|ubuntu|linuxmint|pop) PKG_FAMILY="deb" ;;
    rhel|centos|rocky|almalinux|ol|fedora) PKG_FAMILY="rpm" ;;
    *)
      if command -v apt-get >/dev/null 2>&1; then PKG_FAMILY="deb";
      elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then PKG_FAMILY="rpm";
      else die "暂不支持自动安装 $OS_PRETTY；支持 Debian/Ubuntu 与 RHEL/CentOS/Rocky/AlmaLinux/Fedora 系。"; fi
      ;;
  esac
  blue "系统版本：$OS_PRETTY"
  blue "CPU 架构：$(uname -m)（下载架构：$CPU）"
  blue "软件包类型：$PKG_FAMILY"
  command -v systemctl >/dev/null 2>&1 || die "当前系统未检测到 systemd，无法创建系统服务。"
}

install_deps(){
  info "安装依赖"
  if [[ "$PKG_FAMILY" == deb ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq openssl tar gzip python3 iproute2 iptables sudo passwd openssh-server socat
  else
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y ca-certificates curl jq openssl tar gzip python3 iproute iptables sudo passwd openssh-server socat
      dnf install -y rpm-build cpio || true
    else
      yum install -y ca-certificates curl jq openssl tar gzip python3 iproute iptables sudo passwd openssh-server socat
      yum install -y rpm-build cpio || true
    fi
  fi
  mkdir -p "$APP_DIR" "$STATE_DIR" "$WEBROOT"
  chmod 700 "$STATE_DIR"
}

port_used(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  ss -H -lntu 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -qx "$p"
}
random_port(){
  local p i
  for i in $(seq 1 200); do
    p=$(shuf -i 20000-60000 -n 1)
    [[ " ${USED_PORTS:-} " == *" $p "* ]] && continue
    if ! port_used "$p"; then printf '%s' "$p"; return 0; fi
  done
  die "无法找到可用随机端口。"
}
choose_port(){
  local label="$1" var="$2" input p
  while true; do
    read -r -p "$label 端口（回车随机）: " input
    if [[ -z "$input" ]]; then p=$(random_port); else p="$input"; fi
    if [[ ! "$p" =~ ^[0-9]{1,5}$ ]] || (( p < 1 || p > 65535 )); then yellow "端口必须为 1–65535 的整数。"; continue; fi
    if [[ " ${USED_PORTS:-} " == *" $p "* ]] || port_used "$p"; then yellow "端口 $p 已被本次配置占用或系统已有监听，请重新选择。"; continue; fi
    USED_PORTS="${USED_PORTS:-} $p"
    printf -v "$var" '%s' "$p"
    green "$label：$p"
    return 0
  done
}

# Rule insertion preserves existing firewall policy. It never flushes tables or disables a firewall.
firewall_allow_one(){
  local port="$1" proto="$2" fw_active=0
  [[ "$proto" == tcp || "$proto" == udp ]] || return 1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "$port/$proto" >/dev/null && green "UFW 已放行 $port/$proto"; return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$port/$proto" >/dev/null && firewall-cmd --reload >/dev/null && green "firewalld 已放行 $port/$proto"; return
  fi
  if command -v iptables >/dev/null 2>&1; then
    if ! iptables -w -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then iptables -w -I INPUT -p "$proto" --dport "$port" -j ACCEPT; fi
    if command -v ip6tables >/dev/null 2>&1; then
      if ! ip6tables -w -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then ip6tables -w -I INPUT -p "$proto" --dport "$port" -j ACCEPT || true; fi
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
      if [[ -d /etc/iptables ]]; then service netfilter-persistent save >/dev/null 2>&1 || true; fi
    fi
    green "iptables 已添加 $port/$proto 规则（能否持久化取决于系统规则保存服务）。"
    return
  fi
  yellow "未检测到受支持的防火墙管理器，未自动放行 $port/$proto；请同时检查云厂商安全组。"
}
firewall_allow(){ local p="$1" protos="$2" pr; for pr in $protos; do firewall_allow_one "$p" "$pr"; done; }

# Optional host hardening from the prior requirements. The script keeps the original
# SSH port until the administrator confirms the new account/port works in a second session.
prepare_system(){
  info "Linux 主机基础初始化"
  [[ -f "$STATE_DIR/system_prepare.done" ]] && { green "基础初始化已执行过，跳过。"; return 0; }
  local hn user group ssh_port old_port sshd_bin backup_dir f
  ask "设置 Linux 主机名" hn "$(hostname)"
  if [[ ! "$hn" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$ ]] || [[ "$hn" == *..* ]]; then die "主机名格式无效。"; fi
  if command -v hostnamectl >/dev/null 2>&1; then hostnamectl set-hostname "$hn"; else hostname "$hn"; fi
  if ! grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+${hn}([[:space:]]|$)" /etc/hosts 2>/dev/null; then printf '\n127.0.1.1 %s\n' "$hn" >> /etc/hosts; fi
  green "主机名已设置为 $hn"

  ask "创建用于 SSH 登录的 sudo 管理账号" user "yuzhouadmin"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]] || die "Linux 用户名格式无效。"
  if ! id "$user" >/dev/null 2>&1; then useradd -m -s /bin/bash "$user"; fi
  if getent group sudo >/dev/null 2>&1; then group=sudo; elif getent group wheel >/dev/null 2>&1; then group=wheel; else group=sudo; groupadd -f "$group"; fi
  usermod -aG "$group" "$user"
  yellow "现在设置 $user 的登录密码（输入时不会显示字符）。"
  passwd "$user"
  green "账号 $user 已加入 $group 组。"

  command -v sshd >/dev/null 2>&1 || die "没有找到 sshd；请先安装并启动 OpenSSH Server。"
  sshd_bin=$(command -v sshd)
  old_port=$("$sshd_bin" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
  old_port="${old_port:-22}"
  while true; do
    read -r -p "新的 SSH 端口（当前 $old_port，回车随机）: " ssh_port
    if [[ -z "$ssh_port" ]]; then ssh_port=$(random_port); fi
    if [[ ! "$ssh_port" =~ ^[0-9]{1,5}$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then yellow "端口必须为 1–65535。"; continue; fi
    if [[ "$ssh_port" == "$old_port" ]] || port_used "$ssh_port"; then yellow "该端口已被使用或与当前端口相同。"; continue; fi
    break
  done
  backup_dir="$STATE_DIR/ssh-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a /etc/ssh/sshd_config "$backup_dir/sshd_config"
  if [[ -d /etc/ssh/sshd_config.d ]]; then cp -a /etc/ssh/sshd_config.d "$backup_dir/sshd_config.d"; fi
  firewall_allow "$ssh_port" "tcp"
  # If root has authorized keys, copy the public-key allow-list to the new admin account.
  if [[ -s /root/.ssh/authorized_keys && ! -s "/home/$user/.ssh/authorized_keys" ]]; then
    install -d -m 700 -o "$user" -g "$group" "/home/$user/.ssh"
    install -m 600 -o "$user" -g "$group" /root/.ssh/authorized_keys "/home/$user/.ssh/authorized_keys"
    yellow "已将 root 的 authorized_keys 公钥白名单复制到新账号，便于测试新端口登录。"
  fi
  # Comment out existing Port/PasswordAuthentication directives before staging; preserve root policy until verification.
  while IFS= read -r -d '' f; do
    cp -a "$f" "$backup_dir/$(basename "$f").$(printf '%s' "$f" | sha256sum | cut -c1-8).bak" 2>/dev/null || true
    sed -Ei '/^[[:space:]]*(Port|PasswordAuthentication)[[:space:]]+/I s/^/# Yuzhou-managed-disabled: /' "$f"
  done < <(find /etc/ssh -maxdepth 2 -type f \( -name 'sshd_config' -o -path '/etc/ssh/sshd_config.d/*.conf' \) -print0)
  # Stage with both ports active. Insert before Match so global directives remain valid.
  # Keep the existing root-login policy unchanged during the test phase.
  awk -v old="$old_port" -v new="$ssh_port" 'BEGIN{done=0} /^[[:space:]]*Match[[:space:]]/ && !done {print "Port " old; if (new != old) print "Port " new; print "PasswordAuthentication yes"; done=1} {print} END{if(!done){print "Port " old; if (new != old) print "Port " new; print "PasswordAuthentication yes"}}' /etc/ssh/sshd_config > "$STATE_DIR/sshd_config.stage"
  install -m 600 "$STATE_DIR/sshd_config.stage" /etc/ssh/sshd_config
  rm -f "$STATE_DIR/sshd_config.stage"
  if ! "$sshd_bin" -t; then
    cp -a "$backup_dir/sshd_config" /etc/ssh/sshd_config
    [[ -d "$backup_dir/sshd_config.d" ]] && { rm -rf /etc/ssh/sshd_config.d; cp -a "$backup_dir/sshd_config.d" /etc/ssh/sshd_config.d; }
    die "SSH 配置语法检查失败，已尝试还原原配置。"
  fi
  systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || die "无法重载 SSH 服务；原 SSH 会话暂时仍在，请检查系统服务。"
  yellow "现在不要关闭当前 SSH 会话。请在另一个终端测试：ssh -p $ssh_port $user@服务器地址"
  if confirm "你是否已在第二个终端成功以新账号和新端口登录？确认后才会停用 root SSH 登录" N; then
    # Final config: new port only, password auth allowed for the newly created account,
    # and root SSH login disabled. Comment conflicting global values in included files first.
    while IFS= read -r -d '' f; do
      sed -Ei '/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication)[[:space:]]+/I s/^/# Yuzhou-managed-disabled: /' "$f"
    done < <(find /etc/ssh -maxdepth 2 -type f \( -name 'sshd_config' -o -path '/etc/ssh/sshd_config.d/*.conf' \) -print0)
    awk -v p="$ssh_port" 'BEGIN{done=0} /^[[:space:]]*Match[[:space:]]/ && !done {print "Port " p; print "PermitRootLogin no"; print "PasswordAuthentication yes"; done=1} {print} END{if(!done){print "Port " p; print "PermitRootLogin no"; print "PasswordAuthentication yes"}}' /etc/ssh/sshd_config > "$STATE_DIR/sshd_config.new"
    install -m 600 "$STATE_DIR/sshd_config.new" /etc/ssh/sshd_config
    rm -f "$STATE_DIR/sshd_config.new"
    if "$sshd_bin" -t && { systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1; }; then
      if "$sshd_bin" -T 2>/dev/null | grep -qi '^permitrootlogin no$'; then
        green "SSH 加固完成：端口 $ssh_port，PermitRootLogin no。"
        printf '%s\n' "$ssh_port" > "$STATE_DIR/ssh-port"
        printf '%s\n' "$user" > "$STATE_DIR/admin-user"
        touch "$STATE_DIR/system_prepare.done"
      else
        red "配置已应用，但 sshd -T 未确认 root 禁止登录；正在还原原 SSH 配置。"
        cp -a "$backup_dir/sshd_config" /etc/ssh/sshd_config
        if [[ -d "$backup_dir/sshd_config.d" ]]; then rm -rf /etc/ssh/sshd_config.d; cp -a "$backup_dir/sshd_config.d" /etc/ssh/sshd_config.d; fi
        "$sshd_bin" -t && { systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1; } || true
      fi
    else
      red "SSH 最终配置检查/重载失败；正在还原原配置。备份位于 $backup_dir。"
      cp -a "$backup_dir/sshd_config" /etc/ssh/sshd_config
      if [[ -d "$backup_dir/sshd_config.d" ]]; then rm -rf /etc/ssh/sshd_config.d; cp -a "$backup_dir/sshd_config.d" /etc/ssh/sshd_config.d; fi
      "$sshd_bin" -t && { systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1; } || true
    fi
  else
    yellow "尚未确认新端口可用；正在还原 SSH 配置，保留原端口和原 root 登录策略。"
    cp -a "$backup_dir/sshd_config" /etc/ssh/sshd_config
    if [[ -d "$backup_dir/sshd_config.d" ]]; then rm -rf /etc/ssh/sshd_config.d; cp -a "$backup_dir/sshd_config.d" /etc/ssh/sshd_config.d; fi
    "$sshd_bin" -t && { systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1; } || yellow "还原后的 SSH 配置需要人工检查：$backup_dir"
    printf '%s\n' "$user" > "$STATE_DIR/admin-user"
    yellow "新账号已创建但尚未完成 SSH 端口切换/root 禁止登录；重新运行菜单第 8 项时可再次处理。"
  fi
}

check_domain(){
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || return 1
  [[ "$1" != *..* && "$1" != *.-* && "$1" != *-.* ]]
}

install_acme(){
  [[ -x "$ACME" ]] && return 0
  info "安装 acme.sh（用于签发和续期证书）"
  local installer="$STATE_DIR/acme-install.sh"
  curl -fsSL --retry 3 https://get.acme.sh -o "$installer" || die "下载 acme.sh 安装脚本失败。"
  chmod 700 "$installer"
  if [[ -n "${ACME_EMAIL:-}" ]]; then bash "$installer" email="$ACME_EMAIL"; else bash "$installer"; fi
  rm -f "$installer"
  [[ -x "$ACME" ]] || die "acme.sh 安装失败。"
}

cert_key_match(){
  local c="$1" k="$2" cp kp
  [[ -s "$c" && -s "$k" ]] || return 1
  openssl x509 -in "$c" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || return 1
  cp=$(openssl x509 -in "$c" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
  kp=$(openssl pkey -in "$k" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
  [[ -n "$cp" && "$cp" == "$kp" ]] || return 1
  openssl x509 -in "$c" -noout -checkend 0 >/dev/null 2>&1
}
acme_row(){ [[ -x "$ACME" ]] || return 1; "$ACME" --list 2>/dev/null | awk -v d="$DOMAIN" 'NR>1 && $1==d {print; exit}'; }

setup_certificate(){
  info "TLS 证书检查 / 复用 / 自动续期"
  local row="" keytype src_cert="" src_key="" c k reload_cmd="systemctl restart yuzhou-sbx.service >/dev/null 2>&1 || true; systemctl try-restart yuzhou-sbx-subscription.service >/dev/null 2>&1 || true"
  mkdir -p "$STATE_DIR"
  # Prefer an existing acme.sh-managed cert for this domain, but do not require
  # installing acme.sh just to reuse an already-valid certificate from old scripts.
  if [[ -x "$ACME" ]]; then row=$(acme_row || true); fi
  if [[ -n "$row" ]]; then
    keytype=$(printf '%s\n' "$row" | awk '{print $2}')
    local -a ecc_args=()
    [[ "$keytype" == ec-* ]] && ecc_args+=(--ecc)
    if "$ACME" --install-cert -d "$DOMAIN" "${ecc_args[@]}" --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$reload_cmd" && cert_key_match "$CERT_FILE" "$KEY_FILE"; then
      chmod 600 "$CERT_FILE" "$KEY_FILE"
      green "已复用 acme.sh 中的 $DOMAIN 证书，并注册自动部署/续期重载钩子。"
      return 0
    fi
    yellow "找到 acme.sh 证书记录，但部署结果未通过证书/私钥/有效期校验；将检查旧证书或重新签发。"
  fi

  # Respect certificates from the user's previous scripts when valid for this exact host.
  for c in "$CERT_FILE" /root/ygkkkca/cert.crt /etc/sing-box/cert.pem /etc/s-box/cert.pem; do
    case "$c" in
      /root/ygkkkca/cert.crt) k="/root/ygkkkca/private.key" ;;
      /etc/sing-box/cert.pem) k="/etc/sing-box/private.key" ;;
      /etc/s-box/cert.pem) k="/etc/s-box/private.key" ;;
      *) k="$KEY_FILE" ;;
    esac
    if cert_key_match "$c" "$k"; then src_cert="$c"; src_key="$k"; break; fi
  done
  if [[ -n "$src_cert" ]]; then
    yellow "发现现有证书且域名与私钥校验通过：$src_cert"
    if confirm "复用此证书？（若不是 acme.sh 管理的证书，本脚本无法替代原管理方续期）" Y; then
      [[ "$src_cert" == "$CERT_FILE" ]] || cp -f "$src_cert" "$CERT_FILE"
      [[ "$src_key" == "$KEY_FILE" ]] || cp -f "$src_key" "$KEY_FILE"
      chmod 600 "$CERT_FILE" "$KEY_FILE"
      yellow "当前复用了旧路径证书：$src_cert。若该证书不是本脚本已成功部署的 acme.sh 证书，续期仍由原证书管理方负责；可在菜单中查看到期时间。"
      return 0
    fi
  fi

  install_acme
  yellow "将为 $DOMAIN 申请新的 Let's Encrypt ECC 证书。请先确认 DNS 解析已指向本机。"
  echo "证书验证方式："
  echo "  1. HTTP-01 standalone（需外部可访问 TCP/80，且 80 端口当前空闲）"
  echo "  2. Cloudflare DNS API（无需开放 80 端口）"
  echo "  3. DNSPod DNS API（无需开放 80 端口）"
  echo "  4. 阿里云 DNS API（无需开放 80 端口）"
  local issue_mode
  read -r -p "请选择 [1-4，默认 1]: " issue_mode
  issue_mode="${issue_mode:-1}"
  local -a issue_args=(--issue -d "$DOMAIN" --keylength ec-256 --server letsencrypt)
  local secret
  case "$issue_mode" in
    1)
      port_used 80 && die "TCP/80 已被占用，脚本不会强杀现有服务。请选择 DNS API 验证或先释放 80 端口。"
      firewall_allow 80 "tcp"
      local listen_flag=()
      if ! getent ahostsv4 "$DOMAIN" >/dev/null 2>&1 && getent ahostsv6 "$DOMAIN" >/dev/null 2>&1; then listen_flag+=(--listen-v6); fi
      issue_args+=(--standalone "${listen_flag[@]}")
      ;;
    2)
      read -r -p "Cloudflare Account ID（如提示可从控制台复制）: " CF_Account_ID
      read -r -s -p "Cloudflare DNS API Token: " CF_Token; printf '\n'
      [[ -n "$CF_Token" ]] || die "Cloudflare API Token 不能为空。"
      export CF_Account_ID CF_Token
      issue_args+=(--dns dns_cf)
      ;;
    3)
      read -r -p "DNSPod DP_Id: " DP_Id
      read -r -s -p "DNSPod DP_Key: " DP_Key; printf '\n'
      [[ -n "$DP_Id" && -n "$DP_Key" ]] || die "DNSPod DP_Id/DP_Key 不能为空。"
      export DP_Id DP_Key
      issue_args+=(--dns dns_dp)
      ;;
    4)
      read -r -p "阿里云 Ali_Key: " Ali_Key
      read -r -s -p "阿里云 Ali_Secret: " Ali_Secret; printf '\n'
      [[ -n "$Ali_Key" && -n "$Ali_Secret" ]] || die "阿里云 Ali_Key/Ali_Secret 不能为空。"
      export Ali_Key Ali_Secret
      issue_args+=(--dns dns_ali)
      ;;
    *) die "证书验证方式必须是 1、2、3 或 4。" ;;
  esac
  "$ACME" "${issue_args[@]}" || die "证书签发失败。请检查域名解析、DNS API 权限或 HTTP-01 连通性。"
  "$ACME" --install-cert -d "$DOMAIN" --ecc --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$reload_cmd" || die "证书已签发，但安装/续期钩子设置失败。"
  chmod 600 "$CERT_FILE" "$KEY_FILE"
  cert_key_match "$CERT_FILE" "$KEY_FILE" || die "签发后的证书未通过域名、私钥和有效期校验。"
  green "证书已安装到 $CERT_FILE 与 $KEY_FILE；acme.sh 将按计划续期。"
}

install_extended_core(){
  info "下载 sing-box-extended 官方发布版"
  local release tag ver asset url tmp extract found
  release=$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' -H 'User-Agent: Yuzhou-SBX-Manager' "$REPO") || die "无法读取 GitHub 发布信息。"
  tag=$(printf '%s' "$release" | jq -r '.tag_name // empty')
  [[ -n "$tag" && "$tag" != null ]] || die "GitHub 没有返回最新发布标签。"
  ver="${tag#v}"
  if [[ "$PKG_FAMILY" == deb ]]; then
    asset="SFL-${ver}-${PKG_ARCH_DEB}.deb"
  else
    local candidate
    asset=""
    if [[ "$CPU" == amd64 ]]; then
      for candidate in "SFL-${ver}-amd64.rpm" "SFL-${ver}-x86_64.rpm"; do
        if printf '%s' "$release" | jq -e --arg n "$candidate" '.assets[] | select(.name==$n)' >/dev/null; then asset="$candidate"; break; fi
      done
    else
      for candidate in "SFL-${ver}-aarch64.rpm" "SFL-${ver}-arm64.rpm"; do
        if printf '%s' "$release" | jq -e --arg n "$candidate" '.assets[] | select(.name==$n)' >/dev/null; then asset="$candidate"; break; fi
      done
    fi
    [[ -n "$asset" ]] || die "最新发布 $tag 中没有适配 $CPU 的 RPM 资产。"
  fi
  url=$(printf '%s' "$release" | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' | head -n1)
  if [[ -z "$url" || "$url" == null ]]; then
    die "最新发布 $tag 中未找到可用资产 $asset。请查看 https://github.com/shtorm-7/sing-box-extended/releases。"
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' RETURN
  curl -fL --retry 3 --connect-timeout 20 -o "$tmp/core.pkg" "$url" || die "下载扩展版安装包失败。"
  mkdir -p "$tmp/extract"
  if [[ "$PKG_FAMILY" == deb ]]; then
    command -v dpkg-deb >/dev/null 2>&1 || die "系统缺少 dpkg-deb，无法解包官方 .deb。"
    dpkg-deb -x "$tmp/core.pkg" "$tmp/extract"
  else
    if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
      (cd "$tmp/extract" && rpm2cpio "$tmp/core.pkg" | cpio -idmu >/dev/null 2>&1) || die "RPM 解包失败。"
    else
      die "缺少 rpm2cpio/cpio，无法解包官方 RPM。请安装这两个工具后重试。"
    fi
  fi
  found=$(find "$tmp/extract" -type f \( -path '*/usr/bin/sing-box' -o -path '*/usr/local/bin/sing-box' -o -name 'sing-box' \) -print -quit)
  [[ -n "$found" ]] || die "在 $asset 中找不到 sing-box 可执行文件。"
  if [[ -x "$BIN" ]]; then cp -f "$BIN" "$APP_DIR/sing-box.previous"; fi
  install -m 755 "$found" "$BIN"
  if ! "$BIN" version; then
    [[ -x "$APP_DIR/sing-box.previous" ]] && cp -f "$APP_DIR/sing-box.previous" "$BIN"
    die "下载的扩展版核心无法启动；已尝试恢复上一个核心。"
  fi
  printf '%s\n' "$tag" > "$STATE_DIR/version"
  green "已安装版本：$tag"
  rm -rf "$tmp"
  trap - RETURN
}

create_credentials(){
  info "生成独立的协议端口与凭据"
  USED_PORTS=""
  choose_port "AnyTLS-TLS" P_ANYTLS_TLS
  choose_port "AnyTLS-Reality" P_ANYTLS_REALITY
  choose_port "Hysteria2-TLS" P_HY2_TLS
  choose_port "Hysteria2-域名证书" P_HY2_DOMAIN
  choose_port "VLESS-Reality-Vision" P_VLESS_REALITY
  choose_port "TUICv5" P_TUIC
  choose_port "VLESS-XHTTP-Reality" P_XHTTP
  choose_port "Mieru-TCP" P_MIERU_TCP
  choose_port "Mieru-UDP" P_MIERU_UDP
  UUID_VLESS_REALITY=$(cat /proc/sys/kernel/random/uuid)
  UUID_TUIC=$(cat /proc/sys/kernel/random/uuid)
  UUID_XHTTP=$(cat /proc/sys/kernel/random/uuid)
  PASS_ANYTLS_TLS=$(openssl rand -hex 24)
  PASS_ANYTLS_REALITY=$(cat /proc/sys/kernel/random/uuid)
  PASS_HY2_TLS=$(openssl rand -hex 24)
  PASS_HY2_DOMAIN=$(openssl rand -hex 24)
  PASS_TUIC=$(openssl rand -hex 24)
  USER_MIERU_TCP="yz$(openssl rand -hex 6)"
  PASS_MIERU_TCP=$(openssl rand -hex 24)
  USER_MIERU_UDP="yz$(openssl rand -hex 6)"
  PASS_MIERU_UDP=$(openssl rand -hex 24)
  REALITY_SNI="www.lovelive-anime.jp"
  ANYTLS_REALITY_SNI="apple.com"
  R_SHORT_ID=$(openssl rand -hex 8)
  local pair
  pair=$("$BIN" generate reality-keypair 2>/dev/null || true)
  R_PRIVATE_KEY=$(printf '%s\n' "$pair" | awk -F': *' 'tolower($1) ~ /privatekey/ {print $2; exit}')
  R_PUBLIC_KEY=$(printf '%s\n' "$pair" | awk -F': *' 'tolower($1) ~ /publickey/ {print $2; exit}')
  [[ -n "$R_PRIVATE_KEY" && -n "$R_PUBLIC_KEY" ]] || die "无法通过扩展版核心生成 Reality 密钥对。"
  SUB_TOKEN=$(openssl rand -hex 24)
  export DOMAIN CERT_FILE KEY_FILE P_ANYTLS_TLS P_ANYTLS_REALITY P_HY2_TLS P_HY2_DOMAIN P_VLESS_REALITY P_TUIC P_XHTTP P_MIERU_TCP P_MIERU_UDP
  export UUID_VLESS_REALITY UUID_TUIC UUID_XHTTP PASS_ANYTLS_TLS PASS_ANYTLS_REALITY PASS_HY2_TLS PASS_HY2_DOMAIN PASS_TUIC USER_MIERU_TCP PASS_MIERU_TCP USER_MIERU_UDP PASS_MIERU_UDP REALITY_SNI ANYTLS_REALITY_SNI R_SHORT_ID R_PRIVATE_KEY R_PUBLIC_KEY SUB_TOKEN WARP_ENABLED
  save_credentials
}

save_credentials(){
  local names name
  names="DOMAIN P_ANYTLS_TLS P_ANYTLS_REALITY P_HY2_TLS P_HY2_DOMAIN P_VLESS_REALITY P_TUIC P_XHTTP P_MIERU_TCP P_MIERU_UDP UUID_VLESS_REALITY UUID_TUIC UUID_XHTTP PASS_ANYTLS_TLS PASS_ANYTLS_REALITY PASS_HY2_TLS PASS_HY2_DOMAIN PASS_TUIC USER_MIERU_TCP PASS_MIERU_TCP USER_MIERU_UDP PASS_MIERU_UDP REALITY_SNI ANYTLS_REALITY_SNI R_SHORT_ID R_PRIVATE_KEY R_PUBLIC_KEY SUB_TOKEN WARP_ENABLED SUB_PORT"
  : > "$ENV_FILE"
  for name in $names; do printf '%s=%q\n' "$name" "${!name-}" >> "$ENV_FILE"; done
  chmod 600 "$ENV_FILE"
}
load_credentials(){
  if [[ -r "$ENV_FILE" ]]; then
    # Root-only file created by this manager; values are shell-escaped when written.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

build_configs(){
  info "生成 sing-box-extended 服务端配置和客户端文件"
  export DOMAIN CERT_FILE KEY_FILE
  python3 - <<'PY'
import json, os, pathlib, base64, urllib.parse
state = pathlib.Path('/etc/yuzhou-sbx')
web = pathlib.Path('/var/lib/yuzhou-sbx/subscriptions')
state.mkdir(parents=True, exist_ok=True)
web.mkdir(parents=True, exist_ok=True)
e = os.environ
D = e['DOMAIN']
CERT = e['CERT_FILE']; KEY = e['KEY_FILE']
def val(k): return e[k]
def tls(sni, reality=False):
    x={'enabled': True, 'server_name': sni}
    if reality:
        x['reality']={'enabled': True, 'handshake': {'server': sni, 'server_port': 443}, 'private_key': val('R_PRIVATE_KEY'), 'short_id':[val('R_SHORT_ID')]}
    else:
        x['certificate_path']=CERT; x['key_path']=KEY
    return x
inbounds = [
 {'type':'anytls','tag':'anytls-01-tls','listen':'::','listen_port':int(val('P_ANYTLS_TLS')),'users':[{'password':val('PASS_ANYTLS_TLS')}], 'padding_scheme':['stop=10','0=30-30','1=100-400,c,10-10','2=200-300,c,200-300,c,200-300','3=9-9','4-9=50-100'],'tls':tls(D)},
 {'type':'anytls','tag':'anytls-02-reality','listen':'::','listen_port':int(val('P_ANYTLS_REALITY')),'users':[{'password':val('PASS_ANYTLS_REALITY')}], 'padding_scheme':[], 'tls':tls(val('ANYTLS_REALITY_SNI'), True)},
 {'type':'hysteria2','tag':'hysteria2-01-tls','listen':'::','listen_port':int(val('P_HY2_TLS')),'users':[{'password':val('PASS_HY2_TLS')}], 'ignore_client_bandwidth':False,'tls':{'enabled':True,'alpn':['h3'],'certificate_path':CERT,'key_path':KEY}},
 {'type':'hysteria2','tag':'hysteria2-02-domain','listen':'::','listen_port':int(val('P_HY2_DOMAIN')),'users':[{'password':val('PASS_HY2_DOMAIN')}], 'ignore_client_bandwidth':False,'tls':{'enabled':True,'alpn':['h3'],'certificate_path':CERT,'key_path':KEY}},
 {'type':'vless','tag':'vless-reality-vision','listen':'::','listen_port':int(val('P_VLESS_REALITY')),'users':[{'uuid':val('UUID_VLESS_REALITY'),'flow':'xtls-rprx-vision'}],'tls':tls(val('REALITY_SNI'), True)},
 {'type':'tuic','tag':'tuicv5-tls','listen':'::','listen_port':int(val('P_TUIC')),'users':[{'uuid':val('UUID_TUIC'),'password':val('PASS_TUIC')}], 'congestion_control':'cubic','auth_timeout':'3s','zero_rtt_handshake':False,'heartbeat':'10s','tls':{'enabled':True,'server_name':D,'alpn':['h3'],'certificate_path':CERT,'key_path':KEY}},
 {'type':'vless','tag':'vless-xhttp-reality','listen':'::','listen_port':int(val('P_XHTTP')),'users':[{'uuid':val('UUID_XHTTP'),'flow':''}],'tls':tls(val('REALITY_SNI'), True),'transport':{'type':'xhttp','path':'/','mode':'stream-up','x_padding_bytes':'100-1000'}},
 {'type':'mieru','tag':'mieru-01-tcp','listen_port':int(val('P_MIERU_TCP')),'transport':'TCP','users':[{'name':val('USER_MIERU_TCP'),'password':val('PASS_MIERU_TCP')}],'traffic_pattern':'GgQIARAK','mtu':1400},
 {'type':'mieru','tag':'mieru-02-udp','listen_port':int(val('P_MIERU_UDP')),'transport':'UDP','users':[{'name':val('USER_MIERU_UDP'),'password':val('PASS_MIERU_UDP')}],'traffic_pattern':'GgQIARAK','mtu':1400},
]
route_rules=[{'action':'sniff'}]
endpoints=[]
if val('WARP_ENABLED') == 'yes':
    endpoints=[{'type':'wireguard','tag':'warp-out','address':['172.16.0.2/32','2606:4700:110:8701:8c03:4abe:4756:1a71/128'],'private_key':'CEfHC7QzBIo62pLZQMIEPchSXKoXW93XfKAwOIOATWE=','peers':[{'address':'162.159.193.10','port':2408,'public_key':'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=','allowed_ips':['0.0.0.0/0','::/0']}]}]
    route_rules.append({'domain':['gemini.google.com','generativelanguage.googleapis.com','aistudio.google.com','alkaliminer-pa.googleapis.com','accounts.google.com','ssl.gstatic.com','www.gstatic.com','fonts.gstatic.com','apis.google.com','openai.com','chat.openai.com','auth0.openai.com','cdn.openai.com','api.openai.com','auth0.com'],'action':'route','outbound':'warp-out'})
route_rules.append({'outbound':'direct','network':'udp,tcp'})
server={'log':{'level':'info','timestamp':True},'inbounds':inbounds,'outbounds':[{'type':'direct','tag':'direct'}],'route':{'rules':route_rules,'final':'direct'}}
if endpoints: server['endpoints']=endpoints
(state/'config.json').write_text(json.dumps(server,ensure_ascii=False,indent=2)+'\n')

# sing-box-extended native client profile (Mieru is represented here, not in common URI subscription lists).
host=D
out=[]
out.append({'type':'direct','tag':'direct'})
out.append({'type':'anytls','tag':'anytls-tls','server':host,'server_port':int(val('P_ANYTLS_TLS')),'password':val('PASS_ANYTLS_TLS'),'tls':{'enabled':True,'server_name':D}})
out.append({'type':'anytls','tag':'anytls-reality','server':host,'server_port':int(val('P_ANYTLS_REALITY')),'password':val('PASS_ANYTLS_REALITY'),'tls':{'enabled':True,'server_name':val('ANYTLS_REALITY_SNI'),'reality':{'enabled':True,'public_key':val('R_PUBLIC_KEY'),'short_id':[val('R_SHORT_ID')]}}})
out.append({'type':'hysteria2','tag':'hysteria2-tls','server':host,'server_port':int(val('P_HY2_TLS')),'password':val('PASS_HY2_TLS'),'tls':{'enabled':True,'server_name':D,'alpn':['h3']}})
out.append({'type':'hysteria2','tag':'hysteria2-domain','server':host,'server_port':int(val('P_HY2_DOMAIN')),'password':val('PASS_HY2_DOMAIN'),'tls':{'enabled':True,'server_name':D,'alpn':['h3']}})
out.append({'type':'vless','tag':'vless-reality-vision','server':host,'server_port':int(val('P_VLESS_REALITY')),'uuid':val('UUID_VLESS_REALITY'),'flow':'xtls-rprx-vision','tls':{'enabled':True,'server_name':val('REALITY_SNI'),'reality':{'enabled':True,'public_key':val('R_PUBLIC_KEY'),'short_id':[val('R_SHORT_ID')]}}})
out.append({'type':'tuic','tag':'tuic-tls','server':host,'server_port':int(val('P_TUIC')),'uuid':val('UUID_TUIC'),'password':val('PASS_TUIC'),'congestion_control':'cubic','tls':{'enabled':True,'server_name':D,'alpn':['h3']}})
out.append({'type':'vless','tag':'vless-xhttp-reality','server':host,'server_port':int(val('P_XHTTP')),'uuid':val('UUID_XHTTP'),'tls':{'enabled':True,'server_name':val('REALITY_SNI'),'reality':{'enabled':True,'public_key':val('R_PUBLIC_KEY'),'short_id':[val('R_SHORT_ID')]}},'transport':{'type':'xhttp','mode':'stream-up','path':'/','x_padding_bytes':'100-1000'}})
out.append({'type':'mieru','tag':'mieru-tcp','server':host,'server_port':int(val('P_MIERU_TCP')),'server_ports':[str(int(val('P_MIERU_TCP')))],'transport':'TCP','username':val('USER_MIERU_TCP'),'password':val('PASS_MIERU_TCP'),'multiplexing':'MULTIPLEXING_LOW','traffic_pattern':'GgQIARAK'})
out.append({'type':'mieru','tag':'mieru-udp','server':host,'server_port':int(val('P_MIERU_UDP')),'server_ports':[str(int(val('P_MIERU_UDP')))],'transport':'UDP','username':val('USER_MIERU_UDP'),'password':val('PASS_MIERU_UDP'),'multiplexing':'MULTIPLEXING_LOW','traffic_pattern':'GgQIARAK'})
proxy_tags=[x['tag'] for x in out if x['tag']!='direct']
out.append({'type':'selector','tag':'proxy','outbounds':proxy_tags,'default':'vless-reality-vision'})
client={'log':{'level':'warn'},'dns':{'servers':[{'type':'local','tag':'default'}]},'inbounds':[{'type':'mixed','tag':'mixed-in','listen':'127.0.0.1','listen_port':7890}],'outbounds':out,'route':{'final':'proxy','default_domain_resolver':'default','auto_detect_interface':True}}
(web/'client.json').write_text(json.dumps(client,ensure_ascii=False,indent=2)+'\n')

# Compatibility URI list. Full extended JSON includes every inbound (including Mieru and AnyTLS-Reality).
def q(s): return urllib.parse.quote(str(s), safe='')
uris=[]
uris.append(f"anytls://{q(val('PASS_ANYTLS_TLS'))}@{host}:{val('P_ANYTLS_TLS')}/?sni={q(D)}&insecure=0#Yuzhou-AnyTLS-TLS")
uris.append(f"hysteria2://{q(val('PASS_HY2_TLS'))}@{host}:{val('P_HY2_TLS')}/?sni={q(D)}&alpn=h3&insecure=0#Yuzhou-Hysteria2-TLS")
uris.append(f"hysteria2://{q(val('PASS_HY2_DOMAIN'))}@{host}:{val('P_HY2_DOMAIN')}/?sni={q(D)}&alpn=h3&insecure=0#Yuzhou-Hysteria2-Domain")
uris.append(f"vless://{q(val('UUID_VLESS_REALITY'))}@{host}:{val('P_VLESS_REALITY')}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={q(val('REALITY_SNI'))}&fp=chrome&pbk={q(val('R_PUBLIC_KEY'))}&sid={q(val('R_SHORT_ID'))}&type=tcp#Yuzhou-VLESS-Reality-Vision")
uris.append(f"tuic://{q(val('UUID_TUIC'))}:{q(val('PASS_TUIC'))}@{host}:{val('P_TUIC')}?congestion_control=cubic&alpn=h3&sni={q(D)}#Yuzhou-TUICv5")
uris.append(f"vless://{q(val('UUID_XHTTP'))}@{host}:{val('P_XHTTP')}?encryption=none&security=reality&sni={q(val('REALITY_SNI'))}&fp=chrome&pbk={q(val('R_PUBLIC_KEY'))}&sid={q(val('R_SHORT_ID'))}&type=xhttp&path=%2F&mode=stream-up#Yuzhou-VLESS-XHTTP-Reality")
raw='\n'.join(uris)+'\n'
(web/'sub.txt').write_text(base64.b64encode(raw.encode()).decode()+'\n')
(state/'uri-list.txt').write_text(raw)
(state/'uri-list.txt').chmod(0o600)
for p in web.iterdir(): p.chmod(0o644)

lines=[
 'Yuzhou Sing-box Extended — protocol details',
 f'Server / TLS domain: {D}',
 '',
 f'AnyTLS TLS: tcp/{val("P_ANYTLS_TLS")}  password={val("PASS_ANYTLS_TLS")}',
 f'AnyTLS Reality: tcp/{val("P_ANYTLS_REALITY")}  password={val("PASS_ANYTLS_REALITY")}  SNI={val("ANYTLS_REALITY_SNI")}',
 f'Hysteria2 TLS: udp/{val("P_HY2_TLS")}  password={val("PASS_HY2_TLS")}',
 f'Hysteria2 domain: udp/{val("P_HY2_DOMAIN")}  password={val("PASS_HY2_DOMAIN")}',
 f'VLESS Reality Vision: tcp/{val("P_VLESS_REALITY")}  uuid={val("UUID_VLESS_REALITY")}  SNI={val("REALITY_SNI")}',
 f'TUIC v5: udp/{val("P_TUIC")}  uuid={val("UUID_TUIC")}  password={val("PASS_TUIC")}',
 f'VLESS XHTTP Reality: tcp/{val("P_XHTTP")}  uuid={val("UUID_XHTTP")}  SNI={val("REALITY_SNI")}',
 f'Mieru TCP: tcp/{val("P_MIERU_TCP")}  username={val("USER_MIERU_TCP")}  password={val("PASS_MIERU_TCP")}',
 f'Mieru UDP: udp/{val("P_MIERU_UDP")}  username={val("USER_MIERU_UDP")}  password={val("PASS_MIERU_UDP")}',
 f'Reality public key: {val("R_PUBLIC_KEY")}',
 f'Reality short ID: {val("R_SHORT_ID")}',
 f'WARP domain routing enabled: {val("WARP_ENABLED")}',
]
(state/'node-info.txt').write_text('\n'.join(lines)+'\n')
(state/'node-info.txt').chmod(0o600)
PY
  chmod 600 "$CONF"
  "$BIN" check -c "$CONF" || die "sing-box-extended 服务端配置检查失败；配置已保存在 $CONF，请查看错误后修正。"
  "$BIN" check -c "$WEBROOT/client.json" || die "客户端 JSON 配置未通过扩展版核心校验；已生成文件但不会发布订阅，请检查版本兼容性。"
  green "服务端配置与客户端 JSON 均通过扩展版核心检查。"
}

write_singbox_service(){
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Yuzhou Sing-box Extended Service
Documentation=https://github.com/shtorm-7/sing-box-extended
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$STATE_DIR
ExecStartPre=$BIN check -c $CONF
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable --now yuzhou-sbx.service
  systemctl is-active --quiet yuzhou-sbx.service || { journalctl -u yuzhou-sbx.service -n 80 --no-pager; die "sing-box 服务启动失败。"; }
  green "yuzhou-sbx.service 已启动并设置开机自启。"
}

install_caddy(){
  info "安装订阅 HTTPS 服务"
  local j tag version asset url tmp bin
  if [[ -x "$CADDY_BIN" ]]; then green "复用已安装的 Caddy：$($CADDY_BIN version 2>/dev/null | head -n1)"; return 0; fi
  j=$(curl -fsSL --retry 3 -H 'User-Agent: Yuzhou-SBX-Manager' https://api.github.com/repos/caddyserver/caddy/releases/latest) || die "读取 Caddy 官方发布信息失败。"
  tag=$(printf '%s' "$j" | jq -r '.tag_name // empty'); version="${tag#v}"
  [[ -n "$version" ]] || die "无法识别 Caddy 最新版本。"
  asset="caddy_${version}_linux_${CPU}.tar.gz"
  url=$(printf '%s' "$j" | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' | head -n1)
  [[ -n "$url" && "$url" != null ]] || die "Caddy 发布中找不到 $asset。"
  tmp=$(mktemp -d)
  curl -fL --retry 3 -o "$tmp/caddy.tar.gz" "$url" || die "下载 Caddy 失败。"
  tar -tzf "$tmp/caddy.tar.gz" | grep -qx 'caddy' || die "Caddy 压缩包内找不到 caddy 文件。"
  tar -xzf "$tmp/caddy.tar.gz" -C "$tmp" caddy
  install -m 755 "$tmp/caddy" "$CADDY_BIN"
  rm -rf "$tmp"
  "$CADDY_BIN" version | head -n1
}

setup_subscription(){
  info "设置 HTTPS 订阅地址"
  local default_port input
  install_caddy
  if ! port_used 443 && [[ " ${USED_PORTS:-} " != *" 443 "* ]]; then default_port=443; else default_port=$(random_port); fi
  while true; do
    read -r -p "HTTPS 订阅端口（回车使用 $default_port；443 可省略 URL 端口）: " input
    SUB_PORT="${input:-$default_port}"
    if [[ ! "$SUB_PORT" =~ ^[0-9]{1,5}$ ]] || (( SUB_PORT < 1 || SUB_PORT > 65535 )); then yellow "端口必须为 1–65535。"; continue; fi
    if [[ "$SUB_PORT" == 80 ]]; then yellow "TCP/80 保留给 ACME HTTP-01 验证，不用作 HTTPS 订阅端口。"; continue; fi
    if [[ " ${USED_PORTS:-} " == *" $SUB_PORT "* ]]; then yellow "该端口已用于代理协议，请换一个。"; continue; fi
    if port_used "$SUB_PORT"; then yellow "端口 $SUB_PORT 已有监听，请换一个。"; continue; fi
    break
  done
  save_credentials
  mkdir -p "$WEBROOT"
  # Explicit HTTPS listener with the selected port and a pre-issued/reused certificate.
  if [[ "$SUB_PORT" == 443 ]]; then
    cat > "$CADDYFILE" <<EOF
https://$DOMAIN {
    tls $CERT_FILE $KEY_FILE
    @sub path /$SUB_TOKEN/*
    handle @sub {
        uri strip_prefix /$SUB_TOKEN
        root * $WEBROOT
        header Cache-Control "no-store"
        header X-Content-Type-Options "nosniff"
        header Referrer-Policy "no-referrer"
        file_server
    }
    handle {
        respond "Not found" 404
    }
}
EOF
  else
    cat > "$CADDYFILE" <<EOF
https://$DOMAIN:$SUB_PORT {
    tls $CERT_FILE $KEY_FILE
    @sub path /$SUB_TOKEN/*
    handle @sub {
        uri strip_prefix /$SUB_TOKEN
        root * $WEBROOT
        header Cache-Control "no-store"
        header X-Content-Type-Options "nosniff"
        header Referrer-Policy "no-referrer"
        file_server
    }
    handle {
        respond "Not found" 404
    }
}
EOF
  fi
  chmod 600 "$CADDYFILE"
  "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null || die "Caddyfile 验证失败，请检查 $CADDYFILE。"
  cat > "$SUB_SERVICE_FILE" <<EOF
[Unit]
Description=Yuzhou HTTPS Subscription Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CADDY_BIN run --config $CADDYFILE --adapter caddyfile
ExecReload=$CADDY_BIN reload --config $CADDYFILE --adapter caddyfile
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SUB_SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable --now yuzhou-sbx-subscription.service
  systemctl is-active --quiet yuzhou-sbx-subscription.service || { journalctl -u yuzhou-sbx-subscription.service -n 60 --no-pager; die "订阅 HTTPS 服务启动失败。"; }
  firewall_allow "$SUB_PORT" "tcp"
  # ACME HTTP-01 renewal needs inbound port 80 on servers where the port is free.
  if ! port_used 80; then firewall_allow 80 "tcp"; fi
  green "HTTPS 订阅服务已启动。"
}

print_summary(){
  load_credentials
  [[ -f "$CONF" ]] || { yellow "尚未安装配置。"; return 0; }
  local base="https://$DOMAIN"
  [[ "${SUB_PORT:-443}" == 443 ]] || base="$base:$SUB_PORT"
  info "安装结果"
  printf '核心：%s\n' "$($BIN version 2>/dev/null | head -n1)"
  printf '服务：yuzhou-sbx.service\n配置：%s\n证书：%s\n订阅目录：%s\n' "$CONF" "$CERT_FILE" "$WEBROOT"
  if [[ -f "$CADDYFILE" && -n "${SUB_TOKEN:-}" ]]; then
    printf '\nHTTPS JSON 配置（含 Mieru）：\n%s/%s/client.json\n' "$base" "$SUB_TOKEN"
    printf '\nHTTPS URI 订阅（不含 Mieru 与 AnyTLS-Reality；请使用 JSON 配置导入完整协议）：\n%s/%s/sub.txt\n' "$base" "$SUB_TOKEN"
  else
    yellow "HTTPS 订阅未启用；请配置域名证书后运行菜单中的订阅服务设置。"
  fi
  printf '\n本地协议详情（权限 600）：%s\n' "$INFO_FILE"
  printf '查看完整客户端配置：%s/client.json\n' "$WEBROOT"
  printf '防火墙还需检查 VPS/云厂商安全组是否允许对应 TCP/UDP 端口。\n'
}

open_protocol_firewall(){
  load_credentials
  [[ -f "$ENV_FILE" ]] || die "没有配置凭据；请先安装。"
  info "按当前协议配置放行端口"
  firewall_allow "$P_ANYTLS_TLS" "tcp"
  firewall_allow "$P_ANYTLS_REALITY" "tcp"
  firewall_allow "$P_HY2_TLS" "udp"
  firewall_allow "$P_HY2_DOMAIN" "udp"
  firewall_allow "$P_VLESS_REALITY" "tcp"
  firewall_allow "$P_TUIC" "udp"
  firewall_allow "$P_XHTTP" "tcp"
  firewall_allow "$P_MIERU_TCP" "tcp"
  firewall_allow "$P_MIERU_UDP" "udp"
  [[ -n "${SUB_PORT:-}" ]] && firewall_allow "$SUB_PORT" "tcp"
  green "防火墙端口规则已处理；云厂商安全组仍需单独核验。"
}

status(){
  info "服务状态"
  if systemctl is-active --quiet yuzhou-sbx.service; then green "sing-box-extended：运行中"; else red "sing-box-extended：未运行"; fi
  systemctl --no-pager --full status yuzhou-sbx.service 2>/dev/null | sed -n '1,12p' || true
  if systemctl is-active --quiet yuzhou-sbx-subscription.service; then green "HTTPS 订阅服务：运行中"; else yellow "HTTPS 订阅服务：未运行"; fi
  [[ -x "$BIN" ]] && "$BIN" version || true
  [[ -f "$CONF" ]] && { printf '配置：%s\n' "$CONF"; "$BIN" check -c "$CONF"; }
  cert_status
}

cert_status(){
  info "证书状态"
  load_credentials || true
  if [[ -s "$CERT_FILE" ]]; then
    openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null || { yellow "证书文件无法读取。"; return; }
    if [[ -n "${DOMAIN:-}" ]]; then openssl x509 -in "$CERT_FILE" -noout -checkhost "$DOMAIN" 2>&1 || true; fi
    if openssl x509 -in "$CERT_FILE" -noout -checkend 604800 >/dev/null 2>&1; then green "证书在未来 7 天内不会到期。"; else red "证书已到期或将在 7 天内到期，请检查 acme.sh 续期。"; fi
  else
    yellow "本项目证书文件不存在：$CERT_FILE"
  fi
  if [[ -x "$ACME" ]]; then
    printf '\nacme.sh 证书记录：\n'
    if [[ -n "${DOMAIN:-}" ]]; then "$ACME" --list 2>/dev/null | awk -v d="$DOMAIN" 'NR==1 || $1==d {print}'; else "$ACME" --list 2>/dev/null; fi
    printf '\n自动续期计划（cron）：\n'
    crontab -l 2>/dev/null | grep -E 'acme\.sh.*--cron' || yellow "未在当前 root crontab 中发现 acme.sh cron；请确认 acme.sh 安装时的定时任务。"
  else
    yellow "未发现 root 的 acme.sh 安装；若当前证书由外部工具管理，续期不由本脚本控制。"
  fi
}

renew_certificate(){
  load_credentials
  [[ -x "$ACME" ]] || die "acme.sh 未安装，无法通过本脚本续期。"
  [[ -n "${DOMAIN:-}" ]] || die "未发现配置域名。"
  local row keytype; row=$(acme_row || true)
  [[ -n "$row" ]] || die "acme.sh 中没有 $DOMAIN 的记录。若复用的是外部证书，请继续使用原证书管理方续期。"
  keytype=$(printf '%s\n' "$row" | awk '{print $2}')
  local -a args=(--renew -d "$DOMAIN") install_args=(--install-cert -d "$DOMAIN")
  if [[ "$keytype" == ec-* ]]; then args+=(--ecc); install_args+=(--ecc); fi
  info "执行 acme.sh 续期检查（不使用 --force，避免无必要地重复签发）"
  "$ACME" "${args[@]}" || { yellow "续期命令返回非零；请查看上方日志和证书诊断。"; return 1; }
  "$ACME" "${install_args[@]}" --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "systemctl restart yuzhou-sbx.service >/dev/null 2>&1 || true; systemctl try-restart yuzhou-sbx-subscription.service >/dev/null 2>&1 || true"
  cert_status
}

custom_firewall(){
  local p proto
  read -r -p "要放行的端口（随机请输入 R，或输入 1–65535）: " p
  if [[ "$p" =~ ^[Rr]$ ]]; then p=$(random_port); yellow "随机端口：$p"; fi
  [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p>=1 && p<=65535 )) || die "端口格式不正确。"
  read -r -p "协议（tcp/udp/both）: " proto
  case "$proto" in tcp|udp) firewall_allow "$p" "$proto";; both|BOTH) firewall_allow "$p" "tcp udp";; *) die "协议必须为 tcp、udp 或 both。";; esac
  yellow "注意：如果该端口没有服务监听，仅放行防火墙并不会自动建立服务。"
}

uninstall(){
  yellow "卸载会停止并删除本脚本创建的 sing-box-extended 服务、订阅服务和项目目录，不会卸载系统 SSH，也不会清理其他脚本的证书。"
  confirm "确定卸载 Yuzhou Sing-box Extended Manager 创建的组件？" N || return 0
  systemctl disable --now yuzhou-sbx.service >/dev/null 2>&1 || true
  systemctl disable --now yuzhou-sbx-subscription.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$SUB_SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$APP_DIR" "$STATE_DIR" "$WEBROOT"
  green "项目组件已卸载。出于安全考虑，脚本不会自动删除已添加的防火墙规则；请按实际情况人工清理。"
}

install_all(){
  install_deps
  if [[ ! -f "$STATE_DIR/system_prepare.done" ]]; then
    yellow "可先初始化主机名、sudo 管理账号、SSH 端口并在验证后禁用 root SSH 登录。"
    if confirm "现在执行系统基础安全初始化？（务必保持当前 SSH 会话；稍后需用第二个终端验证新登录）" Y; then prepare_system; else yellow "已跳过系统安全初始化。可稍后从菜单单独执行。"; fi
  fi
  if [[ -f "$CONF" && -f "$SERVICE_FILE" ]]; then
    yellow "检测到已有配置。为防止覆盖你的节点 UUID/端口，本次保留现有凭据，只更新核心并检查服务。"
    install_extended_core
    if ! "$BIN" check -c "$CONF"; then
      [[ -x "$APP_DIR/sing-box.previous" ]] && cp -f "$APP_DIR/sing-box.previous" "$BIN"
      die "现有配置与新核心不兼容；已尝试恢复旧核心。"
    fi
    systemctl restart yuzhou-sbx.service || true
    if [[ -f "$ENV_FILE" && -s "$CERT_FILE" && ! -f "$SUB_SERVICE_FILE" ]]; then
      load_credentials
      USED_PORTS=" $P_ANYTLS_TLS $P_ANYTLS_REALITY $P_HY2_TLS $P_HY2_DOMAIN $P_VLESS_REALITY $P_TUIC $P_XHTTP $P_MIERU_TCP $P_MIERU_UDP "
      setup_subscription
      open_protocol_firewall
    fi
    print_summary
    return 0
  fi
  ask "用于 TLS 证书和 HTTPS 订阅的域名（需先解析到本机；不接受 IP）" DOMAIN
  check_domain "$DOMAIN" || die "域名格式无效；请输入完整域名，例如 sub.example.com。"
  getent ahosts "$DOMAIN" >/dev/null 2>&1 || yellow "系统当前无法解析 $DOMAIN；ACME 签发前请确认 DNS A/AAAA 已正确配置。"
  ask "acme.sh 注册邮箱（可留空）" ACME_EMAIL ""
  if confirm "是否启用你提供的 Cloudflare WARP 出站，并仅对指定 AI 域名分流？" Y; then WARP_ENABLED=yes; else WARP_ENABLED=no; fi
  install_extended_core
  create_credentials
  setup_certificate
  build_configs
  write_singbox_service
  # Keep used ports available for subscription selector.
  USED_PORTS=" $P_ANYTLS_TLS $P_ANYTLS_REALITY $P_HY2_TLS $P_HY2_DOMAIN $P_VLESS_REALITY $P_TUIC $P_XHTTP $P_MIERU_TCP $P_MIERU_UDP "
  setup_subscription
  open_protocol_firewall
  print_summary
  green "安装完成。请同时在 VPS 厂商控制面板放行对应 TCP/UDP 端口。"
}

update_core(){
  install_deps
  install_extended_core
  if [[ -f "$CONF" ]]; then
    if ! "$BIN" check -c "$CONF"; then
      [[ -x "$APP_DIR/sing-box.previous" ]] && cp -f "$APP_DIR/sing-box.previous" "$BIN"
      die "现有配置未通过新核心检查；已尝试恢复旧核心。请查看 $APP_DIR/sing-box.previous 与配置兼容性。"
    fi
    systemctl restart yuzhou-sbx.service
  fi
  green "核心更新完成。"
}

show_credentials(){
  load_credentials
  [[ -f "$INFO_FILE" ]] || die "节点详情文件不存在，请先安装。"
  cat "$INFO_FILE"
  printf '\n客户端完整 JSON：%s/client.json\n' "$WEBROOT"
  print_summary
}

main_menu(){
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|setup) install_all ;;
      update|upx) update_core ;;
      status|stat) status ;;
      show|list) show_credentials ;;
      restart|res) systemctl restart yuzhou-sbx.service; systemctl restart yuzhou-sbx-subscription.service 2>/dev/null || true; green "服务已重启。" ;;
      logs|log) journalctl -u yuzhou-sbx.service -n 100 --no-pager ;;
      firewall|fw) custom_firewall ;;
      cert) cert_status ;;
      renew) renew_certificate ;;
      prepare) install_deps; prepare_system ;;
      uninstall|del) uninstall ;;
      *) echo "用法：$0 {install|update|status|show|restart|logs|firewall|cert|renew|prepare|uninstall}"; exit 2 ;;
    esac
    return
  fi
  while true; do
    cat <<'MENU'

============================================================
 Yuzhou Sing-box Extended Manager
============================================================
 1. 一键安装 / 继续安装（核心、协议、证书、HTTPS 订阅、防火墙）
 2. 查看运行状态与证书诊断
 3. 查看节点端口、凭据与 HTTPS 订阅地址
 4. 重启服务
 5. 查看 sing-box 运行日志
 6. 随机或指定端口并放行防火墙（TCP/UDP）
 7. 检查 / 执行 acme.sh 续期
 8. Linux 主机安全初始化（主机名、sudo 用户、SSH 端口、禁 root）
 9. 更新 sing-box-extended 核心
10. 卸载本项目服务与文件
 0. 退出
------------------------------------------------------------
MENU
    read -r -p "请选择 [0-10]: " choice
    case "$choice" in
      1) install_all ;;
      2) status ;;
      3) show_credentials ;;
      4) systemctl restart yuzhou-sbx.service; systemctl restart yuzhou-sbx-subscription.service 2>/dev/null || true; green "服务已重启。" ;;
      5) journalctl -u yuzhou-sbx.service -n 100 --no-pager ;;
      6) custom_firewall ;;
      7) if confirm "执行当前域名的 acme.sh 续期流程？" N; then renew_certificate; else cert_status; fi ;;
      8) install_deps; prepare_system ;;
      9) update_core ;;
      10) uninstall ;;
      0) exit 0 ;;
      *) yellow "输入无效，请输入 0–10。" ;;
    esac
  done
}

check_system "$@"
main_menu "$@"
