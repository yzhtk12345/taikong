#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/yzhtk12345/taikong/main"
PROJECT_DIR="${TAIKONG_HOME:-${HOME}/.local/share/taikong}"

echo "================================"
echo "       Taikong VPS Manager"
echo "================================"

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[错误] 缺少命令：$cmd"
        echo "请先安装缺少的工具后再运行。"
        exit 1
    fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "[信息] 正在下载 Taikong..."

if ! curl -fsSL --connect-timeout 10 --max-time 60 \
    "$REPO_RAW/manager.sh" -o "$tmp_dir/manager.sh"; then
    echo "[错误] 下载管理程序失败，请检查网络和 GitHub 仓库。"
    exit 1
fi

if ! bash -n "$tmp_dir/manager.sh"; then
    echo "[错误] 管理程序语法检查失败，已停止运行。"
    exit 1
fi

echo "[信息] 入口下载成功。"
echo "[信息] 当前仅验证下载与语法，不执行管理功能。"
echo "[信息] 项目目录规划：$PROJECT_DIR"
