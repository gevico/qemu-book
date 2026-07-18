#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"

if [[ -z "${qemu_src}" || ! -d "${qemu_src}/rust/qom" ]]; then
    echo "QEMU_SRC must point to the fixed QEMU source tree with Rust crates" >&2
    exit 2
fi
mkdir -p "${results_dir}"
{
    "${script_dir}/../../../tools/source-report.sh"
    printf '\n[QOM ownership and casts]\n'
    rg -n -m 100 'unsafe|ObjectType|Owned|as_mut_ptr|from_raw' \
        "${qemu_src}/rust/qom/src"
    printf '\n[sysbus C calls]\n'
    rg -n 'unsafe|system_sys::|as_mut_ptr|MemoryRegion' \
        "${qemu_src}/rust/system/src/sysbus.rs"
    printf '\n[qdev callbacks and BQL-sensitive state]\n'
    rg -n -m 140 'unsafe extern "C"|unsafe impl|state.as_ref|Bql|bql' \
        "${qemu_src}/rust/hw/core/src/qdev.rs" "${qemu_src}/rust/bql/src"
    printf '\n[generated binding inputs]\n'
    find "${qemu_src}/rust/bindings" -maxdepth 2 \
        -type f \( -name 'wrapper.h' -o -name 'meson.build' \) -print | sort
} >"${results_dir}/ffi-audit.txt"

echo "Recorded one C/Rust callback, pointer, BQL, and binding audit surface."
