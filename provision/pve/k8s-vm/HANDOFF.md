# Handoff: Kubernetes VM Provisioning on Proxmox VE

## Project Status: FUNCTIONAL (but needs optimization)

The script `create-k8s-vm.sh` successfully creates Kubernetes VMs on both LVM and ZFS storage. SSH root login works. Cloud-init vendor-data is correctly applied.

---

## CRITICAL LESSONS LEARNED

### 1. `qm disk import` behaves differently per storage type
**THIS IS THE #1 PITFALL.**

| Storage Type | Volume Path Format | Example |
|---|---|---|
| local-lvm | `local-lvm:vm-{VMID}-disk-0` | `local-lvm:vm-199-disk-0` |
| zfs | `{pool}:{VMID}/vm-{VMID}-disk-0.raw` | `zfs_proxmox_1:180/vm-180-disk-0.raw` |
| local (dir) | `local:{VMID}/vm-{VMID}-disk-0.qcow2` | `local:100/vm-100-disk-0.qcow2` |

**Solution:** After `qm disk import`, extract the path from `qm config`:
```bash
DISK_PATH=$(qm config $VMID | grep "unused0" | awk '{print $2}')
qm set $VMID --scsi0 "$DISK_PATH" --boot order=scsi0
```

### 2. `--cicustom user=` vs `--cicustom vendor=`
- **`user=`** REPLACES the generated user-data completely. `--sshkeys` is IGNORED.
- **`vendor=`** AUGMENTS the generated user-data. `--sshkeys` is PRESERVED.
- **Always use `vendor=`** when you want to keep Proxmox's auto-generated settings (hostname, users, ssh keys from `--sshkeys`).

### 3. SSH Keys: Do NOT put them in the YAML
- Use `qm set $VMID --sshkeys /path/to/authorized_keys`
- Proxmox generates the correct user-data for SSH keys
- If you use `--cicustom user=`, SSH keys from `--sshkeys` are IGNORED
- The `authorized_keys` file must NOT contain comment lines starting with `#` (Proxmox rejects them)
- Remove inline comments (everything after ` #`) before passing to `--sshkeys`

### 4. `--nameserver` with multiple DNS servers
```bash
# CORRECT (with quotes):
qm set 199 --nameserver "1.1.1.1 8.8.4.4"

# WRONG (without quotes):
qm set 199 --nameserver 1.1.1.1 8.8.4.4  # "too many arguments" error
```
Space-separated, wrapped in quotes.

### 5. `--ciuser root` is the way to go
- Default Proxmox cloud-init creates `ubuntu` user (via `users: - default`)
- Setting `--ciuser root` means SSH keys are applied to root directly
- This is cleaner than trying to configure root login via vendor-data

### 6. Ubuntu cloud images have `disable_root: true` by default
- Cloud-init won't create root's authorized_keys properly
- Fix via vendor-data: `disable_root: false`
- Also add `/etc/ssh/sshd_config.d/60-root-login.conf` with `PermitRootLogin yes`

### 7. `--ciupgrade 0` disables package upgrades
- Stronger than `package_upgrade: false` in vendor-data
- Essential for fast debugging (no apt update/download on boot)

### 8. DNS: Ubuntu 26.04 uses systemd-resolved
- `/etc/resolv.conf` points to `127.0.0.53` (stub resolver) - this is NORMAL
- Real DNS servers are configured via Netplan/systemd-networkd
- `--nameserver` sets the DNS correctly via cloud-init

### 9. `kubectl` in `runcmd` needs explicit KUBECONFIG (CRITICAL)
**Confirmed root cause of the broken first K8s provisioning.**

Symptom in `/var/log/cloud-init-output.log`:
```
"Couldn't get current server API group list"
err="Get \"http://localhost:8080/api?timeout=32s\": dial tcp [::1]:8080: connect: connection refused"
error validating "https://github.com/flannel-io/flannel/.../kube-flannel.yml": ...
```

- `cp /etc/kubernetes/admin.conf /root/.kube/config` writes the file correctly.
- But in the cloud-init/runcmd environment `$HOME` is **not** `/root` (unset/other),
  so `kubectl` looked in the wrong `$HOME/.kube/config` and fell back to `localhost:8080`.
- Consequence: **every** kubectl command after `kubeadm init` failed:
  - `kubectl get nodes` / `kubectl get pods`
  - `kubectl apply -f kube-flannel.yml` → **no CNI** → node stays `NotReady`
  - `kubectl taint ... || true` → silently failed → `control-plane` taint stayed
- Interactive SSH as root later worked because there `$HOME=/root`.

Fix in `k8s-cloud-init.yaml` (applied):
```yaml
  - mkdir -p /root/.kube
  - cp -f /etc/kubernetes/admin.conf /root/.kube/config   # was: cp -i (interactive -> wrong)
  - chown root:root /root/.kube/config
  - export KUBECONFIG=/etc/kubernetes/admin.conf          # explicit for all following commands
```
General rule: never rely on `$HOME` inside cloud-init `runcmd`; set `KUBECONFIG` explicitly.

### 10. Package name change on Ubuntu 26.04
- `dnsutils` no longer exists as a package name → install `bind9-dnsutils`.
- A failing `packages` entry makes the `packages` module fail, but did NOT abort `runcmd`
  (kubeadm still ran). The two problems were independent.

---

## CURRENT FILE STRUCTURE

```
provision/pve/k8s-vm/
├── create-k8s-vm.sh          # Main script (works for all storage types)
├── k8s-cloud-init.yaml       # Kubernetes vendor-data (full install)
├── debug-cloud-init.yaml     # Minimal vendor-data (SSH test only)
├── default.conf              # Default config (local-lvm)
├── lain.conf                 # Lain config (zfs_proxmox_1)
├── debug.conf                # Debug config (no packages, fast)
└── README.md                 # Documentation
```

## USAGE

```bash
# Debug mode (fast, no packages, SSH test only)
./create-k8s-vm.sh debug.conf

# Kubernetes install (full)
./create-k8s-vm.sh lain.conf

# Generate vendor-data only (no VM creation)
./create-k8s-vm.sh lain.conf --only-generate-userdata
```

## KNOWN ISSUES

1. **FIXED: `kubectl`/`KUBECONFIG` in runcmd** → caused missing Flannel + stuck control-plane taint
2. **FIXED: `dnsutils` package name** → now `bind9-dnsutils`
3. `lain.conf` still runs `package_upgrade: true` (deliberate) → slower first boot
4. Debug mode is fast because `CIUPGRADE=0` is set and no packages are installed
5. SSH login delay on full install is caused by apt updates running in the background

## NEXT STEPS

1. Re-provision the full K8s VM and verify: node `Ready`, Flannel running, taint removed automatically
2. Confirm `/var/log/cloud-init-output.log` has no `localhost:8080` errors
3. Optionally mark `runcmd` as success even if the last `kubectl` call fails (avoid `cloud-final` failed state)

