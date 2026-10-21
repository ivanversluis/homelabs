# Kubernetes requests, limits and KubeVirt memory: a homelab lab

> A practical companion to the 23 September 2026 Portainer article **"KubeVirt and Windows"** by Neil. This is an original technical explanation and validation guide, not a reproduction of the article.
>
> Scope: the Git-managed configuration of [ivanversluis/homelabs](https://github.com/ivanversluis/homelabs). Commands below inspect **live** Kubernetes state, which can differ from Git. Verified from repository manifests on 10 October 2026; no live-cluster access was used to prepare this guide.

## The mental model: Kubernetes is not VMware

Kubernetes normally schedules **Pods** into **Nodes**. A Namespace is an administrative boundary, **not** a pool of physical CPU/RAM. Namespaces can have admission policies such as LimitRange (individual container defaults/constraints) and ResourceQuota (aggregate namespace budget).

~~~text
Cluster
  +-- Node k8s-worker03 (physical RAM, CPU, allocatable capacity)
      +-- Pod: normal application container(s)
      +-- Pod: virt-launcher for KubeVirt Debian VM
          +-- compute container / QEMU process
              +-- Debian guest: configured vCPU and guest RAM
  +-- Namespace vms               [logical scope across nodes]
      +-- VirtualMachine debian-bookworm
      +-- optionally: ResourceQuota and LimitRange
~~~

A Namespace can span nodes. ResourceQuota does not physically partition or reserve RAM. The scheduler considers **requests** against a node's **allocatable** capacity; the kernel/runtime enforce **limits** during execution. Actual working-set usage can be lower or higher than the request.

| Term | What it means | What it does **not** mean |
| --- | --- | --- |
| Node capacity | Physical/logical capacity reported by kubelet | All available for application Pods |
| Node allocatable | Capacity available for scheduling after node reservations | RAM already consumed |
| Memory request | Scheduling/accounting amount | Preallocated, pinned physical RAM |
| Memory limit | Runtime upper bound; exceeding it can cause OOM kill | A guaranteed amount of available RAM |
| CPU request | Scheduling budget and proportional share under contention | A physically dedicated core |
| CPU limit | Enforced CPU-time ceiling (throttling) | A second CPU reservation |
| Actual usage | Observed resource consumption at a point in time | The same metric as a request |
| Guest memory | RAM presented inside a KubeVirt VM | Automatically identical to host RSS or virt-launcher request |

Example: a 16 GiB physical node may expose **less** than 16 GiB as allocatable. If a Pod requests 1 GiB and has a 2 GiB memory limit, the scheduler accounts for 1 GiB. The Pod may use 1.5 GiB while the host has headroom. If multiple Pods do that together, node memory pressure can cause OOM kills or eviction; unused request is **not** a private RAM allocation.

**Important gotcha:** in typical container specs, if only a limit is provided and there is no admission-time default request, Kubernetes normally copies the limit into the request. If you want different values, set both explicitly. CPU unit `1000m` = 1 CPU; `100m` = 0.1 CPU. Memory `Gi` means GiB (binary), not GB (decimal).

## Requests versus limits with regular containers

~~~yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
~~~

The Pod contributes **100m CPU + 128 MiB memory** to the scheduling accounting; it may briefly consume up to **500m CPU** before CPU throttling and up to **512 MiB memory** before memory-limit enforcement. Reaching a memory limit may kill the container; CPU throttling merely slows it down. Node-level pressure can also evict Pods even when they are below their own memory limit.

Quality of Service (QoS): `Guaranteed` requires matching nonzero CPU **and** memory requests and limits for **every** container; `Burstable` has at least one declared CPU/memory request or limit but does not satisfy Guaranteed; `BestEffort` has neither. Matching **memory alone** does not establish Guaranteed. Inspect the *actual generated Pod* because admission controllers and KubeVirt can change resource values.

## Where the homelab differs: KubeVirt

The repository declares:

| Component | Git definition |
| --- | --- |
| KubeVirt | v1.8.2, namespace `kubevirt` |
| Debian VM | `VirtualMachine/debian-bookworm`, namespace `vms` |
| VM node | `k8s-worker03` via `nodeSelector` |
| Guest CPUs | `domain.cpu.cores: 2` (two vCPUs) |
| Guest/requested RAM | `resources.requests.memory: 2Gi` |
| Explicit memory limit | `resources.limits.memory: 2Gi` |
| VM disk | local-path PVC, 20 GiB, node-local NVMe-backed storage |
| Metrics | metrics-server and Prometheus/Grafana configured in repo |

Sources: [Debian VM manifest](../workloads/vms/debian-bookworm-vm.yaml), [KubeVirt configuration](../platform/virtualization/kubevirt/kubevirt-cr.yaml), [KubeVirt platform runbook](kubevirt.md), [observability](observability.md).

**Two vCPUs are not the same as a Kubernetes CPU request of 2.** Without an explicit VM CPU request, KubeVirt normally requests 1/10 CPU per vCPU by default (so approximately **200m** for a two-vCPU VM). A configured topology describes what Debian sees; it does not reserve two dedicated physical host cores. Inspect the real compute container for the exact value.

**KubeVirt memory includes overhead.** A VM that wants 2 GiB for Debian normally creates a virt-launcher Pod whose memory *request* exceeds 2 GiB, because QEMU and virtualization infrastructure need additional host memory. The overhead is calculated, not a single fixed amount valid for all VMs.

### Configuration finding to verify first

The Git manifest explicitly makes both VM memory request and memory limit **2Gi**. Current upstream KubeVirt documentation warns that a manually specified memory limit must exceed **VM memory request plus computed overhead**, or the generated Pod can be rejected, and tight caps can crash a VM under memory bursts.

This is a **potential defect**, not proof of an outage. Actual version behavior, generated Pod resources, admission events and VM state must be checked before changing it. **Do not blindly patch the running VM.** The checks below establish what KubeVirt really admitted.

For a future change, a conservative design to evaluate would be: give Debian `domain.memory.guest: 2Gi`, request sufficient host memory through KubeVirt's default calculation, and **omit an explicit memory limit** unless there is a specific policy reason to cap the launcher. If a hard limit is required, it must cover guest memory, calculated overhead and sensible headroom. Review KubeVirt version behavior and schedule a controlled VM restart if the resource definition changes.

## Read-only validation: step by step

Run from a terminal where `kubectl` can access `k8s-homelab`. No objects are changed by this section. `jq` is used for formatting.

### 1. Compare node capacity, allocatable, requests and real usage

~~~bash
kubectl get nodes -o wide
kubectl get node k8s-worker03   -o jsonpath='{.status.capacity.cpu}{" CPU capacity; "}{.status.allocatable.cpu}{" CPU allocatable\n"}{.status.capacity.memory}{" memory capacity; "}{.status.allocatable.memory}{" memory allocatable\n"}'

kubectl describe node k8s-worker03
kubectl top node k8s-worker03
~~~

In `kubectl describe node`, find the **Allocated resources** section. It summarizes scheduled requests and limits for Pods on that node (including system workloads). Compare it with `kubectl top node`: a node may be **80% requested** but use only **30% RAM**, or the reverse. The scheduler considers the former, while runtime pressure depends on the latter.

### 2. Check namespaces and their policies

~~~bash
kubectl get namespaces
kubectl get resourcequota,limitrange -A
kubectl -n vms get resourcequota,limitrange
kubectl -n vms get pods -o wide
~~~

An empty quota/LimitRange result in `vms` means **no such namespace policy object**, not unlimited physical RAM and not an implicit reservation. Namespace policies apply across *all nodes* for objects in that namespace.

If a quota exists:

~~~bash
kubectl -n vms describe resourcequota
kubectl -n vms describe limitrange
~~~

### 3. Examine the VM object, the running VMI and the launcher Pod

~~~bash
kubectl -n vms get vm,vmi
kubectl -n vms get vm debian-bookworm -o yaml
kubectl -n vms get vmi debian-bookworm -o yaml
kubectl -n vms get pods -l kubevirt.io=virt-launcher -o wide --show-labels
~~~

VM = desired definition; VMI = running instance; Pod = actual Kubernetes workload. If the VM is stopped, there is no running launcher Pod to inspect. The following uses KubeVirt's domain label; verify it in `--show-labels` output if no Pod matches.

~~~bash
POD=$(kubectl -n vms get pods   -l kubevirt.io/domain=debian-bookworm   -o jsonpath='{.items[0].metadata.name}')

# Run the next commands only when POD contains a pod name.
echo "$POD"
kubectl -n vms get pod "$POD" -o json | jq '{
  pod: .metadata.name,
  node: .spec.nodeName,
  qos: .status.qosClass,
  containers: [.spec.containers[] | {
    name: .name,
    requests: .resources.requests,
    limits: .resources.limits
  }]
}'
kubectl -n vms describe pod "$POD"
kubectl -n vms top pod "$POD" --containers
~~~

