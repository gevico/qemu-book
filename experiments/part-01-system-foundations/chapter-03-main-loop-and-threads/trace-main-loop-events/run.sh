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

events=(runstate_set run_poll_handlers_begin run_poll_handlers_end)
trace_args=()
for event in "${events[@]}"; do
    if rg -q "^${event}$" "${results_dir}/trace-help.txt"; then
        trace_args+=( -trace "enable=${event}" )
    fi
done
if (( ${#trace_args[@]} == 0 )); then
    echo "none of the selected main-loop/run-state events exists" >&2
    exit 1
fi

printf 'cont\nstop\nquit\n' | "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -S -display none -serial none \
    -monitor stdio "${trace_args[@]}" -trace "file=${results_dir}/events.txt" \
    >"${results_dir}/monitor.txt" 2>"${results_dir}/qemu.stderr"
test -s "${results_dir}/events.txt"
echo "Captured available poll and run-state events in results/events.txt."
