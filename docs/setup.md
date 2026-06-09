# Setup Guide

Complete bootstrap guide for the Volcano Multi-Tenant AI Cluster Scheduling Lab on Azure.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Azure CLI | latest | Cloud resource management |
| Terraform | >= 1.5 | Infrastructure provisioning |
| kubectl | >= 1.28 | Cluster management |
| helm | >= 3.12 | Chart deployment |
| SSH key pair | — | VM access |

## Step 1 — Provision worker VM (Terraform)

The Terraform module in `terraform/` provisions the worker node infrastructure:

- Resource group `rg-ai-platform-lab`
- VNet `vnet-ai-platform-lab` (10.1.0.0/16)
- VM `vm-ai-platform-lab` with public IP
- NSG allowing SSH (port 22)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
subscription_id = "<your-azure-subscription-id>"
ssh_public_key  = "ssh-rsa AAAA... your-key"
location        = "malaysiawest"   # optional
vm_size         = "Standard_D2as_v4" # optional
```

```bash
terraform init
terraform plan
terraform apply
```

Note the outputs:

```bash
terraform output public_ip_address   # SSH into worker
terraform output ssh_command
```

## Step 2 — K3s cluster bootstrap

This lab uses a **2-node K3s cluster**: one control-plane (master) and one worker (agent).

### 2a. Install K3s server (master node)

On the master VM:

```bash
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token   # save this token
hostname -I                                        # note private IP (e.g. 10.0.0.4)
```

Configure kubectl:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl get nodes
```

### 2b. Networking — VNet peering

If master and worker are in **separate Azure VNets** (as in this lab), you must peer them and open NSG ports before the agent can join.

**Create bidirectional VNet peering:**

```bash
# Master → Lab
az network vnet peering create \
  --resource-group <MASTER_RG> \
  --vnet-name <MASTER_VNET> \
  --name peer-to-ai-platform-lab \
  --remote-vnet /subscriptions/<SUB_ID>/resourceGroups/rg-ai-platform-lab/providers/Microsoft.Network/virtualNetworks/vnet-ai-platform-lab \
  --allow-vnet-access

# Lab → Master
az network vnet peering create \
  --resource-group rg-ai-platform-lab \
  --vnet-name vnet-ai-platform-lab \
  --name peer-to-vm-master \
  --remote-vnet /subscriptions/<SUB_ID>/resourceGroups/<MASTER_RG>/providers/Microsoft.Network/virtualNetworks/<MASTER_VNET> \
  --allow-vnet-access
```

**Add NSG rules on the master NSG** (allow worker subnet):

```bash
# TCP: Kubernetes API + kubelet
az network nsg rule create \
  --resource-group <MASTER_RG> \
  --nsg-name <MASTER_NSG> \
  --name AllowK3sFromLab \
  --priority 310 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes 10.1.0.0/16 \
  --destination-port-ranges 6443 10250

# UDP: Flannel VXLAN
az network nsg rule create \
  --resource-group <MASTER_RG> \
  --nsg-name <MASTER_NSG> \
  --name AllowFlannelFromLab \
  --priority 320 \
  --direction Inbound \
  --access Allow \
  --protocol Udp \
  --source-address-prefixes 10.1.0.0/16 \
  --destination-port-ranges 8472
```

Verify connectivity from worker before proceeding:

```bash
nc -zv <MASTER_PRIVATE_IP> 6443
```

### 2c. Join worker as K3s agent

On the worker VM:

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<MASTER_PRIVATE_IP>:6443 \
  K3S_TOKEN=<NODE_TOKEN> \
  sh -
```

> **Important:** Do not insert a backslash between the chart path and flags. Write the command on one line, or use `\` only at end-of-line for continuation.

Verify from master:

```bash
kubectl get nodes
# Expected: vm-master (control-plane) + vm-ai-platform-lab (worker)
```

## Step 3 — Create tenant namespaces

```bash
kubectl create namespace ai-research
kubectl create namespace ai-product
kubectl create namespace data-science
```

## Step 4 — Deploy Kubernetes governance

### Option A: Raw manifests

```bash
kubectl apply -f k8s/quotas/
```

Apply LimitRange per namespace (example for ai-research):

```bash
kubectl apply -f k8s/limitrange.yaml -n ai-research
kubectl apply -f k8s/limitrange.yaml -n ai-product
kubectl apply -f k8s/limitrange.yaml -n data-science
```

### Option B: Helm chart

Deploy per team, customizing `values.yaml` for each:

```bash
# AI Product team
helm upgrade --install ai-product-governance ./helm/ai-team-governance \
  --namespace ai-product

# Repeat with updated values.yaml team.name for other teams
```

Verify:

```bash
kubectl get resourcequota,limitrange -n ai-research
kubectl get resourcequota,limitrange -n ai-product
kubectl get resourcequota,limitrange -n data-science
```

## Step 5 — Install Volcano Scheduler

```bash
helm repo add volcano-sh https://volcano-sh.github.io/helm-charts
helm repo update

helm install volcano volcano-sh/volcano \
  --namespace volcano-system \
  --create-namespace
```

Verify:

```bash
kubectl get pods -n volcano-system
kubectl get crd | grep volcano
```

## Step 6 — Apply scheduling configuration

```bash
kubectl apply -f volcano/priorityclasses.yaml
kubectl apply -f volcano/queues.yaml

kubectl get priorityclass | grep ai-
kubectl get queues
```

## Step 7 — Run basic Kubernetes demos (optional)

These manifests in `k8s/` demonstrate native Kubernetes resource governance before introducing Volcano:

```bash
# Pod with resource requests
kubectl apply -f k8s/cpu-demo.yaml -n ai-product

# Pod without resource requests (uses LimitRange defaults)
kubectl apply -f k8s/no-resource.yaml -n ai-product

# Oversized job that exceeds quota (should fail scheduling)
kubectl apply -f k8s/huge-job.yaml -n ai-product
kubectl describe pod -n ai-product -l app=huge-job
```

## Step 8 — Run the scheduling experiment

See [scheduling-experiment.md](scheduling-experiment.md) for the full Phase 1 / Phase 2 walkthrough.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `k3s-agent` stuck at "Starting" | Worker cannot reach master :6443 | Check VNet peering + NSG rules |
| Helm install ownership conflict | Pre-existing ResourceQuota not managed by Helm | Delete old resources: `kubectl delete resourcequota,limitrange -n <ns> --all` |
| Volcano Job stays Pending | Insufficient cluster/queue capacity or gang constraint | `kubectl describe vcjob <name> -n <ns>` |
| `helm upgrade requires 2 arguments` | Stray `\` in command line | Remove backslash between chart path and flags |

## Teardown

```bash
# Remove Volcano jobs
kubectl delete -f volcano/ds-borrower-job.yaml
kubectl delete -f volcano/research-high-job.yaml

# Uninstall Volcano
helm uninstall volcano -n volcano-system

# Destroy Terraform infrastructure
cd terraform && terraform destroy
```
