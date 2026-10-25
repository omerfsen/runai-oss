# Ansible

Builds a single-node GPU Kubernetes cluster on an Ubuntu 24.04 workstation
with an NVIDIA GPU, and NVIDIA Run:ai 3.0 (open source) on top.

| Playbook | Runs as | Does |
|---|---|---|
| `host.yml` | root (sudo) | signed NVIDIA driver, `linux-generic`, container toolkit, Docker runtime; stops once for a reboot if the driver changed |
| `cluster.yml` | your user (docker group) | builds the k3s CUDA node image locally, creates the k3d cluster, installs GPU Operator, cert-manager and a demo app |
| `runai.yml` | your user | kube-prometheus-stack, lab CA + certificates (cert-manager), Run:ai control plane, cluster registration over the REST API, Run:ai cluster; waits until the cluster is Connected |
| `teardown.yml` | your user | deletes the cluster (image and driver stay) |

## Run

```bash
cd ansible
ansible-playbook host.yml            # reboot if it asks, then run it again
ansible-playbook cluster.yml
ansible-playbook runai.yml           # ~10 minutes; UI at https://runai.<host-ip-with-dashes>.nip.io
kubectl --context k3d-runai get nodes
```

Run:ai admin: `admin@runai.local`, password from `$RUNAI_ADMIN_PASSWORD` or
generated once into `~/.config/runai-oss/admin-password`. Trust
`~/.config/runai-oss/runai-ca.pem` in the browser: steps per OS in
[docs/ui-access.md](../docs/ui-access.md).

Needs on the host: Docker, k3d v5.9.0, kubectl, helm, ansible-core 2.16+.

## VM track: Rocky Linux 10.2 + RKE2, dedicated GPU node

Production-shaped alternative to k3d: two KVM VMs, RKE2 (on Run:ai's support
list), the GPU passed through to one of them. Settings live in a gitignored
`vm.local.yml`, copied from `vm.example.yml`.

| VM | Role | Run:ai node role |
|---|---|---|
| `runai-cp` (20 vCPU, 40 GB) | RKE2 server, Run:ai control plane + cluster services, Prometheus, cert-manager | `runai-system`, `runai-cpu-worker` |
| `runai-rocky` (8 vCPU, 24 GB, GPU) | RKE2 agent, GPU workloads only | `runai-gpu-worker` |

| Playbook | Does |
|---|---|
| `vm-host.yml` | GPU to vfio-pci (stops once for a host reboot), creates both VMs (cloud-init, UEFI without Secure Boot) |
| `vm-guest.yml` | Rocky prep (SELinux enforcing), RKE2 server + agent, node roles, kubeconfig context `rke2-runai-cp` |
| `vm-cluster.yml` | GPU Operator (builds the 615 driver inside the GPU VM), cert-manager, nvidia as default runtime |
| `runai.yml` | the same Run:ai install as on k3d |
| `vm-verify.yml` | fails if anything but DaemonSets and GPU work runs on the GPU node |
| `vm-teardown.yml` | deletes both VMs |

```bash
cp vm.example.yml vm.local.yml        # set your bridge, addresses, GPU PCI ids
ansible-playbook vm-host.yml -e @vm.local.yml      # reboot when asked, run again
ansible-playbook vm-guest.yml -e @vm.local.yml
ansible-playbook vm-cluster.yml -e @vm.local.yml
ansible-playbook runai.yml -e @vm.local.yml
ansible-playbook vm-verify.yml -e @vm.local.yml
CONTEXT=rke2-runai-cp ../labs/run.sh
```

While the GPU is passed through, the host (and the k3d track) has no GPU and
the monitor on the NVIDIA card is dark. Back: `gpu_passthrough_mode: off` in
`vm.local.yml`, `vm-host.yml`, reboot.

## Switches

All in `group_vars/all.yml`, or per run with `-e`:

```bash
ansible-playbook cluster.yml -e gpus=0                  # CPU-only cluster
ansible-playbook cluster.yml -e install_demo=false
ansible-playbook cluster.yml -e demo_host=demo.example.com -e letsencrypt_email=you@example.com
ansible-playbook cluster.yml -e node_image_rebuild=true # rebuild the node image
```

## What "done" looks like

```
Cluster runai (k3s v1.37.1-k3s1, 1 GPU) on <host-ip>:80/443, kubectl context k3d-runai.
GPU Operator up, CUDA validator passed, node GPU: NVIDIA-GeForce-RTX-4080-SUPER
cert-manager v1.21.3 running.
Demo answers through Traefik: http://demo.example.com (HTTP 200)
```

A second run of `cluster.yml` reports `changed=0`.
