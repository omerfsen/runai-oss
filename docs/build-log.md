# Build log: open-source NVIDIA Run:ai on one workstation

A step-by-step record of bringing up the open-source NVIDIA Run:ai platform
(control plane + GPU cluster) on a single workstation with a consumer GPU.
Each step lists what was done, the commands, what came back, and why. Dead
ends stay in: they are most of the learning.

## Background

- NVIDIA open-sourced the full Run:ai platform on 2026-10-13 under Apache 2.0:
  https://github.com/dsx-ai-factory/run-ai
- Public Helm repo, no NGC key: `https://helm.ngc.nvidia.com/nvidia/runai-oss`,
  charts `control-plane` and `runai-cluster`, version 3.0.20.
- Images pull anonymously from `nvcr.io/nvidia/runai-oss`.
- The official self-hosted docs were written for the paid product (`nvidia/runai`
  + NGC API key). For the OSS release, swap in `nvidia/runai-oss` and drop the
  credentials.

Run:ai's limits drive every version choice below:

| Requirement | Supported range |
|---|---|
| Kubernetes | 1.34 to 1.36 |
| NVIDIA GPU Operator | 25.10 to 26.3 |
| Helm | 3.14 or later |
| Control plane system node | 10 CPU, 12 GB RAM, 110 GB disk |
| Cluster system node | 10 CPU, 20 GB RAM, 50 GB disk |

## The workstation

| Item | Value |
|---|---|
| OS | Ubuntu 24.04.5 LTS, Secure Boot on |
| CPU / RAM / disk | 24 cores, 92 GB, 409 GB free |
| GPU | NVIDIA GeForce RTX 4080 SUPER (16 GB), also the boot display |
| iGPU | AMD (amdgpu), HDMI to an IP-KVM |
| Network | onboard `eno1` (r8169) inside bridge `br1`, 192.0.2.10/24 (addresses in this log are documentation examples) |
| Container runtime | Docker 29.9.2, NVIDIA Container Toolkit 1.20.1 |
| Kubernetes | k3d v5.9.0 (k3s in Docker) |

The same GPU had been passed through to a KVM guest for an earlier project
(an agentic SecOps lab on RKE2). The bridge `br1` comes from that project: it
puts the guest directly on the LAN.

---

## Step 1: The host can't see its GPU

```bash
$ nvidia-smi
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.
```

`nvidia-driver-595-open` (595.91.07) was installed, built by DKMS for the
running kernel, but no NVIDIA module was loaded.

**First suspect: the GPU passthrough.** The earlier lab binds the card to
`vfio-pci` in "permanent" mode and refuses the NVIDIA modules outright
(`install nvidia /bin/false` in modprobe.d). Its "off" mode removes that and
rebuilds the initrd. Checked:

```bash
lspci -nnk -s 01:00          # no "Kernel driver in use" for 01:00.0, not vfio-pci
ls /etc/modprobe.d/          # no vfio.conf, no blacklist-gpu-passthrough.conf
lsinitramfs /boot/initrd.img-$(uname -r) | grep modprobe.d   # stock files only
sudo virsh dominfo secops-lab | grep -i autostart            # disable
```

Re-running the lab's playbook in off mode changed nothing (`changed=0`). The
passthrough was already undone. Not the cause.

**The boot logs told the real story:**

| Boot | NVIDIA driver |
|---|---|
| Oct 1, 4, 9 | 595.91.07 loaded fine, Secure Boot on |
| Oct 11 | nothing: the passthrough "permanent" boot |
| Oct 25 (after passthrough off) | still nothing |

After one more reboot the kernel finally said why:

```
kernel: Loading of module with unavailable key is rejected
```

**Root cause:** Secure Boot only loads modules signed by a trusted key. DKMS
signs the NVIDIA module with a local Machine Owner Key (MOK). That key was no
longer in the firmware's MOK list (`mokutil --test-key ... is not enrolled`),
most likely reset during the firmware changes made for the passthrough. The
module had been fine for weeks, then silently stopped loading.

## Step 2: Switch to Canonical-signed driver modules

Ubuntu ships prebuilt NVIDIA modules signed with Canonical's key, which
Secure Boot already trusts. No DKMS, no MOK enrollment, nothing to break the
next time the key list gets reset.

Find the newest signed branch:

```bash
apt-cache search --names-only '^linux-modules-nvidia-[0-9]+(-server)?(-open)?-generic$'
# newest: linux-modules-nvidia-615-open-generic  (615.71.09, kernel 6.8.0-147)
```

Why 615: CUDA 13.4 (the newest CUDA) needs R615 for its new features
(13.3 -> R610, 13.2 -> R595, any 13.x runs on R580+), and GPU Operator 26.7
lists 615.71.09. `nvidia-driver-615-open` hard-depends on DKMS, so use the
headless no-DKMS package instead. Simulate first:

```bash
apt-get -s install linux-modules-nvidia-615-open-generic \
  nvidia-headless-no-dkms-615-open nvidia-utils-615 \
  nvidia-driver-595-open- nvidia-dkms-595-open-
```

Then install for real and reboot. Check the signer:

```bash
$ modinfo -k 6.8.0-147-generic -F signer nvidia
Canonical Ltd. Kernel Module Signing
```

## Step 3: The new kernel boots without network

The signed modules exist only for the newest kernel (6.8.0-147), so apt
pulled that kernel in. The first two boots on it had **no wired network**, and:

```
nvidia_drm: Unknown symbol drm_hdcp_update_content_protection (err -2)
```

Both had one cause: the kernel came without `linux-modules-extra`, which holds
the onboard NIC driver (`r8169`), the USB NIC and Wi-Fi drivers, and
`drm_display_helper` (needed by `nvidia_drm`). The kernel was installed as a
dependency, without the `linux-generic` metapackage that normally brings
modules-extra along.

```bash
sudo apt-get install linux-generic     # moves the metapackage to 147, adds modules-extra
for m in r8169 drm_display_helper nvidia_drm bridge; do
  modinfo -k 6.8.0-147-generic -F filename $m
done
```

