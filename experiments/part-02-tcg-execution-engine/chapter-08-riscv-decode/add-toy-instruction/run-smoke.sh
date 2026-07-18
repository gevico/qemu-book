#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${script_dir}/build"
results_dir="${script_dir}/results"
cc="${RISCV_CC:-riscv64-linux-gnu-gcc}"
qemu="${QEMU_SYSTEM_RISCV64:-}"

if [[ -z "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name the locally patched QEMU binary" >&2
    exit 2
fi

for tool in "${cc}" "${qemu}" timeout; do
    if ! command -v "${tool}" >/dev/null 2>&1 && [[ ! -x "${tool}" ]]; then
        echo "required tool not found: ${tool}" >&2
        exit 2
    fi
done

mkdir -p "${build_dir}" "${results_dir}"
"${cc}" -march=rv64gc -mabi=lp64d -nostdlib -nostartfiles -static \
    -fno-pie -no-pie -Wl,--build-id=none \
    -T "${script_dir}/guest/linker.ld" "${script_dir}/guest/toy-op.S" \
    -o "${build_dir}/toy-op.elf"

set +e
timeout "${RUN_TIMEOUT_SECONDS:-20}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -bios none \
    -kernel "${build_dir}/toy-op.elf" -display none -serial none \
    -monitor none -no-reboot -d in_asm,op -D "${results_dir}/tcg.log"
qemu_status=$?
set -e

if (( qemu_status != 0 )); then
    echo "patched QEMU did not reach the pass finisher (status ${qemu_status})" >&2
    exit 1
fi

if ! rg -q 'aab5050b|bookadd' "${results_dir}/tcg.log"; then
    echo "the trace does not expose the private instruction encoding" >&2
    exit 1
fi

echo "Patched QEMU executed BOOKADD and the guest reached the pass finisher."
