# k3s + Kustomize + ArgoCD – Homelab GitOps (PVE LXC)

> **Purpose:** Project overview, entry point, and public-facing documentation.
> Use this to understand what this repo contains and how to get started.

GitOps-driven homelab cluster on Proxmox VE LXC with k3s, Kustomize and ArgoCD.

This repository is a spin-off of my private Gitea repository at `git.blox.media`.
The GitHub branch serves as a public reference and follows with a delay.
If you want to mirror this repo in your own ArgoCD, adjust the Git URLs
in the configuration files (e.g. `provision/example.conf`, `provision/lain-k3s-draft.conf`,
`argocd/root.lain-k3s-draft.yaml`) to point to your own fork.
Also, my mount points may not make sense for your setup.

## App

**Uptime Kuma** – Self-hosted uptime monitoring, deployed via ArgoCD in namespace `uptime-kuma`.
NodePort 30001, persistent volume via ZFS bind-mount from the PVE host.

## Tech Stack

| Layer | Technology |
|---|---|
| Virtualization | Proxmox VE (LXC, privileged Debian 13) |
| Kubernetes | k3s (Lightweight K8s) |
| Manifest Management | Kustomize (base + overlays) |
| GitOps | ArgoCD (Application CRDs, Root App) |
| Git | Gitea (self-hosted) |
| Ingress | Traefik (k3s built-in, optional) |

## Architecture

Git as single source of truth – Kustomize overlays per cluster, ArgoCD syncs automatically.

```
k8s-apps/
├── base/uptime-kuma/          # Cluster-neutral manifests
├── overlays/lain-k3s-draft/   # Cluster-specific patches
├── argocd/lain-k3s-draft/     # ArgoCD Application definitions
├── provision/                 # PVE-LXC provisioning (k3s + ArgoCD)
└── doc/                       # Documentation
```

## Feature Status

| Status | Feature |
|---|---|
| ✓ | PVE-LXC provisioning (idempotent Bash script) |
| ✓ | ArgoCD Root App + auto-deploy |
| ◻ | Helm charts as additional templating |
| ◻ | Secrets manager (external-secrets / sealed-secrets) |
| ◻ | Second cluster (Strato vServer) |
| ◻ | Migration LXC → VM + cloud-init |

## IaC

Infrastructure is set up via the provisioning script in [`provision/`](provision/):
idempotent Bash steps for LXC creation, k3s, Helm, ArgoCD, and Root App.
See [`doc/lxc-k3s.md`](doc/lxc-k3s.md) for details.

A full IaC setup (Terraform/Packer) for VM + cloud-init is planned for the future.

## Security Caveats & Attack Vectors

This repo is a homelab project and does NOT follow security best practices:
- The LXC container has so many privileges that a compromise could also take over the Proxmox hypervisor.
- The LXC root user has write access to the `.mounted` script, which is executed by the PVE host root.
This is a learning project – for critical deployments, an isolated VM with Kubernetes storage services should be used.

## Background

### Infrastructure Being Migrated From

- Docker Compose on multiple servers
- 1 git repo per server documenting the current structure
- No automated CD or self-healing
- Data directories stored on ZFS

### Lessons Learned

- Docker Compose files can be converted to Kubernetes relatively easily, but complexity increases.
- For scalable and complex applications, Helm templates should be used.
- LXC doesn't make sense for k3s – too much tinkering required.
