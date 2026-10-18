# How a pod asks for a GPU

Every example uses `schedulerName: kai-scheduler` and the label `kai.scheduler/queue`. The cluster is installed with `global.gpuSharingMode: NonMemoryEnforced`. KAI places a fractional pod and holds the whole device with a reservation pod in `kai-resource-reservation`. It does not cap GPU memory inside the container.

The simulated devices are four Tesla-K80s, 11441 MiB each (`deploy/fake-gpu-values.yaml`).

## Works on the default install

| Mechanism | What the pod sets | What this lab does |
| --- | --- | --- |
| Whole GPU | `nvidia.com/gpu: "1"` | One device. `manifests/team-a-trainings.yaml`. |
| Fraction | `gpu-fraction: "0.5"` | Two such pods share one device. `manifests/share-gpu.yaml`. `0.5` is half of 11441 MiB, so KAI records `5720Mi`. |
| Memory, MiB | `gpu-memory: "5000"` | Two 5000 MiB pods share one device. A third does not fit and takes another GPU. `manifests/gpu-memory.yaml`. |
| Memory quantity | `nvidia.com/container.notebook.gpu-memory.request: 2048Mi` | Same packing, aimed at one container. An optional `.gpu-memory.limit` is stored and not enforced here. `manifests/gpu-memory-request.yaml`. |
| Several devices | `gpu-fraction-num-devices: "2"` with a fraction or a memory request | That share on each of N devices. One pod with `0.5` and `"2"` holds two GPUs. `manifests/fraction-two-devices.yaml`. |
| Which container | `gpu-fraction-container-name: notebook` | The share goes to that container instead of the first one. `manifests/fraction-named-container.yaml`. |
| Compute mode | `nvidia.com/container.<name>.gpu-compute.mode` | `time-slicing` (the default) or `sm-sharing`. Different modes are not placed on the same GPU. `manifests/fraction-compute-modes.yaml`. |

`gpu-fraction` must be greater than 0 and less than 1. `gpu-memory` is a positive integer, MiB, with no unit suffix. A pod cannot set a fraction (or `gpu-memory`) and `nvidia.com/gpu` together. Only one container in the pod can take the fractional GPU.

`sm-sharing` is the scheduling side of [MPS](https://docs.nvidia.com/deploy/mps/index.html). This node has no MPS control daemon, so the annotation separates the pods and nothing in the container talks to MPS.

Apply one file at a time. They all land in `team-a` and will stack on the same four GPUs if you apply them together.

```bash
kubectl apply -f manifests/gpu-memory.yaml
kubectl apply -f manifests/fraction-two-devices.yaml
kubectl apply -f manifests/fraction-compute-modes.yaml
```

## DRA

Dynamic Resource Allocation is a second inventory. It is off unless you install with:

```bash
DRA=1 ./deploy/setup.sh
```

That overlay (`deploy/dra-values.yaml`) starts fake-gpu-operator's DRA plugin and its compute-domain plugin. The worker then publishes four `gpu.nvidia.com` devices and one IMEX channel. KAI's `dynamicresources` plugin is already on, so it binds the claim itself.

```bash
kubectl apply -f manifests/dra-gpu.yaml          # one exclusive GPU
kubectl apply -f manifests/dra-shared-gpu.yaml   # two pods, one claim, one GPU
kubectl apply -f manifests/dra-imex.yaml         # one-node ComputeDomain channel
```

`dra-imex.yaml` creates a `ComputeDomain`. The controller turns that into a `ResourceClaimTemplate` named `imex-channel`. If the pod in the same file is rejected because the template is not there yet, apply the file again.

A `ResourceClaim` used by more than one pod has to be labeled `kai.scheduler/queue`. KAI will not schedule it otherwise. A claim template used by a single pod does not need that label; the pod's label is enough.

DRA and the fraction annotations do not run together. With the slices present, a `gpu-fraction` pod stays Pending: KAI reports that fractional pods are not supported on a DRA node. Turn DRA back off (`./deploy/setup.sh` with `DRA` unset) before `make demo`.

Two more limits, both checked on this cluster:

- The queue field `gpu.quota` counts `nvidia.com/gpu` (whole devices and reservation pods). A DRA claim is `gpu.nvidia.com`. Four exclusive claims ran on team-a while `gpu.quota` was 2. The fifth stayed Pending because the slice only has four devices.
- The device plugin still advertises `nvidia.com/gpu: 4` while the slice also has four devices. A whole-GPU pod can be scheduled on top of a GPU that a claim already holds. They are not the same allocation.

## Not available here

| Mechanism | Why it is not in this lab |
| --- | --- |
| MIG | The device plugin never advertises `nvidia.com/mig-*`, and the simulated product is a Tesla-K80. The request KAI expects, and the quota cost of a profile, are in [mig.md](mig.md). |
| HAMi | Needs `global.gpuSharingMode: HamiCore` and HAMi-core on a real GPU. This install is `NonMemoryEnforced`. |
| NvFractions enforcement | The per-container annotations above are accepted for placement. The CUDA memory cap needs the gpu-fractioning runtime and a real GPU stack. |
| MPS itself | `sm-sharing` only affects which pods share a device. There is no `nvidia-cuda-mps-control` on the kind node. |
| DRA time-slicing or MPS config | The fake slice publishes whole devices. Sharing across pods is the shared `ResourceClaim` in `manifests/dra-shared-gpu.yaml`, not a `GpuConfig` sharing strategy. |
