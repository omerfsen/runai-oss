# Lab 11: Background workloads (only idle GPUs)

**Goal:** soak up idle GPU time with work that steps aside instantly when real
work arrives.

## Concept

A **background** workload runs in a project with **no quota** (here `batch`,
deserved 0). It is never entitled to anything, so it only uses capacity that
is idle, and it is evicted the moment a project with quota needs that GPU.

Requirements (Run:ai docs, `background-workloads.md`):

- label `kai.scheduler/background: "true"` and preemptible
- whole GPUs only (`nvidia.com/gpu`), no fractions
- short `terminationGracePeriodSeconds` (5) so the real workload is not delayed
- a controller that recreates the pod (Deployment, DaemonSet): eviction is
  normal operation

Setup: `project_create batch 0` (lab helper). On 3.0.20 the queue gets
over-quota weight 0.01 rather than 0: with adjustable weights off the control
plane derives it from the quota.

## Steps

```bash
source labs/lib.sh && project_create batch 0
kubectl apply -f labs/11-background/background.yaml
kubectl -n runai-batch get pods          # Running on the idle GPU

kubectl apply -f labs/11-background/foreground.yaml   # team-a wants its half
kubectl -n runai-batch get pods -w       # evicted, replacement Pending
kubectl -n runai-batch get events | grep -E 'Evict|Unschedulable'

kubectl delete -f labs/11-background/foreground.yaml
kubectl -n runai-batch get pods -w       # back to Running
```

## Expected

```
Evict   Pod runai-batch/background-xxx was preempted by workload runai-team-a/pg-foreground-...
```

The background pod runs whenever the card is free, steps aside for team-a,
and comes back when team-a is done.

Clean up: `kubectl delete -f labs/11-background/ --ignore-not-found`
