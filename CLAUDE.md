# runai-oss

Open-source NVIDIA Run:ai on one workstation, as training material. Parts:

- `ansible/`: builds the platform. k3d track: `host.yml` (GPU driver +
  container toolkit on the host), `cluster.yml` (k3d GPU cluster + add-ons).
  VM track (Rocky Linux 10.2 + RKE2, GPU passthrough): `vm-host.yml`,
  `vm-guest.yml`, `vm-cluster.yml`, all with `-e @vm.local.yml` (gitignored,
  from `vm.example.yml`). Both: `runai.yml` (Prometheus, TLS, Run:ai), `teardown.yml`.
- `labs/`: one Run:ai feature per lab (README + YAML + `check.sh`);
  `labs/run.sh` runs them all. `tests/`: platform tests below Run:ai.
- `docs/build-log.md`: every step, command, failure and fix, written as it
  happens. **Add to it whenever something is done or learned**; it feeds a
  LinkedIn article and the training material. Keep dead ends in.

## Rules

- Pin every version to a release number. No `latest`, `main` or bare tags
  like `nginx:alpine`. All versions live in `ansible/group_vars/all.yml`.
- Run:ai 3.0 caps the stack (source: run-ai repo,
  `docs/installation-and-configuration/support-matrix.md`): Kubernetes 1.35
  to 1.37, GPU Operator 25.10 to 26.7.1 (fractions need 26.7.1), Helm 3.14+.
  Newest within those limits, not newest overall. Check the source, not
  memory or older guides: those were wrong here.
- Playbooks must stay idempotent: a second run reports `changed=0`. Helm
  installs only run when the chart version differs, or (gpu_operator,
  prometheus) when the values differ too. cert-manager's only value is fixed
  in the role; Run:ai releases are installed once, then upgraded by version.
- Roles drive `kubectl`/`helm`/`k3d`/`docker` with `ansible.builtin.command`
  (no Python kubernetes library), always with `--context {{ kube_context }}`
  (default `k3d-runai`; the VM track sets `rke2-<vm_name>`). Every non-obvious
  task gets a comment saying why.
- Show the plan and values before installing Run:ai itself.
- The repo is public: no registry names, credentials, client names or
  personal secret-tool names in it.

## Current versions (2026-10-25)

| Component | Version | Variable |
|---|---|---|
| Host driver | 615.71.09, Ubuntu signed modules | `nvidia_driver_branch` |
| NVIDIA container toolkit | 1.20.1-1 | `nvidia_ctk_version` |
| k3s | v1.37.1-k3s1 | `k3s_version` |
| k3d | v5.9.0 | host |
| CUDA base image | 13.4.3-base-ubuntu24.04 | `cuda_tag` |
| NVIDIA device plugin | v0.20.1 | `device_plugin_version` |
| NVIDIA GPU Operator | v26.7.1 | `gpu_operator_version` |
| kube-prometheus-stack | 92.13.1 | `prometheus_stack_version` |
| NVIDIA Run:ai (charts control-plane, runai-cluster) | 3.0.20 | `runai_version` |
| cert-manager | v1.21.3 | `cert_manager_version` |
| Demo app | nginx 1.31.8-alpine | `demo_image` |
| Traefik | 3.7.13 | bundled with k3s |
| Helm | 4.3.1 | host (brew) |
| Ansible | core 2.16 | host |

## How to update versions

1. Latest releases: GitHub releases (k3d, k3s, NVIDIA toolkit, device plugin,
   GPU Operator, cert-manager), Docker Hub tags (`nvidia/cuda`,
   `library/nginx`), NGC tags via an anonymous token from
   `https://nvcr.io/proxy_auth?scope=repository:<repo>:pull`.
2. Check the Run:ai caps above, and that the CUDA minor matches the driver
   branch (13.4 -> R615, 13.3 -> R610, 13.2 -> R595; any 13.x runs on R580+).
