# Lab 07: Over-quota borrowing and reclaim

**Goal:** let one team use the whole GPU while it is idle, then watch Run:ai
give the other team its share back the moment it asks.

## Concept

Quota (`deserved`) is a **guarantee**, not a cap. Idle GPUs are lent to
projects that want more (over-quota), but only to **preemptible** workloads
(Lab 06). When the owner of the quota submits work, the scheduler
**reclaims**: it evicts borrowed pods until the owner fits. Over-quota
weight decides who gets idle capacity first when several projects want it.

## Steps

team-a and team-b own 0.5 GPU each.

1. team-a borrows the whole card (a Job: preemptible by default):

   ```bash
   kubectl apply -f labs/07-over-quota-reclaim/borrower.yaml
   kubectl -n runai-team-a get pods -l job-name=borrower     # Running, 1 GPU
   ```

   UI: Projects shows team-a at 1.0 allocated against 0.5 quota.

2. team-b asks for its half:

   ```bash
   kubectl apply -f labs/07-over-quota-reclaim/owner.yaml
   kubectl -n runai-team-b get pod owner -w
   ```

3. See what Run:ai did:

   ```bash
   kubectl -n runai-team-a get events --sort-by=.lastTimestamp | grep -E 'Evict|Unschedulable' | tail -3
   kubectl -n runai-team-a get pods -l job-name=borrower
   ```

## Expected

```
Evict   Pod runai-team-a/borrower-xxxxx was preempted by workload runai-team-b/pg-owner-...
```

- `owner` Running in team-b
- team-a's pod was evicted (the event sits on its **PodGroup**, `pg-borrower-...`)
- the Job created a replacement pod that stays Pending
  (`didn't have enough resources: GPUs`) and starts again when room frees up

Note the replacement asks for a whole GPU, so it waits even though half the
card belongs to team-a. With a 0.5 request it would fit right away.

Clean up: `kubectl delete -f labs/07-over-quota-reclaim/`
