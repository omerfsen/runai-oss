# Lab 09: Gang scheduling (all or nothing)

**Goal:** see why distributed jobs must start all their workers at once, and
how Run:ai enforces it.

## Concept

A distributed training job with 2 workers is useless with 1: the started
worker sits idle, holding a GPU, waiting for a partner that cannot fit. The
default Kubernetes scheduler places pods one by one and happily creates this
deadlock.

Run:ai schedules **PodGroups** (`scheduling.run.ai/v2alpha2`). `minMember`
says how many pods must fit **at the same time**; until they do, none start.
Run:ai creates PodGroups automatically for every workload (distributed
frameworks get `minMember` = workers). Here we make one by hand and join pods
to it with the annotation `pod-group-name`.

## Steps

1. Two workers at 0.6 GPU each (one would fit, two cannot):

   ```bash
   kubectl apply -f labs/09-gang-scheduling/gang-too-big.yaml
   kubectl -n runai-team-a get pods -l '!job-name' | grep worker
   kubectl -n runai-team-a describe podgroup trainers | tail -3
   ```

   Expected: both `Pending`, with:

   ```
   Resources were found for 1 pods while 2 are required for gang scheduling.
   ```

2. Shrink each to 0.5 GPU:

   ```bash
   kubectl delete -f labs/09-gang-scheduling/gang-too-big.yaml
   kubectl apply -f labs/09-gang-scheduling/gang-fits.yaml
   kubectl -n runai-team-a get pods -o wide | grep worker
   ```

   Expected: both `Running`, started together, same GPU.

Compare: delete the PodGroup and the `pod-group-name` annotations, apply the
0.6 pods again: now one of them starts alone and the other waits forever.

Clean up: `kubectl delete -f labs/09-gang-scheduling/ --ignore-not-found`
