#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"
kernel="${GUEST_KERNEL:-}"
disk="${GUEST_DISK:-}"
disk_format="${GUEST_DISK_FORMAT:-qcow2}"

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
for guest_file in "${kernel}" "${disk}"; do
    if [[ -z "${guest_file}" || ! -f "${guest_file}" ]]; then
        echo "GUEST_KERNEL and GUEST_DISK must name files" >&2
        exit 2
    fi
done
if ! command -v timeout >/dev/null 2>&1; then
    echo "GNU timeout is required" >&2
    exit 2
fi
mkdir -p "${results_dir}"
"${qemu}" -trace help >"${results_dir}/trace-help.txt"
events=(virtqueue_pop virtqueue_fill virtqueue_flush virtio_queue_notify virtio_notify virtio_blk_handle_read virtio_blk_handle_write virtio_blk_req_complete)
trace_args=()
for event in "${events[@]}"; do
    if rg -q "^${event}$" "${results_dir}/trace-help.txt"; then
        trace_args+=( -trace "enable=${event}" )
    fi
done
if (( ${#trace_args[@]} == 0 )); then
    echo "no selected virtqueue event is available" >&2
    exit 1
fi

set +e
timeout "${TRACE_SECONDS:-45}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -smp 2 -m 1G \
    -kernel "${kernel}" -append 'console=ttyS0' \
    -drive "file=${disk},if=none,id=disk0,format=${disk_format},snapshot=on" \
    -device virtio-blk-pci,drive=disk0 \
    -display none -serial stdio -monitor none -no-reboot \
    "${trace_args[@]}" -trace "file=${results_dir}/virtqueue.trace" \
    >"${results_dir}/serial.log" 2>"${results_dir}/qemu.stderr"
status=$?
set -e
echo "${status}" >"${results_dir}/status.txt"
test -s "${results_dir}/virtqueue.trace"
echo "Captured available virtqueue and virtio-blk ownership transitions."