**Lesson:** install the signed NVIDIA modules together with `linux-generic`.

## Step 4: Console resolution and small host fixes

- **1280x1024 console.** `/etc/default/grub` pinned `GRUB_GFXMODE=1280x1024`,
  and `GRUB_GFXMODE_LINUX=keep` was a typo (the key is `GRUB_GFXPAYLOAD_LINUX`).
  Set `GRUB_GFXMODE=1920x1080,auto` and `GRUB_GFXPAYLOAD_LINUX=keep`, added
  `options nvidia_drm modeset=1 fbdev=1`, ran `update-grub`. With `nvidia_drm`
  loaded, the console runs at 3840x2160.
- **Webcam reset loop.** `usb 1-1: reset high-speed USB device` every ~3 s:
  a Logitech MX Brio failing to wake from USB autosuspend. A udev rule sets
  `power/control=on` for `046d:0944`. Writing `on` stopped the resets at once.
- **Console spam.** `kernel.printk` was `15` at runtime; set back to the
  configured `4 4 1 7`.
- **Prompt glyphs on the text console.** The Linux console uses small bitmap
  fonts that have no Nerd Font glyphs, so oh-my-posh's prompt showed diamonds.
  `.bashrc` now uses a plain `PS1` when `TERM=linux`.

## Step 5: Verify the host GPU

```bash
$ uname -r
6.8.0-147-generic
$ nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
NVIDIA GeForce RTX 4080 SUPER, 615.71.09
$ docker run --rm --gpus all nvcr.io/nvidia/cuda:13.4.3-base-ubuntu24.04 \
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
NVIDIA GeForce RTX 4080 SUPER, 615.71.09
```

## Step 6: Pick versions

| Component | Latest | Chosen | Why |
|---|---|---|---|
| k3d | v5.9.0 | v5.9.0 | already installed |
| k3s | v1.37.1 (latest), v1.36.5 (stable) | v1.36.5 | Run:ai stops at 1.36 |
| CUDA base image | 13.4.3 | 13.4.3 | matches the R615 driver |
| Container toolkit | 1.20.1 | 1.20.1 | |
| Device plugin | v0.20.1 | v0.20.1 | |
| GPU Operator | v26.7.2 | v26.3.3 | Run:ai stops at 26.3 |

## Step 7: Build the k3s CUDA node image

k3d runs Kubernetes nodes as Docker containers. For GPUs, the node image needs
the NVIDIA container toolkit on top of k3s (the k3d CUDA guide pattern).
The image lives in the `mac-desktop` repo under `k3d/gpu/`.

Changes from the previous image (k3s 1.31.7, CUDA 12.8.1):

- k3s v1.36.5, CUDA 13.4.3, toolkit pinned to 1.20.1, device plugin v0.20.1.
- **Removed `nvidia-utils` from the image.** With `--gpus`, Docker injects the
  host's driver libraries and `nvidia-smi`. Baked-in driver libraries of a
  different version clash with them.
- `build.sh` got `PUSH=false` for local builds (no registry login or push).

```bash
cd k3d/gpu && PUSH=false ./build.sh
docker run --rm --gpus all --entrypoint sh <image> -c 'nvidia-smi -L'
# GPU 0: NVIDIA GeForce RTX 4080 SUPER
```

## Step 8: Create the GPU cluster, three surprises

```bash
./k3d.sh -i <k3s-cuda-image> -g 1 start
```

**Surprise 1: no host IP.** `k3d.sh` binds ports 80/443 to "the first physical
NIC with an IPv4 address". With the bridge, `eno1` has no address and `br1` is
virtual, so detection found nothing and the port mapping would break. Fix:
fall back to the interface carrying the default route (`br1:192.0.2.10`).

**Surprise 2: GPU allocated, but no driver in the pod.**

```
$ kubectl logs nvidia-smi
/bin/bash: line 1: nvidia-smi: command not found
```

The node advertised `nvidia.com/gpu: 1` and the pod got it, but it ran under
the default `runc` runtime, which doesn't inject the driver. Only pods with
`runtimeClassName: nvidia` get it, and most GPU workloads (Run:ai's
included) don't set one. Fix: start k3s with nvidia as the default runtime:

```bash
k3d cluster create ... --gpus 1 --k3s-arg "--default-runtime=nvidia@server:*"
```

After that the same pod printed the full `nvidia-smi` table.

**Surprise 3: helm wasn't installed.** Installed with Homebrew, which brought
Helm 4.3.1. Run:ai documents Helm 3.14+. To be checked against the Run:ai
charts.

## Step 9: Optional NVIDIA GPU Operator

Run:ai needs the GPU Operator (DCGM exporter for metrics, node labels). In
k3d the "node" shares the host kernel, so the operator must **not** install a
driver: the host already has one, and with Secure Boot the operator's
unsigned modules would be rejected anyway. So the operator runs with driver,
toolkit, device plugin and CDI off (`gpu/gpu-operator-values.yaml`), behind a
`-G` flag:

```bash
./k3d.sh -i <k3s-cuda-image> -g 1 -G start
```

Result:

```
gpu-feature-discovery                 Running
gpu-operator                          Running
node-feature-discovery (gc/master/worker)  Running
nvidia-cuda-validator                 Completed
nvidia-dcgm-exporter                  Running
nvidia-operator-validator             Running
node label nvidia.com/gpu.product = NVIDIA-GeForce-RTX-4080-SUPER
```

`driver.enabled: true` stays available in the values file for real nodes with
no host driver.

## Step 10: Ingress

k3s bundles Traefik 3.7.13 and makes `traefik` the default IngressClass, so
plain `kind: Ingress` works. For Run:ai this replaces the HAProxy controller
from the official guide: `global.ingress.ingressClass: traefik`.

## Step 11: Rewrite the cluster script, pin every version

The old `k3d.sh` had grown by accretion: eight getopts flags nothing used,
`deploy`/`test` commands calling functions that didn't exist, a DNS override
that always fired (`[ -n $VAR ]` unquoted), a hard-coded hostname and ~170
lines of help text. It was rewritten from scratch (it lives on as `k3d.sh`
in a separate dotfiles repo), same features:

