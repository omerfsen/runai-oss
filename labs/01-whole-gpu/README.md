# Lab 01: A whole GPU, scheduled by Run:ai

**Goal:** run a normal Kubernetes Job and see Run:ai take over its scheduling.

## Concept

Nothing in `job.yaml` mentions Run:ai. The Run:ai admission webhook rewrites
the pod because its namespace (`runai-team-a`) carries
`runai/enforce-scheduler-name=true`:

- `spec.schedulerName` becomes `runai-scheduler`
- label `project: team-a` is added
- after scheduling, annotations such as `runai-allocated-gpus: "1"` appear

Run:ai also wraps the pod in a **PodGroup** (`scheduling.run.ai/v2alpha2`), the
unit it schedules. For a plain Job it picks `priorityClassName: low` and
`preemptibility: preemptible`:

```bash
kubectl -n runai-team-a get podgroups -o jsonpath='{.items[0].spec}'
# {"minMember":1,"preemptibility":"preemptible","priorityClassName":"low","queue":"team-a",...}
```

(Measured on 3.0.20. The docs list a Job as "Build", high priority and
non-preemptible; the cluster does otherwise, and the lab teaches what it does.)

team-a's quota is 0.5 GPU but the Job asks for 1. It still runs: the other
half is idle, so team-a **borrows** it (over-quota). Because the Job is
preemptible, Run:ai can take that borrowed half back later (Lab 07).

## Steps

```bash
kubectl apply -f labs/01-whole-gpu/job.yaml
kubectl -n runai-team-a get pod -l job-name=whole-gpu -o jsonpath='{.items[0].spec.schedulerName}'
kubectl -n runai-team-a get pod -l job-name=whole-gpu -o jsonpath='{.items[0].metadata.annotations}' | tr ',' '\n' | grep runai
kubectl -n runai-team-a logs job/whole-gpu
```

## Expected

```
runai-scheduler
"runai-allocated-gpus":"1"
NVIDIA GeForce RTX 4080 SUPER, 16376 MiB
```

In the UI: Workloads shows `whole-gpu` in project team-a with 1 GPU allocated.

Clean up: `kubectl delete -f labs/01-whole-gpu/job.yaml`
