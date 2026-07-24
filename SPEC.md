# SPEC – GitOps Repository for k3s Homelab

> **Purpose:** Technical specification – architecture, repo structure, workflows, and conventions.
> Use this to understand how the repo is organized and how to add apps or clusters.

## Goal

This repository is the **GitOps control repo** for my k3s clusters.
ArgoCD syncs the desired state (stored in Git) with the live state in the clusters.
Principle: **"Git as single source of truth"** – changes via Git only, ArgoCD applies them automatically.

## Cluster Overview

| Cluster / Overlay | Host | Status |
|---|---|---|
| `lain-k3s-draft` | OptiPlex LXC on PVE (192.168.0.183) | active |
| `strato25` | Strato vServer | planned |
| `ki-laptop` | local laptop (AI development) | planned |

Each cluster gets its own overlay under `overlays/<cluster-name>/`.
Contains cluster-specific values, patches, and secret references.

## Repo Structure

```
k8s-apps/
├── base/                        # Cluster-neutral app manifests
│   └── uptime-kuma/             # 1 app = 1 subdirectory
│       ├── deployment.yaml
│       ├── service.yaml
│       └── kustomization.yaml
├── overlays/                    # Cluster-specific values
│   └── lain-k3s-draft/          # 1 subdirectory per cluster
│       └── uptime-kuma/         # 1 app = 1 subdirectory
│           ├── kustomization.yaml
│           └── patches/
│               └── hostpath.yaml
├── argocd/                      # ArgoCD Application definitions
│   └── lain-k3s-draft/          # 1 subdirectory per cluster
│       └── uptime-kuma.yaml     # 1 Application YAML per app
├── provision/                   # Cluster provisioning (script + configs)
│   ├── provision-pve-lxc.sh
│   ├── example.conf
│   └── lain-k3s-draft.conf
├── doc/
│   └── lxc-k3s.md               # Manual setup guide
├── SPEC.md                      # This document
└── README.md                    # Quick intro
```

### Rationale

- **`base/<app>/`** – manifests that are **identical across all clusters** (image, port, env)
- **`overlays/<cluster>/<app>/`** – **per-cluster deviations** (e.g. hostPath, NodePort, resources)
- **`argocd/<cluster>/<app>.yaml`** – **ArgoCD Application CRD** – connects overlay + namespace + sync policy. One file per app + cluster.
- **Each app lives in its own k8s namespace** (`destination.namespace: <app>`)
- **New cluster** = new subdirectory in `overlays/` and `argocd/`

## Provisioning – New LXC + k3s + ArgoCD

The script [`provision/provision-pve-lxc.sh`](provision/provision-pve-lxc.sh) sets up a
cluster idempotently (steps 0–13, `--step N` for partial execution).
The manual guide with explanations is in [`doc/lxc-k3s.md`](doc/lxc-k3s.md).

## GitOps Workflow

1. **Developer** changes YAMLs in this repo (new deployment, new service, ConfigMap...)
2. **Push** to Git (via `git push`)
3. **ArgoCD** detects the new commit (polling or webhook)
4. **ArgoCD** applies the changes to the cluster
5. On **drift** (e.g. someone patching directly on the cluster), ArgoCD restores the Git state automatically

## Adding a New App (for an Existing Cluster)

1. Create `base/<app>/`: deployment.yaml, service.yaml, kustomization.yaml
2. Create `overlays/<cluster>/<app>/`: kustomization.yaml (resources: base) + patches/
3. Create `argocd/<cluster>/<app>.yaml`: Application CRD with `destination.namespace: <app>`
4. Commit + Push → ArgoCD Root App syncs → App is deployed

## Adding a New Cluster

1. **Provision LXC** – script `provision/provision-pve-lxc.sh <config>` or manually per [`doc/lxc-k3s.md`](doc/lxc-k3s.md)
2. **Install k3s + Helm + ArgoCD** (automatic via script, steps 4–7)
3. In **ArgoCD UI**: add repo, create Root App with `path: argocd/<cluster>/`
4. Done – all apps defined for this cluster are deployed automatically

## Running Notes

- ArgoCD does not install an Ingress controller by default – either use k3s's built-in Traefik (omit `--disable=traefik`) or install your own (e.g. nginx-ingress) via Helm
- Secrets should NOT be committed directly to Git → use sealed-secrets, external-secrets (Vault), or ArgoCD's `argocd-vault-plugin`
- `lain-k3s-draft` = OptiPlex (192.168.0.183) → to be replaced with a production name later
