#!/usr/bin/env bash
# Lab 12: JupyterLab with 0.5 GPU behind Traefik at its own HTTPS URL, with a
# certificate from the lab CA; the notebook kernel sees half the GPU.
set -euo pipefail
cd "$(dirname "$0")" && source ../lib.sh
domain=${RUNAI_URL#https://}
host="jupyter-team-a.$domain"
cleanup() {
  sed "s/RUNAI_DOMAIN/$domain/g" jupyter.yaml | k delete -f - --ignore-not-found --wait=true --timeout=120s >/dev/null
  k -n runai-team-a delete secret jupyter-token jupyter-tls --ignore-not-found >/dev/null
}
trap cleanup EXIT

k -n runai-team-a create secret generic jupyter-token --from-literal=token="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
token=$(k -n runai-team-a get secret jupyter-token -o jsonpath='{.data.token}' | base64 -d)
sed "s/RUNAI_DOMAIN/$domain/g" jupyter.yaml | k apply -f - >/dev/null

# First run pulls a ~5 GB image.
k -n runai-team-a rollout status deploy/jupyter --timeout=900s >/dev/null
k -n runai-team-a wait --for=condition=Ready certificate/jupyter-tls --timeout=120s >/dev/null

code=$(curl -s -o /dev/null -w '%{http_code}' --cacert ~/.config/runai-oss/runai-ca.pem \
  "https://$host/api/status?token=$token")
[[ $code == 200 ]] || { echo "FAIL: https://$host/api/status answered $code"; exit 1; }
echo "  https://$host: HTTP $code, certificate trusted via the lab CA"

pod=$(k -n runai-team-a get pod -l app=jupyter -o jsonpath='{.items[0].metadata.name}')
gib=$(k -n runai-team-a exec "$pod" -- python -c \
  "import torch; print(round(torch.cuda.mem_get_info()[1] / 2**30, 1))")
echo "  notebook kernel sees ${gib} GiB of GPU memory"
awk -v g="$gib" 'BEGIN { exit !(g > 7 && g < 8.5) }' || { echo "FAIL: expected about half the GPU"; exit 1; }
echo "PASS: interactive workspace with half a GPU at its own HTTPS URL"
