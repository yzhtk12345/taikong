
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

while true; do
    echo
    echo "================================"
    echo "       Taikong VPS Manager"
    echo "================================"
    echo "1) 系统兼容性检测"
    echo "2) 主机名管理"
    echo "0) 退出"
    read -r -p "请选择 [0-2]: " choice || choice=0

    case "$choice" in
        1)
            bash "$SCRIPT_DIR/modules/system/check.sh"
            ;;
        2)
            source "$SCRIPT_DIR/modules/system/hostname.sh"
            hostname_menu
            ;;
        0)
            echo "已退出。"
            exit 0
            ;;
        *)
            echo "无效选项，请输入 0、1 或 2。"
            ;;
    esac
done
