#!/usr/bin/env bash

set -euo pipefail

book_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
minimum_han="${CHAPTER_MIN_HAN:-3000}"
minimum_experiments="${CHAPTER_MIN_EXPERIMENTS:-2}"
minimum_experiment_links="${CHAPTER_MIN_EXPERIMENT_LINKS:-2}"
minimum_book_han="${BOOK_MIN_HAN:-300000}"
enforce=false

if [[ "${1:-}" == "--enforce" ]]; then
    enforce=true
fi

status=0
book_han_count=0

for chapter_number in $(seq 1 26); do
    chapter_file="${book_dir}/chapter${chapter_number}.md"

    if [[ ! -f "${chapter_file}" ]]; then
        printf 'missing chapter%d.md\n' "${chapter_number}" >&2
        status=1
        continue
    fi

    han_count="$({
        perl -CSDA -ne '
            if (/^\s*```/) {
                $in_code = !$in_code;
                next;
            }
            next if $in_code;
            next if /^\s*(?:#|:{3,}|\\)/;
            s{https?://\S+}{}g;
            $count += () = /\p{Han}/g;
            END { print $count // 0; }
        ' "${chapter_file}"
    })"
    experiment_count="$(rg -c '^::: \{\.hands-on\}$' "${chapter_file}" || true)"
    experiment_links="$(
        rg -o '\.\./experiments/part-[^/ )]+/chapter-[^/ )]+/[^/ )]+/README\.md' \
            "${chapter_file}" | LC_ALL=C sort -u || true
    )"
    experiment_link_count="$(printf '%s\n' "${experiment_links}" | sed '/^$/d' | wc -l | tr -d ' ')"
    book_han_count=$((book_han_count + han_count))

    printf 'chapter%-2d  han=%-5d  experiments=%d  manual-links=%d\n' \
        "${chapter_number}" "${han_count}" "${experiment_count}" \
        "${experiment_link_count}"

    while IFS= read -r experiment_link; do
        [[ -z "${experiment_link}" ]] && continue
        if [[ ! -f "${book_dir}/${experiment_link}" ]]; then
            printf 'chapter%d has missing experiment manual: %s\n' \
                "${chapter_number}" "${experiment_link}" >&2
            status=1
        fi
    done <<<"${experiment_links}"

    if (( han_count < minimum_han ||
          experiment_count < minimum_experiments ||
          experiment_link_count < minimum_experiment_links )); then
        status=1
    fi
done

printf 'book total  han=%d  required=%d\n' "${book_han_count}" "${minimum_book_han}"

if (( book_han_count < minimum_book_han )); then
    status=1
fi

if [[ "${enforce}" == true && "${status}" -ne 0 ]]; then
    printf 'content gate failed: each chapter needs at least %d Han characters, %d experiments, and %d experiment manual links; chapters need at least %d Han characters in total\n' \
        "${minimum_han}" "${minimum_experiments}" \
        "${minimum_experiment_links}" "${minimum_book_han}" >&2
    exit 1
fi
