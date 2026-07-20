#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for relative_path in README.md preflight.sh launch.sh kernel.gdb.in; do
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
rg -q 'nokaslr' "${script_dir}/kernel.gdb.in" "${script_dir}/launch.sh"
rg -q 'hbreak \*KERNEL_PHYSICAL_ENTRY' "${script_dir}/kernel.gdb.in"
rg -q 'handle_exception' "${script_dir}/kernel.gdb.in"
rg -q '\$scause' "${script_dir}/kernel.gdb.in"
rg -q 'stopped_layer=guest-cpu/kernel-boundary' "${script_dir}/preflight.sh"
rg -q 'not_visible=' "${script_dir}/preflight.sh"
rg -q -- '-gdb chardev:gdb0' "${script_dir}/launch.sh"
rg -q 'socket,path=' "${script_dir}/launch.sh"
rg -q '^umask 077$' "${script_dir}/launch.sh"
rg -q 'exit 77' "${script_dir}/preflight.sh" "${script_dir}/launch.sh"

if rg -n -- '-gdb tcp:|-s([[:space:]]|$)|0\.0\.0\.0' \
    "${script_dir}/launch.sh" "${script_dir}/kernel.gdb.in"; then
    echo "unsafe debugger listener found" >&2
    exit 1
fi

echo "static_check=passed"
echo "live_execution=not_run"
