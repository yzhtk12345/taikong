#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/manager.sh" ]]; then
    echo "[错误] 未找到 manager.sh，请检查项目文件是否完整。" >&2
    exit 1
fi

chmod +x "$SCRIPT_DIR/manager.sh" \
    "$SCRIPT_DIR/modules/system/check.sh" \
    "$SCRIPT_DIR/tests/run.sh" \
    "$SCRIPT_DIR/tests/test-os-detection.sh" 2>/dev/null || true

echo "Taikong VPS Manager 初始化完成"
echo "版本：$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo unknown)"
echo "本版本不会自动安装软件或修改系统配置。"
echo "启动命令：$SCRIPT_DIR/manager.sh"
