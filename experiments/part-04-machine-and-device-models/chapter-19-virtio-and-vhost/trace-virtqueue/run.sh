#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"
kernel="${GUEST_KERNEL:-}"
disk="${GUEST_DISK:-}"
disk_format="${GUEST_DISK_FORMAT:-qcow2}"
guest_request_marker="${GUEST_REQUEST_MARKER:-}"

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
if [[ -z "${guest_request_marker}" ]]; then
    echo "GUEST_REQUEST_MARKER must identify the controlled guest request" >&2
    exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "GNU timeout is required" >&2
    exit 2
fi
mkdir -p "${results_dir}"
"${qemu}" -trace help >"${results_dir}/trace-help.txt"
events=(virtqueue_pop virtqueue_fill virtqueue_flush virtio_queue_notify virtio_notify virtio_blk_handle_read virtio_blk_handle_write virtio_blk_req_complete)
trace_args=()
selected_events=()
for event in "${events[@]}"; do
    if rg -q "^${event}$" "${results_dir}/trace-help.txt"; then
        trace_args+=( -trace "enable=${event}" )
        selected_events+=( "${event}" )
    fi
done
if (( ${#trace_args[@]} == 0 )); then
    echo "no selected virtqueue event is available" >&2
    exit 1
fi
printf '%s\n' "${selected_events[@]}" >"${results_dir}/selected-events.txt"

set +e
timeout "${TRACE_SECONDS:-45}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -smp 2 -m 1G \
    -kernel "${kernel}" -append 'console=ttyS0' \
    -drive "file=${disk},if=none,id=disk0,format=${disk_format},snapshot=on" \
    -device virtio-blk-pci,drive=disk0 \
    -display none -serial stdio -monitor none -no-reboot \
    "${trace_args[@]}" -trace "file=${results_dir}/virtqueue.trace" \
    >"${results_dir}/serial.log" 2>"${results_dir}/qemu.stderr"
qemu_exit_code=$?
set -e
echo "${qemu_exit_code}" >"${results_dir}/status.txt"
if (( qemu_exit_code != 0 && qemu_exit_code != 124 )); then
    echo "QEMU failed before the bounded virtqueue trace ended (status ${qemu_exit_code})" >&2
    exit 1
fi
test -s "${results_dir}/virtqueue.trace"
if ! rg -F -q -- "${guest_request_marker}" "${results_dir}/serial.log"; then
    echo "the controlled guest request marker was not observed" >&2
    exit 1
fi
if ! rg -q 'virtqueue_pop|virtio_blk_handle_(read|write)' \
        "${results_dir}/virtqueue.trace"; then
    echo "the trace contains no request-acquisition event" >&2
    exit 1
fi
if ! rg -q 'virtio_blk_req_complete|virtqueue_(fill|flush)' \
        "${results_dir}/virtqueue.trace"; then
    echo "the trace contains no request-completion event" >&2
    exit 1
fi
echo "Captured both acquisition and completion sides of one controlled request."
