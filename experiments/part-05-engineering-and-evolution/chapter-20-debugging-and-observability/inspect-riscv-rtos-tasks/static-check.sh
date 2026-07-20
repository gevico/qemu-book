#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for relative_path in README.md preflight.sh launch.sh rtos-tasks.gdb.in; do
    if [[ ! -f "${script_dir}/${relative_path}" ]]; then
        echo "missing fixture: ${relative_path}" >&2
        exit 1
    fi
done
for script in static-check.sh preflight.sh launch.sh; do
    bash -n "${script_dir}/${script}"
done

rg -q 'Target release: QEMU `v11\.1\.0`' "${script_dir}/README.md"
rg -q 'source-review baseline `v11\.1\.0-rc0`' "${script_dir}/README.md"
rg -q '^info threads$' "${script_dir}/rtos-tasks.gdb.in"
rg -q '^thread apply all info registers pc sp ra$' "${script_dir}/rtos-tasks.gdb.in"
rg -q 'pxCurrentTCB->pxTopOfStack' "${script_dir}/rtos-tasks.gdb.in"
rg -q 'stopped_layer=guest-cpu/rtos-scheduler' "${script_dir}/preflight.sh"
rg -q 'not_visible=' "${script_dir}/preflight.sh"
rg -q -- '-machine virt' "${script_dir}/launch.sh"
rg -q -- '-accel .*tcg' "${script_dir}/launch.sh"
rg -q -- '-gdb chardev:gdb0' "${script_dir}/launch.sh"
rg -q '^umask 077$' "${script_dir}/launch.sh"
rg -q 'RTOS_HARTS:-1' "${script_dir}/preflight.sh" "${script_dir}/launch.sh"
rg -q 'exit 77' "${script_dir}/preflight.sh" "${script_dir}/launch.sh"

if rg -n -- '-gdb tcp:|-s([[:space:]]|$)|0\.0\.0\.0' \
    "${script_dir}/launch.sh" "${script_dir}/rtos-tasks.gdb.in"; then
    echo "unsafe debugger listener found" >&2
    exit 1
fi

echo "static_check=passed"
echo "live_execution=not_run"
