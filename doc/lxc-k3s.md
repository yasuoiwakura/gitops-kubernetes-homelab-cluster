# LXC + k3s + ArgoCD – Manual Setup Guide

> **Purpose:** Step-by-step guide to set up k3s + Helm + ArgoCD on PVE LXC **by hand**.
> Use this to understand each step and why it is needed, or follow along without the automation script.

This guide describes how to set up a k3s cluster in a privileged Debian LXC
on Proxmox VE by hand. Result: k3s + Helm + ArgoCD + first app.

Every step is explained with the actual commands and the reasoning behind them.

## Prerequisites

- Proxmox VE 8+ with ZFS storage
- Debian 13 container template (`pveam download <storage> debian-13-standard_*.tar.zst`)
- Admin SSH key on the PVE host at `/root/.ssh/authorized_keys`
- Network: bridge (`vmbr0`), free IP (e.g. `192.168.0.183/24`), gateway, DNS
- Optional: dmcrypt volume for persistent data

## 1. Create LXC Container

```bash
# Check template list
pveam list <storage>

# Export SSH keys without comments
grep -v '^#' /root/.ssh/authorized_keys > /tmp/keys.txt

# Create container
VMID=183
pct create $VMID <storage>:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname k3s-draft \
  --memory 4096 \
  --cores 4 \
  --storage local-lvm \
  --rootfs 100 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.0.183/24,gw=192.168.0.1 \
  --nameserver 192.168.0.201 \
  --unprivileged 0 \
  --ssh-public-keys /tmp/keys.txt
```

**Important parameters:**
- `--unprivileged 0` – creates a privileged container. k3s needs
  `--rootfs` access and bind-mounts, which don't work in unprivileged LXCs
  without complex UID mappings. Downside: reduced isolation.
- `--rootfs 100` – root filesystem at 100G (adjust as needed)
- `--ssh-public-keys` – allows root login with the configured key

## 2. Configure LXC for k3s (nesting, devices)

k3s requires nesting rights and device access inside the LXC. This is done
by adding `lxc.*` lines to the container config (`/etc/pve/lxc/183.conf`).

```bash
# Remove old custom lines (for idempotency)
sed -i '/^lxc\.apparmor\.profile/d; /^lxc\.cgroup\.devices\.allow/d; /^lxc\.cap\.drop/d; /^lxc\.mount\.auto/d' /etc/pve/lxc/$VMID.conf

# Insert new lines before rootfs
sed -i '/^rootfs/i\lxc.apparmor.profile: unconfined\nlxc.cgroup.devices.allow: a\nlxc.cap.drop:\nlxc.mount.auto: proc:rw sys:rw' /etc/pve/lxc/$VMID.conf
```

**What these flags do:**

| Flag | Meaning |
|---|---|
| `lxc.apparmor.profile: unconfined` | Disables AppArmor for the container – k3s needs non-systemd mount operations and device access |
| `lxc.cgroup.devices.allow: a` | Allows all device nodes – k3s needs access to `/dev/kmsg`, loop devices, etc. |
| `lxc.cap.drop:` | Empty list → no capabilities are dropped. The container retains root-equivalent privileges |
| `lxc.mount.auto: proc:rw sys:rw` | Mounts `/proc` and `/sys` read-write – k3s-containerd requires writable cgroups |

## 3. Start Container + Base Setup

```bash
pct start $VMID
pct exec $VMID -- apt update && apt upgrade -y
pct exec $VMID -- apt install -y screen mc curl net-tools git
```

**k3s-specific workarounds inside the container:**

```bash
# /dev/kmsg workaround: k3s-containerd expects /dev/kmsg.
# In LXC it doesn't exist → symlink to console
# rc.local runs at boot (systemd-compatible)
cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
if [ ! -e /dev/kmsg ]; then
    ln -s /dev/console /dev/kmsg
fi
mount --make-rshared /
EOF
chmod +x /etc/rc.local
```

`mount --make-rshared /` is required so that bind-mounts from the PVE host
are propagated into the container (for data volumes via `mp0`).

```bash
# PS1 to distinguish multiple clusters
echo 'PS1="\[\e[34m\][k3s-draft] \u@\h:\w\$ \[\e[0m\]"' >> /root/.bashrc

# Reboot (via PVE)
pct reboot $VMID
```

