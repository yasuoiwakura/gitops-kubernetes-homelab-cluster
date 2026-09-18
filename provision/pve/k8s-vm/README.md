# Kubernetes VM Provisioning for Proxmox VE

Creates a single-node Kubernetes cluster on a Proxmox VM using cloud-init.

## Files

| File | Description |
|---|---|
| `create-k8s-vm.sh` | Main script (run on PVE host) |
| `k8s-cloud-init.yaml` | Cloud-init template (kubeadm + Flannel) |
| `default.conf` | Config for local-lvm storage |
| `lain.conf` | Config for ZFS storage (production) |
| `debug.conf` | Minimal config (SSH test only) |

## Quick Start

```bash
# Upload files to Proxmox host
scp create-k8s-vm.sh k8s-cloud-init.yaml lain.conf root@proxmox-host:/root/

# SSH and run
ssh root@proxmox-host "chmod +x /root/create-k8s-vm.sh && /root/create-k8s-vm.sh lain.conf"
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `VMID` | 180 | Proxmox VM ID |
| `VM_NAME` | k8s-cp01 | VM hostname |
| `MEMORY` | 2048 | RAM in MB |
| `CORES` | 2 | CPU cores |
| `STORAGE` | zfs_proxmox_1 | Proxmox storage |
| `DISK_SIZE` | 20G | Disk size |
| `K8S_VERSION` | 1.37 | Kubernetes version |
| `IP_ADDRESS` | 192.168.0.180/24 | Static IP with CIDR |
| `GATEWAY` | 192.168.0.1 | Network gateway |
| `DNS_SERVER` | 192.168.0.201 | DNS server(s), space-separated |

## What Cloud-init Does

1. System config (hostname, locale, /etc/hosts)
2. User setup (SSH keys via `qm set --sshkeys`)
3. Package install (containerd, kubeadm, kubelet, kubectl)
4. Kernel config (overlay, br_netfilter modules)
5. Containerd setup (cgroup v2)
6. kubeadm init + Flannel CNI
7. Reboot

## Monitoring

```bash
# Proxmox console
qm terminal 180

# SSH (once IP is assigned)
ssh root@192.168.0.180 "cloud-init status"
ssh root@192.168.0.180 "tail -f /var/log/cloud-init-output.log"
```

## Verification

```bash
ssh root@192.168.0.180
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
