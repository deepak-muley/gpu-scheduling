#!/usr/bin/env bash
# Demonstrates the sharing behaviors from
# https://anishbista.org/blog/nvidia-runai-open-source/ on the local kind cluster:
#   1. projects are KAI queues with a GPU quota
#   2. two 0.5 GPU notebooks share one device
#   3. an idle team's GPUs are borrowed, then reclaimed
#   4. two gpu-memory pods share one device
#   5. one pod holds a fraction of two devices
#   6. time-slicing and sm-sharing land on different devices
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-gpu-sharing}"

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  "${ROOT}/deploy/setup.sh"
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

dump_debug() {
  echo "----- nodes -----"
  kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu' || true
  echo "----- queues -----"
  kubectl get queues -o wide || true
  echo "----- pods -----"
  kubectl get pods -A -o wide || true
  echo "----- recent events -----"
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true
}
trap 'status=$?; if ((status != 0)); then dump_debug; fi' EXIT

count_running() {
  local ns="$1" selector="$2" n
  n="$(kubectl get pods -n "${ns}" -l "${selector}" --field-selector=status.phase=Running -o name 2>/dev/null || true)"
  if [[ -z "${n}" ]]; then
    echo 0
  else
    echo "${n}" | wc -l | tr -d ' '
  fi
}

wait_until() {
  local desc="$1" timeout="$2"
  shift 2
  local start=$SECONDS
  until "$@"; do
    if ((SECONDS - start > timeout)); then
      echo "timed out waiting for: ${desc}" >&2
      return 1
    fi
    sleep 5
  done
  echo "ok: ${desc}"
}

clear_workloads() {
  kubectl delete job,pod --all -n team-a --ignore-not-found --wait=true >/dev/null
  kubectl delete job,pod --all -n team-b --ignore-not-found --wait=true >/dev/null
  # Reservation pods disappear after the fractional pods are gone.
  if kubectl get ns kai-resource-reservation >/dev/null 2>&1; then
    wait_until "GPU reservation pods removed" 120 \
      bash -c '[[ -z "$(kubectl get pods -n kai-resource-reservation -o name 2>/dev/null || true)" ]]'
  fi
}

echo "==> demo 1: projects become queues"
kubectl get queues -o custom-columns='NAME:.metadata.name,PARENT:.spec.parentQueue,GPU_QUOTA:.spec.resources.gpu.quota,GPU_LIMIT:.spec.resources.gpu.limit'
quota_a="$(kubectl get queue team-a -o jsonpath='{.spec.resources.gpu.quota}')"
quota_b="$(kubectl get queue team-b -o jsonpath='{.spec.resources.gpu.quota}')"
parent="$(kubectl get queue team-a -o jsonpath='{.spec.parentQueue}')"
[[ "${quota_a}" == "2" && "${quota_b}" == "2" && "${parent}" == "research" ]]
echo "ok: team-a and team-b each deserve 2 GPUs under research"

echo "==> demo 2: two notebooks share one GPU"
clear_workloads
kubectl apply -f "${ROOT}/manifests/share-gpu.yaml"
wait_until "nb1 and nb2 running" 180 bash -c '[[ "$(kubectl get pods -n team-a -l app=shared-notebook --field-selector=status.phase=Running -o name | wc -l | tr -d " ")" == "2" ]]'

notebook_nodes=()
while IFS= read -r node; do
  [[ -n "${node}" ]] && notebook_nodes+=("${node}")
