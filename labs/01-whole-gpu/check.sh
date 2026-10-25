#!/usr/bin/env bash
# Lab 01: a plain Job with nvidia.com/gpu: 1 is scheduled by runai-scheduler.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f job.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

k apply -f job.yaml >/dev/null
until pod=$(k -n runai-team-a get pod -l job-name=whole-gpu -o name 2>/dev/null) && [[ -n $pod ]]; do sleep 2; done
pod=${pod#pod/}
wait_phase runai-team-a "$pod" Running 300 || wait_phase runai-team-a "$pod" Succeeded 5

sched=$(k -n runai-team-a get pod "$pod" -o jsonpath='{.spec.schedulerName}')
gpus=$(k -n runai-team-a get pod "$pod" -o jsonpath='{.metadata.annotations.runai-allocated-gpus}')
[[ $sched == runai-scheduler ]] || { echo "FAIL: schedulerName is '$sched'"; exit 1; }
[[ $gpus == 1 ]] || { echo "FAIL: runai-allocated-gpus is '$gpus', expected 1"; exit 1; }
pg=$(k -n runai-team-a get podgroups.scheduling.run.ai -o json \
  | jq -r '.items[] | select(.metadata.name | startswith("pg-whole-gpu-")) | "\(.spec.priorityClassName)/\(.spec.preemptibility)"')
echo "  PodGroup: priority/preemptibility = $pg"
k -n runai-team-a logs "$pod" | sed 's/^/  /'
echo "PASS: plain Job scheduled by $sched with $gpus GPU (team-a borrows over its 0.5 quota)"
