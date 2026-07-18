#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

qemu_src="${QEMU_SRC:-}"
if [[ -z "${qemu_src}" ]]; then
    echo "QEMU_SRC must point to the fixed QEMU source tree" >&2
    exit 2
fi

trace_events="${qemu_src}/hw/riscv/trace-events"
documentation="${qemu_src}/docs/specs/riscv-iommu.rst"
for source_file in "${trace_events}" "${documentation}"; do
    if [[ ! -f "${source_file}" ]]; then
        echo "missing upstream file: ${source_file}" >&2
        exit 1
    fi
done

for event in riscv_iommu_new riscv_iommu_dma riscv_iommu_flt riscv_iommu_cmd; do
    rg -q "^${event}\\(" "${trace_events}"
done
rg -q 'riscv-iommu-pci' "${documentation}"

echo "RISC-V IOMMU device documentation and required trace events are present."
