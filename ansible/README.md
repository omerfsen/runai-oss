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
`~/.config/runai-oss/runai-ca.pem` in the browser.

Needs on the host: Docker, k3d v5.9.0, kubectl, helm, ansible-core 2.16+.

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
