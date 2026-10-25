# Lab 12: An interactive workspace with its own URL

**Goal:** give a data scientist JupyterLab with half a GPU, reachable in the
browser at its own HTTPS address.

## Concept

Interactive work (notebooks, VS Code in the browser) needs a URL, not just a
pod. On this cluster:

- **Traefik** routes a plain `kind: Ingress` by host name
- **nip.io** resolves any `*.runai.<ip-with-dashes>.nip.io` to the host IP:
  every workspace gets a name with no DNS work
- **cert-manager** issues the certificate from the lab CA: the Ingress only
  needs the annotation `cert-manager.io/cluster-issuer: runai-ca`
- the pod asks for `gpu-fraction: "0.5"`: two notebooks can share the card

The login token comes from a Secret, never from the YAML.

## Steps

```bash
DOMAIN=$(kubectl -n runai-backend get ingress runai-backend-ingress -o jsonpath='{.spec.rules[0].host}')
kubectl -n runai-team-a create secret generic jupyter-token --from-literal=token=$(openssl rand -hex 16) \
  --dry-run=client -o yaml | kubectl apply -f -
sed "s/RUNAI_DOMAIN/$DOMAIN/g" labs/12-interactive-url/jupyter.yaml | kubectl apply -f -
kubectl -n runai-team-a rollout status deploy/jupyter      # first time: ~5 GB image
kubectl -n runai-team-a get certificate jupyter-tls        # READY True

echo "https://jupyter-team-a.$DOMAIN/?token=$(kubectl -n runai-team-a get secret jupyter-token -o jsonpath='{.data.token}' | base64 -d)"
```

Open the URL (trust `~/.config/runai-oss/runai-ca.pem` in the browser to skip
the warning). In a notebook:

```python
import torch
torch.cuda.get_device_name(0), torch.cuda.mem_get_info()[1] / 2**30
# ('NVIDIA GeForce RTX 4080 SUPER', 8.0)
```

## Gotchas met while building it

- **Service named `jupyter`** makes Kubernetes inject `JUPYTER_PORT=tcp://...`,
  which Jupyter reads as its port and crashes. Fixed with
  `enableServiceLinks: false`.
- **Readiness probe on `/api/status`** gets 403 (it needs the token), so the pod
  never turns Ready. Probe `/api` instead.
- **First pull** of the 5 GB image outlasts the default 10-minute rollout
  deadline: `progressDeadlineSeconds: 1800`.

Clean up:

```bash
sed "s/RUNAI_DOMAIN/$DOMAIN/g" labs/12-interactive-url/jupyter.yaml | kubectl delete -f -
kubectl -n runai-team-a delete secret jupyter-token jupyter-tls
```
