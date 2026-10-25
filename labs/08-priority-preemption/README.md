# Lab 08: Priority and preemption inside a project

**Goal:** a more important workload takes the GPU from a less important one
in the same project.

## Concept

Within a project's quota, Run:ai orders workloads by **priority**. Set it with
the standard `spec.priorityClassName`. Classes on the cluster:

| Class | Value | Default preemptibility |
|---|---|---|
| `very-low`, `low`, `train`, `medium-low`, `interactive-preemptible`, `medium`, `medium-high` | 25 to 90 | preemptible (< 100) |
| `build` | 100 | non-preemptible (>= 100) |
| `high`, `inference` | 125 | non-preemptible |
| `very-high` | 150 | non-preemptible |

All of them use `PreemptLowerPriority`: a waiting higher-priority workload may
evict lower-priority, preemptible ones. Lab 07 was preemption *between*
projects (reclaim); this one is *within* a project.

## Steps

`pods.yaml` fills the card: team-b's half with a non-preemptible pod, team-a's
half with a `train` (50), preemptible pod. Then `high.yaml` adds a `build`
(100) pod to team-a.

```bash
kubectl apply -f labs/08-priority-preemption/pods.yaml
kubectl get pods -n runai-team-a; kubectl get pods -n runai-team-b
kubectl -n runai-team-a get podgroups -o custom-columns=NAME:.metadata.name,PRIO:.spec.priorityClassName,PREEMPT:.spec.preemptibility

kubectl apply -f labs/08-priority-preemption/high.yaml
kubectl -n runai-team-a get pods -w
kubectl -n runai-team-a get events | grep Evict
```

## Expected

```
Evict   Pod runai-team-a/low-prio was preempted by higher priority workload runai-team-a/pg-high-prio-...
```

`high-prio` Running, `low-prio` gone. A bare Pod is not recreated; a Job or
training operator would resubmit it and it would queue.

Try: give `high.yaml` `priorityClassName: medium` (80, preemptible). It still
evicts `train` (50). Then try `very-low` (25): it waits instead.

Clean up: `kubectl delete -f labs/08-priority-preemption/ --ignore-not-found`
