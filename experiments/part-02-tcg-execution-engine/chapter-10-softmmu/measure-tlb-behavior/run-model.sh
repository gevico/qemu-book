#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"

mkdir -p "${results_dir}"
(
    cd "${script_dir}"
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_tlb_index_model.py
)
PYTHONDONTWRITEBYTECODE=1 python3 "${script_dir}/tlb_index_model.py" \
    | tee "${results_dir}/modeled-counts.csv"

if [[ -n "${QEMU_SRC:-}" ]]; then
    "${script_dir}/check-upstream.sh"
fi
