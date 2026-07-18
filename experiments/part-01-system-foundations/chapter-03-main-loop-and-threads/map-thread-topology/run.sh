#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"
active_qemu_pid=""

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
mkdir -p "${results_dir}"

stop_active_qemu()
{
    if [[ -z "${active_qemu_pid}" ]] ||
       ! kill -0 "${active_qemu_pid}" 2>/dev/null; then
        active_qemu_pid=""
        return
    fi

    kill "${active_qemu_pid}" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "${active_qemu_pid}" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "${active_qemu_pid}" 2>/dev/null; then
        kill -KILL "${active_qemu_pid}" 2>/dev/null || true
    fi
    active_qemu_pid=""
}

trap stop_active_qemu EXIT INT TERM

capture_mode()
{
    local mode="$1"
    local thread_option="$2"
    local pid_file="${results_dir}/${mode}.pid"

    "${qemu}" -machine virt -cpu rv64 -smp 4 \
        -accel "tcg${thread_option}" -S -display none -serial none \
        -monitor none -daemonize -pidfile "${pid_file}" \
        2>"${results_dir}/${mode}.stderr"
    active_qemu_pid="$(<"${pid_file}")"
    if [[ "$(uname -s)" == Linux ]]; then
        ps -L -p "${active_qemu_pid}" -o pid,tid,comm,stat \
            >"${results_dir}/${mode}-threads.txt"
    else
        ps -M -p "${active_qemu_pid}" \
            >"${results_dir}/${mode}-threads.txt"
    fi
    stop_active_qemu
}

capture_mode multi ",thread=multi"
capture_mode single ",thread=single"
echo "Captured paused TCG thread inventories for multi and single policies."
