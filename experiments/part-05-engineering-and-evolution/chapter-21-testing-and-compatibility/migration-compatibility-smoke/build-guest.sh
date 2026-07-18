#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${script_dir}/build"
cc="${RISCV_CC:-riscv64-linux-gnu-gcc}"

if ! command -v "${cc}" >/dev/null 2>&1; then
    echo "required compiler not found: ${cc}" >&2
    exit 2
fi

mkdir -p "${build_dir}"
"${cc}" -march=rv64gc -mabi=lp64d -mcmodel=medany \
    -ffreestanding -fno-pie -no-pie -nostdlib -nostartfiles -static \
    -Wl,--build-id=none -T "${script_dir}/guest/linker.ld" \
    "${script_dir}/guest/start.S" "${script_dir}/guest/counter.c" \
    -o "${build_dir}/counter.elf"

echo "Created ${build_dir}/counter.elf"
