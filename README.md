# Volcano Multi-Tenant AI Cluster Scheduling Lab

A hands-on sandbox for **enterprise AI cluster resource governance** on Kubernetes. This project simulates how multiple AI teams share a common compute cluster with reserved capacity, burstable usage, priority scheduling, and resource reclamation — patterns commonly seen in Slurm-based HPC and modern GPU platforms.

> **Portfolio deliverable** — demonstrates Kubernetes multi-tenancy, platform engineering, and queue-based batch scheduling for AI infrastructure roles.

---

## Objective

Simulate enterprise AI cluster resource governance using **Kubernetes** and the **Volcano Scheduler**, focusing on:

- Multi-tenant resource sharing
- Quota management
- Priority scheduling
- Resource reclamation

The lab models a common AI platform scenario:

| Scenario | Implementation |
|----------|----------------|
| Multiple AI teams share a common compute cluster | Namespace + Volcano Queue isolation |
| Each team owns a guaranteed (reserved) allocation | Queue `deserved` resources |
| Idle resources can be borrowed by other teams | Queue `capability` > `deserved`, `reclaimable: true` |
| Resources can be reclaimed when the owning team needs them | Volcano `reclaim` / `preempt` actions |

This closely resembles GPU governance models commonly implemented in Slurm-based HPC environments.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Azure (Terraform)                        │
│  ┌──────────────────────┐      VNet Peering      ┌───────────┐ │
│  │  VM-Master (K3s Server)│ ◄──────────────────► │ Worker VM │ │
│  │  10.0.0.0/16           │                      │ 10.1.0.0/16│ │
│  └──────────┬─────────────┘                      └─────┬─────┘ │
└─────────────┼────────────────────────────────────────────┼────────┘
              │                                            │
              ▼                                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     2-Node K3s Cluster                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ ai-research │  │ ai-product  │  │data-science │  Namespaces │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                     │
│         ▼                ▼                ▼                     │
│  ResourceQuota + LimitRange (Helm / raw manifests)              │
│         │                │                │                     │
│         └────────────────┼────────────────┘                     │
│                          ▼                                      │
│              Volcano Scheduler (Queues + PriorityClasses)         │
└─────────────────────────────────────────────────────────────────┘
```

See [docs/architecture.md](docs/architecture.md) for component details and the Slurm mapping table.

---

## Environment

### Infrastructure

| Component | Details |
|-----------|---------|
| Cloud | Azure |
| IaC | Terraform (`terraform/`) |
| Cluster | 2-node K3s (control-plane + worker) |
| CI | GitHub Actions — Terraform fmt / validate / plan |

### Platform Components

- Kubernetes (K3s)
- Helm
- Volcano Scheduler
- GitHub Actions

---

## Multi-Tenant Design

Three logical AI teams were created:

| Team | Namespace | Queue | Deserved CPU | Capability CPU |
|------|-----------|-------|--------------|----------------|
| AI Research | `ai-research` | `ai-research-queue` | 3 | 6 |
| AI Product | `ai-product` | `ai-product-queue` | 3 | 6 |
| Data Science | `data-science` | `data-science-queue` | 1 | 3 |

**Concepts:**

- **Deserved** — reserved capacity guaranteed to the team
- **Capability** — maximum capacity the team can consume when idle resources are available
- **Reclaimable** — borrowed resources can be reclaimed by the owning queue

Queue definitions: [`volcano/queues.yaml`](volcano/queues.yaml)

---

## Volcano Scheduler Configuration

**Scheduler actions enabled:**

```
enqueue → allocate → reclaim → preempt → backfill
```

**Queue scheduling enabled:**

- Priority scheduling
- Gang scheduling
- DRF (Dominant Resource Fairness)
- Resource reclamation

### Priority Classes

| Priority Class | Value |
|----------------|-------|
| `ai-high-priority` | 100000 |
| `ai-medium-priority` | 50000 |
| `ai-low-priority` | 10000 |

Critical workloads receive scheduling preference over lower-priority workloads.

Definitions: [`volcano/priorityclasses.yaml`](volcano/priorityclasses.yaml)

---

## Scheduling Experiment

### Phase 1 — Borrowing idle capacity

A low-priority Data Science workload was submitted:

- **Queue:** `data-science-queue`
- **Priority:** Low
- **CPU Requests:** 1 CPU per Pod
- **Replicas:** 2

Manifest: [`volcano/ds-borrower-job.yaml`](volcano/ds-borrower-job.yaml)

**Result:**

- Job scheduled successfully
- Queue allocated resources beyond its deserved allocation

### Phase 2 — High-priority gang job under contention

A high-priority Research workload was submitted:

- **Queue:** `ai-research-queue`
- **Priority:** High
- **Gang Scheduling:** enabled (`minAvailable = 2`)

Manifest: [`volcano/research-high-job.yaml`](volcano/research-high-job.yaml)

**Result:**

- Job remained Pending
- Volcano correctly evaluated queue capacity and cluster resources
- Scheduler reported insufficient CPU capacity

**Observed scheduler events:**

- Queue-based scheduling
- Gang scheduling constraints
- Resource allocation evaluation
- Pending state due to cluster resource limitations

Step-by-step commands and expected output: [docs/scheduling-experiment.md](docs/scheduling-experiment.md)

---

## Repository Structure

```
ai-platform-lab/
├── .github/workflows/
│   └── terraform-ci.yml          # Terraform fmt / validate / plan
├── docs/
│   ├── architecture.md           # Component design & Slurm mapping
│   ├── setup.md                  # Full cluster bootstrap guide
│   └── scheduling-experiment.md  # Hands-on scheduling lab
├── helm/
│   └── ai-team-governance/       # Helm chart: ResourceQuota + LimitRange
├── k8s/
│   ├── quotas/                   # Per-team ResourceQuota manifests
│   ├── cpu-demo.yaml             # Basic resource request demo
│   ├── huge-job.yaml             # Oversized workload (scheduling failure)
│   ├── limitrange.yaml           # Default container limits
│   └── no-resource.yaml          # Pod without resource requests
├── terraform/
│   ├── main.tf                   # Azure worker VM + VNet
│   └── terraform.tfvars.example  # Variable template
└── volcano/
    ├── queues.yaml               # Multi-tenant Volcano queues
    ├── priorityclasses.yaml      # AI workload priority tiers
    ├── ds-borrower-job.yaml        # Phase 1 experiment job
    └── research-high-job.yaml      # Phase 2 experiment job
