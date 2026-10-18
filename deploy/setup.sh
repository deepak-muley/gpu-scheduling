#!/usr/bin/env bash
# Same-cluster lab for the Run:ai sharing model, without a physical GPU.
#
# Production same-cluster install (real GPUs) is:
#   1. NVIDIA GPU Operator
#   2. Ingress and a storage class (only needed for the Run:ai UI)
#   3. runai-cluster Helm chart, with the command and NGC key from the Run:ai UI
# This script is the no-GPU stand-in described in
# https://anishbista.org/blog/nvidia-runai-open-source/ :
#   fake-gpu-operator  -> advertises nvidia.com/gpu
#   KAI Scheduler      -> the scheduler the Run:ai cluster chart installs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-gpu-sharing}"
FAKE_GPU_VERSION="${FAKE_GPU_VERSION:-0.2.1}"
KAI_VERSION="${KAI_VERSION:-v0.18.6}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need kind
need kubectl
need helm
need docker

if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not reachable" >&2
  exit 1
fi

echo "==> kind cluster ${CLUSTER}"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "cluster ${CLUSTER} already exists"
else
  kind create cluster --name "${CLUSTER}" --config "${ROOT}/deploy/kind-config.yaml"
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

echo "==> label worker nodes for the fake GPU pool"
# Control-plane nodes stay unlabeled so they do not advertise GPUs.
workers=()
while IFS= read -r node; do
  [[ -n "${node}" ]] && workers+=("${node}")
done < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name)
if [[ ${#workers[@]} -eq 0 ]]; then
  echo "no worker nodes found" >&2
  exit 1
fi
kubectl label "${workers[@]}" run.ai/simulated-gpu-node-pool=default --overwrite

echo "==> fake-gpu-operator ${FAKE_GPU_VERSION}"
# DRA=1 also publishes ResourceSlices. Fractional pods then stay Pending;
# see docs/mechanisms.md. Leave DRA unset for the fraction and quota demos.
helm_values=(--values "${ROOT}/deploy/fake-gpu-values.yaml")
if [[ "${DRA:-}" == "1" ]]; then
  echo "DRA overlay enabled; gpu-fraction and gpu-memory pods will not schedule"
  helm_values+=(--values "${ROOT}/deploy/dra-values.yaml")
fi
helm upgrade --install gpu-operator \
  "oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator" \
  --version "${FAKE_GPU_VERSION}" \
  --namespace gpu-operator --create-namespace \
  "${helm_values[@]}" \
  --wait --timeout 10m

if [[ "${DRA:-}" != "1" ]]; then
  # The DRA plugins create ResourceSlices at runtime. Helm does not delete
  # those, and KAI keeps refusing fractional pods while a slice remains.
  while IFS=$'\t' read -r name driver; do
    [[ -z "${name}" ]] && continue
    if [[ "${driver}" == "gpu.nvidia.com" || "${driver}" == "compute-domain.nvidia.com" ]]; then
      kubectl delete resourceslice "${name}" --wait=false
    fi
  done < <(kubectl get resourceslices -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.driver}{"\n"}{end}' 2>/dev/null || true)
fi

echo "==> wait until the worker advertises 4 GPUs"
deadline=$((SECONDS + 180))
until kubectl get nodes -l 'run.ai/simulated-gpu-node-pool=default' \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  | awk '$2+0>=4 {found=1} END {exit found?0:1}'; do
  if ((SECONDS > deadline)); then
    kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
    echo "timed out waiting for simulated GPUs" >&2
    exit 1
  fi
  sleep 5
done
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'

echo "==> KAI Scheduler ${KAI_VERSION}"
helm upgrade --install kai-scheduler \
  "oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler" \
  --version "${KAI_VERSION}" \
  --namespace kai-scheduler --create-namespace \
  --values "${ROOT}/deploy/kai-values.yaml" \
  --wait --timeout 10m

echo "==> wait for the KAI operator to roll out its controllers"
# The chart's --wait covers the operator. The operator then creates the
# scheduler, admission, and queue webhook deployments.
for dep in queue-controller admission binder pod-grouper podgroup-controller kai-scheduler-default; do
  deadline=$((SECONDS + 600))
  until kubectl get "deployment/${dep}" -n kai-scheduler >/dev/null 2>&1; do
    if ((SECONDS > deadline)); then
      echo "deployment ${dep} was not created" >&2
      kubectl get deploy,pods -n kai-scheduler
      exit 1
    fi
    sleep 5
  done
  kubectl wait --for=condition=available "deployment/${dep}" -n kai-scheduler --timeout=10m
done

echo "==> queues (Run:ai projects)"
kubectl apply -f "${ROOT}/manifests/namespaces.yaml"
# The queue webhook can refuse connections for a few seconds after the pod is Ready.
deadline=$((SECONDS + 180))
until kubectl apply -f "${ROOT}/manifests/queues.yaml"; do
  if ((SECONDS > deadline)); then
    echo "timed out applying queues" >&2
    exit 1
  fi
  sleep 5
done
kubectl get queues

echo
echo "cluster ${CLUSTER} is ready. Next: make demo"
