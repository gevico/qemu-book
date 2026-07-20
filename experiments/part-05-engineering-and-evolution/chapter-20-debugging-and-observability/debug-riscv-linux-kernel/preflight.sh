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
vmlinux="${VMLINUX:-}"
image="${RISCV_KERNEL_IMAGE:-}"
boot_path="${RISCV_BOOT_PATH:-opensbi}"
accelerator="${QEMU_ACCELERATOR:-tcg}"
firmware="${RISCV_FIRMWARE:-}"
opensbi_elf="${RISCV_OPENSBI_ELF:-}"
initrd="${RISCV_INITRD:-}"
dtb="${RISCV_DTB:-}"
kernel_load_addr="${KERNEL_LOAD_ADDR:-0x80200000}"
kernel_cmdline="${RISCV_KERNEL_CMDLINE:-console=ttyS0 earlycon=sbi nokaslr}"
harts="${QEMU_SMP:-1}"

for variable_name in QEMU_SYSTEM_RISCV64 VMLINUX RISCV_KERNEL_IMAGE; do
    if [[ -z "${!variable_name:-}" ]]; then
        echo "SKIP: set ${variable_name} to an exact live artifact"
        exit 77
    fi
done
for path in "${qemu}" "${vmlinux}" "${image}"; do
    if [[ ! -f "${path}" ]]; then
        echo "SKIP: artifact is unavailable: ${path}"
        exit 77
    fi
done
if [[ ! -x "${qemu}" ]]; then
    echo "SKIP: QEMU_SYSTEM_RISCV64 is not executable: ${qemu}"
    exit 77
fi
if [[ ! "${harts}" =~ ^[1-9][0-9]*$ ]]; then
    echo "QEMU_SMP must be a positive integer" >&2
    exit 2
fi

