#!/usr/bin/env bash
# Lab 02: gpu-fraction 0.5 -> the container sees half of the GPU's memory.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f pod.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

total=$(k get nodes -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.memory}')
k apply -f pod.yaml >/dev/null
wait_phase runai-team-a half-gpu Running 300 || { pending_reason runai-team-a half-gpu; exit 1; }
until line=$(k -n runai-team-a logs half-gpu 2>/dev/null) && [[ -n $line ]]; do sleep 2; done
seen=$(grep -oE '[0-9]+ MiB' <<<"$line" | grep -oE '[0-9]+')
echo "  container sees: $line (physical: $total MiB)"
(( seen * 100 / total >= 45 && seen * 100 / total <= 55 )) \
  || { echo "FAIL: expected about half of $total MiB, container sees $seen MiB"; exit 1; }
[[ $(k -n runai-team-a get pod half-gpu -o jsonpath='{.metadata.annotations.runai-allocated-gpus}') == 0.5 ]] \
  || { echo "FAIL: runai-allocated-gpus is not 0.5"; exit 1; }
echo "PASS: gpu-fraction 0.5 gives the pod $seen of $total MiB"
