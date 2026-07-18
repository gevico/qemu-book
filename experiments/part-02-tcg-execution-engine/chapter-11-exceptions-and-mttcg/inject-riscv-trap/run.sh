#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${script_dir}/build"
results_dir="${script_dir}/results"
cc="${RISCV_CC:-riscv64-linux-gnu-gcc}"
objdump="${RISCV_OBJDUMP:-riscv64-linux-gnu-objdump}"
qemu="${QEMU_SYSTEM_RISCV64:-qemu-system-riscv64}"

for tool in "${cc}" "${objdump}" "${qemu}" timeout; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "required tool not found: ${tool}" >&2
        exit 2
    fi
done

mkdir -p "${build_dir}" "${results_dir}"
"${cc}" -march=rv64gc -mabi=lp64d -nostdlib -nostartfiles -static \
    -fno-pie -no-pie -Wl,--build-id=none \
    -T "${script_dir}/guest/linker.ld" "${script_dir}/guest/trap.S" \
    -o "${build_dir}/trap.elf"
"${objdump}" -d "${build_dir}/trap.elf" >"${results_dir}/trap.disassembly"

set +e
timeout "${RUN_TIMEOUT_SECONDS:-20}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -bios none \
    -kernel "${build_dir}/trap.elf" -display none -serial stdio \
    -monitor none -no-reboot -d int,in_asm -D "${results_dir}/trap.log" \
    >"${results_dir}/serial.log" 2>"${results_dir}/qemu.stderr"
qemu_status=$?
set -e

if (( qemu_status != 0 )); then
    echo "QEMU did not reach the pass finisher (status ${qemu_status})" >&2
    exit 1
fi

rg -q '^trap:2$' "${results_dir}/serial.log"
rg -q '<illegal_site>' "${results_dir}/trap.disassembly"
test -s "${results_dir}/trap.log"

echo "Observed mcause=2, exact mepc, handler entry, mepc advance, and mret."
