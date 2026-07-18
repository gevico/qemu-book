#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

qemu_src="${QEMU_SRC:-}"
if [[ -z "${qemu_src}" ]]; then
    echo "QEMU_SRC must point to the fixed QEMU source tree" >&2
    exit 2
fi

cputlb="${qemu_src}/accel/tcg/cputlb.c"
bounds="${qemu_src}/accel/tcg/tlb-bounds.h"

for source_file in "${cputlb}" "${bounds}"; do
    if [[ ! -f "${source_file}" ]]; then
        echo "missing upstream source: ${source_file}" >&2
        exit 1
    fi
done

rg -q 'return \(addr >> TARGET_PAGE_BITS\) & size_mask;' "${cputlb}"
rg -q '#define CPU_TLB_DYN_DEFAULT_BITS 8' "${bounds}"
rg -q 'rate > 70' "${cputlb}"
rg -q 'rate < 30' "${cputlb}"

echo "Confirmed direct-map index, 2^8 default size, and dynamic resize bounds."
echo "The Python model intentionally omits resize windows, victim entries,"
echo "large-page handling, MMU modes, permission tags, and invalidation."
