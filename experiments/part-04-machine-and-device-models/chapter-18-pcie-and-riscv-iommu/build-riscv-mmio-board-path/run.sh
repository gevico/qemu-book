#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1

python3 -m unittest discover \
    -s "${script_dir}" \
    -p 'test_*.py' \
    -v
python3 "${script_dir}/verify_lab.py"
