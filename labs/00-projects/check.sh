#!/usr/bin/env bash
# Lab 00: two projects with 0.5 GPU each; check namespace, labels and Queue.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh

for p in team-a team-b; do
  project_create "$p" 0.5
  [[ $(k get ns "runai-$p" -o jsonpath='{.metadata.labels.runai/queue}') == "$p" ]] \
    || { echo "FAIL: namespace runai-$p has no runai/queue=$p label"; exit 1; }
  [[ $(k get ns "runai-$p" -o jsonpath='{.metadata.annotations.runai/enforce-scheduler-name}') == true ]] \
    || { echo "FAIL: runai-$p does not enforce runai-scheduler"; exit 1; }
  quota=$(k get queues.scheduling.run.ai "$p" -o jsonpath='{.spec.resources.gpu.quota}')
  [[ $quota == 0.5 ]] || { echo "FAIL: queue $p GPU quota is '$quota', expected 0.5"; exit 1; }
  echo "  $p: namespace runai-$p, queue quota $quota GPU"
done
echo "PASS: projects team-a and team-b each own half of the GPU"
