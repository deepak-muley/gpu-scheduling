#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${CLUSTER:-gpu-sharing}"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  kind delete cluster --name "${CLUSTER}"
else
  echo "cluster ${CLUSTER} is not present"
fi
