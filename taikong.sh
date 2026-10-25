
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/yzhtk12345/taikong/archive/refs/heads/main.tar.gz"
INSTALL_DIR="${TAIKONG_HOME:-${HOME}/.local/share/taikong}"

info() { printf '[信息] %s\n' "$*"; }
error() { printf '[错误] %s\n' "$*" >&2; }

echo "================================"
echo "       Taikong VPS Manager"
echo "================================"

# 1. 检查下载所需命令
for cmd in curl tar bash; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "缺少必要命令：$cmd"
        error "请先安装该命令后重试。"
        exit 1
    fi
done

# 2. 准备下载目录
PARENT_DIR="$(dirname "$INSTALL_DIR")"
mkdir -p "$PARENT_DIR"

TMP_DIR="$(mktemp -d "$PARENT_DIR/.taikong-update.XXXXXX")"
BACKUP_DIR="${INSTALL_DIR}.previous"
SWAPPED=0

cleanup() {
    if [[ "$SWAPPED" == "1" && ! -d "$INSTALL_DIR" && -d "$BACKUP_DIR" ]]; then
        mv "$BACKUP_DIR" "$INSTALL_DIR" || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

info "正在下载完整项目..."

if ! curl -fLsS --connect-timeout 10 --max-time 120 \
    "$REPO_URL" -o "$TMP_DIR/project.tar.gz"; then
    error "下载失败，请检查网络、仓库地址和默认分支。"
    exit 1
fi

mkdir "$TMP_DIR/project"

if ! tar -xzf "$TMP_DIR/project.tar.gz" \
    -C "$TMP_DIR/project" --strip-components=1; then
    error "项目压缩包解压失败。"
    exit 1
fi

# 3. 检查必要文件
REQUIRED_FILES=(
    manager.sh
    lib/common.sh
    lib/os.sh
    modules/system/check.sh
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$TMP_DIR/project/$file" ]]; then
        error "项目缺少必要文件：$file"
        exit 1
    fi
done

# 4. 检查所有 Shell 脚本语法
while IFS= read -r -d '' file; do
    if ! bash -n "$file"; then
        error "脚本语法检查失败：${file#"$TMP_DIR/project/"}"
        exit 1
    fi
done < <(find "$TMP_DIR/project" -type f -name '*.sh' -print0)

info "文件完整性与 Bash 语法检查通过。"

# 5. 替换旧版本；替换失败时尽量恢复
mv "$TMP_DIR/project" "$TMP_DIR/new-project"

if [[ -e "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
fi

if [[ -e "$INSTALL_DIR" ]]; then
    mv "$INSTALL_DIR" "$BACKUP_DIR"
    SWAPPED=1
fi

if ! mv "$TMP_DIR/new-project" "$INSTALL_DIR"; then
    error "新版本安装失败。"
    exit 1
fi

SWAPPED=0
rm -rf "$BACKUP_DIR"

info "项目准备完成。"
info "安装目录：$INSTALL_DIR"
info "正在启动管理菜单..."

# 6. 启动菜单
exec bash "$INSTALL_DIR/manager.sh"
