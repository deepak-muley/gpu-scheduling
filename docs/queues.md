# How queues work

A queue is KAI Scheduler's version of a Run:ai project. Workloads do not ask the default Kubernetes scheduler for a GPU. They name a leaf queue, and KAI decides when they run.

```yaml
metadata:
  labels:
    kai.scheduler/queue: team-a
spec:
  schedulerName: kai-scheduler
```

The objects in `manifests/queues.yaml` are `scheduling.run.ai/v2` `Queue`s. Only a leaf queue can run jobs. `research` is the department (a parent). `team-a` and `team-b` are its children, and they are the queues the demo pods use.

```
research          department, no jobs of its own
├── team-a        leaf, gpu.quota 2
└── team-b        leaf, gpu.quota 2
```

KAI also installs `default-parent-queue` and `default-queue`. This demo does not submit work to them.

## Quota, limit, and weight

Each resource (cpu, memory, gpu) has three fields:

| Field | Meaning |
| --- | --- |
| `quota` | How much the queue is guaranteed when it asks for it. KAI hands out guarantees before any spare capacity. |
| `limit` | The most the queue may hold, including capacity it borrowed. |
| `overQuotaWeight` | How spare capacity is split between queues that already have their quota. Both teams use `1`, so they split spare GPUs evenly. |

KAI does this in two steps:

1. Give every queue `min(quota, what it is asking for)`. Queue priority does not matter here. With four GPUs and both teams asking for work, each team gets two.
2. Give out whatever is left. A higher `priority` on the queue is served first. Queues with the same priority split the remainder by `overQuotaWeight`. Neither team sets `priority`, so weight is the only tie-break, and they match.

That is why team-a can run four 1-GPU trainings while team-b is idle. team-a's guarantee is 2, and `gpu.limit: -1` allows the other two. When team-b submits a training, team-b is still under its guarantee of 2 and team-a is over its guarantee, so KAI reclaims one preemptible team-a pod. Trainings use priority class `train` (value 50). A workload is preemptible when its priority is below 100. The notebook pods use `build` (100), so they stay inside the guarantee and are not reclaimed.

## What `-1` means

`-1` is a sentinel. It is not a quantity of CPU, memory, or GPUs.

| Field | `-1` | `0` or omitted |
| --- | --- | --- |
| `quota` | Unlimited guarantee | No guarantee |
| `limit` | No cap | The queue may not take anything beyond its quota |

A real number is a quantity, and the unit depends on the resource:

| Resource | Unit of a positive number | Example |
| --- | --- | --- |
| `cpu` | millicores (`1000` = 1 core) | `quota: 2000` guarantees 2 cores |
| `memory` | megabytes | `quota: 4096` guarantees 4 GB |
| `gpu` | whole devices | `quota: 2` guarantees 2 GPUs |

### `cpu.quota: -1` and `cpu.limit: -1`

On `research`, `team-a`, and `team-b`, both CPU fields are `-1`. The queue's CPU guarantee is unlimited, and the queue has no CPU cap. KAI will not hold a pod back because of CPU fair-share, and it will not stop a queue from using more CPU when the node has some free.

The same pair is set for memory. GPU is the resource this lab actually divides: each team has `gpu.quota: 2` and `gpu.limit: -1`.

`research` uses `-1` for GPU quota and limit as well. The department does not keep a GPU budget of its own. The four simulated devices are split by the two leaf quotas.

Leaving CPU unset would not mean "ignore CPU". An omitted quota is `0` (nothing guaranteed) and an omitted limit is `0` (nothing beyond the quota). A team could then be blocked on CPU even while GPUs were free. `-1` is what turns that accounting off.

The demo containers do not set CPU requests or limits. Node capacity still applies. The queue numbers do not.

`gpu.quota` counts the extended resource `nvidia.com/gpu`. A DRA claim is a different resource, `gpu.nvidia.com`, and this quota does not cap it. That path is described in [mechanisms.md](mechanisms.md).
