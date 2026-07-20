#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"

if [[ -z "${qemu_src}" ]] || \
   ! git -C "${qemu_src}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "QEMU_SRC must point to a QEMU Git worktree" >&2
    exit 2
fi
mkdir -p "${results_dir}"
{
    "${script_dir}/../../../tools/source-report.sh"
    printf '\n[virtio control path]\n'
    rg -n 'virtio_queue_notify|virtqueue_pop|virtqueue_push|virtio_set_status' \
        "${qemu_src}/hw/virtio"
    printf '\n[vhost delegation path]\n'
    rg -n -m 100 'vhost_dev_start|vhost_dev_stop|VHOST_SET_|vhost_set_' \
        "${qemu_src}/hw/virtio/vhost.c" "${qemu_src}/hw/net/vhost_net.c"
    printf '\n[migration boundary]\n'
    rg -n 'VMStateDescription|vmstate|migration' \
        "${qemu_src}/hw/net/virtio-net.c" "${qemu_src}/hw/virtio/vhost.c"
} >"${results_dir}/control-data-boundary.txt"
echo "Recorded virtio control and vhost delegation source boundaries."
