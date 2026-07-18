#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${script_dir}/build"
results_dir="${script_dir}/results"
cc="${RISCV_CC:-riscv64-linux-gnu-gcc}"
qemu="${QEMU_SYSTEM_RISCV64:-qemu-system-riscv64}"

for tool in "${cc}" "${qemu}" timeout; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "required tool not found: ${tool}" >&2
        exit 2
    fi
done

mkdir -p "${build_dir}" "${results_dir}"

"${cc}" \
    -march=rv64gc -mabi=lp64d -mcmodel=medany \
    -ffreestanding -fno-pie -no-pie -nostdlib -nostartfiles -static \
    -Wl,--build-id=none \
    -T "${script_dir}/guest/linker.ld" \
    "${script_dir}/guest/start.S" \
    "${script_dir}/guest/self-modifying.c" \
    -o "${build_dir}/self-modifying.elf"

set +e
timeout "${RUN_TIMEOUT_SECONDS:-20}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -smp 1 -m 128M \
    -bios none -kernel "${build_dir}/self-modifying.elf" \
    -display none -serial stdio -monitor none -no-reboot \
    -d in_asm,exec -D "${results_dir}/tcg.log" \
    >"${results_dir}/serial.log" 2>"${results_dir}/qemu.stderr"
qemu_status=$?
set -e

if (( qemu_status != 0 )); then
    echo "QEMU did not reach the pass finisher (status ${qemu_status})" >&2
    exit 1
fi

if ! rg -q '^12$' "${results_dir}/serial.log"; then
    echo "guest did not report the expected 1 -> 2 transition" >&2
    exit 1
fi

if ! rg -q 'Trace|IN:' "${results_dir}/tcg.log"; then
    echo "TCG execution log is empty or has an unexpected format" >&2
    exit 1
fi

echo "Observed conforming self-modification: 1 -> 2"
echo "Trace: ${results_dir}/tcg.log"
