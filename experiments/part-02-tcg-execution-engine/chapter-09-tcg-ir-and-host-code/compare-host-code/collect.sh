#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
qemu="${QEMU_SYSTEM_RISCV64:-}"
image="${RISCV_GUEST_IMAGE:-}"
host_label="${HOST_LABEL:-$(uname -m)}"
results_dir="${script_dir}/results/${host_label}"

if [[ ! "${host_label}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "HOST_LABEL contains unsafe path characters" >&2
    exit 2
fi
if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
if [[ -z "${image}" || ! -f "${image}" ]]; then
    echo "RISCV_GUEST_IMAGE must name a guest image" >&2
    exit 2
fi
for tool in timeout shasum; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "required tool not found: ${tool}" >&2
        exit 2
    }
done
mkdir -p "${results_dir}"
shasum -a 256 "${qemu}" "${image}" >"${results_dir}/sha256.txt"
"${qemu}" --version >"${results_dir}/qemu-version.txt"

set +e
timeout "${TRACE_SECONDS:-3}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg,one-insn-per-tb=on \
    -bios none -kernel "${image}" -display none -serial none -monitor none \
    -d in_asm,op_opt,out_asm -D "${results_dir}/tcg.log" \
    2>"${results_dir}/qemu.stderr"
status=$?
set -e
test -s "${results_dir}/tcg.log"
echo "${status}" >"${results_dir}/status.txt"
echo "Collected host-labelled TCG evidence under results/${host_label}/."
