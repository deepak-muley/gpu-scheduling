# GPU sharing POC

Same-cluster proof of the Run:ai sharing model from [NVIDIA Just Open-Sourced Run:ai](https://anishbista.org/blog/nvidia-runai-open-source/), scaled to one kind node and four simulated GPUs.

Two teams share one pool:

| Team | Guaranteed GPUs | May borrow while the other team is idle |
| --- | --- | --- |
| team-a | 2 | yes |
| team-b | 2 | yes |

How those queues divide CPUs and GPUs, and what `cpu: -1` means, is in [docs/queues.md](docs/queues.md). Other ways to ask for a GPU (a memory size, a share of several devices, compute mode, DRA) are in [docs/mechanisms.md](docs/mechanisms.md).

The demo checks three things:

1. A project quota is a [KAI](https://github.com/NVIDIA/KAI-Scheduler) queue (`gpu.quota: 2`).
2. Two notebooks that each ask for `gpu-fraction: "0.5"` land on the same GPU. KAI holds that GPU with one reservation pod.
3. team-a runs four trainings (two GPUs over quota) while team-b is idle. When team-b submits one GPU, KAI reclaims a team-a pod. Deleting team-b's job lets that training run again.

## Why this is not the full Run:ai Helm install

A production [same-cluster install](https://docs.nvidia.com/run-ai/self-hosted/documentation/installation-and-configuration/install/guided-installation/connected-installation/same-cluster-installation) is:

1. A Kubernetes cluster with NVIDIA GPUs.
2. The NVIDIA GPU Operator (Helm repo `https://helm.ngc.nvidia.com/nvidia`, chart `gpu-operator`).
3. An ingress controller and a dynamic storage class, for the UI.
4. `helm upgrade --install runai-cluster`, using the command the Run:ai UI generates. That chart pulls images with an NGC username and API key.

This machine has no GPU, and the chart needs a registry key this repo does not have. Docker Desktop here is also about 8 GB, which is too small for the full open-source control plane (about 50 services). The behaviors above are enforced by KAI Scheduler, which is the scheduler that `runai-cluster` installs. [fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator) advertises `nvidia.com/gpu` so the scheduling decisions are real and the devices are not.

`NonMemoryEnforced` places fractional pods. It does not cap GPU memory inside the container. Memory isolation needs HAMi or NvFractions, which need a real GPU stack. DRA is a separate install (`DRA=1 ./deploy/setup.sh`) and it disables those fractional pods; details are in [docs/mechanisms.md](docs/mechanisms.md).

## Run

Requirements: Docker, kind, kubectl, Helm 3.8+.

```bash
make demo    # create the cluster, install both charts, run the three checks
make down    # delete the kind cluster
```

`make up` stops after install if you want to apply the manifests yourself:

```bash
kubectl apply -f manifests/share-gpu.yaml
kubectl apply -f manifests/team-a-trainings.yaml
kubectl apply -f manifests/team-b-training.yaml
```

Pinned charts: fake-gpu-operator `0.2.1`, KAI Scheduler `v0.18.6`. The fake-gpu chart is pointed at KAI's reservation namespace (`kai-resource-reservation`); its default is still the older `runai-reservation` name, and fractional pods never bind without that.
