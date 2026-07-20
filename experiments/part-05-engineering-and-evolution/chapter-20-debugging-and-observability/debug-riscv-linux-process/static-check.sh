#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for relative_path in README.md preflight.sh connect.sh \
    guest-gdbserver.sh.in process.gdb.in; do
    if [[ ! -f "${script_dir}/${relative_path}" ]]; then
        echo "missing fixture: ${relative_path}" >&2
        exit 1
    fi
done
for script in static-check.sh preflight.sh connect.sh; do
    bash -n "${script_dir}/${script}"
done

rg -q 'Target release: QEMU `v11\.1\.0`' "${script_dir}/README.md"
rg -q 'source-review baseline `v11\.1\.0-rc0`' "${script_dir}/README.md"
rg -q '127\.0\.0\.1:2345' "${script_dir}/guest-gdbserver.sh.in"
rg -q '^info threads$' "${script_dir}/process.gdb.in"
rg -q '^info sharedlibrary$' "${script_dir}/process.gdb.in"
rg -q 'thread apply all bt' "${script_dir}/process.gdb.in"
rg -q 'stopped_layer=guest-linux-process' "${script_dir}/preflight.sh"
rg -q 'not_visible=' "${script_dir}/preflight.sh"
rg -q 'RUN_LIVE' "${script_dir}/connect.sh"
rg -q '^umask 077$' "${script_dir}/connect.sh"
rg -q 'exit 77' "${script_dir}/preflight.sh" "${script_dir}/connect.sh"

if rg -n '0\.0\.0\.0|\[::\]:' "${script_dir}"/{connect.sh,guest-gdbserver.sh.in,process.gdb.in}; then
    echo "non-loopback debugger listener found" >&2
    exit 1
fi

echo "static_check=passed"
echo "live_execution=not_run"
