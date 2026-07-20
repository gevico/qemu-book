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
if [[ "$(uname -s)" != Linux || "$(uname -m)" != riscv64 || \
      ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "SKIP: a Linux RISC-V host with read/write /dev/kvm is required"
    exit 77
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "GNU timeout is required" >&2
    exit 2
fi
mkdir -p "${results_dir}"

set +e
timeout "${TRACE_SECONDS:-15}" "${qemu}" \
    -machine virt -accel kvm -cpu host -smp 1 -m 256M \
    -kernel "${image}" -display none -serial stdio -monitor none -no-reboot \
    -trace enable=kvm_vcpu_ioctl -trace enable=kvm_run_exit \
    -trace file="${results_dir}/kvm.trace" \
    >"${results_dir}/serial.log" 2>"${results_dir}/qemu.stderr"
qemu_exit_code=$?
set -e
if (( qemu_exit_code != 0 && qemu_exit_code != 124 )); then
    echo "QEMU failed before the bounded KVM trace ended (status ${qemu_exit_code})" >&2
    exit 1
fi
echo "${qemu_exit_code}" >"${results_dir}/status.txt"
rg -q 'kvm_vcpu_ioctl|kvm_run_exit' "${results_dir}/kvm.trace"
echo "Captured bounded KVM vCPU ioctl and exit observations."
