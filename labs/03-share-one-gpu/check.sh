#!/usr/bin/env bash
# Lab 03: two 0.5 pods from two projects share one GPU; a third waits, then
# starts when one finishes.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f pods.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

uuid() { k -n "$1" get pod "$2" -o jsonpath='{.metadata.annotations.nvidia\.com/container\.cuda\.gpus\.devices}'; }

k apply -f pods.yaml >/dev/null
wait_phase runai-team-a share-a Running 300
wait_phase runai-team-b share-b Running 300
a=$(uuid runai-team-a share-a); b=$(uuid runai-team-b share-b)
[[ -n $a && $a == "$b" ]] || { echo "FAIL: not on the same GPU ('$a' vs '$b')"; exit 1; }
echo "  share-a (team-a) and share-b (team-b) both on $a"

sleep 15
c=$(k -n runai-team-b get pod share-c -o jsonpath='{.status.phase}')
[[ $c == Pending ]] || { echo "FAIL: share-c is '$c', expected Pending (GPU is full)"; exit 1; }
echo "  share-c Pending: $(pending_reason runai-team-b share-c | tail -1 | cut -c1-140)"

k -n runai-team-a delete pod share-a --wait=false >/dev/null
wait_phase runai-team-b share-c Running 180 || { echo "FAIL: share-c did not take the freed half"; exit 1; }
echo "  share-a deleted -> share-c Running on $(uuid runai-team-b share-c)"
echo "PASS: two projects shared one GPU; the third half waited for room"