```
./k3d.sh [options] <up|down|status|versions>
  -i IMAGE  -g N  -G (GPU Operator)  -m MIRROR  -n NAME
  -e EMAIL  -d HOST  -C (no cert-manager)  -D (no demo)  -r DNS
```

- Every setting is also an environment variable (`INSTALL_DEMO=false ./k3d.sh up`).
- Prompts only when stdin is a terminal, so `</dev/null` gives a fully
  unattended run.
- `set -euo pipefail`, shellcheck clean.
- `wait_for_traefik` checks that the `traefik` IngressClass exists and is the
  default, and fails clearly if k3s was started without Traefik.

**No floating versions anywhere.** "latest" is a moving target, so every
image and download is pinned to the newest release by number:

| Was | Now |
|---|---|
| k3d install script from `main` | `v5.9.0`, `TAG=v5.9.0` |
| cert-manager v1.16.2 | v1.21.3 |
| `nginx:alpine` | `nginx:1.31.8-alpine` |
| `tensorflow/tensorflow:latest-gpu` | `2.21.0-gpu` |
| `pytorch/pytorch:latest` | `2.14.1-cuda13.2-cudnn9-runtime` |
| `nvcr.io/nvidia/tensorrt:23.12-py3` | `26.09-py3` |
| `k8s.gcr.io/cuda-vector-add:v0.1` (dead registry) | `nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubuntu22.04` |
| `nvidia/cuda:12.8.1-base-ubuntu24.04` | `nvcr.io/nvidia/cuda:13.4.3-base-ubuntu24.04` |

The bare-metal driver script was rewritten too: it now installs the signed
modules + `linux-generic` + the pinned toolkit (Steps 2 and 3 as code), where
it used to install driver 570 from a PPA with DKMS.

End-to-end check of the rewrite:

```bash
./k3d.sh -i <k3s-cuda-image> -g 1 -G -d demo.example.test up </dev/null
```

