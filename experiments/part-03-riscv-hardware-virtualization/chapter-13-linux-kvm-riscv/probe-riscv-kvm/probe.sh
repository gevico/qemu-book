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
{
    uname -a
    printf 'architecture=%s\n' "$(uname -m)"
    if [[ -e /dev/kvm ]]; then
        ls -l /dev/kvm
    else
        echo '/dev/kvm absent'
    fi
    "${qemu}" --version
    "${qemu}" -accel help
} >"${results_dir}/probe.txt" 2>"${results_dir}/probe.stderr"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != riscv64 || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "status=skipped: requires Linux riscv64 and read/write /dev/kvm" \
        >>"${results_dir}/probe.txt"
    echo "Recorded an explicit KVM skip in results/probe.txt."
    exit 77
fi

printf 'info cpus\nquit\n' | "${qemu}" \
    -machine virt -accel kvm -cpu host -S -display none -serial none \
    -monitor stdio >>"${results_dir}/probe.txt" \
    2>>"${results_dir}/probe.stderr"
echo "status=created-riscv-kvm-vcpu" >>"${results_dir}/probe.txt"
echo "Created and paused one RISC-V KVM vCPU."
