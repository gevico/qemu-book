#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
qemu_src="${QEMU_SRC:-}"
fixture="${script_dir}/test-qemu-book-counter.c"

if [[ -z "${qemu_src}" ]]; then
    echo "QEMU_SRC must point to a QEMU v11.1.0 or v11.1.0-rc0 tree" >&2
    exit 2
fi

required_paths=(
    "include/qom/object.h"
    "qom/object.c"
    "tests/unit/meson.build"
)

for relative_path in "${required_paths[@]}"; do
    if [[ ! -e "${qemu_src}/${relative_path}" ]]; then
        echo "missing upstream path: ${relative_path}" >&2
        exit 1
    fi
done

required_symbols=(
    "OBJECT_DECLARE_SIMPLE_TYPE"
    "object_property_add_uint32_ptr"
    "object_property_get_uint"
    "object_property_set_uint"
    "instance_finalize"
)

for symbol in "${required_symbols[@]}"; do
    if ! rg -q --fixed-strings "${symbol}" "${fixture}"; then
        echo "fixture does not exercise ${symbol}" >&2
        exit 1
    fi
done

if ! rg -q "object_property_add_uint32_ptr" \
        "${qemu_src}/include/qom/object.h" "${qemu_src}/qom/object.c"; then
    echo "the selected QEMU tree does not provide the pointer property API" >&2
    exit 1
fi

if ! rg -q "'check-qom-proplist': \[qom\]" \
        "${qemu_src}/tests/unit/meson.build"; then
    echo "unexpected unit-test dependency layout; review Meson integration" >&2
    exit 1
fi

echo "QOM fixture matches the selected upstream API surface."
echo "Next: copy it into tests/unit/, add meson-snippet.build to the tests map,"
echo "then build and run tests/unit/test-qemu-book-counter in a disposable tree."
