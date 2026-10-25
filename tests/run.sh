#!/usr/bin/env bash
#
# Runs the feature tests one after another (there is one GPU, and each GPU
# test takes all of it). Every test is a Job that fails when its check fails.
#
#   tests/run.sh                 all tests
#   tests/run.sh tensorflow      only files matching "tensorflow"
#   CONTEXT=k3d-other tests/run.sh
set -uo pipefail

CONTEXT="${CONTEXT:-k3d-runai}"
NAMESPACE=runai-oss-tests
TIMEOUT="${TIMEOUT:-900}"          # seconds per test; first runs pull multi-GB images
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
k() { kubectl --context "$CONTEXT" "$@"; }

k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f - >/dev/null

results=()
failed=0
for file in "$HERE"/[0-9][0-9]-*.yaml; do
  [[ -n ${1:-} && $file != *"$1"* ]] && continue
  name=$(basename "$file" .yaml)
  job=$(k apply -f "$file" -o name | grep '^job' | cut -d/ -f2)
  printf '\n==> %s\n' "$name"

  start=$SECONDS
  status=TIMEOUT
  while (( SECONDS - start < TIMEOUT )); do
    s=$(k -n "$NAMESPACE" get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}')
    [[ $s == 1/* ]] && { status=PASS; break; }
    [[ $s == */1 ]] && { status=FAIL; break; }
    sleep 5
  done
  took=$((SECONDS - start))

  k -n "$NAMESPACE" logs "job/$job" --tail=6 2>/dev/null | sed 's/^/    /'
  if [[ $status != PASS ]]; then
    failed=1
    k -n "$NAMESPACE" get pods -l "job-name=$job" -o wide 2>/dev/null | sed 's/^/    /'
  fi
  printf '    %s (%ss)\n' "$status" "$took"
  results+=("$(printf '%-28s %-8s %5ss' "$name" "$status" "$took")")

  k delete -f "$file" --wait=true --timeout=120s >/dev/null 2>&1
done

printf '\n==> summary (%s)\n' "$CONTEXT"
printf '    %s\n' "${results[@]}"
exit "$failed"
