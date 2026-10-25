#!/usr/bin/env bash
# Lab 08: a build (100) pod evicts a train (50) pod in the same project when
# the card is full.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f pods.yaml -f high.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

k apply -f pods.yaml >/dev/null
wait_phase runai-team-b blocker Running 300
wait_phase runai-team-a low-prio Running 300
echo "  card full: team-b blocker (0.5, non-preemptible) + team-a low-prio (0.5, train)"

k apply -f high.yaml >/dev/null
wait_phase runai-team-a high-prio Running 300 || { pending_reason runai-team-a high-prio; exit 1; }
# Pod names repeat between runs; the PodGroup name carries this pod's UID, so
# match on it to ignore events left over from an earlier run.
uid=$(k -n runai-team-a get pod high-prio -o jsonpath='{.metadata.uid}')
why=$(k -n runai-team-a get events -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' \
  | grep "^Evict: Pod runai-team-a/low-prio was preempted by higher priority workload runai-team-a/pg-high-prio-$uid" | tail -1 || true)
[[ -n $why ]] || { echo "FAIL: low-prio was not preempted for priority"; exit 1; }
echo "  $why"
echo "PASS: higher priority preempted lower priority inside team-a"
