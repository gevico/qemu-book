#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
command -v dtc >/dev/null 2>&1 || {
    echo "Device Tree Compiler (dtc) is required" >&2
    exit 2
}
mkdir -p "${results_dir}"

"${qemu}" -machine "virt,dumpdtb=${results_dir}/virt.dtb" \
    -cpu rv64 -accel tcg -smp 2 -m 512M -display none -serial none \
    -monitor none 2>"${results_dir}/qemu.stderr"
dtc -I dtb -O dts -o "${results_dir}/virt.dts" "${results_dir}/virt.dtb"
for node in cpus memory chosen soc; do
    rg -q "${node}" "${results_dir}/virt.dts"
done
echo "Generated and decompiled the selected RISC-V virt FDT."