done < <(kubectl get pods -n team-a -l app=shared-notebook -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)
[[ ${#notebook_nodes[@]} -eq 1 ]]
echo "ok: both notebooks are on ${notebook_nodes[0]}"

kubectl get pods -n team-a -l app=shared-notebook \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,FRACTION:.metadata.annotations.gpu-fraction'

wait_until "one reservation pod holds the shared GPU" 120 bash -c '[[ "$(kubectl get pods -n kai-resource-reservation --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d " ")" == "1" ]]'
kubectl get pods -n kai-resource-reservation -o wide

echo "==> demo 3: borrow idle GPUs, then give them back"
clear_workloads
kubectl apply -f "${ROOT}/manifests/team-a-trainings.yaml"
wait_until "team-a running 4 GPUs (2 over its quota of 2)" 180 bash -c '[[ "$(kubectl get pods -n team-a -l app=team-a-training --field-selector=status.phase=Running -o name | wc -l | tr -d " ")" == "4" ]]'
echo "ok: team-a borrowed the idle GPUs"
kubectl get pods -n team-a -l app=team-a-training -o wide

kubectl apply -f "${ROOT}/manifests/team-b-training.yaml"
wait_until "team-b reclaimed 1 GPU from team-a" 240 bash -c '
  b=$(kubectl get pods -n team-b -l app=team-b-training --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d " ")
  a=$(kubectl get pods -n team-a -l app=team-a-training --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d " ")
  [[ "$b" == "1" && "$a" == "3" ]]
'
echo "ok: b1 is running and one team-a training was reclaimed"
kubectl get pods -n team-a -l app=team-a-training -o wide
kubectl get pods -n team-b -l app=team-b-training -o wide
kubectl get events -A --field-selector involvedObject.kind=PodGroup --sort-by=.lastTimestamp | tail -20 || true

kubectl delete job b1 -n team-b --wait=true
wait_until "team-a training resumed after b1 finished" 240 bash -c '[[ "$(kubectl get pods -n team-a -l app=team-a-training --field-selector=status.phase=Running -o name | wc -l | tr -d " ")" == "4" ]]'
echo "ok: deleting b1 returned the GPU and all four team-a trainings are running"
kubectl get pods -n team-a -l app=team-a-training -o wide

echo "==> demo 4: two gpu-memory pods share one device"
clear_workloads
kubectl apply -f "${ROOT}/manifests/gpu-memory.yaml"
wait_until "mem1 and mem2 running" 180 bash -c '[[ "$(kubectl get pods -n team-a -l app=gpu-memory --field-selector=status.phase=Running -o name | wc -l | tr -d " ")" == "2" ]]'
wait_until "one reservation pod holds the memory share" 120 bash -c '[[ "$(kubectl get pods -n kai-resource-reservation --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d " ")" == "1" ]]'
kubectl get pods -n team-a -l app=gpu-memory \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,MEMORY:.metadata.annotations.gpu-memory'
echo "ok: 5000 MiB + 5000 MiB fit on one of the 11441 MiB GPUs"

echo "==> demo 5: one pod takes half of two GPUs"
clear_workloads
kubectl apply -f "${ROOT}/manifests/fraction-two-devices.yaml"
wait_until "two-dev running" 180 bash -c '[[ "$(kubectl get pods -n team-a -l app=fraction-two-devices --field-selector=status.phase=Running -o name | wc -l | tr -d " ")" == "1" ]]'
wait_until "two reservation pods hold the two devices" 120 bash -c '[[ "$(kubectl get pods -n kai-resource-reservation --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d " ")" == "2" ]]'
echo "ok: gpu-fraction 0.5 across 2 devices reserved both GPUs"

echo "==> demo 6: different compute modes do not share a GPU"
clear_workloads
kubectl apply -f "${ROOT}/manifests/fraction-compute-modes.yaml"
wait_until "slice and sm running" 180 bash -c '[[ "$(kubectl get pods -n team-a -l app=compute-mode --field-selector=status.phase=Running -o name | wc -l | tr -d " ")" == "2" ]]'
wait_until "one reservation per compute mode" 120 bash -c '[[ "$(kubectl get pods -n kai-resource-reservation --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d " ")" == "2" ]]'
modes="$(kubectl get pods -n kai-resource-reservation -o jsonpath='{range .items[*]}{.metadata.annotations.nvidia\.com/container\.resource-reservation\.gpu-compute\.mode}{"\n"}{end}' | sort | tr '\n' ' ')"
[[ "${modes}" == "sm-sharing time-slicing " ]]
echo "ok: time-slicing and sm-sharing each hold their own GPU"

echo
echo "all six sharing demos passed"
