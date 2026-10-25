#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/os.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s (expected=%s actual=%s)\n' \
            "$label" "$expected" "$actual" >&2
        exit 1
    fi

    printf 'PASS: %s\n' "$label"
}

cat > "$tmpdir/debian" <<'EOF'
ID=debian
PRETTY_NAME="Debian GNU/Linux 12"
VERSION_ID="12"
EOF

detect_os "$tmpdir/debian"
assert_eq "debian" "$OS_FAMILY" "Debian family"
assert_eq "12" "$OS_VERSION_ID" "Debian version"

cat > "$tmpdir/ubuntu" <<'EOF'
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04 LTS"
VERSION_ID="24.04"
EOF

detect_os "$tmpdir/ubuntu"
assert_eq "debian" "$OS_FAMILY" "Ubuntu family"

cat > "$tmpdir/almalinux" <<'EOF'
ID=almalinux
ID_LIKE="rhel centos fedora"
PRETTY_NAME="AlmaLinux 9"
VERSION_ID="9"
EOF

detect_os "$tmpdir/almalinux"
assert_eq "redhat" "$OS_FAMILY" "AlmaLinux family"

cat > "$tmpdir/derivative" <<'EOF'
ID=somecustomlinux
ID_LIKE="fedora rhel"
PRETTY_NAME="Custom Linux"
EOF

detect_os "$tmpdir/derivative"
assert_eq "redhat" "$OS_FAMILY" "ID_LIKE token matching"

cat > "$tmpdir/unknown" <<'EOF'
ID=totallyunknown
PRETTY_NAME="Totally Unknown Linux"
EOF

detect_os "$tmpdir/unknown"
assert_eq "unknown" "$OS_FAMILY" "unknown family resets correctly"

echo
echo "所有系统识别测试均已通过。"
