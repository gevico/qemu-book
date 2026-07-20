#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"
image="${RISCV_GUEST_IMAGE:-}"
expected_image_sha256="${EXPECTED_IMAGE_SHA256:-}"
guest_workload_marker="${GUEST_WORKLOAD_MARKER:-}"

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
if [[ -z "${image}" || ! -f "${image}" ]]; then
    echo "RISCV_GUEST_IMAGE must name a guest image" >&2
    exit 2
fi
if [[ -z "${expected_image_sha256}" || \
      ! "${expected_image_sha256}" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "EXPECTED_IMAGE_SHA256 must be the guest image's 64-digit SHA-256" >&2
    exit 2
fi
if [[ -z "${guest_workload_marker}" ]]; then
    echo "GUEST_WORKLOAD_MARKER must identify successful guest progress" >&2
    exit 2
fi
for tool in perf timeout rg; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "required profiling tool not found: ${tool}" >&2
        exit 2
    }
done
if command -v sha256sum >/dev/null 2>&1; then
    image_hash_output="$(sha256sum "${image}")"
elif command -v shasum >/dev/null 2>&1; then
    image_hash_output="$(shasum -a 256 "${image}")"
else
    echo "sha256sum or shasum is required" >&2
    exit 2
fi
actual_image_sha256="${image_hash_output%% *}"
if [[ "${actual_image_sha256,,}" != "${expected_image_sha256,,}" ]]; then
    echo "RISCV_GUEST_IMAGE does not match EXPECTED_IMAGE_SHA256" >&2
    exit 1
fi
mkdir -p "${results_dir}"
"${qemu}" --version >"${results_dir}/qemu-version.txt"
printf '%s  %s\n' "${actual_image_sha256}" "${image}" \
    >"${results_dir}/guest-image.sha256"

for run_number in 1 2 3; do
    qemu_command=(
        "${qemu}"
        -machine virt -cpu rv64 -accel tcg -smp 1 -m 256M
        -bios none -kernel "${image}" -display none
        -serial "file:${results_dir}/serial-${run_number}.log" -monitor none
    )
    {
        printf 'perf record -q -F 99 -g -o %q -- timeout %q' \
            "${results_dir}/perf-${run_number}.data" "${PROFILE_SECONDS:-10}"
        printf ' %q' "${qemu_command[@]}"
        printf '\n'
    } >"${results_dir}/command-${run_number}.txt"
    set +e
    perf record -q -F 99 -g -o "${results_dir}/perf-${run_number}.data" -- \
        timeout "${PROFILE_SECONDS:-10}" "${qemu_command[@]}" \
        2>"${results_dir}/run-${run_number}.stderr"
    profile_exit_code=$?
    set -e
    echo "${profile_exit_code}" >"${results_dir}/run-${run_number}.status"
    if (( profile_exit_code != 0 && profile_exit_code != 124 )); then
        echo "profiling run ${run_number} failed (status ${profile_exit_code})" >&2
        exit 1
    fi
    test -s "${results_dir}/perf-${run_number}.data"
    if ! rg -F -q -- "${guest_workload_marker}" \
            "${results_dir}/serial-${run_number}.log"; then
        echo "guest progress marker missing from profiling run ${run_number}" >&2
        exit 1
    fi
    perf report --stdio -i "${results_dir}/perf-${run_number}.data" \
        >"${results_dir}/report-${run_number}.txt"
done

echo "Captured three bounded sampling profiles; interpret variance before design."