3. `docker manifest inspect <image:tag>` for every image. k3s tags use `-`
   where GitHub uses `+`.
4. Edit `ansible/group_vars/all.yml`, then verify:
   - `ansible-playbook host.yml` then a second run: `changed=0`
   - `ansible-playbook teardown.yml && ansible-playbook cluster.yml -e demo_host=demo.test`
   - second `cluster.yml` run: `changed=0`
   - `tests/run.sh`: every test PASS. Test images are pinned in the
     `tests/*.yaml` files; bump them with the stack.

## Tests

`tests/NN-<feature>.yaml`, one Job per feature, run serially by `tests/run.sh`
(one GPU: each GPU test takes all of it). A test must **fail** when its check
fails: assert in the script, `backoffLimit: 0`. A test that only prints can
"succeed" while the feature is broken (that is how a CPU-only TensorFlow once
passed). New feature = new numbered file, self-contained in namespace
`runai-oss-tests`; `run.sh` deletes everything in the file afterwards.

## Labs

`labs/NN-<feature>/`: `README.md` (concept, steps, expected output; an "In the
UI" section per lab is still to come), the YAML, and `check.sh` (sources `labs/lib.sh`, asserts, cleans up
with a trap). Same rule as tests: a lab must **fail** when the feature
misbehaves. Every claim in a README is measured on the cluster first; where
the cluster disagrees with Run:ai's docs, the README says so. Projects are
created through the REST API (`project_create` in `lib.sh`), workloads with
plain YAML. Match events by pod UID (names repeat across runs).

Run:ai facts verified on 3.0.20: scheduler `runai-scheduler` (injected by the
namespace annotation); project namespace `runai-<name>`, label `runai/queue`;
fractions via annotations `gpu-fraction` / `gpu-memory` (whole percentages of
the card only) / `nvidia.com/container.<c>.gpu-memory.request|limit` (never
mixed); preemptibility label `kai.scheduler/preemptibility`; plain Job =
`low` preemptible, plain Pod = non-preemptible; PodGroup
`scheduling.run.ai/v2alpha2` + annotation `pod-group-name`; eviction events
are on the PodGroup.

## Gotchas already paid for

- Secure Boot + DKMS driver: the GPU vanishes when the firmware's MOK list is
  reset ("Loading of module with unavailable key is rejected"). Use the signed
  `linux-modules-nvidia-<branch>-open-generic` packages.
- The signed modules only exist for the newest kernel; install `linux-generic`
  with them or the new kernel boots without `linux-modules-extra` (no NIC).
- No driver libraries in the node image; `--gpus` injects the host's.
- k3s needs `--default-runtime=nvidia` or GPU pods run under runc with no
  driver inside.
- GPU Operator on k3d: driver, toolkit and device plugin off (the host and the
  node image provide them); `gpu_operator_install_driver: true` is for real
  nodes only.
- The host's NIC sits in bridge `br1`, so the host address comes from the
  default route, not the first physical NIC.
- cert-manager has no env var to skip the HTTP-01 self-check; behind NAT it
  needs hairpin NAT on the host.
- `tensorflow/tensorflow:2.21.0-gpu` ships cuDNN 8.9.6 while TF 2.21 needs
  cuDNN 9: TF silently runs on CPU. The test installs `nvidia-cudnn-cu12` 9.x.
- Traefik is the ingress controller: plain `kind: Ingress`,
  `ingressClassName: traefik`. For Run:ai use `global.ingress.ingressClass: traefik`.
- Run:ai install: values templates must use the computed `runai_fqdn`; k3s
  needs `--kubelet-arg=registry-qps=0` (~40 pods pull at once); the token API
  takes the password grant without a `clientID`; wait for cluster state
  `Connected` + all operands ready via the API, not for deployments.
- Admin password: `$RUNAI_ADMIN_PASSWORD` or `~/.config/runai-oss/admin-password`
  (full password, mode 0600, outside the repo). Lab CA: `~/.config/runai-oss/runai-ca.pem`.