case "${boot_path}" in
    opensbi)
        if [[ "${accelerator}" != tcg ]]; then
            echo "SKIP: the recorded OpenSBI path in this lab requires QEMU_ACCELERATOR=tcg"
            exit 77
        fi
        if [[ -z "${firmware}" || ! -f "${firmware}" ]]; then
            echo "SKIP: RISCV_BOOT_PATH=opensbi requires a hashable RISCV_FIRMWARE file"
            exit 77
        fi
        ;;
    kvm-direct)
        if [[ "${accelerator}" != kvm ]]; then
            echo "SKIP: RISCV_BOOT_PATH=kvm-direct requires QEMU_ACCELERATOR=kvm"
            exit 77
        fi
        if [[ "$(uname -m)" != riscv64* || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
            echo "SKIP: RISC-V KVM direct boot is unavailable on this host"
            exit 77
        fi
        ;;
    *)
        echo "unsupported RISCV_BOOT_PATH: ${boot_path}" >&2
        exit 2
        ;;
esac

for optional_path in "${opensbi_elf}" "${initrd}" "${dtb}"; do
    if [[ -n "${optional_path}" && ! -f "${optional_path}" ]]; then
        echo "SKIP: optional artifact was requested but is unavailable: ${optional_path}"
        exit 77
    fi
done

readelf_tool="$(find_tool "${RISCV_READELF:-}" riscv64-linux-gnu-readelf llvm-readelf readelf || true)"
gdb_tool="$(find_tool "${RISCV_GDB:-}" riscv64-linux-gnu-gdb riscv64-unknown-elf-gdb gdb-multiarch || true)"
if [[ -z "${readelf_tool}" ]]; then
    echo "SKIP: no ELF reader is available to validate vmlinux"
    exit 77
fi
if [[ -z "${gdb_tool}" ]]; then
    echo "SKIP: no RISC-V-capable GDB is available"
    exit 77
fi
if ! vmlinux_header="$("${readelf_tool}" -h "${vmlinux}" 2>/dev/null)" || \
    ! rg -q 'Machine:[[:space:]]+RISC-V' <<<"${vmlinux_header}"; then
    echo "SKIP: VMLINUX is not a readable RISC-V ELF"
    exit 77
fi
if ! vmlinux_sections="$("${readelf_tool}" -S "${vmlinux}" 2>/dev/null)" || \
    ! rg -q '\.symtab' <<<"${vmlinux_sections}"; then
    echo "SKIP: VMLINUX has no static symbol table; use the unstripped build artifact"
    exit 77
fi
if ! vmlinux_symbols="$("${readelf_tool}" -Ws "${vmlinux}" 2>/dev/null)" || \
    ! rg -q '[[:space:]]_start$' <<<"${vmlinux_symbols}"; then
    echo "SKIP: VMLINUX does not expose the RISC-V kernel _start symbol"
    exit 77
fi
if [[ -n "${opensbi_elf}" ]]; then
    if ! opensbi_header="$("${readelf_tool}" -h "${opensbi_elf}" 2>/dev/null)" || \
        ! rg -q 'Machine:[[:space:]]+RISC-V' <<<"${opensbi_header}"; then
        echo "SKIP: RISCV_OPENSBI_ELF is not a readable RISC-V ELF"
        exit 77
    fi
    if ! opensbi_sections="$("${readelf_tool}" -S "${opensbi_elf}" 2>/dev/null)" || \
        ! rg -q '\.symtab' <<<"${opensbi_sections}"; then
        echo "SKIP: RISCV_OPENSBI_ELF has no static symbol table"
        exit 77
    fi
fi
if ! qemu_hash="$(hash_file "${qemu}")" || \
    ! vmlinux_hash="$(hash_file "${vmlinux}")" || \
    ! image_hash="$(hash_file "${image}")"; then
    echo "SKIP: no SHA-256 utility is available"
    exit 77
fi
if [[ "${boot_path}" == opensbi ]]; then
    firmware_hash="$(hash_file "${firmware}")"
fi
if [[ -n "${opensbi_elf}" ]]; then
    opensbi_elf_hash="$(hash_file "${opensbi_elf}")"
fi
if [[ -n "${initrd}" ]]; then
    initrd_hash="$(hash_file "${initrd}")"
fi
if [[ -n "${dtb}" ]]; then
    dtb_hash="$(hash_file "${dtb}")"
fi

echo "qemu_path=${qemu}"
echo "qemu_sha256=${qemu_hash}"
"${qemu}" --version | sed -n '1p' | sed 's/^/qemu_version=/'
echo "vmlinux_path=${vmlinux}"
echo "vmlinux_sha256=${vmlinux_hash}"
echo "kernel_image_path=${image}"
echo "kernel_image_sha256=${image_hash}"
if [[ "${boot_path}" == opensbi ]]; then
    echo "firmware_path=${firmware}"
    echo "firmware_sha256=${firmware_hash}"
fi
if [[ -n "${opensbi_elf}" ]]; then
    echo "opensbi_elf_path=${opensbi_elf}"
    echo "opensbi_elf_sha256=${opensbi_elf_hash}"
fi
if [[ -n "${initrd}" ]]; then
    echo "initrd_path=${initrd}"
    echo "initrd_sha256=${initrd_hash}"
fi
if [[ -n "${dtb}" ]]; then
    echo "dtb_path=${dtb}"
    echo "dtb_sha256=${dtb_hash}"
fi
echo "gdb_path=$(command -v "${gdb_tool}")"
echo "boot_path=${boot_path}"
echo "accelerator=${accelerator}"
if [[ "${accelerator}" == tcg ]]; then
    echo "accelerator_options=thread=single"
fi
echo "machine=virt"
echo "harts=${harts}"
echo "kernel_load_addr=${kernel_load_addr}"
echo "kernel_cmdline=${kernel_cmdline}"
echo "stopped_layer=guest-cpu/kernel-boundary"
echo "visible=selected-hart architectural registers and guest physical/virtual memory at a stop"
echo "not_visible=QEMU host call stacks, device-internal state, other-hart history, and Linux task semantics not reconstructed by helpers"
if [[ " ${kernel_cmdline} " != *" nokaslr "* ]]; then
    echo "warning=kernel command line does not contain nokaslr; virtual symbols may relocate"
fi
echo "preflight=ready"
