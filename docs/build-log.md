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
