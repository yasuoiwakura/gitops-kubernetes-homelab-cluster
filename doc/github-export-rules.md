# GitHub Export Rules

This document describes the process of exporting from the private Gitea repository
to the public GitHub repository `gitops-kubernetes-homelab-cluster`.

The export is a **one-way mirror**: changes flow Gitea → GitHub only.

---

## 1. Files in Private Repo Only (NOT in GitHub)

These files exist in the Gitea repo but must **never** be pushed to GitHub:

| File | Reason |
|---|---|
| `doc/github-export-rules.md` | Internal process documentation |
| `provision/lain-k3s-draft.conf` | Contains private IPs, host paths, Gitea URL, storage names |
| `.git/` | Entire git history with private commits |

Future additions belong here if they contain private infrastructure details.

---

## 2. Files in GitHub Only (NOT in Private Repo)

These files exist in the GitHub repo but **not** in the Gitea source:

| File | Reason |
|---|---|
| `LICENSE` | MIT license – not needed in private Gitea, required for public GitHub |

The GitHub repo's `README.md` fork notice already tells users to adjust Git URLs.
No additional GitHub-specific files are needed.

---

## 3. Data to Anonymize

This section lists every value that should be replaced with placeholders (`YOUR_*`)
before pushing to GitHub, so that the repo is self-contained and usable by anyone.

Currently these are **not yet anonymized** – the list serves as a spec for a future
automation step (script or LLM-driven). When anonymization is implemented,
this checklist ensures nothing is missed.

### 3.1 Domains & URLs

| Current value | File(s) | Target placeholder |
|---|---|---|
| `git.blox.media` | `README.md`, `doc/lxc-k3s.md`, `argocd/root.lain-k3s-draft.yaml`, `argocd/lain-k3s-draft/uptime-kuma.yaml`, `provision/example.conf` | `YOUR_GIT_SERVER` |
| `git.blox.media:222` | same files | `YOUR_GIT_SERVER:PORT` |
| `ssh://git@git.blox.media:222/matt/k8s-apps.git` | same files | `ssh://git@YOUR_GIT_SERVER:PORT/YOUR_USER/k8s-apps.git` |
| `matt` (Git user) | `argocd/root.lain-k3s-draft.yaml`, `argocd/lain-k3s-draft/uptime-kuma.yaml`, `provision/example.conf` | `YOUR_USER` |

### 3.2 IP Addresses

| Current value | File(s) | Target placeholder |
|---|---|---|
| `192.168.0.183/24` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_IP/24` |
| `192.168.0.183` | `SPEC.md`, `argocd/lain-k3s-draft/uptime-kuma.yaml` | `YOUR_HOST_IP` |
| `192.168.0.1` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_GATEWAY` |
| `192.168.0.201` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_DNS` |
| `https://192.168.0.183:30444` | `doc/lxc-k3s.md` | `https://YOUR_IP:30444` |

### 3.3 Hostnames & Identifiers

| Current value | File(s) | Target placeholder |
|---|---|---|
| `lain-k3s-draft` (cluster name) | `SPEC.md`, `doc/lxc-k3s.md`, `argocd/root.lain-k3s-draft.yaml`, directory names under `argocd/`, `overlays/` | `YOUR_CLUSTER` (or keep as example name) |
| `k3s-draft` (hostname) | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_HOSTNAME` |
| `[k3s-draft]` (PS1 label) | `doc/lxc-k3s.md`, `provision/example.conf` | `[YOUR_CLUSTER]` |
| `OptiPlex` | `SPEC.md` | `YOUR_HOST` |
| `argocd@k3s-draft` (SSH key comment) | `doc/lxc-k3s.md` | `argocd@YOUR_HOSTNAME` |

### 3.4 Infrastructure Paths

| Current value | File(s) | Target placeholder |
|---|---|---|
| `vmbr0` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_BRIDGE` |
| `zfs_proxmox_1` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_STORAGE` |
| `local-lvm` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_ROOTFS_STORAGE` |
| `/zfs/phison4t/plain/k3s` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_HOST_PATH` |
| `/mnt/plain_k3s` | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_LXC_MOUNTPOINT` |
| `183` (VMID) | `doc/lxc-k3s.md`, `provision/example.conf` | `YOUR_VMID` |
| `30444` (NodePort) | `doc/lxc-k3s.md`, `provision/example.conf` | keep as is (port, not infra-specific) |

### 3.5 Not Yet Applied

The `provision/example.conf` already uses `YOUR_*` placeholders (updated).
All other files listed above still contain real values and would need replacement
before a clean public release. This section is the authoritative spec for that task.

---

## 4. Git Workflow: Private Branch → GitHub Branch

This workflow switches the branch pointer to `github` while keeping the
working copy from your private branch. You then manually stage/unstage
what should go to GitHub and commit only the desired changes.

### 4.1 Initial Setup (One-Time)

```bash
# Add GitHub as a remote
git remote add github https://github.com/YOUR_USER/gitops-kubernetes-homelab-cluster.git
# Ensure the local "github" branch exists (checkout once from remote or create orphan)
# Optional: fetch current GitHub state
git fetch github
```

### 4.2 Create the GitHub Branch (Orphan) from Current State

```bash
# Create an orphan branch – no parent commit, no history.
# The working copy stays unchanged, everything is staged.
git checkout --orphan github
```

**How it works:**
- `--orphan` creates a branch **without any parent commit**
- The working directory and the index stay **exactly as they were** from your private branch
- `git status` shows **all files as staged** (new branch, new first commit)
- You now remove/unstage what you don't want, commit the rest as a single clean snapshot

### 4.3 Remove Private Files + Stage Only What You Want

```bash
# 1. Unstage everything (the orphan branch staged all files from your working copy)
git reset HEAD

# 2. Remove private files from the working copy entirely
rm provision/lain-k3s-draft.conf
rm doc/github-export-rules.md
echo "provision/lain-k3s-draft.conf" >> .gitignore
echo "doc/github-export-rules.md" >> .gitignore

# 3. Stage everything you want to keep
git add -A

# 4. Or: use interactive staging for fine-grained control per file/hunk
git add -p
```

### 4.4 Review + Commit + Push

```bash
# Review what will go to GitHub
git status
git diff --cached --stat

# Check for accidental private data
git diff --cached -S "192.168." -- .
git diff --cached -S "blox.media" -- .

# Commit
git commit -m "chore: sync from private repo"

# Push to GitHub (overwrites remote main)
git push github github:main --force

# Switch back to your private development branch
git checkout <private-branch>
```

### 4.5 Branch State After This Workflow

```
Before:
  private-branch (feat-004-github) ──→ Commit X

Step "git checkout --orphan github":
  private-branch ──→ Commit X
  github          ──→ (no commits yet, no parent)

After commit:
  private-branch ──→ Commit X
  github          ──→ Commit G1 (clean snapshot, orphan)

Next sync (from same private branch or later commit):
  private-branch ──→ Commit Y
  github          ──→ Commit G1 (intact, needs merge or force push)
```

### 4.6 Advantages of This Approach

| Aspect | What happens |
|---|---|
| Private files | `rm` + `.gitignore` → never in commit |
| Private commit history | Stays in Gitea, never pushed to GitHub |
| Selective changes | Manual `git add` per file/hunk |
| Data leaks | `git diff --cached -S` before commit |
| Force push | `github:main --force` overwrites remote safely |
| Local branches | `github` can be updated incrementally next time |
