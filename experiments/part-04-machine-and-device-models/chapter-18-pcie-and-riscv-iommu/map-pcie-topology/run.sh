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
mkdir -p "${results_dir}"

printf 'info pci\ninfo qtree\ninfo mtree -f\nquit\n' | "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -S -display none -serial none \
    -monitor stdio -nodefaults \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    >"${results_dir}/pci-map.txt" 2>"${results_dir}/qemu.stderr"
rg -q 'virtio-net-pci' "${results_dir}/pci-map.txt"
rg -qi 'pci' "${results_dir}/pci-map.txt"
echo "Captured PCI BDF, qtree, ECAM, BAR, and MMIO representations."
