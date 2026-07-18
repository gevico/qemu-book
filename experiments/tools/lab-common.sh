#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

lab_die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

lab_skip()
{
    printf 'SKIP: %s\n' "$*"
    exit 77
}

lab_require_command()
{
    local command_name="$1"

    command -v "${command_name}" >/dev/null 2>&1 ||
        lab_die "required command is unavailable: ${command_name}"
}

lab_require_directory()
{
    local variable_name="$1"
    local variable_value="${!variable_name:-}"

    [[ -n "${variable_value}" ]] ||
        lab_die "set ${variable_name} to an absolute directory"
    [[ -d "${variable_value}" ]] ||
        lab_die "${variable_name} is not a directory: ${variable_value}"
}

lab_qemu_binary()
{
    local qemu_binary="${QEMU_SYSTEM_RISCV64:-${QEMU_BUILD:-}/qemu-system-riscv64}"

    [[ -x "${qemu_binary}" ]] ||
        lab_die "qemu-system-riscv64 is unavailable: ${qemu_binary}"
    printf '%s\n' "${qemu_binary}"
}

lab_results_directory()
{
    local project_dir="$1"
    local results_dir="${project_dir}/results"

    mkdir -p "${results_dir}"
    printf '%s\n' "${results_dir}"
}

lab_record_command()
{
    local output_file="$1"
    shift

    {
        printf 'command:'
        printf ' %q' "$@"
        printf '\n'
    } >"${output_file}"
}
