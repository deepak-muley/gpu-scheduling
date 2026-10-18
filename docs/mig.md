# Multi-Instance GPU

MIG splits one physical GPU into instances that the hardware isolates from each other. Each instance has its own compute engines, memory, and L2 cache. A container on one slice cannot read or stall a container on another slice of the same GPU. NVIDIA supports this on A100, A30, H100, and newer data-center GPUs. A profile name such as `1g.5gb` is the instance: the number before `g` is how many compute slices it takes, and the number before `gb` is its memory.

KAI schedules a MIG pod by the extended resource for that profile. The pod still names a leaf queue and `kai-scheduler`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mig-small
  namespace: team-a
  labels:
    kai.scheduler/queue: team-a
spec:
  schedulerName: kai-scheduler
  containers:
    - name: train
      image: registry.k8s.io/pause:3.10
      resources:
        limits:
          nvidia.com/mig-1g.5gb: "1"
```

A second pod with the same limit needs its own instance. Two `1g.5gb` requests do not land in one slice.

KAI v0.18.6 charges the queue's `gpu` quota by the number in front of `g`, multiplied by how many instances the pod requests. `nvidia.com/mig-1g.5gb: "1"` costs 1. `nvidia.com/mig-3g.20gb: "1"` costs 3. `nvidia.com/mig-1g.5gb: "2"` costs 2. With team-a's guarantee of 2, two `1g.5gb` pods sit inside the guarantee, and one `3g.20gb` pod is over it. `gpu.limit: -1` still allows the borrow, as long as the node has that profile free.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mig-large
  namespace: team-b
  labels:
    kai.scheduler/queue: team-b
spec:
  schedulerName: kai-scheduler
  containers:
    - name: train
      image: registry.k8s.io/pause:3.10
      resources:
        limits:
          nvidia.com/mig-3g.20gb: "1"
```

After a bind, KAI records `received-resource-type: MigInstance` on the pod.

## Mixed and single

The node label `nvidia.com/mig.strategy` matters only once KAI treats the node as MIG-enabled. That is either `node-role.kubernetes.io/mig-enabled=true`, or (when that label is absent) a positive allocatable `nvidia.com/mig-*` resource.

| Strategy | What a pod may ask for |
| --- | --- |
| `mixed` | A `nvidia.com/mig-<profile>` resource. Whole-GPU and fractional pods are rejected on that node. |
| `single` | `nvidia.com/gpu`. The device plugin has already counted each slice as one GPU, and a profile request is rejected. |
| unset, while the node is not MIG-enabled | Ignored. This lab's worker carries `nvidia.com/mig.strategy=mixed` from the chart default and still schedules fractional pods, because it is not MIG-enabled. |

Fractional annotations (`gpu-fraction`, `gpu-memory`) and MIG are separate paths. A MIG instance is a fixed hardware slice. A fraction is a scheduler share of whatever memory the whole device has, with no hardware boundary in `NonMemoryEnforced` mode.

## Why this cluster has no MIG manifest

fake-gpu-operator `0.2.1` is the chart this repo installs. Its device plugin registers `nvidia.com/gpu` only, so `nvidia.com/mig-1g.5gb` never becomes allocatable and the pods above stay Pending. [Issue 177](https://github.com/run-ai/fake-gpu-operator/issues/177) describes that gap. `v0.2.1` is still the latest release, and the device plugin on `main` has the same limit.

`mig-faker` is enabled in the chart. It starts only on a node labeled `node-role.kubernetes.io/runai-dynamic-mig=true`, and it only rewrites node metadata from the `run.ai/mig.config` annotation. It does not register a device plugin. On this worker the product label is `Tesla-K80`, and the faker accepts only product names that contain `40GB` or `80GB`. Applying a `1g.5gb` config here logs `gpuProduct Tesla-K80 not supported` and leaves `nvidia.com/gpu: 4` unchanged.

The annotation it parses, for a product it does support, is:

```yaml
run.ai/mig.config: |
  version: v1
  mig-configs:
    selected:
      - devices: ["0"]
        mig-enabled: true
        mig-devices:
          - name: 1g.5gb
            position: 0
            size: 1
```

`devices` is a list of GPU indexes as strings. That annotation is how the faker records a mapping. A scheduler still needs something else, the NVIDIA device plugin on a real MIG GPU, to publish `nvidia.com/mig-1g.5gb`.

Profiles for an A100 40GB include `1g.5gb`, `2g.10gb`, `3g.20gb`, `4g.20gb`, and `7g.40gb`. An A100 80GB or H100 80GB uses names such as `1g.10gb`, `2g.20gb`, `3g.40gb`, and `7g.80gb`. The exact set is the GPU's, from the [MIG user guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html). KAI counts whatever profile the device plugin advertised, using the number before `g`.