| Check | Result |
|---|---|
| GPU capacity | `nvidia.com/gpu: 1`, product `NVIDIA-GeForce-RTX-4080-SUPER` |
| GPU Operator | all pods Running, `nvidia-cuda-validator` Completed |
| cert-manager v1.21.3 | Running (no email given, so no Let's Encrypt issuers) |
| Demo via Traefik `kind: Ingress` | `curl --resolve demo.example.test:80:192.0.2.10 ...` -> 200 |
| GPU pod, no runtimeClassName | `nvidia-smi` shows driver 615.71.09, CUDA 13.4 |

## Step 12: The same thing as Ansible

A shell script is fine for one machine; training material needs something
people can read top to bottom and re-run safely. Everything from Steps 1 to
11 became three playbooks (`ansible/`), in the style of the earlier SecOps lab:

| Playbook | Roles |
|---|---|
| `host.yml` | `nvidia_host`: remove DKMS drivers, signed modules + `linux-generic`, pinned toolkit, Docker runtime, reboot gate, signer check, CUDA container check |
| `cluster.yml` | `node_image` (local build, no registry), `k3d_cluster`, `gpu_operator`, `cert_manager`, `demo_app` |
| `teardown.yml` | `k3d cluster delete` |

Design choices:

- One switch per component and every version in `group_vars/all.yml`.
- Roles call `kubectl`/`helm`/`k3d` directly, always with an explicit
  `--context`, so no Python Kubernetes library is needed.
- The node image is built locally and used straight from Docker, which also
  takes the private registry out of the picture.
- GPU Operator values are a template: `gpu_operator_install_driver: true`
  flips driver, toolkit and device plugin on together for real nodes.
- Each role ends with a check that proves its piece works (CUDA validator
  passed, Ingress answers with 200), not just that the install command ran.

**Idempotence found two real bugs.** The first re-run reported `changed=2`:

1. `helm upgrade` always says "upgraded". The roles now compare the deployed
   chart version and values with the desired ones and skip Helm when equal.
2. cert-manager was installed with `kubectl apply` and then patched with an
   env var. Every re-apply reset the Deployment and dropped the env var, so
   cert-manager restarted on every run. Looking closer, the env var
   (`CERT_MANAGER_DISABLE_HTTP01_SELF_CHECK`, inherited from the old script)
   **doesn't exist**: zero references in cert-manager's source. It was removed,
   and cert-manager now comes from its Helm chart (`crds.enabled=true`).

Final check, from nothing:

```bash
ansible-playbook teardown.yml
ansible-playbook cluster.yml -e demo_host=demo.example.test   # ok=29 changed=4
ansible-playbook cluster.yml -e demo_host=demo.example.test   # ok=23 changed=0
```

`host.yml` on the already-prepared host: first run `changed=2` (new key file,
apt source rewritten without two stale lines), second run `changed=0`.

## Step 13: From scratch, timed

Cluster deleted and the locally built node image removed, so nothing is
reused except the host driver:

```bash
ansible-playbook teardown.yml
docker rmi localhost/k3s-cuda:v1.36.5-k3s1-cuda-13.4.3-base-ubuntu24.04
ansible-playbook host.yml
ansible-playbook cluster.yml -e demo_host=demo.example.test
ansible-playbook cluster.yml -e demo_host=demo.example.test
```

| Run | Result | Time |
|---|---|---|
| `teardown.yml` | `changed=1` | |
| `host.yml` (driver already in place) | `changed=0`, CUDA container sees the GPU | 5 s |
| `cluster.yml` #1: image build, cluster, GPU Operator, cert-manager, demo | `changed=9`, every check green | 126 s |
| `cluster.yml` #2 | `changed=0` | 3 s |

GPU workloads on the new cluster:

| Test pod | Result |
|---|---|
| nvidia-smi pod (no runtimeClassName, now `tests/01-gpu-nvidia-smi.yaml`) | Succeeded: RTX 4080 SUPER, driver 615.71.09, CUDA 13.4 |
| CUDA vectorAdd sample (now `tests/02-gpu-cuda-vectoradd.yaml`) | Succeeded: `Test PASSED` |
| TensorFlow 2.21.0, PyTorch 2.14.1, TensorRT 26.09 | not run here (multi-GB images), see Step 14 |

Two minutes from an empty Docker to a GPU Kubernetes cluster with GPU
Operator, cert-manager and ingress.

## Step 14: The big framework tests, and a "passing" test that wasn't

Running the remaining test pods (TensorFlow, PyTorch, TensorRT): all four
pods ended `Succeeded`. But one log said:

```
Num GPUs Available: 0
```

TensorFlow ran on the CPU, and the pod "passed" because the test only
printed. Same result with plain `docker run --gpus all`, so not a cluster
problem:

```
Failed to determine cuDNN version ... CUDNN_STATUS_INTERNAL_ERROR
Cannot dlopen some GPU libraries ...
Skipping registering GPU devices...
built with CUDA 12.5.1 cuDNN 9
```

**Cause:** the official `tensorflow/tensorflow:2.21.0-gpu` image is built
against cuDNN 9 but ships cuDNN 8.9.6 (`libcudnn.so.8`). TF can't load the
library it needs and quietly falls back to the CPU. NVIDIA's own TensorFlow
container stopped at 25.02, so that's not a way out.

**Fix:** add cuDNN 9 from pip in the container:

```bash
pip install nvidia-cudnn-cu12==9.27.0.42
# GPUs: [PhysicalDevice(name='/physical_device:GPU:0', device_type='GPU')]
# conv2d on GPU ok
```

## Step 15: One test per feature, on one GPU

The episode above changed how tests are written: **a test must fail when the
feature is broken.** Each feature got its own file under `tests/`, as a Job
with `backoffLimit: 0` and an explicit assertion:

| Test | Proves |
|---|---|
| `01-gpu-nvidia-smi` | GPU reaches a pod with no runtimeClassName (default runtime) |
| `02-gpu-cuda-vectoradd` | a real CUDA kernel computes the right answer |
| `03-gpu-tensorflow` | TF sees the GPU, conv2d (cuDNN) and matmul run on it |
| `04-gpu-pytorch` | same for PyTorch |
| `05-gpu-tensorrt` | TensorRT builds an engine on the GPU |
| `06-gpu-operator-metrics` | DCGM exporter publishes this GPU's metrics |
| `07-ingress-traefik` | Traefik routes a plain `kind: Ingress` |
| `08-cert-manager` | cert-manager issues a certificate (the pod can't start until the Secret exists) |

**One GPU.** Without GPU sharing the card fits one GPU pod at a time, and
parallel GPU tests would just queue in `Pending`. `tests/run.sh` runs the
files in order: apply, wait for the Job to succeed or fail, print the key
log lines, delete everything the file created, next. Exit code non-zero if
anything failed.

```
==> summary (k3d-runai)
    01-gpu-nvidia-smi            PASS         5s
    02-gpu-cuda-vectoradd        PASS         5s
    03-gpu-tensorflow            PASS        30s
    04-gpu-pytorch               PASS         5s
    05-gpu-tensorrt              PASS         6s
    06-gpu-operator-metrics      PASS        10s
    07-ingress-traefik           PASS        10s
    08-cert-manager              PASS         5s
```

Highlights from the logs: TensorFlow 2.21.0 / CUDA 12.5.1 / cuDNN 9;
PyTorch 2.14.1 / CUDA 13.2 / cuDNN 9.24; TensorRT 11.3 built a 9 KB engine;
DCGM reported the RTX 4080 SUPER at 33 °C. Times are with images cached; the
first run pulls several GB.

## Step 16: Read the source before installing

The install guide and the support range I started from were written against
older docs. Before writing any values, an agent swept the Run:ai monorepo
(`dsx-ai-factory/run-ai`) for the facts, and the key ones were re-checked by
hand. What changed:

| Assumed | Source says (3.0) |
|---|---|
| Kubernetes 1.34 to 1.36 | **1.35 to 1.37** (`docs/installation-and-configuration/support-matrix.md`) |
| GPU Operator 25.10 to 26.3 | **25.10 to 26.7.1**; GPU fractions need **26.7.1**, driver r615+, CUDA 13.4+, `cdi.nriPluginEnabled=false`, cgroup v2 |
| scheduler `kai-scheduler` | **`runai-scheduler`** (`runai-cluster/common/constants/constants.go`) |
| `TrainingWorkload` etc. CRDs | **removed in 3.0**: plain Pods/Jobs/Deployments plus Run:ai labels and annotations |
| Cluster registered in the UI wizard | can be done through the REST API with a one-time bootstrap token (as `local-dev.sh` does) |

So the base moved to **k3s v1.37.1** and **GPU Operator v26.7.1** (cluster
rebuilt, all 8 platform tests green again), and the host already met every
fraction prerequisite thanks to Steps 1 to 5.

Design choices for this cluster:

- **Domain** `runai.192-0-2-10.nip.io`: resolves to the host IP, wildcard
  included, on the host and inside pods; no DNS server, works for any trainee.
- **TLS** from a self-signed CA in cert-manager (`runai-ca` ClusterIssuer),
  with `global.customCA.enabled=true` so every component trusts it.
- **Ingress class `traefik`**: the chart only documents nginx and haproxy, but
  `helm template` shows a single plain Ingress with no controller-specific
  annotations.
- **kube-prometheus-stack 92.13.1** (Run:ai needs 88.6.5+).

## Step 17: Install Run:ai with Ansible, and what broke

`ansible/runai.yml` with four roles: `prometheus`, `runai_tls` (CA,
certificates, the four secrets, wildcard Ingress), `runai_control_plane`,
`runai_cluster`. Bugs met on the way:

1. **Empty domain.** The values templates used `runai_domain` (empty by
   default) instead of the computed `runai_fqdn`. Helm 4's server-side apply
   refused the Ingress: `spec.tls[0].hosts[0]: Invalid value: ""`. My earlier
   `helm template` check used a hand-written file, not the template, so it
   missed this. Lesson: render the real template.
2. **`pull QPS exceeded`.** The control plane starts ~40 pods at once and hits
   kubelet's 5 pulls/s limit. k3s now runs with `--kubelet-arg=registry-qps=0`.
3. **Token endpoint.** `POST /api/v1/token` with `clientID: runai-cli` (taken
   from `local-dev.sh`) answers 502; without a `clientID` the password grant
   works.
4. **"Ready" too early.** `kubectl wait deploy --all` passed before the
   operator had even created its ~25 operands (it does so only after pulling
   config from the control plane). The role now waits for the control
   plane's own view: cluster state `Connected` and every operand `ready`.

Result, from scratch: control plane up in ~7 minutes, cluster `Connected`
3 to 5 minutes later. Re-run: `changed=0`.

The cluster status from the API is a good debugging tool. It showed
`gpu-stack: available` (including `gpu-fractioning`) long before the UI did,
and named the one missing piece (Run:ai's own Prometheus, still starting).

## Step 18: Run:ai labs on one GPU

Projects live in the control plane, so the labs create them through the REST
API (`labs/lib.sh`), and workloads are plain YAML. A project becomes a
namespace `runai-<name>` (label `runai/queue`, annotation
`runai/enforce-scheduler-name=true`) and a `Queue` (`scheduling.run.ai/v2`).
Two projects with 0.5 GPU each make quota, sharing and reclaim visible on a
single card.

**The big question first: do GPU fractions work on a consumer RTX 4080?**
Yes. A pod with `gpu-fraction: "0.5"` sees 8188 of 16376 MiB, and a
reservation pod holds the GPU in `runai-reservation`.

Thirteen labs, each with a `check.sh` that fails when the feature misbehaves
(see `labs/README.md`). What the cluster taught, beyond the docs:

| Finding | Where |
|---|---|
| A plain **Job** gets PodGroup priority `low`, **preemptible** (docs: Job = Build, non-preemptible) | Lab 01 |
| A plain **Pod** is **non-preemptible**, so it can never go over quota (`NonPreemptibleOverQuota`), even with an idle GPU | Lab 06 |
| `gpu-memory` that is not a whole percentage of the card (4096 of 16376 MiB = 25.01%) is rounded to 26% and then **rejected by Run:ai's own webhook**: the pod never binds. 4094 (25%) works | Lab 04 |
| Docs suggest `kai.scheduler/...portion.limit` with `gpu-fraction` for dynamic fractions; the **webhook rejects** that combination. NVIDIA's `gpu-memory.request`/`limit` annotations alone work (request 4G, burst to 6 GiB, capped at 8G) | Lab 10 |
| Memory isolation is real: with 0.25 GPU, PyTorch gets 2 GiB and is refused 6 GiB | Lab 05 |
| Eviction events sit on the **PodGroup**, not the pod: `Pod ... was preempted by workload ...` | Labs 07, 08, 11 |
| Gang scheduling: two 0.6-GPU pods with `minMember: 2` both wait ("Resources were found for 1 pods while 2 are required") | Lab 09 |
| A Service named `jupyter` injects `JUPYTER_PORT` and crashes JupyterLab | Lab 12 |

Test-writing lessons from the labs: match events by **pod UID** (names repeat
between runs, old events linger), and with `set -o pipefail` a `grep` that
finds nothing ends the script.


## Step 19: An independent review

With everything green, a second model (Claude Fable) reviewed the repo
read-only, with the goal and the code but not my conclusions. It found one
blocking bug that every test on this machine had hidden:

**The labs could never log in on a fresh install.** The Ansible role had just
been changed to store the *full* admin password (`Ra1-` + random) in
`~/.config/runai-oss/admin-password`, while `labs/lib.sh` still added the
`Ra1-` prefix itself. On a new machine: `Ra1-Ra1-...`, "could not log in",
13 failed labs. Here it passed only because the local file was still in the
old format. Fixed in `lib.sh`, and the file migrated once.

The rest, all fixed:

| Finding | Fix |
|---|---|
| Password drift: set `$RUNAI_ADMIN_PASSWORD` once, run without it later, and a new random password was used against a control plane that keeps the old one | the role always stores the password it uses, then logs in once and fails with a clear message if the control plane disagrees |
| Labs 06/09 and `pending_reason` matched events by name: a stale event from an earlier run could produce a false PASS | events matched by object UID everywhere |
| `project_create` returned before the Queue existed, with no timeout | waits for namespace **and** Queue, 120 s cap |
| Secrets on command lines (`ps`): admin password and bootstrap token in `helm --set-string`, password in `curl -d` | passed on stdin (`helm -f -`, `curl -d @-`); `no_log` on every task carrying the bearer token |
| The "dry run first" ran under `no_log`, so it showed nothing | replaced with printing the rendered values (no secrets in them) |
| Lab cleanups used `--wait=false`: the next lab could start while the last one's pods still held the GPU | cleanups wait for deletion |
| Prometheus role ignored values changes; node DNS override always reported `changed` | values compared; DNS written only when different |
| Docs drift: old k3s version in a sample, an unused switch, two README commands that fail on a re-run, private addresses in this log | fixed; addresses here are now documentation examples (192.0.2.10) |

Lesson: a reviewer that did not write the code reads the *current* state of
every file. I had changed the role and the helper an hour apart and every
test still passed, because the test machine carried state from before.


## Step 20: Second track: Rocky Linux 10.2 VM, RKE2, GPU passthrough

k3s is not on Run:ai's support list; RKE2 is. And a VM is closer to a real
GPU node (and to Proxmox): the node is a machine, not a container, so the GPU
Operator can install the driver itself. The VM track reuses the earlier SecOps
lab's KVM design (Ansible + `virt-install` + cloud-init, no Terraform) with
Rocky Linux 10.2 instead of SLES.

What was checked before writing a line:

| Need | Found |
|---|---|
| Newest Rocky 10 cloud image | 10.2, `Rocky-10-GenericCloud-Base-10.2-20260525.0.x86_64.qcow2` + official SHA256 |
| GPU Operator on Rocky 10 | supported, with Rocky driver containers; `nvcr.io/nvidia/driver:615.71.09-rocky10` exists |
| RKE2 on EL10 | official installer has an EL10 RPM repo, `rke2-selinux` policy included; Traefik is the default ingress since v1.36 |
| EL10 quirk | `kernel-modules-extra` needed for `nf_conntrack` (RKE2 requirements page) |
| osinfo | no `rocky10` entry yet; `rhel10.1` is the same platform |

Playbooks (`ansible/vm-*.yml`, all with `-e @vm.local.yml`; the network
settings live in that gitignored file, the repo only has `vm.example.yml`):

1. **`vm-host.yml`**: `gpu_passthrough` role (from the SecOps lab, permanent
   and off modes only; its on-demand mode once froze this host) writes the
   vfio-pci binding, rebuilds the initrd and stops for a reboot. After the
   reboot both GPU functions sat on `vfio-pci`; the `rocky_vm` role then built
   the VM: 16 vCPU, 48 GB, 200 GB disk, UEFI **without Secure Boot** (the
   operator builds an unsigned driver inside), GPU hostdevs `managed='no'`.
2. **`vm-guest.yml`**: Rocky prep, RKE2 `v1.37.1+rke2r1` from the EL10 RPMs.
   dnf pulled a newer kernel with `kernel-modules-extra`; the role rebooted
   once. SELinux stays Enforcing.
3. **`vm-cluster.yml`**: GPU Operator v26.7.1 with `driver.enabled=true`. The
   driver container installed kernel headers for the VM's own kernel,
   compiled the modules and loaded them: inside the VM, `nvidia-smi` shows the
   RTX 4080 SUPER on 615.71.09.

All shared roles took a `kube_context` variable (default `k3d-runai`), so the
same GPU Operator, cert-manager and Run:ai roles, tests and labs serve both
tracks.

**The platform tests caught two RKE2 differences** (6 of 8 failed at first):

- **No default nvidia runtime.** RKE2 registers the `nvidia` runtime once the
  operator's toolkit exists, but keeps `runc` as the default. GPU pods ran
  without the driver: `nvidia-smi: command not found`, `CUDA driver version is
  insufficient`. Making nvidia the default *before* the toolkit exists would
  break every pod, so the `rke2` role adds `default-runtime: nvidia` only when
  `/usr/local/nvidia/toolkit/nvidia-container-runtime` is present, and
  `vm-cluster.yml` re-applies it after the operator (one RKE2 restart).
- **Traefik's Service is `rke2-traefik`**, not `traefik`. The ingress test now
  tries both. On RKE2 Traefik runs as a DaemonSet with hostPorts 80/443, so
  the VM's address serves ingress directly.

After the fixes: **8/8 platform tests PASS on Rocky + RKE2.**


## Step 21: Keep the GPU node for GPU work only

A single node that runs the control plane, Run:ai's ~40 services and the
GPU workloads is fine for k3d, but it is not how a GPU cluster should look:
controllers and services eat CPU and memory on the most expensive machine.
Run:ai has node roles for exactly this:

| Label | For |
|---|---|
| `node-role.kubernetes.io/runai-system=true` | Run:ai control plane + cluster services |
| `node-role.kubernetes.io/runai-gpu-worker=true` | GPU workloads |
| `node-role.kubernetes.io/runai-cpu-worker=true` | CPU-only workloads |

By default Run:ai only *prefers* system nodes, and
`clusterConfig.global.nodeAffinity.restrictScheduling` turns the worker roles
into requirements. So the VM track became two VMs:

| VM | Role | Size |
|---|---|---|
| `runai-cp` | RKE2 server; runai-system + runai-cpu-worker | 12 vCPU, 40 GB |
| `runai-rocky` | RKE2 agent with the GPU; runai-gpu-worker only | 8 vCPU, 24 GB |

No taint on the GPU node: fractional pods do not request `nvidia.com/gpu`,
so they would not get the automatic toleration. Instead every system
component gets a *required* placement on the system node, from one variable
(`system_node_selector`), and `vm-verify.yml` fails if the GPU node runs
anything but DaemonSets and GPU workloads.

**What it took, in the order the cluster revealed it:**

1. **Node-role labels cannot come from the kubelet.** NodeRestriction stops a
   kubelet from setting `node-role.kubernetes.io/*` on its own node, so the
   labels are applied with `kubectl label` from the server, as Run:ai's
   node-roles guide does.
2. **SELinux blocked the volumes.** local-path-provisioner's helper pod could
   not create `/opt/local-path-provisioner/...` ("Permission denied"), every
   PVC stayed Pending and the control-plane install timed out after 20
   minutes. Fix: the directory gets the `container_file_t` type, registered
   with `semanage fcontext` so a relabel keeps it. SELinux stays Enforcing.
3. **`global.affinity` does not reach the subcharts.** 24 Run:ai services
   landed on `runai-cp`, but Keycloak and thanos-query on the GPU node: the
   third-party subcharts (`keycloakx`, `postgresql.primary`, `thanos.query`,
   `thanos.receive`, `nats`) default to a YAML anchor of the chart's own
   *preferred* affinity, which a user value for `global.affinity` does not
   change. Each now gets the required affinity explicitly (keycloakx as a
   template string).
4. **RKE2's own add-ons.** coredns had no node restriction and ran on the GPU
   node. `HelmChartConfig` manifests pin coredns and metrics-server to the
   system node. Then coredns would not finish rolling out: its chart
   *requires* one replica per node and its autoscaler keeps two replicas, so
   on one system node the second replica can never schedule. The
   anti-affinity is now *preferred*; helm merged the new value with the
   default until the required key was set to `null` explicitly.
5. GPU Operator, cert-manager and kube-prometheus-stack controllers got a
   `nodeSelector`; their per-node DaemonSets (driver, toolkit, device plugin,
   DCGM, node-exporter) still cover the GPU node, as they must.


## Step 22: Run:ai on the two-node RKE2 cluster, and a hardening that breaks fractions

After the placement fixes, `runai.yml` installed Run:ai unchanged on RKE2:
cluster `Connected`, all operands ready, UI at `https://runai.<cp-ip>.nip.io`.
Two more things surfaced on the way:

- **CPU requests, not CPU usage.** With 12 vCPU the control-plane VM was at
  94% of its CPU *requests* before Run:ai's cluster side was even installed;
  the third NATS replica could not schedule ("Insufficient cpu"), JetStream
  could not create its streams and `audit-service` and `tenants-manager`
  crash-looped. Run:ai's requirements (about 10 CPU for the control plane +
  10 for cluster services) were right: the VM went to 20 vCPU (offline
  resize with `virsh setvcpus --config`).
- **Two more controllers on the GPU node.** `vm-verify.yml` caught
  `karta-operator` and the `gpu-fractioning` controller, both from subcharts
  of the cluster chart (`karta.nodeSelector`,
  `kai-resource-management.kai-scheduler.gpu-fractioning.nodeSelector`). The
  cluster role now also applies values changes to an installed release
  (compared without the cluster UID and the spent bootstrap token). After
  that: "runai-rocky runs 13 pods, all DaemonSets or GPU workloads".

Then the labs: scheduling labs passed, but **every GPU-fraction lab failed**:
inside a fractional pod there was no `/dev/nvidia*` and no `nvidia-smi`.
The pod spec asks for no GPU at all (fractions do not request
`nvidia.com/gpu`); Run:ai's fractioning layer injects
`NVIDIA_VISIBLE_DEVICES=GPU-<uuid>` (plus `NVIDIA_GPU_MEMORY_REQUEST/LIMIT`)
into the container when it is created. RKE2's GPU Operator guide recommends
`ACCEPT_NVIDIA_VISIBLE_DEVICES_ENVVAR_WHEN_UNPRIVILEGED=false` so pods cannot
grab GPUs through that variable, and the toolkit duly ignored it. On k3d the
toolkit ran with defaults (`true`), which is why fractions worked there.

**Run:ai fractions need `ACCEPT_NVIDIA_VISIBLE_DEVICES_ENVVAR_WHEN_UNPRIVILEGED=true`.**
The trade-off is documented next to the setting: an unprivileged pod could
set the variable itself; whole-GPU requests still go through volume mounts.
After the change all five fraction labs passed on Rocky + RKE2.

Also found: Rocky's GenericCloud image enables **Cockpit** (web console on
port 9090, reachable from the LAN). Nobody can log in (the user has no
password), but it is an extra admin login page on the LAN. Now a switch,
`vm_cockpit` (see Step 24). And with the GPU passed through, the VM's text
console shows up on the monitor plugged into the GPU while the keyboard stays
with the host: expected, the host console lives on the iGPU / IP-KVM.

## Step 23: Logging in to the UI, and a "changed" that never stopped

With the labs green on the VM track, the next question was the obvious one:
what are the username and password for the UI? The answers were spread over
a role default, a generated file and a CA file nobody had trusted yet, so
they now have their own page, [ui-access.md](ui-access.md): user
`admin@runai.local`, the password from `~/.config/runai-oss/admin-password`
(generated once, shared by both tracks), and how to trust
`runai-ca.pem` on macOS, Linux, Windows and Firefox. Watching the Workloads
page while `labs/run.sh` ran was a good first tour: each lab's pods appear,
go Pending for the reason the lab is about (a gang that doesn't fit, a
foreground pod waiting for a background one to be reclaimed) and disappear.

The full VM run (second run of every playbook, all 13 labs, `vm-verify.yml`)
passed, except idempotence: `vm-guest.yml` and `vm-cluster.yml` reported
`changed=1` on every run. The culprit was the node-role task:
`kubectl label --overwrite` prints `node/runai-cp not labeled` when nothing
changes, and the check was `'labeled' in stdout`. Substring checks on
human-readable output need the negative case tested too. Now
`'not labeled' not in stdout`, and the second run reports `changed=0`.

## Step 24: Password login for the VMs, as a switch

Cockpit was on in both VMs but useless: cloud-init locks the `rocky` password.
Rather than set one by hand, `rocky_base` got two switches, both off by
default:

- `vm_cockpit`: generates a password once into
  `~/.config/runai-oss/vm-password` (0600, outside the repo), sets it for
  `rocky`, starts Cockpit. Off masks `cockpit.socket`, so no login page sits
  on the LAN.
- `vm_ssh_password`: also accepts that password over SSH, through
  `/etc/ssh/sshd_config.d/40-runai-oss.conf`. sshd keeps the first value it
  reads and loads drop-ins in name order, so `40-` beats cloud-init's
  `50-cloud-init.conf` (`PasswordAuthentication no`).

Root stays locked in both cases. Two small traps. Ansible's `password_hash`
filter needs Python's `crypt` module, which is gone from the control node's
Python 3.15, so the hash is made on the guest with `openssl passwd -6`.
And a random salt would change the hash on every run (`changed=1` forever),
so the salt comes from the host name: same password, same hash, `changed=0`.
Checked without putting the password on a command line: Cockpit's
`/cockpit/login` with curl reading `-K -` from stdin (200 on both VMs), and
SSH with `SSH_ASKPASS` reading the file.

## Step 25: The VM track becomes the main track

Before calling the VM track done, the one suite never run on it: the platform
tests. `CONTEXT=rke2-runai-cp tests/run.sh`, all 8 PASS, including
TensorFlow (151 s) and TensorRT (91 s) on the passed-through card, and test 07
against RKE2's `rke2-traefik` service, which had only been adjusted, never run.

| Check on the VM track | Result |
|---|---|
| Second run of every playbook | `changed=0` |
| `labs/run.sh`, 13 labs | all PASS |
| `tests/run.sh`, 8 platform tests | all PASS |
| `vm-verify.yml` (GPU node runs GPU work only) | PASS |

So the README now leads with the VM track: two Rocky Linux 10.2 VMs on RKE2,
a supported Kubernetes, separate system and GPU nodes, SELinux enforcing. k3d
stays as the quick start: same labs, same Run:ai roles, and it is the only
option on a machine that cannot pass a GPU to a VM. Tagged `v0.2.0`
(`v0.1.0` is the k3d-only version).

A side effect worth knowing for the article: with the GPU passed through, the
monitor cable on the NVIDIA card shows the VM's console, and the keyboard,
still on the host, does nothing there. The host's screen is on the
motherboard's output (the CPU's integrated GPU). Switch the monitor's input,
don't pass the keyboard through.

