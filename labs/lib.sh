#!/usr/bin/env bash
# Shared helpers for the labs. Source it: `source labs/lib.sh`.
#
# Projects, quotas and departments live in the Run:ai control plane (not in
# Kubernetes), so the labs create them through its REST API. Workloads are
# plain Kubernetes YAML.

CONTEXT="${CONTEXT:-k3d-runai}"
RUNAI_URL="${RUNAI_URL:-https://$(kubectl --context "$CONTEXT" -n runai-backend get ingress runai-backend-ingress -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)}"
RUNAI_USER="${RUNAI_USER:-admin@runai.local}"
RUNAI_PASSWORD="${RUNAI_PASSWORD:-${RUNAI_ADMIN_PASSWORD:-$(cat ~/.config/runai-oss/admin-password 2>/dev/null)}}"

k() { kubectl --context "$CONTEXT" "$@"; }

# api <path> [curl args...]: authenticated call to the Run:ai REST API.
# The lab CA is self-signed, hence -k; the token is never printed.
api() {
  local path=$1; shift
  if [[ -z ${_RUNAI_TOKEN:-} ]]; then
    # The password goes to curl on stdin (-d @-), not on its command line.
    _RUNAI_TOKEN=$(jq -n --arg u "$RUNAI_USER" --arg p "$RUNAI_PASSWORD" \
        '{grantType:"password",username:$u,password:$p}' \
      | curl -sk -X POST "$RUNAI_URL/api/v1/token" -H 'Content-Type: application/json' -d @- \
      | jq -r .accessToken)
    [[ -n $_RUNAI_TOKEN && $_RUNAI_TOKEN != null ]] || { echo "error: could not log in to $RUNAI_URL" >&2; return 1; }
  fi
  curl -sk -H "Authorization: Bearer $_RUNAI_TOKEN" -H 'Content-Type: application/json' "$RUNAI_URL$path" "$@"
}

cluster_id()   { api /v1/k8s/clusters | jq -r '.[0].uuid'; }
nodepool_id()  { api /api/v1/node-pools | jq -r --arg n "${1:-default}" '.nodepools[] | select(.name==$n) | .id'; }
project_id()   { api /api/v1/org-unit/projects | jq -r --arg n "$1" '.projects[] | select(.name==$n) | .id'; }

# project_create <name> <gpu-deserved> [gpu-limit]: a project in the default
# department with a GPU quota; CPU and memory unlimited. Idempotent.
project_create() {
  local name=$1 gpu=$2 limit=${3:--1}
  if [[ -n $(project_id "$name") ]]; then echo "project $name exists"; return 0; fi
  api /api/v1/org-unit/projects -X POST -d "$(jq -n \
    --arg n "$name" --arg c "$(cluster_id)" --arg np "$(nodepool_id default)" \
    --argjson g "$gpu" --argjson l "$limit" '{
      name: $n, clusterId: $c,
      resources: [{nodePool: {id: $np, name: "default"},
                   gpu: {deserved: $g, limit: $l},
                   cpu: {deserved: -1, limit: -1},
                   memory: {deserved: -1, limit: -1, units: "Mib"}}]}')" \
    | jq -r '"project \(.name) created: GPU deserved \(.resources[0].gpu.deserved), limit \(.resources[0].gpu.limit)"'
  # The cluster agent turns it into namespace runai-<name> and a Queue.
  for _ in $(seq 1 60); do
    k get ns "runai-$name" >/dev/null 2>&1 && k get queues.scheduling.run.ai "$name" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "error: namespace runai-$name / queue $name did not appear within 120s" >&2; return 1
}

project_delete() {
  local id; id=$(project_id "$1")
  [[ -n $id ]] && api "/api/v1/org-unit/projects/$id" -X DELETE -o /dev/null && echo "project $1 deleted"
}

# wait_phase <ns> <pod> <phase> [timeout]: wait for a pod phase.
wait_phase() {
  local ns=$1 pod=$2 want=$3 t=${4:-300} p=""
  for ((i = 0; i < t; i += 3)); do
    p=$(k -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || true
    [[ $p == "$want" ]] && return 0
    sleep 3
  done
  echo "timeout: $ns/$pod is '$p', wanted $want" >&2; return 1
}

# pending_reason <ns> <object> [kind]: the scheduler's explanation for a
# Pending pod (or a PodGroup with kind=podgroups.scheduling.run.ai). Matched by
# UID: names repeat between runs and old events live for an hour.
pending_reason() {
  local uid
  uid=$(k -n "$1" get "${3:-pod}" "$2" -o jsonpath='{.metadata.uid}' 2>/dev/null) || return 0
  k -n "$1" get events --field-selector "involvedObject.uid=$uid" \
    -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' | tail -3
}
