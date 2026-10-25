# Run:ai labs

Hands-on labs for NVIDIA Run:ai 3.0 (open source) on one GPU. Each lab has a
`README.md` (concept, steps, expected result), the YAML it applies, and a
`check.sh` that runs it and **fails if the feature does not behave as
described**. Everything was measured on Run:ai 3.0.20 with an RTX 4080 SUPER;
where the cluster disagrees with the docs, the lab says so.

| Lab | Feature |
|---|---|
| [00](00-projects/) | Projects, quotas and queues (two teams, 0.5 GPU each) |
| [01](01-whole-gpu/) | A plain Job scheduled by Run:ai; PodGroups; Job = low, preemptible |
| [02](02-gpu-fraction/) | Half a GPU with `gpu-fraction` |
| [03](03-share-one-gpu/) | Two teams on one GPU; a third waits for room |
| [04](04-gpu-memory/) | `gpu-memory` in MiB, and a rounding bug that keeps pods Pending |
| [05](05-memory-isolation/) | Memory isolation: PyTorch cannot exceed its share |
| [06](06-non-preemptible-quota/) | Non-preemptible workloads stay within quota |
| [07](07-over-quota-reclaim/) | Over-quota borrowing and reclaim |
| [08](08-priority-preemption/) | Priority and preemption inside a project |
| [09](09-gang-scheduling/) | Gang scheduling: all or nothing |
| [10](10-dynamic-fraction/) | Dynamic fractions: request + burst limit |
| [11](11-background/) | Background workloads: idle GPU time only |
| [12](12-interactive-url/) | JupyterLab with half a GPU at its own HTTPS URL |

Prerequisites: the cluster and Run:ai from `ansible/` (`host.yml`,
`cluster.yml`, `runai.yml`). `lib.sh` holds the helpers (API login, project
creation, waits).

```bash
labs/run.sh          # all labs, in order
labs/run.sh 07       # one lab
```

Not possible with one GPU on one node: multi-GPU fractions, bin-pack vs
spread, consolidation, distributed training, node pools, multi-node
scheduling. MIG and GPU memory swap are not in Run:ai 3.0.
