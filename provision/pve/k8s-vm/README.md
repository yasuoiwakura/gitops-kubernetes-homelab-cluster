# Kubernetes VM Provisioning for Proxmox VE

Creates a single-node Kubernetes cluster on a Proxmox VM using cloud-init.

## Files

| File | Description |
|---|---|
| `create-k8s-vm.sh` | Main script (run on PVE host) |
| `k8s-cloud-init.yaml` | Cloud-init template (kubeadm + Flannel) |
| `default.conf` | Minimal vanilla Kubernetes (2 GB) |
| `default-argocd.conf` | ArgoCD + Gateway API from public GitHub (3 GB) |
| `default-fast.conf` | Same as `default-argocd.conf`, no apt upgrades |
| `debug.conf` | Minimal config (SSH test only) |

## Quick Start

```bash
# Upload files to Proxmox host
scp create-k8s-vm.sh k8s-cloud-init.yaml default*.conf root@proxmox-host:/root/

# SSH and run (minimal vanilla K8s)
ssh root@proxmox-host "chmod +x /root/create-k8s-vm.sh && /root/create-k8s-vm.sh default.conf"

# or full GitOps (ArgoCD + Gateway API)
ssh root@proxmox-host "/root/create-k8s-vm.sh default-argocd.conf"
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `VMID` | 180 | Proxmox VM ID |
| `VM_NAME` | k8s-node | VM hostname |
| `MEMORY` | 2048 (default-argocd.conf: 3072) | RAM in MB |
| `CORES` | 2 | CPU cores |
| `STORAGE` | local-zfs | Proxmox storage |
| `DISK_SIZE` | 20G | Disk size |
| `K8S_VERSION` | 1.36 | Kubernetes version (newest tested with ArgoCD 3.5) |
| `CIUPGRADE` | 1 | Proxmox cloud-init package upgrade (`0` = off; `default.conf` uses `0`) |
| `PACKAGE_UPGRADE` | `true` | Run apt upgrade in cloud-init (`default-fast.conf`: `false`) |
| `IP_ADDRESS` | 203.0.113.11/24 | Static IP with CIDR |
| `GATEWAY` | 203.0.113.1 | Network gateway |
| `DNS_SERVER` | 203.0.113.53 | DNS server(s), space-separated |
| `K8S_CONVENIENCE` | `false` | Install `kubectx`/`kubens`, `k` alias + bash completion |
| `PROVISION_STATUS` | `false` | Show cloud-init stage + duration on login |
| `PROVISION_ROLE` | `k8s-vm` | Label shown in the provisioning status block |
| `ARGOCD_ENABLED` | `false` | Install ArgoCD, connect the repo, apply the root app |
| `ARGOCD_CHART_VERSION` | `10.11.6` | argo-cd Helm chart (ArgoCD 3.5.6) |
| `ARGOCD_NODEPORT` | 30444 | HTTPS NodePort for the ArgoCD UI (HTTP: 30081) |
| `ARGOCD_REPO_URL` | – | Git repo URL |
| `ARGOCD_REPO_KEY` | `/root/.ssh/argocd` | Private deploy key on the PVE host (SSH only; empty for public HTTPS) |
| `ARGOCD_ROOT_APP_PATH` | `argocd/k8s-lain` | Root app path in the repo |
| `ARGOCD_TARGET_REVISION` | `main` | Branch/tag the root app tracks |
| `GATEWAY_ENABLED` | `false` | Include `argocd/k8s-lain/gateway/` (Gateway API CRDs, NGF, Gateway) |

## Public Configs

| Config | Purpose |
|---|---|
| `default.conf` | Minimal vanilla Kubernetes, no ArgoCD/gateway, 2 GB RAM |
| `default-argocd.conf` | ArgoCD + Gateway API from the public GitHub repo (anonymous HTTPS, no deploy key), 3 GB RAM |
| `default-fast.conf` | Same as `default-argocd.conf` without first-boot apt upgrades |

```bash
./create-k8s-vm.sh default.conf
./create-k8s-vm.sh default-argocd.conf
./create-k8s-vm.sh default-fast.conf
```

For a private Git repo over SSH, set `ARGOCD_REPO_URL` and `ARGOCD_REPO_KEY`
instead of using the public HTTPS defaults.

## Provisioning Status

`PROVISION_STATUS=true` installs `provision-status` and shows it on interactive
login (`/etc/profile.d/99-provision-status.sh`):

- step `x/6`: `cloud-init packages`, `base`, `kubeadm`, `flannel`, `helm`, `finalize`
- elapsed time, and `PROVISION_START`/`PROVISION_DONE` with duration after completion
- git metadata (repo, branch, short commit, commit date, dirty) and hashes of
  the used `.sh`/`.conf`/`.yaml`
- per-step benchmark with `provision-status --benchmark`

Data lives in the same directory:

| Path | Content |
|---|---|
| `/var/lib/provisioning/start.env` | immutable, injected by `create-k8s-vm.sh` (`PROVISION_START`, git, hashes) |
| `/var/lib/provisioning/state.env` | copy of `start.env` plus `PROVISION_TS_*`, `PROVISION_DONE*` |

On login, `provision-status --short` prints two lines (status/step/elapsed and
the git source). Full details: `provision-status`. Step benchmark:
`provision-status --benchmark`. Live: `watch -n 5 provision-status --short`.

Git metadata is only available when the script is started from a git checkout on
the PVE host; otherwise it shows `unknown` while the hashes still identify the
exact files.

## ArgoCD Bootstrap

`ARGOCD_ENABLED=true` installs ArgoCD via Helm (pinned chart), exposes the UI on
NodePort 30444 (HTTPS) / 30081 (HTTP), registers the Git repo with a read-only
SSH deploy key and applies the root Application (`argocd/root.k8s-lain.yaml`).
ArgoCD then syncs everything under `argocd/k8s-lain/`.

The chart is installed without `--wait`; afterwards the provisioning waits for
the `argocd-server`, `argocd-repo-server` and `argocd-application-controller`
pods to become Ready. `done` is only written if `argocd-server` and the
application controller are Ready.

Precondition for **SSH** repos: `ARGOCD_REPO_KEY` must be a private key on the
PVE host whose public key is added to the Git server as a read-only deploy key:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/argocd -N "" -C "argocd@k8s-node"
# add /root/.ssh/argocd.pub as a read-only deploy key in your Git server
```

