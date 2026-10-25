# Lab 04: Request GPU memory, not a fraction (and read a scheduler error)

**Goal:** ask for an exact amount of GPU memory, and learn to read why a pod
does not start.

## Concept

`gpu-fraction: "0.25"` means a quarter of whatever card the pod lands on. On a
mixed fleet that is 4 GB on one GPU and 20 GB on another. `gpu-memory: "<MiB>"`
asks for an amount wherever it runs, which matches a model's real footprint.
Run:ai turns it into the same driver-enforced limit as a fraction.

## Steps

```bash
kubectl apply -f labs/04-gpu-memory/pod.yaml
kubectl -n runai-team-a logs gpu-mem
```

Expected:

```
NVIDIA GeForce RTX 4080 SUPER, 4094 MiB
```

## Exercise: a value that never binds (found while building this lab)

Ask for 4096 MiB instead of 4094:

```bash
sed -e 's/gpu-mem$/gpu-mem-4096/' -e 's/"4094"/"4096"/' labs/04-gpu-memory/pod.yaml | kubectl apply -f -
kubectl -n runai-team-a get pod gpu-mem-4096          # Pending, forever
kubectl -n runai-team-a get events --field-selector involvedObject.name=gpu-mem-4096
```

```
BindingError: ... admission webhook "admission.runai.svc" denied the request:
NvFractions memory request (4257Mi) does not match gpu-memory annotation value (4096 MiB)
```

What happened: 4096 is 25.01% of the 16376 MiB card. The scheduler rounds the
share up to 26% (4257 MiB) and Run:ai's own webhook then refuses the
mismatch. Values that are an exact whole percentage of the card bind:
`16376 * N / 100`, e.g. 4094 (25%) or 8188 (50%). Measured on 3.0.20; this
looks like an upstream bug worth reporting.

The general lesson: a Pending pod always says why in its **events**.

Clean up:

```bash
kubectl delete -f labs/04-gpu-memory/pod.yaml
kubectl -n runai-team-a delete pod gpu-mem-4096 --ignore-not-found
```
