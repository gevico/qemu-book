#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
qemu="${QEMU_SYSTEM_RISCV64:-}"
image="${RISCV_GUEST_IMAGE:-}"
qemu_src="${QEMU_SRC:-}"
qemu_build="${QEMU_BUILD:-}"
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
if [[ -z "${qemu_src}" ]] || \
   ! git -C "${qemu_src}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "QEMU_SRC must name the QEMU Git worktree used for this build" >&2
    exit 2
fi
if [[ -z "${qemu_build}" ]]; then
    qemu_build="$(dirname -- "${qemu}")"
fi
if [[ ! -d "${qemu_build}" ]]; then
    echo "QEMU_BUILD must name the QEMU build directory" >&2
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
QEMU_SRC="${qemu_src}" "${script_dir}/../../../tools/source-report.sh" \
    >"${results_dir}/source-report.txt"

build_evidence=()
for candidate in \
    "${qemu_build}/config-host.mak" \
    "${qemu_build}/meson-info/intro-buildoptions.json" \
    "${qemu_build}/meson-logs/meson-log.txt"; do
    if [[ -f "${candidate}" ]]; then
        build_evidence+=( "${candidate}" )
    fi
done
if (( ${#build_evidence[@]} > 0 )); then
    shasum -a 256 "${build_evidence[@]}" >"${results_dir}/build-evidence.sha256"
else
    printf 'No standard QEMU build metadata found under %s\n' "${qemu_build}" \
        >"${results_dir}/build-evidence.missing.txt"
fi

qemu_command=(
    "${qemu}"
    -machine virt -cpu rv64 -accel "tcg,one-insn-per-tb=on"
    -bios none -kernel "${image}" -display none -serial none -monitor none
    -d "in_asm,op_opt,out_asm" -D "${results_dir}/tcg.log"
)
{
    printf 'timeout %q' "${TRACE_SECONDS:-3}"
    printf ' %q' "${qemu_command[@]}"
    printf '\n'
} >"${results_dir}/command.txt"

set +e
timeout "${TRACE_SECONDS:-3}" "${qemu_command[@]}" \
    2>"${results_dir}/qemu.stderr"
qemu_exit_code=$?
set -e
if (( qemu_exit_code != 0 && qemu_exit_code != 124 )); then
    echo "QEMU failed before the bounded collection ended (status ${qemu_exit_code})" >&2
    exit 1
fi
test -s "${results_dir}/tcg.log"
echo "${qemu_exit_code}" >"${results_dir}/status.txt"
echo "Collected host-labelled TCG evidence under results/${host_label}/."
