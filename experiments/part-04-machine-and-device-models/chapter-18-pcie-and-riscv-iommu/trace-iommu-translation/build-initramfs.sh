#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${script_dir}/build"
rootfs_dir="${build_dir}/rootfs"
cc="${RISCV_CC:-riscv64-linux-gnu-gcc}"

for tool in "${cc}" cpio; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "required tool not found: ${tool}" >&2
        exit 2
    fi
done

mkdir -p "${rootfs_dir}"
"${cc}" -O2 -static -Wall -Wextra -Werror \
    "${script_dir}/guest/iommu-dma-probe.c" \
    -o "${rootfs_dir}/iommu-dma-probe"

(
    cd "${rootfs_dir}"
    find . -print0 | cpio --null -o --format=newc \
        >"${build_dir}/iommu-dma-probe.cpio"
)

echo "Created ${build_dir}/iommu-dma-probe.cpio"
