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
guest_image="${RISCV_GUEST_IMAGE:-}"
user_elf="${RISCV_USER_ELF:-}"
guest_program="${GUEST_PROGRAM_PATH:-}"
guest_kernel="${RISCV_GUEST_KERNEL:-}"
guest_dtb="${RISCV_GUEST_DTB:-}"
accelerator="${QEMU_ACCELERATOR:-tcg}"
endpoint="${GDBSERVER_ENDPOINT:-127.0.0.1:1234}"

for variable_name in QEMU_SYSTEM_RISCV64 RISCV_GUEST_IMAGE RISCV_USER_ELF \
    GUEST_PROGRAM_PATH; do
    if [[ -z "${!variable_name:-}" ]]; then
        echo "SKIP: set ${variable_name} to the exact guest/session artifact"
        exit 77
    fi
done
for path in "${qemu}" "${guest_image}" "${user_elf}"; do
    if [[ ! -f "${path}" ]]; then
        echo "SKIP: artifact is unavailable: ${path}"
        exit 77
    fi
done
if [[ ! -x "${qemu}" ]]; then
    echo "SKIP: QEMU_SYSTEM_RISCV64 is not executable: ${qemu}"
    exit 77
fi
if [[ "${accelerator}" != tcg && "${accelerator}" != kvm ]]; then
    echo "QEMU_ACCELERATOR must be tcg or kvm" >&2
    exit 2
fi
if [[ "${accelerator}" == kvm && \
      ( "$(uname -m)" != riscv64* || ! -r /dev/kvm || ! -w /dev/kvm ) ]]; then
    echo "SKIP: a RISC-V KVM run cannot be reproduced on this host"
    exit 77
fi
if [[ ! "${endpoint}" =~ ^127\.0\.0\.1:[1-9][0-9]{0,4}$ && \
      ! "${endpoint}" =~ ^\[::1\]:[1-9][0-9]{0,4}$ ]]; then
    echo "refusing non-loopback GDBSERVER_ENDPOINT: ${endpoint}" >&2
    exit 2
fi
endpoint_port="${endpoint##*:}"
if (( endpoint_port > 65535 )); then
    echo "refusing invalid GDBSERVER_ENDPOINT port: ${endpoint_port}" >&2
    exit 2
fi
for optional_path in "${guest_kernel}" "${guest_dtb}"; do
    if [[ -n "${optional_path}" && ! -f "${optional_path}" ]]; then
        echo "SKIP: optional artifact was requested but is unavailable: ${optional_path}"
        exit 77
    fi
done
if [[ -n "${RISCV_SYSROOT:-}" && ! -d "${RISCV_SYSROOT}" ]]; then
    echo "SKIP: requested RISCV_SYSROOT is unavailable: ${RISCV_SYSROOT}"
    exit 77
fi

readelf_tool="$(find_tool "${RISCV_READELF:-}" riscv64-linux-gnu-readelf llvm-readelf readelf || true)"
gdb_tool="$(find_tool "${RISCV_GDB:-}" riscv64-linux-gnu-gdb gdb-multiarch || true)"
if [[ -z "${readelf_tool}" ]]; then
    echo "SKIP: no ELF reader is available"
    exit 77
fi
if [[ -z "${gdb_tool}" ]]; then
    echo "SKIP: no RISC-V-capable GDB is available"
    exit 77
fi
if ! user_header="$("${readelf_tool}" -h "${user_elf}" 2>/dev/null)" || \
    ! rg -q 'Machine:[[:space:]]+RISC-V' <<<"${user_header}"; then
    echo "SKIP: RISCV_USER_ELF is not a readable RISC-V ELF"
    exit 77
fi
if ! user_sections="$("${readelf_tool}" -S "${user_elf}" 2>/dev/null)" || \
    ! rg -q '\.symtab' <<<"${user_sections}"; then
    echo "SKIP: RISCV_USER_ELF lacks the symbols required for this experiment"
    exit 77
fi
if ! qemu_hash="$(hash_file "${qemu}")" || \
    ! guest_image_hash="$(hash_file "${guest_image}")" || \
    ! user_elf_hash="$(hash_file "${user_elf}")"; then
    echo "SKIP: no SHA-256 utility is available"
    exit 77
fi
if [[ -n "${guest_kernel}" ]]; then
    guest_kernel_hash="$(hash_file "${guest_kernel}")"
fi
if [[ -n "${guest_dtb}" ]]; then
    guest_dtb_hash="$(hash_file "${guest_dtb}")"
fi

echo "qemu_path=${qemu}"
echo "qemu_sha256=${qemu_hash}"
"${qemu}" --version | sed -n '1p' | sed 's/^/qemu_version=/'
echo "guest_image_path=${guest_image}"
echo "guest_image_sha256=${guest_image_hash}"
echo "user_elf_path=${user_elf}"
echo "user_elf_sha256=${user_elf_hash}"
echo "guest_program_path=${guest_program}"
if [[ -n "${guest_kernel}" ]]; then
    echo "guest_kernel_path=${guest_kernel}"
    echo "guest_kernel_sha256=${guest_kernel_hash}"
fi
if [[ -n "${guest_dtb}" ]]; then
    echo "guest_dtb_path=${guest_dtb}"
    echo "guest_dtb_sha256=${guest_dtb_hash}"
fi
echo "gdb_path=$(command -v "${gdb_tool}")"
echo "accelerator=${accelerator}"
echo "gdbserver_endpoint=${endpoint}"
echo "transport=host-loopback SSH tunnel to guest-loopback gdbserver"
echo "stopped_layer=guest-linux-process"
echo "visible=selected inferior process, Linux threads, user mappings, signals, and matching shared-library symbols"
echo "not_visible=pre-exec firmware, other guest processes, kernel/device internals, QEMU host frames, and execution history before attach"
if [[ -n "${RISCV_SYSROOT:-}" ]]; then
    echo "sysroot=${RISCV_SYSROOT}"
else
    echo "warning=RISCV_SYSROOT is unset; dynamic-library symbols may be incomplete"
fi
echo "guest_runtime_record_required=uname, gdbserver-version, pid, program-sha256, and library-build-ids"
echo "preflight=ready"
