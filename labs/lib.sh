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
  if [[ -n $(project_id "$name") ]]; then
    echo "project $name exists"
  else
    api /api/v1/org-unit/projects -X POST -d "$(jq -n \
      --arg n "$name" --arg c "$(cluster_id)" --arg np "$(nodepool_id default)" \
      --argjson g "$gpu" --argjson l "$limit" '{
        name: $n, clusterId: $c,
        resources: [{nodePool: {id: $np, name: "default"},
                     gpu: {deserved: $g, limit: $l},
                     cpu: {deserved: -1, limit: -1},
                     memory: {deserved: -1, limit: -1, units: "Mib"}}]}')" \
      | jq -r '"project \(.name) created: GPU deserved \(.resources[0].gpu.deserved), limit \(.resources[0].gpu.limit)"'
  fi
  # The cluster agent turns it into namespace runai-<name> and a Queue, and
  # Run:ai's admission webhook learns about it a little later: until then pods
  # are refused ("project <name> does not exist"), which bites right after a
  # project was deleted and created again. A server-side dry run goes through
  # that webhook (sideEffects=None) without creating anything.
  for _ in $(seq 1 60); do
    k get ns "runai-$name" >/dev/null 2>&1 && k get queues.scheduling.run.ai "$name" >/dev/null 2>&1 \
      && k -n "runai-$name" run admission-probe --image=registry.k8s.io/pause:3.10 \
           --restart=Never --dry-run=server >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "error: project $name not ready (namespace, queue, admission) within 120s" >&2; return 1
}

# project_delete <name>: idempotent, a project that is already gone is fine.
# Returns once the admission webhook has forgotten it too: a project created
# again right after a delete would otherwise race the webhook's stale entry.
project_delete() {
  local id; id=$(project_id "$1")
  [[ -n $id ]] || { echo "project $1 not found"; return 0; }
  api "/api/v1/org-unit/projects/$id" -X DELETE -o /dev/null || return 1
  for _ in $(seq 1 60); do
    k -n "runai-$1" run admission-probe --image=registry.k8s.io/pause:3.10 \
      --restart=Never --dry-run=server >/dev/null 2>&1 || break
    sleep 2
  done
  echo "project $1 deleted"
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

# lab_reset: delete every workload the labs create, in all three lab
# namespaces, so a lab starts on an idle GPU even when an earlier one stopped
# half-way. Projects stay.
lab_reset() {
  local ns
  for ns in runai-team-a runai-team-b runai-batch; do
    k get ns "$ns" >/dev/null 2>&1 || continue
    k -n "$ns" delete deploy,job,pod --all --wait=true --timeout=180s >/dev/null 2>&1
  done
  return 0
}

# wait_pods <ns> <selector> [timeout]: wait until a pod matching the selector
# exists (a Job's pod appears a moment after the Job).
wait_pods() {
  local ns=$1 sel=$2 t=${3:-120}
  for ((i = 0; i < t; i += 2)); do
    [[ -n $(k -n "$ns" get pods -l "$sel" -o name 2>/dev/null) ]] && return 0
    sleep 2
  done
  echo "timeout: no pod matching $sel in $ns" >&2; return 1
}

# wait_running <ns> <selector> [timeout]: wait until a pod matching the
# selector is Running (pods of a Job or Deployment, whose names are generated;
# evicted or terminating pods with the same labels are ignored).
wait_running() {
  local ns=$1 sel=$2 t=${3:-300}
  for ((i = 0; i < t; i += 3)); do
    [[ -n $(k -n "$ns" get pods -l "$sel" --field-selector=status.phase=Running -o name 2>/dev/null) ]] && return 0
    sleep 3
  done
  echo "timeout: no Running pod matching $sel in $ns" >&2; return 1
}

# wait_logs <ns> <pod> [timeout]: print a pod's log once it has one (the pod
# may still be pulling or starting right after kubectl apply).
wait_logs() {
  local ns=$1 pod=$2 t=${3:-300} out
  for ((i = 0; i < t; i += 3)); do
    out=$(k -n "$ns" logs "$pod" 2>/dev/null) && [[ -n $out ]] && { echo "$out"; return 0; }
    sleep 3
  done
  echo "timeout: no log from $ns/$pod" >&2; return 1
}

# wait_events <ns> <regex> [timeout]: wait for events matching <regex> that
# were recorded since $LAB_START (set it before a scenario, UTC ISO 8601),
# then print the last three. Old events live for hours and repeat the same
# names, so anything older is ignored.
wait_events() {
  local ns=$1 re=$2 t=${3:-120} out
  for ((i = 0; i < t; i += 3)); do
    out=$(k -n "$ns" get events -o json | jq -r --arg t "${LAB_START:-1970-01-01T00:00:00Z}" \
      '.items[] | select((.lastTimestamp // .eventTime // "") >= $t)
       | "\(.reason): \(.involvedObject.kind)/\(.involvedObject.name): \(.message)"' | grep -E "$re")
    [[ -n $out ]] && { tail -3 <<<"$out"; return 0; }
    sleep 3
  done
  echo "timeout: no event matching '$re' in $ns" >&2; return 1
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

# Exported so the helpers also work in child shells (bash -c, xargs, watch):
# they need the settings they read too. The password stays in the environment,
# never on a command line.
export CONTEXT RUNAI_URL RUNAI_USER RUNAI_PASSWORD
export -f k api cluster_id nodepool_id project_id project_create project_delete lab_reset wait_phase wait_pods wait_running wait_logs wait_events pending_reason
