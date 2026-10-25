#!/usr/bin/env bash
# Lab 07: team-a borrows the whole GPU; when team-b asks for its own half,
# Run:ai evicts team-a's borrowed (preemptible) pod and team-b runs.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
trap 'k delete -f borrower.yaml -f owner.yaml --ignore-not-found --wait=true --timeout=120s >/dev/null' EXIT

k apply -f borrower.yaml >/dev/null
until first=$(k -n runai-team-a get pod -l job-name=borrower -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [[ -n $first ]]; do sleep 2; done
wait_phase runai-team-a "$first" Running 300
echo "  borrower ($first) Running with 1 GPU: team-a uses 1.0 against a 0.5 quota"

k apply -f owner.yaml >/dev/null
wait_phase runai-team-b owner Running 300 || { pending_reason runai-team-b owner; exit 1; }
echo "  owner (team-b, 0.5) Running"

# The borrowed pod must be gone, and its event says why.
if phase=$(k -n runai-team-a get pod "$first" -o jsonpath='{.status.phase}' 2>/dev/null) && [[ $phase == Running ]]; then
  echo "FAIL: $first still Running: nothing was reclaimed"; exit 1
fi
# The Evict event is recorded on the PodGroup (pg-borrower-...), not the pod.
why=$(k -n runai-team-a get events -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' \
  | grep "^Evict: Pod runai-team-a/$first was preempted" | tail -1 || true)
[[ -n $why ]] || { echo "FAIL: no Evict event for $first"; exit 1; }
echo "  $why"
sleep 10
next=$(k -n runai-team-a get pods -l job-name=borrower --no-headers 2>/dev/null | awk '$1 != "'"$first"'" {print $1" "$3}' | head -1)
echo "  replacement pod: ${next:-<none>} (waits for room)"
echo "PASS: Run:ai reclaimed the borrowed GPU for the project that owns it"