## 4. Install k3s

```bash
# Option A: With Traefik (k3s built-in Ingress controller)
curl -sfL https://get.k3s.io | sh -

# Option B: Without Traefik (recommended – ArgoCD or nginx-ingress handles Ingress)
curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode=644
```

**Flag `--write-kubeconfig-mode=644`** allows non-root users to read the
kubeconfig (otherwise it's root-only).

## 5. kubeconfig + kubectl Access

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes

# Copy kubeconfig to home directory for persistent access
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
```

## 6. Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 7. Install ArgoCD

Install via Helm chart into its own namespace `argocd`:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --namespace argocd --create-namespace
```

## 8. Expose ArgoCD UI

ArgoCD starts with `ClusterIP` by default. Change to NodePort for LAN access:

```bash
kubectl patch svc argocd-server -n argocd \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/ports/1/nodePort", "value": 30444}]'
```

The UI is then reachable at `https://192.168.0.183:30444`.

**Retrieve initial admin password:**

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d
```

## 9. Connect Git Repository to ArgoCD

ArgoCD needs access to the Git repo to sync manifests.
Connection via SSH key.

**Generate SSH key on the PVE host:**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/argocd -N "" -C "argocd@k3s-draft"
```

**Add public key to Gitea:**
Gitea → User Settings → SSH/GPG Keys → Add Key → Paste contents of `~/.ssh/argocd.pub`.

**Register private key + repository in ArgoCD – Secret YAML method:**

```bash
cat > /tmp/repo-secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-k8s-apps
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ssh://git@git.blox.media:222/matt/k8s-apps.git
  sshPrivateKey: |
EOF
cat ~/.ssh/argocd >> /tmp/repo-secret.yaml
kubectl apply -f /tmp/repo-secret.yaml
```

**Alternative via ArgoCD CLI:**

```bash
# Install CLI (inside the container)
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

# Login + add repo
argocd login 192.168.0.183:30444 --name root --username admin --password <pass> --insecure
argocd repo add ssh://git@git.blox.media:222/matt/k8s-apps.git \
  --ssh-private-key-path /root/.ssh/argocd
```

Before `repo add`, the SSH host key of Gitea must be trusted:
```bash
ssh-keyscan -p 222 git.blox.media | argocd cert add-ssh --batch --upsert
```

Then restart the repo server to load the new key:
```bash
kubectl rollout restart deployment argocd-repo-server -n argocd
```

## 10. Create Root App in ArgoCD

The Root App is an ArgoCD Application CRD that deploys all apps under
`argocd/<cluster>/` automatically. ArgoCD manages itself this way.

```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ssh://git@git.blox.media:222/matt/k8s-apps.git
    path: argocd/lain-k3s-draft
    targetRevision: main
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

**Sync Policy:**
- `prune: true` – deletes resources that no longer exist in Git
- `selfHeal: true` – automatically reverts manual changes to the cluster back to Git state

From now on: **Git as single source of truth**. Every change to the manifests
in Git is automatically synced to the cluster by ArgoCD.

## 11. Data Mount Preflight (optional)

Prevents the LXC from starting while a data volume (e.g. dmcrypt) is not
mounted. Without this protection, the container starts with an empty mount
path – k3s data is preserved, but the app runs without its data.

**How it works:** `lxc.hook.pre-start` points to an executable file that
resides **on the data volume**. If the volume is not mounted, the file does
not exist → the hook fails → the container does not start.

```bash
# Create preflight file (on the data volume)
echo '#!/bin/true' > /zfs/phison4t/plain/k3s/.mounted
chmod +x /zfs/phison4t/plain/k3s/.mounted

# Add to container config
echo "lxc.hook.pre-start: /zfs/phison4t/plain/k3s/.mounted" >> /etc/pve/lxc/$VMID.conf
echo "mp0: /zfs/phison4t/plain/k3s,mp=/mnt/plain_k3s" >> /etc/pve/lxc/$VMID.conf
```

**Behavior:**

| State | `.mounted` exists? | Container starts? |
|---|---|---|
| dmcrypt mounted | Yes | Yes |
| dmcrypt not mounted | No | No (hook fails) |
| no dmcrypt (test) | Created manually | Yes (preflight is pointless) |

