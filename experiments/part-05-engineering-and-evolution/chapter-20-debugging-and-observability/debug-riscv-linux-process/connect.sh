#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if preflight_output="$("${script_dir}/preflight.sh" 2>&1)"; then
    preflight_status=0
else
    preflight_status=$?
fi
printf '%s\n' "${preflight_output}"
if (( preflight_status != 0 )); then
    exit "${preflight_status}"
fi
if ! rg -q '^preflight=ready$' <<<"${preflight_output}"; then
    echo "preflight returned success without a ready record" >&2
    exit 1
fi
if [[ "${RUN_LIVE:-0}" != 1 ]]; then
    echo "SKIP: set RUN_LIVE=1 only after the guest gdbserver and SSH tunnel are ready"
    exit 77
fi

endpoint="${GDBSERVER_ENDPOINT:-127.0.0.1:1234}"
if [[ ! "${endpoint}" =~ ^127\.0\.0\.1:[1-9][0-9]{0,4}$ && \
      ! "${endpoint}" =~ ^\[::1\]:[1-9][0-9]{0,4}$ ]]; then
    echo "refusing non-loopback GDBSERVER_ENDPOINT: ${endpoint}" >&2
    exit 2
fi
endpoint_port="${endpoint##*:}"
if (( endpoint_port > 65535 )); then
    echo "refusing invalid GDBSERVER_ENDPOINT port: ${endpoint_port}" >&2
    exit 2
fi

gdb="${RISCV_GDB:-}"
if [[ -z "${gdb}" ]]; then
    for candidate in riscv64-linux-gnu-gdb gdb-multiarch; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            gdb="${candidate}"
            break
        fi
    done
fi
if [[ -z "${gdb}" ]]; then
    echo "SKIP: no RISC-V-capable GDB is available"
    exit 77
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
results_dir="${script_dir}/results/${run_id}"
mkdir -p "${results_dir}"
printf '%s\n' "${preflight_output}" >"${results_dir}/manifest.txt"
{
    echo "connection_requested=true"
    echo "connection_result=inspect-gdb-log"
} >>"${results_dir}/manifest.txt"

gdb_args=(
    -nx
    -q
    "${RISCV_USER_ELF}"
    -ex "set pagination off"
    -ex "set print thread-events on"
    -ex "set logging file \"${results_dir}/gdb.log\""
    -ex "set logging overwrite on"
    -ex "set logging enabled on"
)
if [[ -n "${RISCV_SYSROOT:-}" ]]; then
    gdb_args+=( -ex "set sysroot \"${RISCV_SYSROOT}\"" )
    gdb_args+=( -ex "set solib-search-path \"${RISCV_SYSROOT}/lib:${RISCV_SYSROOT}/usr/lib\"" )
fi
gdb_args+=(
    -ex "target remote ${endpoint}"
    -ex "info inferiors"
    -ex "info threads"
    -ex "info sharedlibrary"
)

echo "Starting interactive guest-process GDB; this is not a QEMU gdbstub session."
echo "manifest=${results_dir}/manifest.txt"
exec "${gdb}" "${gdb_args[@]}"
