# provision/ – Cluster Provisioning

> **Purpose:** Reference for the automated provisioning script.
> Use this to run, configure, or understand what `provision-pve-lxc.sh` does.

`provision-pve-lxc.sh` sets up a k3s cluster inside a PVE LXC idempotently
(steps 1–13, corresponding to the guide in `doc/lxc-k3s.md`).

**Usage:**
```
./provision-pve-lxc.sh <config>           # full run
./provision-pve-lxc.sh <config> --step N  # resume from step N
./provision-pve-lxc.sh <config> --list    # list steps
```

**Configuration:**
- `example.conf` – template with all options (documented)
- `lain-k3s-draft.conf` – production cluster configuration

The script is idempotent: already completed steps are detected and skipped.
