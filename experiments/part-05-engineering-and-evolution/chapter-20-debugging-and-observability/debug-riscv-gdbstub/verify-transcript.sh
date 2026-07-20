#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

transcript="${1:-}"
if [[ -z "${transcript}" || ! -f "${transcript}" ]]; then
    echo "usage: $0 /path/to/gdb.txt" >&2
    exit 2
fi

extract_one() {
    local marker="$1"
    local count
    local value

    count="$(rg -c "^${marker}=[0-9]+$" "${transcript}" || true)"
    if [[ "${count:-0}" != 1 ]]; then
        echo "expected one numeric ${marker} marker, found ${count:-0}" >&2
        return 1
    fi
    value="$(sed -n "s/^${marker}=//p" "${transcript}")"
    printf '%s\n' "${value}"
}

rg -q 'Breakpoint .*store_counter' "${transcript}"
before="$(extract_one COUNTER_BEFORE)"
s0_at_store="$(extract_one S0_AT_STORE)"
after="$(extract_one COUNTER_AFTER)"
before_line="$(rg -n '^COUNTER_BEFORE=[0-9]+$' "${transcript}" | cut -d: -f1)"
s0_line="$(rg -n '^S0_AT_STORE=[0-9]+$' "${transcript}" | cut -d: -f1)"
after_line="$(rg -n '^COUNTER_AFTER=[0-9]+$' "${transcript}" | cut -d: -f1)"

if [[ "${before}" != 0 ]]; then
    echo "first counter value must be zero, got ${before}" >&2
    exit 1
fi
if [[ "${s0_at_store}" != 1 ]]; then
    echo "first store must use s0=1, got ${s0_at_store}" >&2
    exit 1
fi
if [[ "${after}" == "${before}" ]]; then
    echo "counter did not change after stepi" >&2
    exit 1
fi
if [[ "${after}" != "${s0_at_store}" ]]; then
    echo "counter ${after} does not match s0 ${s0_at_store}" >&2
    exit 1
fi
if (( before_line >= s0_line || s0_line >= after_line )); then
    echo "counter markers are not in before/register/after order" >&2
    exit 1
fi

echo "transcript_check=passed"
