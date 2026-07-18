#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

failures=0

check_directory() {
    local variable_name="$1"
    local variable_value="$2"

    if [[ -z "$variable_value" ]]; then
        printf 'MISSING  %s is not set\n' "$variable_name"
        failures=$((failures + 1))
    elif [[ ! -d "$variable_value" ]]; then
        printf 'INVALID  %s does not name a directory: %s\n' \
            "$variable_name" "$variable_value"
        failures=$((failures + 1))
    else
        printf 'OK       %s=%s\n' "$variable_name" "$variable_value"
    fi
}

check_directory QEMU_SRC "${QEMU_SRC:-}"
check_directory QEMU_BUILD "${QEMU_BUILD:-}"

qemu_binary="${QEMU_SYSTEM_RISCV64:-${QEMU_BUILD:-}/qemu-system-riscv64}"
if [[ -x "$qemu_binary" ]]; then
    printf 'OK       QEMU_SYSTEM_RISCV64=%s\n' "$qemu_binary"
else
    printf 'MISSING  executable qemu-system-riscv64: %s\n' "$qemu_binary"
    failures=$((failures + 1))
fi

if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    printf 'OPTIONAL /dev/kvm is accessible\n'
else
    printf 'OPTIONAL /dev/kvm is unavailable; skip KVM execution labs\n'
fi

if ((failures > 0)); then
    exit 1
fi
