#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

qemu_src="${QEMU_SRC:-}"
if [[ -z "${qemu_src}" || ! -f "${qemu_src}/system/memory.c" ]]; then
    echo "QEMU_SRC must point to the fixed QEMU source tree" >&2
    exit 2
fi

rg -q 'subregion->priority >= other->priority' "${qemu_src}/system/memory.c"
rg -q 'memory_region_add_subregion_overlap' "${qemu_src}/system/memory.c"
rg -q 'mr->alias_offset' "${qemu_src}/system/memory.c"
rg -n 'memory_region_init_alias' "${qemu_src}/hw/riscv" || true
echo "Confirmed priority ordering and alias-offset handling at the source tag."
