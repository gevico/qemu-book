#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

qemu_src="${QEMU_SRC:-}"
helper="${qemu_src}/target/riscv/tcg/cpu_helper.c"
if [[ -z "${qemu_src}" || ! -f "${helper}" ]]; then
    echo "QEMU_SRC must point to the fixed QEMU source tree" >&2
    exit 2
fi

rg -q 'static int get_physical_address\(' "${helper}"
rg -q 'riscv_cpu_tlb_fill\(' "${helper}"
rg -q 'PTE_D \| PTE_A' "${helper}"
rg -q 'pte & PTE_V' "${helper}"
echo "Confirmed RISC-V walk, TLB fill, validity, and A/D paths at the tag."
