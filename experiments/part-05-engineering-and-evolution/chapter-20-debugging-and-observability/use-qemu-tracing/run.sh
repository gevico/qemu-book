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
"${qemu}" -trace help >"${results_dir}/events.txt"

events=(runstate_set cpu_reset resettable_reset serial_write)
trace_args=()
for event in "${events[@]}"; do
    if rg -q "^${event}$" "${results_dir}/events.txt"; then
        trace_args+=( -trace "enable=${event}" )
    fi
done
if (( ${#trace_args[@]} == 0 )); then
    echo "none of the bounded lifecycle events is available" >&2
    exit 1
fi

printf 'system_reset\nquit\n' | "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -S -display none -serial none \
    -monitor stdio "${trace_args[@]}" -trace "file=${results_dir}/lifecycle.trace" \
    >"${results_dir}/monitor.txt" 2>"${results_dir}/qemu.stderr"
test -s "${results_dir}/lifecycle.trace"
echo "Captured a narrow reset/lifecycle trace using build-listed events."
