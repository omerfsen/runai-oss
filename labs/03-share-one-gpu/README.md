# Lab 03: Two teams on one GPU

**Goal:** run two workloads from different projects on the same physical GPU
at the same time, and see the scheduler refuse a third.

## Concept

Fractions let several pods share a card. Each pod gets its own memory slice;
compute is time-sliced between them by default. Run:ai packs fractions onto
the same GPU (the node pool's GPU placement is `binpack`), and it counts what
is left: two halves fill the card, so a third half stays `Pending` until one
finishes.

## Steps

```bash
kubectl apply -f labs/03-share-one-gpu/pods.yaml
kubectl get pods -A | grep share-
# Same physical GPU for both running pods:
for p in runai-team-a/share-a runai-team-b/share-b; do
  kubectl -n ${p%/*} get pod ${p#*/} -o jsonpath='{.metadata.annotations.nvidia\.com/container\.cuda\.gpus\.devices}{"\n"}'
done
kubectl -n runai-team-b describe pod share-c | tail -5   # why it waits
```

## Expected

- `share-a` and `share-b` Running, both with the same `GPU-...` UUID
- `share-c` Pending: `no nodes with enough resources were found: ... GPUs`
- In the UI (Workloads, Nodes): one GPU, allocation 1.0, two workloads

`share-c` carries `kai.scheduler/preemptibility: preemptible`, so it may borrow
above team-b's quota: it waits only for room on the card. A plain pod is
non-preemptible and could never go over quota; Lab 06 shows that rule.

Delete `share-a` and watch `share-c` start on the freed half:

```bash
kubectl -n runai-team-a delete pod share-a
kubectl -n runai-team-b get pod share-c -w
```

Clean up: `kubectl delete -f labs/03-share-one-gpu/pods.yaml`
