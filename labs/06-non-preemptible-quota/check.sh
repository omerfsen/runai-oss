#!/usr/bin/env bash
# Lab 06: a second non-preemptible pod over quota is refused even with free
# GPU; the same request marked preemptible runs.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f pods.yaml -f preemptible.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

k apply -f pods.yaml >/dev/null
wait_phase runai-team-b np-first Running 300
sleep 15
[[ $(k -n runai-team-b get pod np-second -o jsonpath='{.status.phase}') == Pending ]] \
  || { echo "FAIL: np-second should be Pending (team-b at quota)"; exit 1; }
reason=$(pending_reason runai-team-b np-second | grep -o 'NonPreemptibleOverQuota[^.]*' | head -1)
[[ -n $reason ]] || { echo "FAIL: expected NonPreemptibleOverQuota, got: $(pending_reason runai-team-b np-second)"; exit 1; }
echo "  np-second Pending: $reason"

k -n runai-team-b delete pod np-second --wait=true >/dev/null
k apply -f preemptible.yaml >/dev/null
wait_phase runai-team-b p-second Running 180 || { pending_reason runai-team-b p-second; exit 1; }
echo "  p-second (preemptible) Running: borrows the idle half over team-b's quota"
echo "PASS: non-preemptible stays within quota; preemptible may borrow"
