# provision/ – Cluster Provisioning

> Automated setup for k3s (LXC) and kubeadm (VM) clusters on Proxmox VE.

## Directory Structure

```
provision/
├── provision-pve-lxc.sh    # LXC provisioning (k3s + ArgoCD)
├── example.conf            # Template with all options
├── lain-k3s-draft.conf     # LXC config (k3s, ZFS)
└── pve/
    └── k8s-vm/            # VM provisioning (kubeadm + cloud-init)
```

## Option 1: LXC (k3s)

Idempotent Bash script – steps 1–13, corresponding to [`doc/lxc-k3s.md`](../doc/lxc-k3s.md).

```bash
./provision-pve-lxc.sh <config>           # full run
./provision-pve-lxc.sh <config> --step N  # resume from step N
./provision-pve-lxc.sh <config> --list    # list steps
```

**Configs:**
| Config | Description |
|---|---|
| `example.conf` | Template with documented options |
| `lain-k3s-draft.conf` | Production cluster (ZFS, 192.168.0.x) |

## Option 2: VM (kubeadm + cloud-init)

Creates a single-node K8s cluster on a Proxmox VM.

```bash
cd pve/k8s-vm
./create-k8s-vm.sh default.conf          # vanilla K8s, no ArgoCD
./create-k8s-vm.sh default-argocd.conf   # ArgoCD + Gateway API (public GitHub)
./create-k8s-vm.sh default-fast.conf     # same, no first-boot apt upgrades
./create-k8s-vm.sh debug.conf            # minimal (SSH test only)
```

See [`pve/k8s-vm/README.md`](pve/k8s-vm/README.md) for full documentation.

**Configs:**
| Config | Purpose |
|---|---|
| `default.conf` | Minimal vanilla Kubernetes, 2 GB RAM |
| `default-argocd.conf` | ArgoCD + Gateway API from the public GitHub repo, 3 GB RAM |
| `default-fast.conf` | `default-argocd.conf` without first-boot apt upgrades |
| `debug.conf` | Cloud-init testing (no K8s) |

## LXC vs VM

| | LXC (k3s) | VM (kubeadm) |
|---|---|---|
| **K8s Distribution** | k3s (lightweight) | kubeadm (upstream) |
| **OS** | Debian 13 | Ubuntu 26.04 |
| **Setup** | Bash script (13 steps) | cloud-init (automated) |
| **Use Case** | Quick, resource-efficient | Full K8s, production-grade |
