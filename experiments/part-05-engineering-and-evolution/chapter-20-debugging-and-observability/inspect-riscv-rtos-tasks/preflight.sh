#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

hash_file() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "${path}" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "${path}" | awk '{print $1}'
    else
        return 1
    fi
}

find_tool() {
    local explicit="$1"
    shift

    if [[ -n "${explicit}" ]] && command -v "${explicit}" >/dev/null 2>&1; then
        printf '%s\n' "${explicit}"
        return 0
    fi
    for candidate in "$@"; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

qemu="${QEMU_SYSTEM_RISCV64:-}"
rtos_elf="${RTOS_ELF:-}"
boot_path="${RTOS_BOOT_PATH:-machine}"
firmware="${RISCV_FIRMWARE:-}"
dtb="${RISCV_DTB:-}"
harts="${RTOS_HARTS:-1}"
scheduler_symbol="${RTOS_SCHEDULER_SYMBOL:-vTaskSwitchContext}"
current_task_symbol="${RTOS_CURRENT_TASK_SYMBOL:-pxCurrentTCB}"

if [[ -z "${qemu}" || -z "${rtos_elf}" ]]; then
    echo "SKIP: set QEMU_SYSTEM_RISCV64 and RTOS_ELF to exact live artifacts"
    exit 77
fi
if [[ ! -x "${qemu}" || ! -f "${rtos_elf}" ]]; then
    echo "SKIP: QEMU or RTOS ELF is unavailable"
    exit 77
fi
if [[ ! "${harts}" =~ ^[1-9][0-9]*$ ]]; then
    echo "RTOS_HARTS must be a positive integer" >&2
    exit 2
fi
case "${boot_path}" in
    machine)
        ;;
    opensbi)
        if [[ -z "${firmware}" || ! -f "${firmware}" ]]; then
            echo "SKIP: RTOS_BOOT_PATH=opensbi requires a hashable RISCV_FIRMWARE file"
            exit 77
        fi
        ;;
    *)
        echo "unsupported RTOS_BOOT_PATH: ${boot_path}" >&2
        exit 2
        ;;
esac
if [[ -n "${dtb}" && ! -f "${dtb}" ]]; then
    echo "SKIP: requested RISCV_DTB is unavailable: ${dtb}"
    exit 77
fi

readelf_tool="$(find_tool "${RISCV_READELF:-}" riscv64-unknown-elf-readelf riscv64-linux-gnu-readelf llvm-readelf readelf || true)"
gdb_tool="$(find_tool "${RISCV_GDB:-}" riscv64-unknown-elf-gdb riscv64-linux-gnu-gdb gdb-multiarch || true)"
if [[ -z "${readelf_tool}" ]]; then
    echo "SKIP: no ELF reader is available"
    exit 77
fi
if [[ -z "${gdb_tool}" ]]; then
    echo "SKIP: no RISC-V-capable GDB is available"
    exit 77
fi
if ! rtos_header="$("${readelf_tool}" -h "${rtos_elf}" 2>/dev/null)" || \
    ! rg -q 'Machine:[[:space:]]+RISC-V' <<<"${rtos_header}"; then
    echo "SKIP: RTOS_ELF is not a readable RISC-V ELF"
    exit 77
fi
if ! rtos_sections="$("${readelf_tool}" -S "${rtos_elf}" 2>/dev/null)" || \
    ! rg -q '\.symtab' <<<"${rtos_sections}"; then
    echo "SKIP: RTOS_ELF lacks a static symbol table"
    exit 77
fi
if ! symbols="$("${readelf_tool}" -Ws "${rtos_elf}" 2>/dev/null)"; then
    echo "SKIP: RTOS_ELF symbol table cannot be read"
    exit 77
fi
if ! awk -v name="${scheduler_symbol}" '$NF == name { found = 1 }
    END { exit !found }' <<<"${symbols}"; then
    echo "SKIP: scheduler symbol is absent: ${scheduler_symbol}"
    exit 77
fi
if ! awk -v name="${current_task_symbol}" '$NF == name { found = 1 }
    END { exit !found }' <<<"${symbols}"; then
    echo "SKIP: current-task symbol is absent: ${current_task_symbol}"
    exit 77
fi
if ! qemu_hash="$(hash_file "${qemu}")" || \
    ! rtos_hash="$(hash_file "${rtos_elf}")"; then
    echo "SKIP: no SHA-256 utility is available"
    exit 77
fi
if [[ "${boot_path}" == opensbi ]]; then
    firmware_hash="$(hash_file "${firmware}")"
fi
if [[ -n "${dtb}" ]]; then
    dtb_hash="$(hash_file "${dtb}")"
fi

echo "qemu_path=${qemu}"
echo "qemu_sha256=${qemu_hash}"
"${qemu}" --version | sed -n '1p' | sed 's/^/qemu_version=/'
echo "rtos_elf_path=${rtos_elf}"
echo "rtos_elf_sha256=${rtos_hash}"
if [[ "${boot_path}" == opensbi ]]; then
    echo "firmware_path=${firmware}"
    echo "firmware_sha256=${firmware_hash}"
fi
if [[ -n "${dtb}" ]]; then
    echo "dtb_path=${dtb}"
    echo "dtb_sha256=${dtb_hash}"
fi
echo "gdb_path=$(command -v "${gdb_tool}")"
echo "boot_path=${boot_path}"
echo "accelerator=tcg"
echo "machine=virt"
echo "harts=${harts}"
echo "scheduler_symbol=${scheduler_symbol}"
echo "current_task_symbol=${current_task_symbol}"
echo "stopped_layer=guest-cpu/rtos-scheduler"
echo "visible=QEMU hart registers plus RTOS scheduler objects explicitly decoded from guest symbols and memory"
echo "not_visible=task identity synthesized by no helper, past scheduling history, interrupt timing while stopped, and QEMU host internals"
echo "preflight=ready"
