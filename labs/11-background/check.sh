#!/usr/bin/env bash
# Lab 11: a background Deployment runs on the idle GPU, is evicted when team-a
# claims its half, and comes back when team-a is done.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f background.yaml -f foreground.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

project_create batch 0
running_bg() {  # name of the Running background pod, if any
  k -n runai-batch get pods -l app=background --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
wait_bg() { for _ in $(seq 1 80); do bg=$(running_bg); [[ -n $bg ]] && return 0; sleep 3; done; return 1; }

k apply -f background.yaml >/dev/null
wait_bg || { echo "FAIL: background pod never ran on the idle GPU"; exit 1; }
first=$bg
echo "  idle GPU: background pod $first Running"

k apply -f foreground.yaml >/dev/null
wait_phase runai-team-a foreground Running 300 || { pending_reason runai-team-a foreground; exit 1; }
uid=$(k -n runai-team-a get pod foreground -o jsonpath='{.metadata.uid}')
why=$(k -n runai-batch get events -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' \
  | grep "^Evict: Pod runai-batch/$first was preempted by workload runai-team-a/pg-foreground-$uid" | tail -1 || true)
[[ -n $why ]] || { echo "FAIL: background pod was not evicted for team-a"; exit 1; }
echo "  $why"

k delete -f foreground.yaml --wait=true >/dev/null
wait_bg || { echo "FAIL: background did not come back after team-a finished"; exit 1; }
echo "  team-a done: background pod $bg Running again"
echo "PASS: background work used only idle GPU time"
