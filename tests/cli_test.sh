#!/bin/sh
# Invalid commands fail before display enumeration or hardware I/O.
set -eu
cli=${1:-./tinyddc}
expect_usage_error() {
    status=0
    "$cli" "$@" >/dev/null 2>&1 || status=$?
    if [ "$status" -ne 2 ]; then
        printf 'Expected usage error (2), got %s: %s\n' "$status" "$*" >&2
        exit 1
    fi
}
"$cli" --help >/dev/null
"$cli" --version >/dev/null
expect_usage_error input dp
expect_usage_error input dp --index 0
expect_usage_error input dp --index -1
expect_usage_error input dp --index 1 --index 2
expect_usage_error input dp --display invalid
expect_usage_error input 65536 --index 1
expect_usage_error input 0 --index 1
expect_usage_error input 0x --index 1
expect_usage_error input 15junk --index 1
expect_usage_error input dp --index 1 --unknown
expect_usage_error get-input --index 1 --dry-run
expect_usage_error list --index 1
expect_usage_error list --json --json
expect_usage_error unknown
printf 'CLI validation tests passed (no hardware I/O).\n'
