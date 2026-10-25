# runai-oss

Open-source NVIDIA Run:ai (control plane + GPU cluster) on a single
workstation, built step by step as training material.

Two ways to build the cluster. The labs, tests and Run:ai install are the same
on both:

| Track | What it is | Use it when |
|---|---|---|
| **VM** (main track) | Two Rocky Linux 10.2 KVM VMs on RKE2: a control-plane VM, and a GPU VM with the card passed through, running GPU work only. The GPU Operator installs the driver. | You want the production shape: a supported Kubernetes, separate system and GPU nodes, SELinux enforcing |
| **k3d** (quick start) | One k3s cluster in Docker on the host, using the host's driver | Your machine can't pass a GPU through to a VM, or you want it running in 15 minutes |

The GPU belongs to one track at a time: while it is passed through to the VM,
the host and k3d have no GPU (`gpu_passthrough_mode` switches it back).

## Software and versions

Everything is pinned; versions live in `ansible/group_vars/all.yml` and the
lab/test manifests. Measured on the running system, 2026-10-25.

| Layer | Software | Version |
|---|---|---|
| Host | Ubuntu | 24.04.5 LTS, kernel 6.8.0-147-generic, Secure Boot on |
| | NVIDIA driver (Canonical-signed modules) | 615.71.09 (CUDA 13.4) |
| | Docker | 29.9.2 |
| | NVIDIA Container Toolkit | 1.20.1 |
| Tools | k3d | v5.9.0 |
| | kubectl | v1.37.1 |
| | Helm | v4.3.1 |
| | Ansible | core 2.16.3 |
| k3d track | k3s (on k3d) | v1.37.1+k3s1, containerd 2.3.4 |
| | Node image | `localhost/k3s-cuda:v1.37.1-k3s1-cuda-13.4.3-base-ubuntu24.04` (built locally) |
| | CUDA base image | 13.4.3-base-ubuntu24.04 |
| | NVIDIA device plugin | v0.20.1 |
| | Traefik (ingress, bundled with k3s) | 3.7.13 |
| Add-ons | NVIDIA GPU Operator | v26.7.1 (DCGM exporter 4.6.1-4.8.4) |
| | cert-manager | v1.21.3 |
| | kube-prometheus-stack | 92.13.1 (Prometheus Operator v0.94.1) |
| Run:ai | NVIDIA Run:ai, open source | **3.0** (charts `control-plane` and `runai-cluster` 3.0.20) |
| | KAI scheduler (bundled, `kai-resource-management`) | v0.18.3 |
| VM track | Rocky Linux (both VMs) | 10.2 GenericCloud, kernel 6.12.0-211.68.1.el10_2, SELinux enforcing |
| | RKE2 | v1.37.1+rke2r1, containerd 2.3.4 |
| | NVIDIA driver (built in the VM by the GPU Operator) | `nvcr.io/nvidia/driver:615.71.09-rocky10` |
| | Traefik (bundled with RKE2) | 3.7.13 |
| | local-path-provisioner | v0.0.37 |
| | libvirt / QEMU on the host | 10.0.0 / 8.2.2 |
| Hardware | GPU | 1 x NVIDIA GeForce RTX 4080 SUPER, 16 GB |
| | CPU / RAM | AMD Ryzen 9 9900X (12 cores) / 92 GB |

Run:ai 3.0 supports Kubernetes 1.35 to 1.37 and GPU Operator 25.10 to 26.7.1;
GPU fractions need GPU Operator 26.7.1, driver r615+ and CUDA 13.4+.

## Contents

- [ansible/](ansible/): builds it all. VM track: `vm-host.yml` (GPU
  passthrough, VMs), `vm-guest.yml` (Rocky prep, RKE2), `vm-cluster.yml`
  (GPU Operator, cert-manager), `vm-verify.yml`, `vm-teardown.yml`. k3d track:
  `host.yml` (driver, toolkit), `cluster.yml`, `teardown.yml`. Both:
  `runai.yml` (Prometheus, TLS, Run:ai control plane + cluster)
- [labs/](labs/): Run:ai features, one lab per feature (projects and quotas,
  GPU fractions, sharing, memory isolation, over-quota and reclaim, priority,
  gang scheduling, dynamic fractions, background workloads, ...), each with
  a README, YAML and a `check.sh` that fails if the feature misbehaves
- [tests/](tests/): platform tests below Run:ai (GPU, CUDA, TensorFlow,
  PyTorch, TensorRT, GPU metrics, ingress, cert-manager)
- [docs/ui-access.md](docs/ui-access.md): log in to the Run:ai UI, trust the lab CA
- [docs/build-log.md](docs/build-log.md): every step, command, failure and fix

VM track (settings in a gitignored `vm.local.yml`; details in
[ansible/README.md](ansible/README.md)):

```bash
cd ansible
cp vm.example.yml vm.local.yml                    # your bridge, addresses, GPU PCI ids
ansible-playbook vm-host.yml -e @vm.local.yml     # reboot when asked, run again
ansible-playbook vm-guest.yml -e @vm.local.yml
ansible-playbook vm-cluster.yml -e @vm.local.yml
ansible-playbook runai.yml -e @vm.local.yml       # UI: https://runai.<cp-vm-ip-with-dashes>.nip.io
ansible-playbook vm-verify.yml -e @vm.local.yml   # nothing but GPU work on the GPU node
cd .. && CONTEXT=rke2-runai-cp tests/run.sh       # platform
CONTEXT=rke2-runai-cp labs/run.sh                 # all labs
```

k3d track:

```bash
cd ansible
ansible-playbook host.yml
ansible-playbook cluster.yml
ansible-playbook runai.yml          # UI: https://runai.<host-ip-with-dashes>.nip.io
cd .. && tests/run.sh               # platform
labs/run.sh                         # all labs
```
