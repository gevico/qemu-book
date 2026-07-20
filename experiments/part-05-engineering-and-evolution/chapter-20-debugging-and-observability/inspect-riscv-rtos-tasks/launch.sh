#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if preflight_output="$("${script_dir}/preflight.sh" 2>&1)"; then
    preflight_status=0
else
    preflight_status=$?
fi
printf '%s\n' "${preflight_output}"
if (( preflight_status != 0 )); then
    exit "${preflight_status}"
fi
if ! rg -q '^preflight=ready$' <<<"${preflight_output}"; then
    echo "preflight returned success without a ready record" >&2
    exit 1
fi
if [[ "${RUN_LIVE:-0}" != 1 ]]; then
    echo "SKIP: set RUN_LIVE=1 after reviewing the preflight record"
    exit 77
fi

qemu="${QEMU_SYSTEM_RISCV64}"
boot_path="${RTOS_BOOT_PATH:-machine}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
results_dir="${script_dir}/results/${run_id}"
socket_dir="$(mktemp -d "${TMPDIR:-/tmp}/qemu-book-rtos-tasks.XXXXXX")"
gdb_socket="${socket_dir}/gdb.sock"
monitor_socket="${socket_dir}/monitor.sock"
qemu_pid=""

cleanup() {
    if [[ -n "${qemu_pid}" ]] && kill -0 "${qemu_pid}" 2>/dev/null; then
        kill -TERM "${qemu_pid}" 2>/dev/null || true
        for _ in {1..30}; do
            if ! kill -0 "${qemu_pid}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        if kill -0 "${qemu_pid}" 2>/dev/null; then
            kill -KILL "${qemu_pid}" 2>/dev/null || true
        fi
        wait "${qemu_pid}" 2>/dev/null || true
    fi
    rm -f -- "${gdb_socket}" "${monitor_socket}"
    rmdir -- "${socket_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "${results_dir}"
chmod 700 "${socket_dir}"
printf '%s\n' "${preflight_output}" >"${results_dir}/manifest.txt"
{
    echo "gdb_socket=${gdb_socket}"
    echo "monitor_socket=${monitor_socket}"
    echo "qemu_starts_halted=true"
} >>"${results_dir}/manifest.txt"

qemu_args=(
    -machine virt
    -cpu rv64
    -accel "tcg,thread=single"
    -smp "${RTOS_HARTS:-1}"
    -m "${QEMU_MEMORY:-256M}"
    -kernel "${RTOS_ELF}"
    -S
    -display none
    -serial "file:${results_dir}/serial.log"
    -monitor "unix:${monitor_socket},server=on,wait=off"
    -chardev "socket,path=${gdb_socket},server=on,wait=off,id=gdb0"
    -gdb chardev:gdb0
    -no-reboot
)
if [[ "${boot_path}" == machine ]]; then
    qemu_args+=( -bios none )
else
    qemu_args+=( -bios "${RISCV_FIRMWARE}" )
fi
if [[ -n "${RISCV_DTB:-}" ]]; then
    qemu_args+=( -dtb "${RISCV_DTB}" )
fi

{
    printf 'qemu_command='
    printf '%q ' "${qemu}" "${qemu_args[@]}"
    printf '\n'
} >>"${results_dir}/manifest.txt"

"${qemu}" "${qemu_args[@]}" \
    >"${results_dir}/qemu.stdout" 2>"${results_dir}/qemu.stderr" &
qemu_pid=$!
for _ in {1..100}; do
    if [[ -S "${gdb_socket}" ]]; then
        break
    fi
    if ! kill -0 "${qemu_pid}" 2>/dev/null; then
        echo "QEMU exited before creating the private gdbstub socket" >&2
        exit 1
    fi
    sleep 0.05
done
if [[ ! -S "${gdb_socket}" ]]; then
    echo "timed out waiting for the private gdbstub socket" >&2
    exit 1
fi

echo "QEMU is halted; no RTOS instruction has executed yet."
echo "gdb_socket=${gdb_socket}"
echo "manifest=${results_dir}/manifest.txt"
echo "Use rtos-tasks.gdb.in from a second terminal; Ctrl-C here cleans up."
wait "${qemu_pid}"
qemu_pid=""
