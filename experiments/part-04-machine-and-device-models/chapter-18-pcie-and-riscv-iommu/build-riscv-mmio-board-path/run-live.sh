#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
qemu="${QEMU_SYSTEM_RISCV64:-}"

if [[ -z "${qemu}" ]] || ! command -v "${qemu}" >/dev/null 2>&1; then
    echo "SKIP: set QEMU_SYSTEM_RISCV64 to the patched riscv64 system emulator"
    exit 77
fi

set +e
"${script_dir}/build-baremetal.sh"
build_status=$?
set -e
if (( build_status == 77 )); then
    exit 77
fi
if (( build_status != 0 )); then
    exit "${build_status}"
fi

if ! "${qemu}" -machine virt,help 2>&1 | rg -q 'qb-mmio-demo'; then
    echo "FAIL: QEMU does not expose the qb-mmio-demo machine property" >&2
    exit 1
fi

python3 "${script_dir}/run_qemu.py" \
    --qemu "${qemu}" \
    --guest "${script_dir}/build/qb-mmio-probe.elf" \
    --timeout "${RUN_TIMEOUT_SECONDS:-20}"
