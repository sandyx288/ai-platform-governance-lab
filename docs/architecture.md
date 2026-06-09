# Architecture

## Overview

This lab implements a two-layer governance model:

1. **Kubernetes layer** — namespace isolation, hard quotas (ResourceQuota), and default limits (LimitRange)
2. **Volcano layer** — queue-based fair sharing, priority, gang scheduling, and reclamation

The two layers complement each other: Kubernetes quotas enforce hard upper bounds per namespace, while Volcano queues model soft reservations and burstable sharing across teams.

## Cluster Topology

```
                    Azure Cloud
┌──────────────────────────────────────────────────────────┐
│                                                          │
│  VM-Master-vnet (10.0.0.0/16)                           │
│  ┌────────────────────────────────────┐                  │
│  │ VM-Master — K3s Server             │                  │
│  │ Role: control-plane                │                  │
│  │ IP: 10.0.0.4                       │                  │
│  └────────────────────────────────────┘                  │
│              ▲                                             │
│              │ VNet Peering                                │
│              ▼                                             │
│  vnet-ai-platform-lab (10.1.0.0/16)                     │
│  ┌────────────────────────────────────┐                  │
│  │ vm-ai-platform-lab — K3s Agent     │                  │
│  │ Role: worker                       │                  │
│  │ IP: 10.1.1.4                       │                  │
│  └────────────────────────────────────┘                  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

> **Networking note:** The master and worker VMs live in separate Azure VNets. VNet peering and NSG rules (TCP 6443/10250, UDP 8472) are required for the K3s agent to join the cluster. See [setup.md](setup.md#networking-vnet-peering).

## Tenant Model

Each AI team maps to three Kubernetes objects:

| Layer | Object | Purpose |
|-------|--------|---------|
| Isolation | Namespace | Logical boundary for RBAC, quotas, and network policies |
| Hard limit | ResourceQuota | Maximum CPU/memory/pods the namespace can hold |
| Default policy | LimitRange | Default and minimum container resource requests/limits |
| Soft reservation | Volcano Queue | Deserved/capability/reclaimable scheduling policy |

### Queue Resource Model

```
┌─────────────────────────────────────────────────┐
│              ai-research-queue                   │
│                                                  │
│  ┌──────────┐  ┌─────────────────────────────┐  │
│  │ Deserved │  │        Capability           │  │
│  │  3 CPU   │  │         6 CPU               │  │
│  │ (guaranteed)│  │  (max when cluster idle)  │  │
│  └──────────┘  └─────────────────────────────┘  │
│                                                  │
│  reclaimable: true                               │
│  weight: 3                                       │
└─────────────────────────────────────────────────┘
```

- **Deserved (3 CPU):** Guaranteed reservation; other queues cannot permanently consume this.
- **Capability (6 CPU):** Upper bound this queue can use when cluster resources are available.
- **Reclaimable:** If another queue borrows beyond its deserved share, the owner can reclaim it via Volcano's `reclaim` action.

## Volcano Scheduler Pipeline

Volcano replaces the default Kubernetes scheduler for batch workloads (`schedulerName: volcano`).

```
Job submitted
     │
     ▼
  enqueue ──► allocate ──► backfill
     │              │
     │              ├── insufficient? ──► preempt / reclaim
     │              │
     ▼              ▼
  Pending        Running
```

**Actions configured:**

| Action | Role |
|--------|------|
| `enqueue` | Place jobs into queue ordering |
| `allocate` | Bind pods to nodes respecting queue constraints |
| `reclaim` | Return borrowed resources to the owning queue |
| `preempt` | Evict lower-priority jobs to free resources |
| `backfill` | Fill idle slots with smaller jobs |

**Plugins:** Priority, Gang, DRF (Dominant Resource Fairness), Proportion, Reclaim.

## Slurm ↔ Volcano Mapping

| Slurm Concept | Volcano Equivalent | This Lab |
|---------------|-------------------|----------|
| Partition | Queue | `ai-research-queue`, etc. |
| `--priority` | PriorityClass | `ai-high-priority` (100000) |
| `--reservation` | Queue `deserved` | 3 CPU reserved per research/product team |
| `--qos` max | Queue `capability` | 6 CPU burst limit |
| Fair-share | DRF + queue weight | weight 3 vs 1 |
| Preemption | reclaim + preempt actions | Enabled in scheduler config |
| `sbatch` | Volcano Job (`vcjob`) | `ds-borrower`, `research-high` |

## Governance Deployment Options

This repo provides two equivalent approaches for Kubernetes-level governance:

### Option A — Raw manifests

```bash
kubectl apply -f k8s/quotas/
kubectl apply -f k8s/limitrange.yaml
```

Per-team quotas live in `k8s/quotas/`.

### Option B — Helm chart (recommended for production pattern)

```bash
# Deploy governance for ai-product team
helm upgrade --install ai-product-governance ./helm/ai-team-governance \
  --namespace ai-product \
  -f helm/ai-team-governance/values.yaml
```

The Helm chart parameterizes team name, quota limits, and LimitRange defaults via `values.yaml`.

## CI/CD

GitHub Actions workflow (`.github/workflows/terraform-ci.yml`) runs on changes to `terraform/`:

- `terraform fmt -check`
- `terraform init`
- `terraform validate`
- `terraform plan`

This ensures infrastructure code stays formatted and syntactically valid without requiring Azure credentials in CI (plan may show provider auth warnings — expected for portfolio CI).
