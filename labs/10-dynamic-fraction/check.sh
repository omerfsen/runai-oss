#!/usr/bin/env bash
# Lab 10: request 4G / limit 8G -> 6 GiB (burst) allocates, 10 GiB is refused.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f pod.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

k apply -f pod.yaml >/dev/null
wait_phase runai-team-a burst Succeeded 600 || { pending_reason runai-team-a burst; exit 1; }
out=$(k -n runai-team-a logs burst | grep -v CUDACachingAllocator)
sed 's/^/  /' <<<"$out"
grep -q 'allocate 6 GiB: OK' <<<"$out" || { echo "FAIL: could not burst above the 4G request"; exit 1; }
grep -q 'allocate 10 GiB: CUDA out of memory' <<<"$out" || { echo "FAIL: the 8G limit was not enforced"; exit 1; }
echo "PASS: burst above the request, capped at the limit"
