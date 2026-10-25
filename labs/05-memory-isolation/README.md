# Lab 05: Memory isolation is real

**Goal:** prove a fractional workload cannot take more GPU memory than it was
given, even if it tries.

## Concept

Older GPU-sharing setups (plain time-slicing) only *advertise* a share: any
pod can still allocate the whole card and crash its neighbours. Run:ai 3.0
fractions are CUDA-native: the driver caps the memory the container can
allocate. This lab gives PyTorch a quarter of a 16 GB card and asks for 2 GB,
then 6 GB.

## Steps

```bash
kubectl apply -f labs/05-memory-isolation/pod.yaml
kubectl -n runai-team-a logs -f isolation
```

## Expected

```
visible GPU memory: 4.0 GiB
allocate 2 GiB: OK
allocate 6 GiB: CUDA out of memory
```

The 6 GiB request fails inside *this* container, while the card still has
~12 GB free: the neighbours stay safe.

Clean up: `kubectl delete -f labs/05-memory-isolation/pod.yaml`
