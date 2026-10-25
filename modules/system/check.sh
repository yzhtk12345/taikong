#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

source "$SCRIPT_DIR/lib/os.sh"
source "$SCRIPT_DIR/lib/common.sh"

detect_os

echo
echo "========== 系统兼容性检测 =========="
print_os_report
echo "===================================="
echo

issues=0

if [[ "$OS_FAMILY" != "debian" && "$OS_FAMILY" != "redhat" ]]; then
    tk_warn "未识别的发行版家族：$OS_FAMILY"
    issues=$((issues + 1))
fi

case "$OS_ARCH" in
    x86_64|aarch64|arm64)
        ;;
    *)
        tk_warn "CPU 架构 $OS_ARCH 尚未列入当前基础兼容范围。"
        issues=$((issues + 1))
        ;;
esac

if [[ "$OS_PACKAGE_MANAGER" == "unknown" ]]; then
    tk_warn "未检测到已支持的包管理器。"
    issues=$((issues + 1))
fi

if [[ "$OS_HAS_SYSTEMD" != "yes" ]]; then
    tk_warn "未确认 systemd 可用，后续服务管理功能可能不兼容。"
    issues=$((issues + 1))
fi

if (( issues == 0 )); then
    tk_info "基础检测通过。请继续进行实际功能测试。"
else
    tk_warn "发现 $issues 项需要留意。当前模块只读，不会修改系统。"
fi

# 检测发现问题不代表脚本运行失败，因此不以非零状态退出
exit 0
