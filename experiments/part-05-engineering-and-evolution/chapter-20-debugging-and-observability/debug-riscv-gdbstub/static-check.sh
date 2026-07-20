#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for relative_path in guest/start.S guest/linker.ld build.sh run.sh \
    verify-transcript.sh fixtures/gdb-success.txt fixtures/gdb-counter-unchanged.txt; do
    if [[ ! -f "${script_dir}/${relative_path}" ]]; then
        echo "missing fixture: ${relative_path}" >&2
        exit 1
    fi
done

for script in static-check.sh build.sh run.sh verify-transcript.sh; do
    bash -n "${script_dir}/${script}"
done

rg -q '^_start:' "${script_dir}/guest/start.S"
rg -q '^store_counter:' "${script_dir}/guest/start.S"
rg -q '^counter:' "${script_dir}/guest/start.S"
rg -q '0x80200000' "${script_dir}/guest/linker.ld"
rg -q -- '-machine virt' "${script_dir}/run.sh"
rg -q -- '-accel tcg' "${script_dir}/run.sh"
rg -q 'target remote' "${script_dir}/run.sh"
rg -q 'COUNTER_BEFORE=' "${script_dir}/run.sh"
rg -q 'S0_AT_STORE=' "${script_dir}/run.sh"
rg -q 'COUNTER_AFTER=' "${script_dir}/run.sh"

"${script_dir}/verify-transcript.sh" "${script_dir}/fixtures/gdb-success.txt" \
    >/dev/null
if "${script_dir}/verify-transcript.sh" \
    "${script_dir}/fixtures/gdb-counter-unchanged.txt" >/dev/null 2>&1; then
    echo "counter parser accepted an unchanged counter" >&2
    exit 1
fi

echo "static_check=passed"
echo "live_execution=not_run"
