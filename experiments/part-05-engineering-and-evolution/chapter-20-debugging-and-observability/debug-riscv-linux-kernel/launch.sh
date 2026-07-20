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
boot_path="${RISCV_BOOT_PATH:-opensbi}"
accelerator="${QEMU_ACCELERATOR:-tcg}"
accelerator_arg="${accelerator}"
if [[ "${accelerator}" == tcg ]]; then
    accelerator_arg="tcg,thread=single"
fi
kernel_cmdline="${RISCV_KERNEL_CMDLINE:-console=ttyS0 earlycon=sbi nokaslr}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
results_dir="${script_dir}/results/${run_id}"
socket_dir="$(mktemp -d "${TMPDIR:-/tmp}/qemu-book-linux-kernel.XXXXXX")"
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
    -smp "${QEMU_SMP:-1}"
    -m "${QEMU_MEMORY:-2G}"
    -accel "${accelerator_arg}"
    -kernel "${RISCV_KERNEL_IMAGE}"
    -append "${kernel_cmdline}"
    -S
    -display none
    -serial "file:${results_dir}/serial.log"
    -monitor "unix:${monitor_socket},server=on,wait=off"
    -chardev "socket,path=${gdb_socket},server=on,wait=off,id=gdb0"
    -gdb chardev:gdb0
    -no-reboot
)
if [[ "${boot_path}" == opensbi ]]; then
    qemu_args+=( -cpu rv64 -bios "${RISCV_FIRMWARE}" )
else
    qemu_args+=( -cpu host -bios none )
fi
if [[ -n "${RISCV_INITRD:-}" ]]; then
    qemu_args+=( -initrd "${RISCV_INITRD}" )
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

echo "QEMU is halted at reset; live execution has not started."
echo "gdb_socket=${gdb_socket}"
echo "manifest=${results_dir}/manifest.txt"
echo "Use kernel.gdb.in from a second terminal; Ctrl-C here performs bounded cleanup."
wait "${qemu_pid}"
qemu_pid=""
