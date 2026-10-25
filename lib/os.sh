#!/usr/bin/env bash
# lib/os.sh

detect_os() {
    local os_release="${1:-/etc/os-release}"
    local ID="" ID_LIKE="" PRETTY_NAME="" VERSION_ID="" NAME=""

    # 每次检测先重置，避免继承上次结果
    OS_ID="unknown"
    OS_ID_LIKE=""
    OS_PRETTY_NAME="Unknown Linux"
    OS_VERSION_ID=""
    OS_FAMILY="unknown"
    OS_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
    OS_PACKAGE_MANAGER="unknown"
    OS_HAS_SYSTEMD="no"

    if [[ -r "$os_release" ]]; then
        # /etc/os-release 是系统标准信息文件
        # shellcheck disable=SC1090
        . "$os_release"
    fi

    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_PRETTY_NAME="${PRETTY_NAME:-${NAME:-Unknown Linux}}"
    OS_VERSION_ID="${VERSION_ID:-}"

    # 优先识别发行版 ID，再参考 ID_LIKE
    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop|elementary)
            OS_FAMILY="debian"
            ;;
        rhel|fedora|centos|rocky|almalinux|ol|amzn|eurolinux|virtuozzo)
            OS_FAMILY="redhat"
            ;;
        *)
            case " $OS_ID_LIKE " in
                *" debian "*|*" ubuntu "*)
                    OS_FAMILY="debian"
                    ;;
                *" rhel "*|*" fedora "*|*" centos "*)
                    OS_FAMILY="redhat"
                    ;;
                *)
                    OS_FAMILY="unknown"
                    ;;
            esac
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        OS_PACKAGE_MANAGER="apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        OS_PACKAGE_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        OS_PACKAGE_MANAGER="yum"
    elif command -v zypper >/dev/null 2>&1; then
        OS_PACKAGE_MANAGER="zypper"
    elif command -v apk >/dev/null 2>&1; then
        OS_PACKAGE_MANAGER="apk"
    fi

    if [[ -d /run/systemd/system ]] ||
       { command -v systemctl >/dev/null 2>&1 &&
         [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == "systemd" ]]; }; then
        OS_HAS_SYSTEMD="yes"
    fi

    export OS_ID OS_ID_LIKE OS_PRETTY_NAME OS_VERSION_ID OS_FAMILY
    export OS_ARCH OS_PACKAGE_MANAGER OS_HAS_SYSTEMD
}

print_os_report() {
    printf '%-18s %s\n' "发行版：" "$OS_PRETTY_NAME"
    printf '%-18s %s\n' "发行版 ID：" "$OS_ID"
    printf '%-18s %s\n' "版本：" "${OS_VERSION_ID:-未知}"
    printf '%-18s %s\n' "系统家族：" "$OS_FAMILY"
    printf '%-18s %s\n' "CPU 架构：" "$OS_ARCH"
    printf '%-18s %s\n' "包管理器：" "$OS_PACKAGE_MANAGER"
    printf '%-18s %s\n' "systemd：" "$OS_HAS_SYSTEMD"
}
