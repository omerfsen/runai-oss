#!/usr/bin/env bash
# Lab 05: with gpu-fraction 0.25, 2 GiB allocates and 6 GiB is refused.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f pod.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

k apply -f pod.yaml >/dev/null
wait_phase runai-team-a isolation Succeeded 600 || { pending_reason runai-team-a isolation; k -n runai-team-a logs isolation 2>/dev/null; exit 1; }
out=$(k -n runai-team-a logs isolation)
sed 's/^/  /' <<<"$out"
grep -q 'allocate 2 GiB: OK' <<<"$out" || { echo "FAIL: 2 GiB should fit in a quarter GPU"; exit 1; }
grep -q 'allocate 6 GiB: CUDA out of memory' <<<"$out" || { echo "FAIL: 6 GiB was not refused: no isolation"; exit 1; }
echo "PASS: the driver held the pod to its quarter of the GPU"