What to record:

1. Guest memory declared by the VM/VMI (2Gi in Git).
2. **Actual** memory request and limit on container `compute` (including KubeVirt's computed overhead).
3. Actual Pod QoS (`Guaranteed` or `Burstable`; do not infer from the VM YAML).
4. Pod status/events: look for `FailedScheduling`, request/limit validation, `OOMKilled`, or eviction.
5. Current launcher memory usage; this is **not** the same as `free -h` inside Debian.

Optional overhead status (may be empty unless the `VmiMemoryOverheadReport` feature gate is enabled):

~~~bash
kubectl -n vms get vmi debian-bookworm   -o jsonpath='{.status.memory.memoryOverhead}{"\n"}'
~~~

Optional Linux cgroup v2 checks (only if the `compute` image exposes these files):

~~~bash
kubectl -n vms exec "$POD" -c compute -- cat /sys/fs/cgroup/memory.current
kubectl -n vms exec "$POD" -c compute -- cat /sys/fs/cgroup/memory.max
kubectl -n vms exec "$POD" -c compute -- cat /sys/fs/cgroup/cpu.max
kubectl -n vms exec "$POD" -c compute -- cat /sys/fs/cgroup/cpu.stat
~~~

On cgroup v2, `memory.max` and `cpu.max` show runtime limits (`max` means no finite cap); `cpu.stat` can reveal throttling. These are container/cgroup views, not guest totals.

### 4. Compare with what Debian sees

Use an existing guest SSH session or the documented `virtctl console debian-bookworm -n vms`. **Run these inside Debian**, not on the Kubernetes host:

~~~bash
nproc
free -h
grep -E 'MemTotal|MemFree|MemAvailable|Cached|Buffers' /proc/meminfo
lsmod | grep virtio_balloon || true
~~~

`nproc` reports usable CPUs in the guest, not CPU cores dedicated on the host. `MemAvailable` estimates guest memory available for new processes (including reclaimable guest cache). A missing `lsmod` entry does **not** prove the driver is absent: it can be built into the kernel or device support may not be active. Do not expect guest `MemFree` to equal host RAM reclaimed.

### 4b. Check Free Page Reporting configuration (no VM restart)

The virtio memory-balloon device can report free guest pages back to the host when **FPR is available and enabled**. Reporting freed pages is *not* the same as host-driven balloon inflation. Debian 12's Linux kernel is new enough for the Linux FPR feature, but the VM/cluster configuration and actual device behavior still matter. Examine these settings **without changing them**:

~~~bash
kubectl -n kubevirt get kv kubevirt -o json | \
  jq '.spec.configuration.virtualMachineOptions // {}'
kubectl -n vms get vmi debian-bookworm -o json | \
  jq '{autoattachMemBalloon: .spec.domain.devices.autoattachMemBalloon}'
~~~

An absent setting is not proof that FPR is working. To corroborate reclamation, compare the VM's guest available memory with QEMU resident memory at idle and during normal workload variation, preferably through the KubeVirt metrics below. **Do not disable caches, introduce artificial memory pressure, or change balloon settings on a live VM just to test this.**

### 5. Optional Grafana/Prometheus cross-check

Your repository includes metrics-server, Prometheus and Grafana. If kube-state-metrics and cAdvisor expose the following series, compare a memory **request**, **limit**, and **working-set usage** for the VM launcher:

~~~promql
kube_pod_container_resource_requests{namespace="vms",resource="memory",unit="byte"}
~~~

~~~promql
kube_pod_container_resource_limits{namespace="vms",resource="memory",unit="byte"}
~~~

~~~promql
container_memory_working_set_bytes{namespace="vms",container="compute"}
~~~

Filter by the current launcher `pod` label to avoid including older/other VMs. These measures answer different questions. The `kubectl` checks above remain authoritative for resource specification and Pod events.

When KubeVirt's `virt-handler` targets are scraped, you can also inspect these **guest and virtualization-specific** series (shown with the KubeVirt `name` and `namespace` labels):

~~~promql
kubevirt_vmi_memory_resident_bytes{namespace="vms",name="debian-bookworm"}
~~~

~~~promql
kubevirt_vmi_memory_usable_bytes{namespace="vms",name="debian-bookworm"}
~~~

~~~promql
kubevirt_vmi_launcher_memory_overhead_bytes{namespace="vms",name="debian-bookworm"}
~~~

The first shows **domain process resident memory**, the second guest-reported reclaimable memory, and the third an estimate of virtualization overhead. **They are not three interchangeable measures of Pod memory.** A missing series may mean its exporter is not scraped, not necessarily a VM problem. [KubeVirt metrics reference](https://kubevirt.io/monitoring/metrics.html).

## Safe hands-on lab: see how a Namespace changes defaults and quotas

**Optional, intentionally isolated from Flux-managed production namespaces.** This creates a temporary Namespace and one nearly idle Pod; it does not stress node memory, alter KubeVirt, or install swap. The example image must be pullable by your nodes.

~~~bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: resource-lab
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: lab-budget
  namespace: resource-lab
spec:
  hard:
    requests.cpu: 500m
    requests.memory: 256Mi
    limits.cpu: "2"
    limits.memory: 512Mi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: container-defaults
  namespace: resource-lab
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 64Mi
      default:
        cpu: 500m
        memory: 128Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: idle-demo
  namespace: resource-lab
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
YAML
~~~

Inspect the defaulted Pod and quota consumption:

~~~bash
kubectl -n resource-lab get pod idle-demo -o wide
kubectl -n resource-lab get pod idle-demo -o json |   jq '.spec.containers[] | {name: .name, resources: .resources}'
kubectl -n resource-lab describe resourcequota lab-budget
kubectl -n resource-lab describe limitrange container-defaults
kubectl -n resource-lab top pod idle-demo
~~~

Expected **declared** values after admission (assuming no other admission policies override them):

| Measure | Pod request | Pod limit |
| --- | --- | --- |
| CPU | 100m | 500m |
| Memory | 64Mi | 128Mi |

The ResourceQuota **Used** columns should count those declared requests/limits even when the process sleeps and consumes very little RAM. This is the distinction to remember: **quota accounting / scheduling != actual consumption**. A LimitRange supplies per-container defaults, while ResourceQuota aggregates resource budgets across a namespace. If the Pod cannot pull its image, the defaulted Pod spec can still be inspected.

Clean up everything created by this optional exercise:

~~~bash
kubectl delete namespace resource-lab
~~~

## Memory overcommit, Linux versus Windows, and the article's key trade-off

**Normal KubeVirt planning:** Debian is shown 2 GiB guest RAM, and KubeVirt schedules approximately 2 GiB **plus launcher overhead**. That is roughly 1:1 in *scheduling accounting*, **not** dedicated physical RAM. QEMU's actual RSS can vary, and a VM with more guest RAM than its requested memory can be configured deliberately, at increased risk.

**Explicit KubeVirt guest-memory overcommit** (illustration only; do not apply to the current Debian VM):

~~~yaml
domain:
  memory:
    guest: 2Gi
  resources:
    requests:
      memory: 1Gi
    # No tight memory limit
~~~

Now Debian can see 2 GiB while Kubernetes schedules against roughly 1 GiB plus overhead. This increases schedulable density, **not physical capacity**. If VMs really consume the extra memory concurrently, Kubernetes cannot conjure missing RAM: performance may collapse, VMs may be evicted or processes OOM-killed. Do not run this experiment against the current node-local production-like VM.

**Free Page Reporting (FPR)**, when supported by hypervisor and guest driver/kernel, lets the guest report freed pages that the host can reclaim. This may reduce host memory usage but **does not lower the Kubernetes request already charged to the scheduler**. FPR is different from an ESXi-like host forcing a guest to release more pages via balloon inflation. Linux guests commonly support FPR; Windows support and reclaim behavior depend on driver and virtualization platform. Do not interpret "Windows has no FPR" as "Windows cannot use *any* virtio balloon driver."

OpenShift Virtualization has additional *OpenShift-specific* density settings and `wasp-agent` swap support for qualifying VM workloads; its documented 150% configuration is **not an upstream KubeVirt default** and is not present merely because the homelab has KubeVirt installed. Avoid enabling node swap or KubeVirt memory overcommit until you have measured workload peaks, pressure, eviction events and recovery.

**Storage also matters.** KVM can provide near-native compute performance, but virtual disk performance depends on the storage path, not the choice of hypervisor alone. Your VM uses a node-local `local-path` PVC on `k8s-worker03`: that may avoid distributed-storage latency, but it ties the VM to that node and is not equivalent to a shared, live-migratable VMware datastore. The configured `LiveMigration` feature gate alone does **not** make this VM live-migratable.

**Windows licensing is more nuanced than a universal host-core rule.** Datacenter physical-core licensing can be expensive as eligible hosts grow, but Microsoft also has qualifying per-VM/vCore licensing routes under subscription/active Software Assurance, subject to minimums and product terms. Linux has a generally simpler OS-license model, but support subscriptions still matter. Evaluate licensing for the actual contract, host pool and VM workload.

## Evidence checklist

- [ ] Record `capacity`, `allocatable`, Allocated resources and `kubectl top` for `k8s-worker03`.
- [ ] Establish whether `vms` has any ResourceQuota or LimitRange.
- [ ] Compare Git VM memory request/limit against generated `virt-launcher` compute-container request/limit.
- [ ] Check whether the launcher Pod is Running, Pending or absent; capture Pod QoS and events.
- [ ] Compare `kubectl top` with Debian `free -h`; explain why the metrics are different.
- [ ] Run the isolated `resource-lab` and observe LimitRange defaults and ResourceQuota Used; delete the Namespace afterward.
- [ ] Decide whether to propose a **separate** Debian memory-limit correction after live validation, with a rollback/restart plan.
- [ ] Keep overcommit, swap, live migration and storage refactoring out of this initial learning exercise.

## Further reading

- [Kubernetes: resource management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes: LimitRange](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Kubernetes: ResourceQuota](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Kubernetes: Pod QoS](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)
- [KubeVirt: resource requests, limits, memory overhead and CPU allocation ratio](https://kubevirt.io/user-guide/compute/resources_requests_and_limits/)
- [KubeVirt: node and guest memory overcommit](https://kubevirt.io/user-guide/compute/node_overcommit/)
- [KubeVirt: live-migration requirements](https://kubevirt.io/user-guide/operations/live_migration/)
- [Red Hat: Memory management in OpenShift Virtualization](https://developers.redhat.com/blog/2025/01/31/memory-management-openshift-virtualization)
- [Red Hat: OpenShift-specific overcommit and wasp-agent](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/postinstallation-configuration)
- [Microsoft: Windows Server 2025 licensing guidance](https://www.microsoft.com/licensing/guidance/Windows-Server-2025)
