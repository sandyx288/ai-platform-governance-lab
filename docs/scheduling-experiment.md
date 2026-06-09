# Scheduling Experiment

Hands-on walkthrough of the two-phase Volcano scheduling experiment demonstrating resource borrowing and gang scheduling under contention.

## Background

The 2-node cluster (2 × Standard_D2as_v4 = 4 vCPU total) runs system pods alongside tenant workloads. Volcano queues partition logical capacity:

| Queue | Deserved | Capability | Weight |
|-------|----------|------------|--------|
| `ai-research-queue` | 3 CPU | 6 CPU | 3 |
| `ai-product-queue` | 3 CPU | 6 CPU | 3 |
| `data-science-queue` | 1 CPU | 3 CPU | 1 |

Total deserved = 7 CPU (exceeds physical capacity by design — models oversubscription).

## Pre-flight checks

```bash
kubectl get nodes
kubectl get queues
kubectl get priorityclass | grep ai-
kubectl top nodes          # optional, requires metrics-server
```

Ensure namespaces exist:

```bash
kubectl get ns ai-research ai-product data-science
```

## Phase 1 — Data Science borrows idle capacity

**Hypothesis:** A low-priority Data Science job can schedule beyond its queue's deserved allocation when cluster resources are idle.

### Submit the job

```bash
kubectl apply -f volcano/ds-borrower-job.yaml
```

Job spec summary:

| Field | Value |
|-------|-------|
| Name | `ds-borrower` |
| Namespace | `data-science` |
| Queue | `data-science-queue` |
| Priority | `ai-low-priority` (10000) |
| Replicas | 2 |
| CPU request | 1 per pod |
| minAvailable | 1 |

### Observe

```bash
kubectl get vcjob -n data-science
kubectl get pods -n data-science -l volcano.sh/job-name=ds-borrower
kubectl describe vcjob ds-borrower -n data-science
```

**Expected result:**

- Both pods reach `Running` state
- Data Science queue consumes 2 CPU — exceeding its 1 CPU deserved allocation
- Demonstrates **burstable sharing**: idle capacity is borrowed

### Inspect queue status

```bash
kubectl get queue data-science-queue -o yaml
```

Look at allocated vs deserved resources in the queue status section.

---

## Phase 2 — High-priority Research gang job under contention

**Hypothesis:** When cluster CPU is saturated, a high-priority gang job with `minAvailable: 2` will remain Pending because Volcano cannot satisfy the all-or-nothing gang constraint.

### Submit the job

```bash
kubectl apply -f volcano/research-high-job.yaml
```

Job spec summary:

| Field | Value |
|-------|-------|
| Name | `research-high` |
| Namespace | `ai-research` |
| Queue | `ai-research-queue` |
| Priority | `ai-high-priority` (100000) |
| Replicas | 2 |
| CPU request | 1 per pod |
| minAvailable | 2 (gang scheduling) |

### Observe

```bash
kubectl get vcjob -n ai-research
kubectl get pods -n ai-research -l volcano.sh/job-name=research-high
kubectl describe vcjob research-high -n ai-research
```

**Expected result:**

- Job status: Pending (or pods in Pending)
- Volcano events show:
  - Queue-based scheduling evaluation
  - Gang scheduling constraint (`minAvailable: 2` not satisfiable)
  - Insufficient CPU capacity in cluster

### Read scheduler events

```bash
kubectl describe vcjob research-high -n ai-research | tail -20
kubectl get events -n ai-research --sort-by='.lastTimestamp' | tail -10
```

Example event patterns to look for:

```
Insufficient cpu
pod group unschedulable
queue resource insufficient
```

---

## Phase 3 (optional) — Observe reclamation

To trigger reclamation, scale up demand on a queue that previously lent resources:

1. Submit additional high-priority jobs to `ai-research-queue`
2. Watch Volcano's reclaim action evict lower-priority borrowed pods

```bash
# Monitor Volcano controller logs
kubectl logs -n volcano-system -l app=volcano-scheduler --tail=50 -f
```

When reclaim fires, Data Science pods from Phase 1 may be terminated to return capacity to the owning queue.

---

## Cleanup

```bash
kubectl delete -f volcano/ds-borrower-job.yaml
kubectl delete -f volcano/research-high-job.yaml

# Verify pods are gone
kubectl get pods -n data-science
kubectl get pods -n ai-research
```

---

## Experiment Summary

| Phase | Workload | Priority | Expected Behavior |
|-------|----------|----------|-------------------|
| 1 | `ds-borrower` (2 pods × 1 CPU) | Low | Scheduled — borrows beyond deserved |
| 2 | `research-high` (2 pods × 1 CPU, gang) | High | Pending — insufficient capacity + gang constraint |
| 3 | Additional high-priority load | High | Reclaim evicts borrowed low-priority pods |

## Key Takeaways

1. **Deserved vs capability** — Teams have guaranteed minimums but can burst when the cluster is idle.
2. **Gang scheduling** — All-or-nothing placement prevents partial job startup that would waste resources.
3. **Priority matters** — High-priority jobs are preferred, but cannot schedule without available resources.
4. **Reclamation** — Borrowed resources are temporary; the owning queue can take them back.
5. **HPC parallel** — These patterns mirror Slurm partitions, reservations, and preemption in a cloud-native form.
