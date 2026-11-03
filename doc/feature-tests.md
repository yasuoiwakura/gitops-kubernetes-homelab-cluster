# Feature Tests

> **Purpose:** Checklist of manually verifiable features. Each entry has a stable ID,
> so an automation/LLM prompt can ask for status or request a specific test.
> Update the **Status** column after running a test.

## How to Use

- Status values: `UNTESTED`, `PASS`, `FAIL`, `BLOCKED`
- Every test lists the exact command and the expected result.
- Record the date and the cluster/VM when a result changes.
- This file is the source of truth for "what was actually verified" – a merged
  commit does **not** imply a tested feature.

## Environment

| Environment | Host | Cluster | Bit |
|---|---|---|---|
| `lain-k3s-draft` | PVE LXC `203.0.113.10` | k3s | LXC / k3s path |
| `k8s-lain` | PVE VM `203.0.113.11` | kubeadm | VM / cloud-init path |

---

## 1. VM Provisioning (`k8s-lain`)

### VM-01 – Cloud-init completes

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Precondition | VM provisioned with `./create-k8s-vm.sh lain.conf` |
| Command | `ssh root@203.0.113.11 "cloud-init status --long"` |
| Expected | `status: done`, no `errors` |

### VM-02 – Node Ready, Flannel running, taint removed

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `ssh root@203.0.113.11 "kubectl get nodes -o wide"` and `kubectl get pods -A` |
| Expected | Node `Ready`; `kube-flannel-*` and `kube-proxy-*` running; no control-plane taint |
| Notes | Regression check for the `KUBECONFIG`/`localhost:8080` bug (HANDOFF.md #9) |

### VM-03 – No `localhost:8080` errors during provisioning

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `ssh root@203.0.113.11 "grep -c localhost:8080 /var/log/cloud-init-output.log"` |
| Expected | `0` |

### VM-04 – Kubernetes 1.36

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `ssh root@203.0.113.11 "kubeadm version -o short"` |
| Expected | `v1.36.x` |
| Notes | 1.36 is the newest Kubernetes version tested with ArgoCD 3.5 |

---

## 2. Helm

### HELM-01 – Helm installed

| Field | Value |
|---|---|
| Status | `PASS` (verified 2026-11-03) |
| Command | `ssh root@203.0.113.11 "helm version"` |
| Expected | `version.BuildInfo{...}` printed, exit code `0` |
| Notes | Installed by `k8s-cloud-init.yaml` via `get-helm-3` (no config toggle) |

### HELM-02 – Helm repo add works

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `helm repo add argo https://argoproj.github.io/argo-helm && helm repo update` |
| Expected | repo added/updated without error |

### HELM-03 – Helm can reach the cluster

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `helm list -A` |
| Expected | table header printed, exit code `0` (empty list is fine) |

---

## 3. Kubernetes CLI Convenience (`K8S_CONVENIENCE=true` in `lain.conf`)

Precondition for all CONV tests: log in again (or `source ~/.bashrc`) so
`/root/.bashrc` is re-read.

### CONV-01 – `k` alias

| Field | Value |
|---|---|
| Status | `PASS` (verified 2026-11-03) |
| Command | `ssh root@203.0.113.11 "bash -ic 'type k && k get nodes'"` |
| Expected | `k is aliased to 'kubectl'`; node list printed |

### CONV-02 – `k` bash completion

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `ssh root@203.0.113.11 "bash -ic 'complete -p k'"` |
| Expected | `complete -o default -F __start_kubectl k` |

### CONV-03 – `kubens` (namespace switch)

| Field | Value |
|---|---|
| Status | `PASS` (verified 2026-11-03) |
| Command | `ssh root@203.0.113.11 "kubens kube-system && kubectl config view --minify -o jsonpath='{..namespace}'"` |
| Expected | prints `kube-system`; then `kubens default` switches back |

### CONV-04 – `kubectx` (context switch)

| Field | Value |
|---|---|
| Status | `PASS` (verified 2026-11-03) |
| Command | `ssh root@203.0.113.11 "kubectx && kubectx kubernetes-admin@kubernetes"` |
| Expected | current context listed/switched, exit code `0` |
| Notes | On a single-context VM this only proves the binary works |

### CONV-05 – `kx` / `kn` aliases

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `ssh root@203.0.113.11 "bash -ic 'type kx && type kn'"` |
| Expected | aliases to `kubectx` / `kubens` |

### CONV-06 – Helm bash completion

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `ssh root@203.0.113.11 "bash -ic 'complete -p helm'"` |
| Expected | completion function `__start_helm` registered |

### CONV-07 – Convenience disabled leaves VM untouched

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | provision a config with `K8S_CONVENIENCE=false`, then `ssh root@... "grep -c k8s-convenience /root/.bashrc; command -v kubectx"` |
| Expected | `0` matches; `kubectx` not found |
| Note | Default is `false`; only `lain.conf` enables it |

---

## 4. GitOps / ArgoCD

### GITOPS-01 – ollama-bridge manifests render

| Field | Value |
|---|---|
| Status | `PASS` (static) |
| Command | `kubectl kustomize base/ollama-bridge` |
| Expected | Namespace + Service + Deployment rendered |
| Notes | Verified locally, not yet applied to a cluster |

### GITOPS-02 – ArgoCD Root App for `k8s-lain`

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Precondition | VM provisioned with `ARGOCD_ENABLED=true` |
| Command | `kubectl get application -n argocd` |
| Expected | `root` app synced; `ollama-bridge` app appears |
| Notes | Bootstrap implemented in `k8s-cloud-init.yaml`; verify after the next provisioning |

### GITOPS-03 – ollama-bridge runs

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Precondition | GITOPS-02 done, Ollama reachable |
| Command | `kubectl -n ollama-bridge get pods` and `curl http://203.0.113.11:30008/health` |
| Expected | pod `Running`/`Ready`; health endpoint responds |
| Risk | `OLLAMA_URL=203.0.113.42:11434` is hardcoded in `base/` and untested |

---

## 5. Repository Integrity

### REPO-01 – Squash of `feat-008-gitops-k8s` is clean

| Field | Value |
|---|---|
| Status | `PASS` (verified 2026-11-03) |
| Command | `git diff --stat feat-008-gitops-k8s 1e6117c` |
| Expected | empty output (squashed commit is content-identical to the 3 source commits) |
| Additional checks | `git show --stat 1e6117c` → 8 files, +106/−5; `git ls-tree -r --name-only 1e6117c \| grep overlays/k8s-lain` → empty |
| Result | all checks passed; overlay churn correctly removed |

### REPO-02 – `dev` contains `feat-008` content

| Field | Value |
|---|---|
| Status | `PASS` (verified 2026-11-03) |
| Command | `git merge-base --is-ancestor 1e6117c dev && echo OK` |
| Expected | `OK` |

### REPO-03 – K8S_CONVENIENCE changes committed

| Field | Value |
|---|---|
| Status | `PASS` (commit `d49bfdd`) |
| Command | `git show --stat d49bfdd` |
| Expected | 5 files: `create-k8s-vm.sh`, `k8s-cloud-init.yaml`, `lain.conf`, `default.conf`, `README.md` |
| Notes | Helm install committed in `bd64941`; checklist added in `56069b2` |

---

## 6. Provisioning Status

Precondition: `PROVISION_STATUS=true` in the config. Login runs
`provision-status --short` via `/etc/profile.d/99-provision-status.sh`.

Data: `/var/lib/provisioning/start.env` (immutable) and `state.env` (mutable copy).

### PROV-01 – Status during provisioning

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | SSH in while cloud-init is running, or `watch -n 5 provision-status --short` |
| Expected | `[host] provisioning: running - step x/6 <label> - <elapsed>` plus a `git:` line |
| Notes | Step 1/6 = cloud-init packages (apt upgrade/install) before `runcmd` |

### PROV-02 – Status after completion

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | SSH in after the final reboot: `provision-status` and `provision-status --benchmark` |
| Expected | `Cloud-init: done`, `Step: 6/6 - done`, `Provision: start … done …`, `Duration`; benchmark shows per-step times |
| Notes | Must survive reboot (data in `/var/lib/provisioning`, not `/run`) |

### PROV-03 – Git metadata injected

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `cat /var/lib/provisioning/start.env` |
| Expected | `REPO_NAME`, `GIT_BRANCH`, `GIT_COMMIT`, `GIT_COMMIT_DATE`, `PROVISION_START`, `PROVISION_START_EPOCH`, hashes populated when started from a git checkout |
| Notes | If run from `scp`-copied files, git fields are `unknown`; hashes still identify the state |

### PROV-04 – Disabled switch

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | provision with `PROVISION_STATUS=false`, then `ls -l /etc/profile.d/99-provision-status.sh; provision-status --short` |
| Expected | hook present but login shows nothing; manual `provision-status` still works |

### PROV-05 – Interrupted run detection

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | interrupt a run mid-`runcmd`, reboot, SSH in |
| Expected | `Cloud-init: done` and warning `cloud-init done but no done marker - runcmd incomplete` |
| Notes | `state.env` has no `PROVISION_DONE` |

### PROV-06 – Fast config skips apt upgrades

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | provision with `lain-fast.conf`, then `grep package_upgrade /var/lib/cloud/instance/vendor-data.txt` |
| Expected | `package_upgrade: false`; step 1 is much shorter |
| Notes | `lain-fast.conf` sources `lain.conf` and only overrides `PACKAGE_UPGRADE` |

---

## 7. ArgoCD Bootstrap

Precondition: `ARGOCD_ENABLED=true` in `lain.conf` and the public deploy key is
registered in Gitea.

### ARGO-01 – ArgoCD pods healthy

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `ssh root@203.0.113.11 "kubectl -n argocd get pods"` |
| Expected | `argocd-server`, `argocd-repo-server`, `argocd-application-controller`, `argocd-redis` Running |

### ARGO-02 – UI reachable on NodePort

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | Browser: `https://<VM_IP>:30444` (HTTP: `30081`) |
| Expected | ArgoCD login page (self-signed certificate warning is expected) |
| Notes | Requires `argocd-server` pod Ready |

### ARGO-03 – Repo secret + root app synced

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl -n argocd get secret repo-k8s-apps` and `kubectl -n argocd get application root` |
| Expected | Secret exists with label `argocd.argoproj.io/secret-type=repository`; root app `Synced`/`Healthy` |

### ARGO-04 – Initial admin password

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Expected | Printable password; login as `admin` works |

### ARGO-05 – Root app path/target

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl -n argocd get application root -o jsonpath='{.spec.source.path}{" "}{.spec.source.targetRevision}'` |
| Expected | `argocd/k8s-lain main` |

---

## 8. API Gateway (NGINX Gateway Fabric)

Precondition: `GATEWAY_ENABLED=true` and the root app synced.

### NGF-01 – Gateway API CRDs installed

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io` |
| Expected | Both CRDs `Established` |

### NGF-02 – NGF control plane running

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl -n nginx-gateway get pods` |
| Expected | `ngf-nginx-gateway-fabric-*` Running/Ready |

### NGF-03 – GatewayClass and Gateway accepted

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl get gatewayclass nginx` and `kubectl get gateway default -o wide` |
| Expected | GatewayClass `Accepted=True`; Gateway `Accepted=True`, `Programmed=True` |

### NGF-04 – Data plane on NodePort 30080

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl -n nginx-gateway get svc` |
| Expected | NGINX data plane Service with `80:30080/TCP` |

### NGF-05 – ArgoCD applications synced

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | `kubectl -n argocd get applications` |
| Expected | `gateway-api-crds`, `nginx-gateway-fabric`, `gateway` Synced/Healthy |

### NGF-06 – Gateway disabled

| Field | Value |
|---|---|
| Status | `UNTESTED` |
| Command | provision with `GATEWAY_ENABLED=false`, then `kubectl -n argocd get applications` |
| Expected | No `gateway-api-crds`/`nginx-gateway-fabric`/`gateway` applications (excluded via `directory.exclude: gateway/*`) |
