# Lab 10: Dynamic fractions (request + burst limit)

**Goal:** guarantee a workload a small slice of GPU memory, but let it use
more when the card is idle.

## Concept

A fixed fraction (Lab 02) is both the guarantee and the ceiling. A dynamic
fraction separates them, like CPU requests and limits:

| Annotation (per container `<c>`) | Meaning |
|---|---|
| `nvidia.com/container.<c>.gpu-memory.request` | guaranteed memory, counted against quota |
| `nvidia.com/container.<c>.gpu-memory.limit` | the most it may ever allocate |

Values are Kubernetes quantities: `4G` is 4 x 10^9 bytes (3.7 GiB), `4Gi`
is 4 x 2^30.

Scheduling uses the **request**, so more workloads fit on a card. Memory above
the request is not guaranteed: a neighbour can claim it.

**Found while building this lab:** the docs suggest
`kai.scheduler/container.<c>.gpu-memory.portion.limit` together with
`gpu-fraction`. On 3.0.20 Run:ai's admission webhook rejects that combination
and the pod never binds:

```
cannot combine nvidia.com/container. limit annotation with gpu-fraction or gpu-memory annotation
```

Use the request/limit pair alone, as in `pod.yaml`.

## Steps

```bash
kubectl apply -f labs/10-dynamic-fraction/pod.yaml
kubectl -n runai-team-a logs -f burst
```

## Expected

```
visible GPU memory: 7.5 GiB          # the limit (8G) is what the container sees
allocate 3 GiB: OK                   # within the 4G request
allocate 6 GiB: OK                   # above the request: burst
allocate 10 GiB: CUDA out of memory  # above the limit
```

Clean up: `kubectl delete -f labs/10-dynamic-fraction/pod.yaml`