```

---

## Quick Start

### Prerequisites

- Azure subscription with CLI access (`az login`)
- Terraform >= 1.5
- `kubectl`, `helm`
- SSH key pair
- An existing K3s control-plane node (or provision one separately)

### 1. Provision worker infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply
```

### 2. Bootstrap the cluster

Follow the full guide in [docs/setup.md](docs/setup.md), including:

- K3s agent join (with Azure VNet peering between master and worker subnets)
- Namespace creation for each AI team
- Helm-based governance deployment
- Volcano Scheduler installation

### 3. Run the scheduling experiment

```bash
# Apply queues and priority classes
kubectl apply -f volcano/priorityclasses.yaml
kubectl apply -f volcano/queues.yaml

# Phase 1 — Data Science borrows capacity
kubectl apply -f volcano/ds-borrower-job.yaml
kubectl get vcjob -n data-science

# Phase 2 — AI Research high-priority gang job
kubectl apply -f volcano/research-high-job.yaml
kubectl get vcjob -n ai-research
kubectl describe vcjob research-high -n ai-research
```

---

## Key Learnings

### Kubernetes Resource Governance

Implemented:

- Namespace isolation
- ResourceQuota
- LimitRange
- Helm-based governance deployment

### Volcano Scheduling

Validated:

- Queue-based multi-tenancy
- Priority-based scheduling
- Gang scheduling
- Resource capability constraints
- Deserved resource reservations
- Reclaim and preemption framework

### HPC Mapping

| Slurm | Volcano |
|-------|---------|
| Partition | Queue |
| Priority | PriorityClass |
| Reservation | Deserved |
| FairShare | DRF + Queue Weight |
| Preemption | Reclaim / Preempt |
| `sbatch` Job | Volcano Job |

---

## Future Enhancements

- [ ] GPU Operator
- [ ] Kueue
- [ ] Elastic Quota
- [ ] Spot / Reserved GPU simulation
- [ ] OpenTelemetry integration
- [ ] Langfuse observability
- [ ] AI inference workloads (Ray, Triton Inference Server)

---

## Outcome

Built a reusable **AI Platform governance sandbox** demonstrating:

- Kubernetes multi-tenancy
- Resource governance
- Queue-based scheduling
- Priority and fairness policies
- HPC-to-Kubernetes scheduling concepts

The lab provides a practical environment for evaluating AI infrastructure and platform engineering concepts commonly used in modern GPU clusters.

---

## License

This project is provided as a portfolio demonstration. Feel free to reference or fork with attribution.
