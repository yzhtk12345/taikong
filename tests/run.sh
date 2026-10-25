#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r -d '' file; do
    echo "[检查语法] ${file#"$ROOT_DIR"/}"
    bash -n "$file"
done < <(find "$ROOT_DIR" -type f -name '*.sh' -print0)

bash "$ROOT_DIR/tests/test-os-detection.sh"

echo
echo "全部测试完成。"
