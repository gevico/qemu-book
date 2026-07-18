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
"${qemu}" -trace help >"${results_dir}/trace-help.txt"
events=(
    resettable_reset
    resettable_phase_enter_begin
    resettable_phase_hold_begin
    resettable_phase_exit_begin
    cpu_reset
)
trace_args=()
for event in "${events[@]}"; do
    if rg -q "^${event}$" "${results_dir}/trace-help.txt"; then
        trace_args+=( -trace "enable=${event}" )
    fi
done
if (( ${#trace_args[@]} == 0 )); then
    echo "no selected reset event is available" >&2
    exit 1
fi

printf 'info registers\nsystem_reset\ninfo registers\nquit\n' | "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -S -display none -serial none \
    -monitor stdio "${trace_args[@]}" -trace "file=${results_dir}/reset.trace" \
    >"${results_dir}/monitor.txt" 2>"${results_dir}/qemu.stderr"
test -s "${results_dir}/reset.trace"
echo "Captured reset phases and pre/post monitor register views."
