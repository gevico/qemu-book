#!/usr/bin/env bash

set -euo pipefail

book_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chapter_count="${BOOK_CHAPTER_COUNT:-23}"
minimum_han="${CHAPTER_MIN_HAN:-2500}"
minimum_experiments="${CHAPTER_MIN_EXPERIMENTS:-1}"
minimum_experiment_links="${CHAPTER_MIN_EXPERIMENT_LINKS:-1}"
minimum_quizzes="${CHAPTER_MIN_QUIZZES:-2}"
maximum_h2="${CHAPTER_MAX_H2:-16}"
enforce=false

if [[ "${1:-}" == "--enforce" ]]; then
    enforce=true
fi

status=0
book_han_count=0

for chapter_number in $(seq 1 "${chapter_count}"); do
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
    quiz_count="$(rg -c '^:{4} \{\.quick-quiz\}$' "${chapter_file}" || true)"
    h2_count="$(rg -c '^## ' "${chapter_file}" || true)"
    experiment_count="${experiment_count:-0}"
    quiz_count="${quiz_count:-0}"
    h2_count="${h2_count:-0}"
    experiment_links="$(
        rg -o '\.\./experiments/part-[^/ )]+/chapter-[^/ )]+/[^/ )]+/README\.md' \
            "${chapter_file}" | LC_ALL=C sort -u || true
    )"
    experiment_link_count="$(printf '%s\n' "${experiment_links}" | sed '/^$/d' | wc -l | tr -d ' ')"
    book_han_count=$((book_han_count + han_count))

    printf 'chapter%-2d  han=%-5d  h2=%-2d  quizzes=%d  experiments=%d  manual-links=%d\n' \
        "${chapter_number}" "${han_count}" "${h2_count}" \
        "${quiz_count}" "${experiment_count}" "${experiment_link_count}"

    while IFS= read -r experiment_link; do
        [[ -z "${experiment_link}" ]] && continue
        if [[ ! -f "${book_dir}/${experiment_link}" ]]; then
            printf 'chapter%d has missing experiment manual: %s\n' \
                "${chapter_number}" "${experiment_link}" >&2
            status=1
        fi
    done <<<"${experiment_links}"

    if (( han_count < minimum_han || h2_count > maximum_h2 ||
          quiz_count < minimum_quizzes ||
          experiment_count < minimum_experiments ||
          experiment_link_count < minimum_experiment_links )); then
        status=1
    fi
done

printf 'book total  han=%d  chapters=%d\n' "${book_han_count}" "${chapter_count}"

if [[ "${enforce}" == true && "${status}" -ne 0 ]]; then
    printf 'content gate failed: each chapter needs at least %d Han characters, no more than %d level-two headings, %d thought questions, %d verification exercise, and %d experiment manual link\n' \
        "${minimum_han}" "${maximum_h2}" \
        "${minimum_quizzes}" "${minimum_experiments}" \
        "${minimum_experiment_links}" >&2
    exit 1
fi
