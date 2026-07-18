#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"
image="${RISCV_GUEST_IMAGE:-}"
gdb="${RISCV_GDB:-gdb-multiarch}"
port="${GDB_PORT:-1234}"

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
if [[ -z "${image}" || ! -f "${image}" ]]; then
    echo "RISCV_GUEST_IMAGE must name a guest image" >&2
    exit 2
fi
if ! command -v "${gdb}" >/dev/null 2>&1; then
    echo "RISC-V-capable GDB not found: ${gdb}" >&2
    exit 2
fi
if [[ "${port}" != 1234 ]]; then
    echo "reset-vector.gdb uses port 1234; set GDB_PORT only after editing a copy" >&2
    exit 2
fi

mkdir -p "${results_dir}"
"${qemu}" -machine virt -cpu rv64 -accel tcg -bios none \
    -kernel "${image}" -S -gdb "tcp::${port}" \
    -display none -serial none -monitor none \
    >"${results_dir}/qemu.stdout" 2>"${results_dir}/qemu.stderr" &
qemu_pid=$!
cleanup()
{
    if kill -0 "${qemu_pid}" 2>/dev/null; then
        kill "${qemu_pid}"
        wait "${qemu_pid}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

sleep 1
"${gdb}" -batch -x "${script_dir}/reset-vector.gdb" \
    >"${results_dir}/registers.txt" 2>"${results_dir}/gdb.stderr"
rg -q '^initial-pc=' "${results_dir}/registers.txt"
rg -q '^after-step-pc=' "${results_dir}/registers.txt"
echo "Captured reset-vector registers and one architectural step."
