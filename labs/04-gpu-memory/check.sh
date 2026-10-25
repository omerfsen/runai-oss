#!/usr/bin/env bash
# Lab 04: gpu-memory 4094 (25% of the card) -> the container sees 4094 MiB.
# Also records whether the 4096-MiB rounding bug is still present.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
cleanup() {
  k delete -f pod.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null
  k -n runai-team-a delete pod gpu-mem-4096 --ignore-not-found --wait=true --timeout=120s >/dev/null
}
trap cleanup EXIT

k apply -f pod.yaml >/dev/null
wait_phase runai-team-a gpu-mem Running 300 || { pending_reason runai-team-a gpu-mem; exit 1; }
until line=$(k -n runai-team-a logs gpu-mem 2>/dev/null) && [[ -n $line ]]; do sleep 2; done
seen=$(grep -oE '[0-9]+ MiB' <<<"$line" | grep -oE '[0-9]+')
echo "  container sees: $line"
(( seen == 4094 )) || { echo "FAIL: expected 4094 MiB, got $seen"; exit 1; }
k delete -f pod.yaml --wait=true >/dev/null

# Informational: does a non-whole-percentage value still fail to bind?
sed -e 's/name: gpu-mem$/name: gpu-mem-4096/' -e 's/"4094"/"4096"/' pod.yaml | k apply -f - >/dev/null
if wait_phase runai-team-a gpu-mem-4096 Running 60 2>/dev/null; then
  echo "  note: gpu-memory 4096 binds now: the rounding bug is fixed, update the README"
else
  echo "  note: gpu-memory 4096 still does not bind: $(pending_reason runai-team-a gpu-mem-4096 | grep -o 'NvFractions[^,]*' | head -1)"
fi
echo "PASS: gpu-memory 4094 gives the pod exactly $seen MiB"
