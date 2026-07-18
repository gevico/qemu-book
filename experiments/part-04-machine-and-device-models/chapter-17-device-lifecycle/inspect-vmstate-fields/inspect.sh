#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"
serial="${qemu_src}/hw/char/serial.c"

if [[ -z "${qemu_src}" || ! -f "${serial}" ]]; then
    echo "QEMU_SRC must point to the fixed QEMU source tree" >&2
    exit 2
fi
mkdir -p "${results_dir}"
{
    "${script_dir}/../../../tools/source-report.sh"
    printf '\n[device state and reset]\n'
    rg -n 'struct SerialState|serial_reset|serial_ioport' \
        "${qemu_src}/include/hw/char/serial.h" "${serial}"
    printf '\n[VMState descriptions]\n'
    rg -n -A90 'VMStateDescription vmstate_serial' "${serial}"
    printf '\n[hooks and subsections]\n'
    rg -n 'pre_save|post_load|subsections|version_id|minimum_version_id' "${serial}"
} >"${results_dir}/vmstate-audit.txt"

echo "Wrote a UART state/reset/VMState evidence inventory."
