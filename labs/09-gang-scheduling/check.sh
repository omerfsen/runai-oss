#!/usr/bin/env bash
# Lab 09: a 2-pod gang at 0.6 GPU each never half-starts; at 0.5 each both run.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f gang-too-big.yaml -f gang-fits.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1' EXIT

k apply -f gang-too-big.yaml >/dev/null
sleep 30
for p in worker-0 worker-1; do
  ph=$(k -n runai-team-a get pod "$p" -o jsonpath='{.status.phase}')
  [[ $ph == Pending ]] || { echo "FAIL: $p is $ph: the gang half-started"; exit 1; }
done
msg=$(pending_reason runai-team-a trainers podgroups.scheduling.run.ai \
  | grep -o 'Resources were found for [0-9]* pods while [0-9]* are required for gang scheduling' | tail -1 || true)
[[ -n $msg ]] || { echo "FAIL: no gang-scheduling event on PodGroup trainers"; exit 1; }
echo "  0.6 + 0.6: both Pending: $msg"

k delete -f gang-too-big.yaml --wait=true >/dev/null
k apply -f gang-fits.yaml >/dev/null
wait_phase runai-team-a worker-0 Running 300
wait_phase runai-team-a worker-1 Running 60
t0=$(k -n runai-team-a get pod worker-0 -o jsonpath='{.status.startTime}')
t1=$(k -n runai-team-a get pod worker-1 -o jsonpath='{.status.startTime}')
echo "  0.5 + 0.5: both Running (start times $t0 / $t1)"
echo "PASS: the gang started all-or-nothing"
