#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-qemu-system-riscv64}"
kernel="${GUEST_KERNEL:-}"
initramfs="${GUEST_INITRAMFS:-${script_dir}/build/iommu-dma-probe.cpio}"

if [[ -z "${kernel}" ]]; then
    echo "GUEST_KERNEL must point to a RISC-V Linux Image" >&2
    exit 2
fi

for tool in "${qemu}" timeout rg; do
    if ! command -v "${tool}" >/dev/null 2>&1 && [[ ! -x "${tool}" ]]; then
        echo "required tool not found: ${tool}" >&2
        exit 2
    fi
done

if [[ ! -f "${kernel}" || ! -f "${initramfs}" ]]; then
    echo "missing guest kernel or initramfs" >&2
    exit 2
fi

mkdir -p "${results_dir}"
timeout 90 "${qemu}" \
    -machine virt,aia=aplic-imsic -accel tcg -cpu rv64 \
    -smp 2 -m 1G -kernel "${kernel}" -initrd "${initramfs}" \
    -append 'console=ttyS0 rdinit=/iommu-dma-probe ip=dhcp panic=-1' \
    -device riscv-iommu-pci,addr=1.0 \
    -device e1000e,netdev=net0,addr=2.0 \
    -netdev user,id=net0 \
    -display none -serial stdio -monitor none -no-reboot \
    -trace enable=riscv_iommu_new \
    -trace enable=riscv_iommu_dma \
    -trace enable=riscv_iommu_flt \
    -trace enable=riscv_iommu_cmd \
    -trace file="${results_dir}/iommu.trace" \
    >"${results_dir}/serial.log" 2>"${results_dir}/qemu.stderr"

rg -q '^iommu-probe:sent$' "${results_dir}/serial.log"
python3 "${script_dir}/analyze_iommu_trace.py" \
    "${results_dir}/iommu.trace" --require-translation
