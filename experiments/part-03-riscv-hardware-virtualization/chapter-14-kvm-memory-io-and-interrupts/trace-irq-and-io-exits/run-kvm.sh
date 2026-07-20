#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-qemu-system-riscv64}"
kernel="${GUEST_KERNEL:-}"
initramfs="${GUEST_INITRAMFS:-${script_dir}/build/io-irq-probe.cpio}"
irqchip_mode="${KVM_IRQCHIP_MODE:-full}"

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

if [[ "$(uname -s)" != Linux || "$(uname -m)" != riscv64 || \
      ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "SKIP: a Linux RISC-V host with read/write /dev/kvm is required"
    exit 77
fi
if [[ ! -f "${kernel}" || ! -f "${initramfs}" ]]; then
    echo "missing guest kernel or initramfs" >&2
    exit 2
fi

case "${irqchip_mode}" in
    full)
        accel="kvm"
        ;;
    split)
        accel="kvm,kernel-irqchip=split"
        ;;
    *)
        echo "KVM_IRQCHIP_MODE must be full or split" >&2
        exit 2
        ;;
esac

mkdir -p "${results_dir}"
trace_file="${results_dir}/${irqchip_mode}.trace"
serial_file="${results_dir}/${irqchip_mode}.serial"
stderr_file="${results_dir}/${irqchip_mode}.stderr"

timeout 45 "${qemu}" \
    -machine virt,aia=aplic-imsic -accel "${accel}" -cpu host \
    -smp 1 -m 512M -kernel "${kernel}" -initrd "${initramfs}" \
    -append 'console=ttyS0 rdinit=/io-irq-probe panic=-1' \
    -display none -serial stdio -monitor none -no-reboot \
    -trace enable=kvm_run_exit -trace enable=serial_write \
    -trace file="${trace_file}" \
    >"${serial_file}" 2>"${stderr_file}"

rg -q '^probe:uart-before$' "${serial_file}"
rg -q '^probe:timer-fired$' "${serial_file}"
python3 "${script_dir}/analyze_trace.py" "${trace_file}"