Also on the k3d side: the CUDA node images moved from a private registry to
a public Docker Hub repository, so readers can pull instead of build.

Then back to normal mode, and one more YAML trap: `gpu_passthrough_mode: off`
reached the playbook as the boolean `false` (YAML 1.1 reads bare
`on`/`off`/`yes`/`no` as booleans), so the mode check failed before anything
changed. It has to be written `"off"`; the check now says so when it sees a
boolean. Off mode also turns autostart off for both VMs now, not only the GPU
VM: without its GPU node the control-plane VM would just hold 20 vCPUs and
40 GB of the host.

## Step 26: Lab helpers that wait for the cluster

Running the labs back to back, many times, on the RKE2 cluster turned up races
between a command and Kubernetes that a single run rarely hits. `labs/lib.sh`
now absorbs them:

- `project_create` returned once the namespace and queue existed, but Run:ai's
  admission webhook learns about a project a little later and refused pods
  ("project team-a does not exist"), worst right after a delete. It now waits
  until a server-side dry run of a pod passes that webhook, and
  `project_delete` waits until the webhook has forgotten the project.
- A lab that stopped half-way left pods holding the GPU, and the next lab timed
  out. `lab_reset` deletes every workload in the lab namespaces.
- `kubectl get` exits 0 on "not yet", so reading a pod right after `apply`
  shows Pending and proves nothing. New helpers wait for the state first:
  `wait_running` (pods with generated names, e.g. a Job's), `wait_logs` and
  `wait_events`. Events live for hours and names repeat, so `wait_events` only
  shows events newer than `$LAB_START` when the caller sets it.
- The lab pods run `sleep` as PID 1, which ignores SIGTERM, so every delete
  waited out the 30 s grace period. `terminationGracePeriodSeconds: 2` in the
  lab manifests: lab 02 went from about 100 s to 30 s.

One finding for lab 04: 4096 MiB rounds up to 26 % of the card, so next to the
lab's first 4094 MiB pod team-a would need 0.51 GPUs of its 0.5 quota, and the
scheduler refuses it for quota before the binding error the lab is about can
appear. `check.sh` frees the first pod before trying 4096, and that order
matters.

## Step 27: The workstation console on the IP-KVM

A host fix for the IP-KVM: Ubuntu here is text-only, and the kernel
puts its console on framebuffer 0. That is the RTX 4080 in normal mode, and
the card's dark firmware framebuffer while it is passed through, so the KVM on
the motherboard HDMI (framebuffer 1, `amdgpu`) never got a login prompt in
either mode. `con2fbmap` (package `fbset`) moved the consoles over live. The
first permanent attempt, `fbcon=map:1` on the kernel command line, held for
one boot only: in passthrough mode no firmware framebuffer is registered and
the motherboard GPU becomes fb0, so `map:1` pointed at nothing and the KVM
went dark again. The number depends on the mode, so the fix finds the
framebuffer by name: a small boot service maps tty1-6 to whichever `fbN` is
called `amdgpudrmfb`. The cleaner fix is in the firmware: make the integrated
GPU the primary display, which also stops the passed-through card from being
the boot VGA. While there: GRUB waits 5 s before booting Ubuntu, except after
an unclean shutdown, when Ubuntu's recordfail logic waits 30 s;
`GRUB_RECORDFAIL_TIMEOUT=5` makes it 5 s always.

---

## Next

- "Dashboard tour" lab and an "In the UI" section per lab, checked with screenshots.
- A VM track (libvirt locally, Proxmox later): RKE2 (on Run:ai's support
  list, unlike k3s), GPU passthrough, GPU Operator installing the driver,
  multiple nodes. Needs a `kube_context` variable in the roles.
- With a second GPU: multi-GPU fractions, bin-pack vs spread, consolidation,
  distributed training, node pools.
- Publish: MkDocs Material on GitHub Pages.

## Lessons so far

1. A Secure Boot host with a DKMS GPU driver can lose the GPU after any
   firmware change. Distro-signed modules remove that failure mode.
2. Installing a kernel as a dependency can skip `linux-modules-extra`. On a
   desktop board that can mean no network after reboot.
3. Read the kernel log of the failed boot, not the current one. The answer
   ("unavailable key is rejected") was only in the boot where the module was
   actually tried.
4. In k3d, "GPU allocated" and "driver available in the pod" are different
   things. The container runtime does the second part.
5. Every version choice for this stack is capped by Run:ai's support matrix,
   not by "latest".
6. Run everything twice. The second run of a playbook found a restart loop
   and a setting that never existed, both invisible on the first run.
7. Copied config deserves a source check: an env var carried along for months
   turned out to do nothing.
8. A test that only prints is not a test. "Succeeded" hid TensorFlow running
   on the CPU; the fix was in the test (assert), then in the image (cuDNN 9).
9. Official framework images can be broken. Check that the framework really
   uses the GPU, not just that the container starts.
10. Read the product's source when the docs are versioned loosely: support
    ranges, scheduler name and removed CRDs were all different from the guide.
11. Wait for the platform's own health signal (cluster `Connected`, every
    operand ready), not for "all deployments available".
12. Where the cluster and the docs disagree, teach what the cluster does and
    say so. Four such gaps turned up in thirteen labs.
13. A machine that passes every test can still hide a bug a fresh install
    hits at once: leftover state (here, an old password file) masks it. Get a
    review from someone, or something, that did not write the code.
