#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
guest="${script_dir}/build/debug-riscv.elf"
qemu="${QEMU_SYSTEM_RISCV64:-}"
gdb="${RISCV_GDB:-}"
qemu_pid=""
socket_dir=""

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
    if [[ -n "${socket_dir}" && -d "${socket_dir}" ]]; then
        rm -f -- "${socket_dir}/gdb.sock"
        rmdir -- "${socket_dir}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

"${script_dir}/static-check.sh"
if [[ ! -s "${guest}" ]]; then
    "${script_dir}/build.sh"
fi
if [[ ! -s "${guest}" ]]; then
    echo "SKIP: live guest was not built"
    exit 77
fi
if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
if [[ -n "${gdb}" ]] && ! command -v "${gdb}" >/dev/null 2>&1; then
    echo "RISCV_GDB is not executable: ${gdb}" >&2
    exit 2
fi
if [[ -z "${gdb}" ]]; then
    for candidate in riscv64-unknown-elf-gdb riscv64-linux-gnu-gdb gdb-multiarch; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            gdb="${candidate}"
            break
        fi
    done
fi
if [[ -z "${gdb}" ]]; then
    echo "SKIP: no RISC-V-capable GDB; ELF and static fixture are available"
    exit 77
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
results_dir="${script_dir}/results/${run_id}"
mkdir -p "${results_dir}"
socket_dir="$(mktemp -d "${TMPDIR:-/tmp}/qemu-book-gdbstub.XXXXXX")"
socket_path="${socket_dir}/gdb.sock"

"${qemu}" --version >"${results_dir}/qemu-version.txt"
"${gdb}" --version >"${results_dir}/gdb-version.txt"
"${qemu}" \
    -machine virt -cpu rv64 -accel tcg,thread=single -smp 1 -m 128M \
    -bios none -kernel "${guest}" -S -display none -serial none -monitor none \
    -chardev "socket,path=${socket_path},server=on,wait=off,id=gdb0" \
    -gdb chardev:gdb0 -no-reboot \
    >"${results_dir}/qemu.stdout" 2>"${results_dir}/qemu.stderr" &
qemu_pid=$!

for _ in {1..100}; do
    if [[ -S "${socket_path}" ]]; then
        break
    fi
    if ! kill -0 "${qemu_pid}" 2>/dev/null; then
        echo "QEMU exited before creating the gdb socket" >&2
        exit 1
    fi
    sleep 0.05
done
if [[ ! -S "${socket_path}" ]]; then
    echo "timed out waiting for the gdb socket" >&2
    exit 1
fi

"${gdb}" -nx -q -batch "${guest}" \
    -ex "set pagination off" \
    -ex "target remote ${socket_path}" \
    -ex "break store_counter" \
    -ex "continue" \
    -ex "info registers pc s0 t0" \
    -ex 'printf "COUNTER_BEFORE=%llu\n", *(unsigned long long *)&counter' \
    -ex "printf \"S0_AT_STORE=%llu\\n\", (unsigned long long)\$s0" \
    -ex "stepi" \
    -ex 'printf "COUNTER_AFTER=%llu\n", *(unsigned long long *)&counter' \
    -ex "x/4i \$pc" \
    -ex "detach" >"${results_dir}/gdb.txt" 2>&1

"${script_dir}/verify-transcript.sh" "${results_dir}/gdb.txt"
echo "gdbstub_result=${results_dir}"
