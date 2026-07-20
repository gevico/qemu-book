#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"
image="${RISCV_GUEST_IMAGE:-}"

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
if [[ -z "${image}" || ! -f "${image}" ]]; then
    echo "RISCV_GUEST_IMAGE must name a guest image" >&2
    exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "GNU timeout is required for bounded trace collection" >&2
    exit 2
fi
mkdir -p "${results_dir}"

set +e
timeout "${TRACE_SECONDS:-3}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg,one-insn-per-tb=on \
    -bios none -kernel "${image}" -display none -serial none -monitor none \
    -d in_asm,op,op_opt,out_asm -D "${results_dir}/tcg.log" \
    2>"${results_dir}/qemu.stderr"
qemu_exit_code=$?
set -e
if (( qemu_exit_code != 0 && qemu_exit_code != 124 )); then
    echo "QEMU failed before the bounded collection ended (status ${qemu_exit_code})" >&2
    exit 1
fi
test -s "${results_dir}/tcg.log"
echo "qemu_status=${qemu_exit_code}" >"${results_dir}/status.txt"
echo "Captured guest assembly, pre/post optimization IR, and host assembly."
