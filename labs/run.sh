#!/usr/bin/env bash
#
# Runs every lab's check.sh in order (one GPU: labs never overlap) and prints
# a summary. Exit code non-zero if any lab failed.
#
#   labs/run.sh            all labs
#   labs/run.sh 07         only labs whose folder matches "07"
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

results=()
failed=0
for dir in "$HERE"/[0-9][0-9]-*/; do
  name=$(basename "$dir")
  [[ -n ${1:-} && $name != *"$1"* ]] && continue
  printf '\n==> %s\n' "$name"
  start=$SECONDS
  if timeout 1800 "$dir/check.sh"; then status=PASS; else status=FAIL; failed=1; fi
  results+=("$(printf '%-28s %-5s %5ss' "$name" "$status" "$((SECONDS - start))")")
done

printf '\n==> summary\n'
printf '    %s\n' "${results[@]}"
exit "$failed"
