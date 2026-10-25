# Lab 02: Half a GPU

**Goal:** give a pod 50% of the GPU and see that it really only sees half.

## Concept

A fraction is requested with a pod **annotation**, not a resource request:

| Annotation | Value | Means |
|---|---|---|
| `gpu-fraction` | `"0.5"` | half of one GPU's memory |
| `gpu-memory` | `"4096"` | 4096 MiB (Lab 04) |
| `gpu-fraction-num-devices` | `"2"` | the fraction on each of N GPUs |

Run:ai 3.0 fractions are CUDA-native: the driver itself limits the memory the
container sees. Requirements on every GPU node: driver r615+, CUDA 13.4+, GPU
Operator 26.7.1+ with `cdi.nriPluginEnabled=false`, cgroup v2. Missing any of
them keeps fractional pods Pending ("Missing prerequisites" in the UI).

When scheduled, Run:ai:
- starts a **reservation pod** in `runai-reservation` that holds the physical GPU
- annotates our pod with the GPU it got and the memory it may use

## Steps

```bash
kubectl apply -f labs/02-gpu-fraction/pod.yaml
kubectl -n runai-team-a logs half-gpu
kubectl -n runai-team-a get pod half-gpu -o jsonpath='{.metadata.annotations}' | tr ',' '\n'
kubectl -n runai-reservation get pods
```

## Expected

```
NVIDIA GeForce RTX 4080 SUPER, 8188 MiB          # half of 16376 MiB
"gpu-fraction":"0.5"
"nvidia.com/container.cuda.gpu-memory.request":"8188Mi"
"nvidia.com/container.cuda.gpus.devices":"GPU-..."
"runai-allocated-gpus":"0.5"
gpu-reservation-xxxx   1/1   Running
```

Clean up: `kubectl delete -f labs/02-gpu-fraction/pod.yaml`
