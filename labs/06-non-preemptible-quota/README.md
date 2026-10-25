# Lab 06: Non-preemptible workloads stay within quota

**Goal:** see the rule that protects guaranteed workloads: anything that
cannot be interrupted must fit inside the project's own quota.

## Concept

Every workload is either:

| | May run over quota (borrow)? | Can be evicted by Run:ai? |
|---|---|---|
| **non-preemptible** | no | no |
| **preemptible** | yes | yes |

The default depends on the kind and priority. Measured on 3.0.20: a plain
**Pod** is non-preemptible; a plain **Job** is `low` priority and preemptible
(Lab 01). Override per workload with the label
`kai.scheduler/preemptibility: preemptible | non-preemptible | semi-preemptible`.

Borrowed GPUs can be reclaimed at any moment, so Run:ai only lends them to
workloads that agree to be interrupted.

## Steps

team-b has 0.5 GPU quota. The other half of the card is idle.

```bash
kubectl apply -f labs/06-non-preemptible-quota/pods.yaml
kubectl -n runai-team-b get pods
kubectl -n runai-team-b get events --field-selector involvedObject.name=np-second | tail -2
```

Expected: `np-first` Running, `np-second` Pending:

```
NonPreemptibleOverQuota: Non-preemptible workload is over quota.
Workload requested 0.5 GPUs, but team-b quota is 0.5 GPUs ...
```

Now the same request, preemptible:

```bash
kubectl delete -n runai-team-b pod np-second
kubectl apply -f labs/06-non-preemptible-quota/preemptible.yaml
kubectl -n runai-team-b get pods        # p-second Running: borrowing the idle half
```

Clean up:

```bash
kubectl delete -f labs/06-non-preemptible-quota/ --ignore-not-found
```