For a **public HTTPS** repo, leave `ARGOCD_REPO_KEY` empty and set
`ARGOCD_REPO_URL=https://...`.

After provisioning:

- UI: `https://<VM_IP>:30444`
- user: `admin`
- password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

## API Gateway (GitOps)

`GATEWAY_ENABLED=true` includes `argocd/k8s-lain/gateway/` in the root app
(otherwise it is excluded via `directory.exclude: gateway/*`). ArgoCD then
installs and manages:

- Gateway API **standard** CRDs, pinned to `v2.8.0`
- **NGINX Gateway Fabric** chart `2.8.0` in namespace `nginx-gateway`
- the `Gateway` resource from `base/gateway/` (`gatewayClassName: nginx`)

The data plane Service is `NodePort`; HTTP (listener 80) is exposed on
**30080**. The apps sync in waves: CRDs/OCI repo secret → NGF → Gateway.

Child applications (including the Gateway) track `main`. Merge the GitOps
changes to `main` before enabling the gateway, or temporarily adjust
`targetRevision` in `argocd/k8s-lain/gateway/gateway.yaml` for testing.

## Kubernetes CLI Convenience

Set `K8S_CONVENIENCE=true` in the config (e.g. `default.conf`) to provision:

- `k` → `kubectl` with bash completion
- `kx` → `kubectx`, `kn` → `kubens` (fast context/namespace switching)
- bash completion for `kubectx`/`kubens` and `helm`

It is appended to `/root/.bashrc`, so it applies to interactive root shells.
The toggle is consolidated under this single config variable; `false` (default)
leaves the VM untouched.

## What Cloud-init Does

1. System config (hostname, locale, /etc/hosts)
2. User setup (SSH keys via `qm set --sshkeys`)
3. Package install (containerd, kubeadm, kubelet, kubectl)
4. Kernel config (overlay, br_netfilter modules)
5. Containerd setup (cgroup v2)
6. kubeadm init + Flannel CNI
7. Helm install
8. Optional: `k` alias, completion, `kubectx`/`kubens` (`K8S_CONVENIENCE=true`)
9. Reboot

## Monitoring

```bash
# Proxmox console
qm terminal 180

# SSH (once IP is assigned)
ssh root@203.0.113.11 "cloud-init status"
ssh root@203.0.113.11 "tail -f /var/log/cloud-init-output.log"
```

## Verification

```bash
ssh root@203.0.113.11
kubectl get nodes
kubectl get pods -A
```

## Troubleshooting

| Problem | Check |
|---|---|
| cloud-init won't start | Proxmox task logs, storage path |
| K8s init fails | `/var/log/cloud-init-output.log`, `systemctl status containerd` |
| Network issues | `ip addr show`, `ping $GATEWAY`, `nslookup k8s.gcr.io` |
| SSH not reachable | IP in Proxmox GUI, firewall |

### Collect Logs

```bash
ssh root@VM_IP "cloud-init collect-logs"
ssh root@VM_IP "cloud-init status --long"
```

### Common Fixes

- Wait 10-15 minutes after VM start for cloud-init to complete
- Check `/var/log/cloud-init-output.log` for errors
- Ensure swap is disabled: `swapon --show`

See [`HANDOFF.md`](HANDOFF.md) for detailed lessons learned and critical pitfalls.

## Customization

- **Worker Nodes:** Remove `kubeadm init`, add `kubeadm join` with token
- **HA Control Plane:** 3+ VMs, external/stacked etcd, load balancer
- **Custom CNI:** Replace Flannel in `runcmd` section
- **Disk Size:** Increase `DISK_SIZE` for production workloads
