# k8s-apps – Homelab GitOps on Proxmox VE

> GitOps-driven Kubernetes clusters on Proxmox VE using k3s/kubeadm, Kustomize, and ArgoCD.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Proxmox%20VE-orange.svg)](https://www.proxmox.com/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36-blue.svg)](https://kubernetes.io/)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-brightgreen.svg)](https://argo-cd.readthedocs.io/)

## Quick Start

### Option 1: LXC (k3s)

```bash
# Clone and provision a k3s cluster on PVE LXC
git clone https://github.com/your-user/k8s-apps.git
cd k8s-apps/provision
./provision-pve-lxc.sh lain-k3s-draft.conf
```

### Option 2: VM (kubeadm + cloud-init)

```bash
# Upload to Proxmox host and create K8s VM
scp provision/pve/k8s-vm/* root@proxmox-host:/root/
ssh root@proxmox-host "./create-k8s-vm.sh default.conf"

# Full GitOps (ArgoCD + Gateway API) from the public GitHub repo
ssh root@proxmox-host "./create-k8s-vm.sh default-argocd.conf"
```

## Architecture

```
k8s-apps/
├── base/                         # Kustomize manifests (cluster-neutral)
│   ├── uptime-kuma/
│   ├── ollama-bridge/
│   └── gateway/                  # Gateway API Gateway resource
├── overlays/                     # Cluster-specific patches (k3s only)
│   └── lain-k3s-draft/
├── argocd/                       # ArgoCD Application definitions
│   ├── lain-k3s-draft/           # k3s cluster
│   └── k8s-lain/                 # kubeadm cluster (gateway/ = API gateway apps)
├── provision/
│   ├── provision-pve-lxc.sh      # LXC provisioning (k3s)
│   └── pve/k8s-vm/              # VM provisioning (kubeadm + cloud-init)
└── doc/                          # Documentation
```

## Tech Stack

| Layer | LXC Path | VM Path |
|---|---|---|
| **Virtualization** | Proxmox VE LXC (Debian 13) | Proxmox VE VM (Ubuntu 26.04) |
| **Kubernetes** | k3s | kubeadm + containerd |
| **Manifests** | Kustomize (base + overlays) | Kustomize (base + overlays) |
| **GitOps** | ArgoCD (Root App) | ArgoCD (Root App, bootstrapped) |
| **Gateway API** | – | NGINX Gateway Fabric (GitOps) |
| **CNI** | k3s built-in (Flannel) | Flannel |

## Apps

| App | Namespace | NodePort | Description |
|---|---|---|---|
| Uptime Kuma | `uptime-kuma` | 30001 | Self-hosted uptime monitoring |
| Ollama Bridge | `ollama-bridge` | 30008 | OpenAI ↔ Ollama API proxy |
| NGINX Gateway Fabric | `nginx-gateway` | 30080 (HTTP data plane) | Gateway API implementation |

## Feature Status

| Status | Feature |
|---|---|
| ✅ | PVE-LXC provisioning (idempotent Bash script) |
| ✅ | PVE-VM provisioning (kubeadm + cloud-init) |
| ✅ | ArgoCD Root App + auto-deploy (k3s and kubeadm VM) |
| ✅ | Gateway API via NGINX Gateway Fabric (GitOps, VM) |
| 🔲 | Helm charts as additional templating |
| 🔲 | Secrets manager (external-secrets / sealed-secrets) |
| 🔲 | Second cluster (Strato vServer) |

## Provisioning

K3S and LXC Containers are both **discouraged**:
-  LXC needs high privileges to run containerd and there is always potential for trouble. Use it only for testing and if your RAM is REALLY low.
-  Vanilla Kubernetes works also Single-Node, kubeadm and kubectl make it easy, just use vanilla.

### LXC (k3s)

Idempotent Bash script that sets up k3s inside a PVE LXC container.

```bash
./provision-pve-lxc.sh <config>           # full run
./provision-pve-lxc.sh <config> --step N  # resume from step N
./provision-pve-lxc.sh <config> --list    # list steps
```

See [`doc/lxc-k3s.md`](doc/lxc-k3s.md) for the full manual guide.

### VM (kubeadm + cloud-init)

Creates a single-node K8s cluster on a Proxmox VM using cloud-init.

```bash
cd provision/pve/k8s-vm
./create-k8s-vm.sh default.conf          # vanilla K8s
./create-k8s-vm.sh default-argocd.conf   # ArgoCD + Gateway API
./create-k8s-vm.sh default-fast.conf     # same, no first-boot apt upgrades
```

See [`provision/pve/k8s-vm/README.md`](provision/pve/k8s-vm/README.md) for details.

## Security Caveats

> ⚠️ This is a homelab project – not production-ready.

- Privileged LXC containers can compromise the Proxmox host.
- LXC root user has write access to the `.mounted` script executed by PVE host root.
- For critical workloads, use an isolated VM with proper Kubernetes storage services.

## Lessons Learned

- Docker Compose → Kubernetes is relatively easy, but complexity increases.
- Helm templates are needed for complex applications.
- LXC for k3s requires too much tinkering – VM is the better path.

## License

[MIT](LICENSE)
