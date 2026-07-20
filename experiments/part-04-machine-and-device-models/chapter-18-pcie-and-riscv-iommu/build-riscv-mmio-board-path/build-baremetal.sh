#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${script_dir}/build"
cc="${RISCV_CC:-}"

if [[ -n "${cc}" ]] && ! command -v "${cc}" >/dev/null 2>&1; then
    echo "RISCV_CC is not executable: ${cc}" >&2
    exit 2
fi
if [[ -z "${cc}" ]]; then
    for candidate in riscv64-unknown-elf-gcc riscv64-linux-gnu-gcc; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            cc="${candidate}"
            break
        fi
    done
fi
if [[ -z "${cc}" ]]; then
    echo "SKIP: no supported RISC-V cross compiler"
    exit 77
fi

mkdir -p "${build_dir}"
"${cc}" --version >"${build_dir}/compiler-version.txt"
"${cc}" -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany \
    -msmall-data-limit=0 -mno-relax \
    -ffreestanding -fno-builtin -fno-pic -fno-pie -no-pie \
    -nostdlib -nostartfiles \
    -Wl,--build-id=none -Wl,-Map,"${build_dir}/qb-mmio-probe.map" \
    -T "${script_dir}/guest/linker.ld" \
    "${script_dir}/guest/start.S" "${script_dir}/guest/probe.c" \
    -o "${build_dir}/qb-mmio-probe.elf"

test -s "${build_dir}/qb-mmio-probe.elf"
echo "guest_elf=${build_dir}/qb-mmio-probe.elf"
