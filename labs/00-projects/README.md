# Lab 00: Projects, quotas and queues

**Goal:** create two Run:ai projects that share one GPU, and see what a
project becomes inside Kubernetes.

## Concept

A **project** is Run:ai's unit of quota. It lives in the control plane, not in
Kubernetes, so it is created in the UI or through the REST API. The cluster
agent then creates:

| Object | What it holds |
|---|---|
| Namespace `runai-<project>` | label `runai/queue=<project>`, annotation `runai/enforce-scheduler-name=true` |
| `Queue` (`scheduling.run.ai/v2`) | `quota` (deserved GPUs), `limit`, `overQuotaWeight`, `parentQueue` (the department) |
| `Project` (`kai.resources/v1alpha1`) | the same quota, per node pool |

Because of the annotation, every pod in the namespace is scheduled by
`runai-scheduler`, even if its YAML never mentions it.

We use two projects with **0.5 GPU deserved each**: together they own the one
GPU, which is what makes quota, over-quota and reclaim visible on a single card.

## Steps

```bash
source labs/lib.sh
project_create team-a 0.5
project_create team-b 0.5
```

(UI: Organization > Projects > New project, GPU devices 0.5.)

Look at what appeared:

```bash
kubectl get ns runai-team-a --show-labels
kubectl get ns runai-team-a -o jsonpath='{.metadata.annotations}'
kubectl get queues.scheduling.run.ai
kubectl get queue team-a -o jsonpath='{.spec.resources.gpu}'
```

## Expected

```
{"limit":-1,"overQuotaWeight":0.5,"quota":0.5}
```

`limit: -1` means "no hard cap": a project may borrow idle GPUs above its
quota. Lab 07 shows what happens when the owner wants them back.

`./check.sh` does all of this and fails if anything is missing.
