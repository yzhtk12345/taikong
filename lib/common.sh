#!/usr/bin/env bash

tk_info() {
    printf '[信息] %s\n' "$*"
}

tk_warn() {
    printf '[警告] %s\n' "$*" >&2
}

tk_error() {
    printf '[错误] %s\n' "$*" >&2
}

tk_have_command() {
    command -v "$1" >/dev/null 2>&1
}
