#!/bin/bash
# provision-pve-lxc.sh – k3s cluster on PVE LXC (idempotent)
# Usage:
#   ./provision-pve-lxc.sh <config>          # all steps
#   ./provision-pve-lxc.sh <config> --step N # resume from step N
#   ./provision-pve-lxc.sh <config> --list   # list steps
set -euo pipefail

LXC_CONF_DIR=/etc/pve/lxc

usage() {
    cat <<USAGE
Usage: $0 <config> [--step N | --list]

  config   Cluster config file (e.g. lain-k3s-draft.conf)
  --step N Start from step N (1-13)
  --list   List steps
USAGE
    exit 0
}
die()   { echo "[FAIL] $*" >&2; exit 1; }
host_info()  { echo "  [HOST] $*"; }
host_ok()    { echo "  [HOST] $*"; }
host_skip()  { echo "  [HOST] $*"; }
lxc_info()   { echo "  [LXC]  $*"; }
lxc_ok()     { echo "  [LXC]  $*"; }
lxc_skip()   { echo "  [LXC]  $*"; }

# ── Load configuration ──────────────────────────────────────────
[ $# -eq 0 ] && usage
CONFIG="$1"
[ -f "$CONFIG" ] || die "Config $CONFIG not found"
source "$CONFIG"

# Derive cluster name from config filename (e.g. lain-k3s-draft.conf → lain-k3s-draft)
CLUSTER_NAME=$(basename "$CONFIG" .conf)

# Security check: privileged containers
if [ "${UNPRIVILEGED:-1}" = "0" ] && \
   [ "${I_DONT_CARE_PRIVILEGED_CONTAINERS_ARE_INSECURE:-false}" != "true" ]; then
    echo ""
    echo "  !!! SECURITY WARNING !!!"
    echo "  This LXC runs as PRIVILEGED (UNPRIVILEGED=0)."
    echo "  Only suitable for test/development environments."
    echo ""
    echo "  Set in the config:"
    echo "    I_DONT_CARE_PRIVILEGED_CONTAINERS_ARE_INSECURE=true"
    echo "  to confirm and proceed."
    echo ""
    exit 1
fi

STEP=1
if [ "${2:-}" = "--step" ]; then
    STEP="${3:?Usage: $0 <config> --step N}"
fi
if [ "${2:-}" = "--list" ]; then
    echo "Steps (doc/lxc-k3s.md):"
    echo "  0  Download template (once per PVE node)"
    echo "  1  Create LXC"
    echo "  2  Configure LXC (nesting, devices)"
    echo "  3  Base packages & LXC fixes"
    echo "  4  Install k3s"
    echo "  5  Set up kubeconfig"
    echo "  6  Install Helm"
    echo "  7  Install ArgoCD"
    echo "  8  ArgoCD Service"
    echo "  9  (Port forward – optional, not in script)"
    echo " 10  Prepare SSH key + ArgoCD CLI"
    echo " 11  ArgoCD login + SSH host key + repo server restart"
    echo " 12  argocd repo add"
    echo " 13  Create Root App in ArgoCD (auto-deploy)"
    exit 0
fi

# ── Helpers ────────────────────────────────────────────────────────
pct_exec() {
    pct exec "$VMID" -- env HOME=/root PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin" "$@"
}

pct_exec_stdin() {
    # Run command via stdin (for here-docs in the console)
    pct exec "$VMID" -- env HOME=/root PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin" bash -s
}


pct_push() { pct push "$VMID" "$1" "$2"; }

wait_container_ready() {
    local max=30 i=0
    while ! pct status "$VMID" 2>/dev/null | grep -q running; do
        sleep 1; ((i++))
        [ $i -ge "$max" ] && die "Container $VMID did not become running"
    done
    sleep 2 # brief stabilization
}

# ── Idempotency checks ─────────────────────────────────────────

step0_needed() {
    pveam list "$PVE_STORAGE" 2>/dev/null | grep -q "$(basename "${TEMPLATE##*:}")" && return 1 || return 0
}

step1_needed() {
    pct status "$VMID" 2>/dev/null && return 1 || return 0
}

step2_needed() {
    grep -q '^lxc.apparmor.profile: unconfined' "$LXC_CONF_DIR/$VMID.conf" 2>/dev/null && return 1 || return 0
}

step3_needed() {
    pct_exec test -f /etc/rc.local 2>/dev/null && \
        pct_exec grep -q 'kmsg' /etc/rc.local 2>/dev/null && return 1 || return 0
}

step4_needed() {
    pct_exec command -v k3s 2>/dev/null && return 1 || return 0
}

step5_needed() {
    pct_exec test -f /root/.kube/config 2>/dev/null && return 1 || return 0
}

step6_needed() {
    pct_exec command -v helm 2>/dev/null && return 1 || return 0
}

step7_needed() {
    pct_exec helm list -n argocd 2>/dev/null | grep -q argocd && return 1 || return 0
}

step8_needed() {
    local current
    current=$(pct_exec kubectl get svc argocd-server -n argocd -o json 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['spec']['type'])" 2>/dev/null || echo "")
    [ "$current" = "${ARGOCD_SERVICE_MODE:-NodePort}" ] && return 1 || return 0
}

step10_needed() {
    [ -f /root/.ssh/argocd ] && pct_exec command -v argocd 2>/dev/null && return 1 || return 0
}

step11_needed() {
    pct_exec test -f /root/.config/argocd/config 2>/dev/null && return 1 || return 0
}

step12_needed() {
    pct_exec argocd repo list 2>/dev/null | grep -qF "$GITEA_REPO_URL" && return 1 || return 0
}

step13_needed() {
    pct_exec kubectl get application root -n argocd 2>/dev/null && return 1 || return 0
}

# ── Steps ──────────────────────────────────────────────────────

step0() {
    echo "=== Step 0: Download template ==="
    step0_needed || { host_skip "Template ${TEMPLATE##*:} already exists"; return 0; }
    pveam download "$PVE_STORAGE" "${TEMPLATE##*:}" || die "Template download failed"
    host_ok "Template ${TEMPLATE##*:} downloaded"
}

step1() {
    echo "=== Step 1: Create LXC ==="
    step1_needed || {
        if [ "${IGNORE_EXISTING_CONTAINER:-false}" = "true" ]; then
            host_skip "Container $VMID already exists (IGNORE_EXISTING_CONTAINER=true)"
            return 0
        fi
        echo ""
        echo "  Container $VMID ($HOSTNAME) already exists."
        echo "  Delete it manually or set IGNORE_EXISTING_CONTAINER=true"
        echo "  in the config to proceed with the existing container."
        echo ""
        exit 1
    }
    grep -v '^#' /root/.ssh/authorized_keys > /tmp/keys_$VMID.txt
    pct create "$VMID" "$TEMPLATE" \
        --hostname "$HOSTNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --storage "$ROOTFS_STORAGE" \
        --rootfs "$ROOTFS_SIZE" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
        --nameserver "$NAMESERVER" \
        --unprivileged "$UNPRIVILEGED" \
        --ssh-public-keys "/tmp/keys_$VMID.txt" || die "pct create failed"
    host_ok "Container $VMID ($HOSTNAME) created"
}

step2() {
    echo "=== Step 2: Configure LXC (nesting, devices) ==="
    local conf="$LXC_CONF_DIR/$VMID.conf"
    [ -f "$conf" ] || die "Config $conf not found – Step 1 executed?"
    # ── Data mount & preflight (idempotent, always run) ──
    if [ -n "$PREFLIGHT_CHECK_SCRIPT" ]; then
        if ! grep -q 'lxc.hook.pre-start' "$conf" 2>/dev/null; then
            echo "lxc.hook.pre-start: $PREFLIGHT_CHECK_SCRIPT" >> "$conf"
            host_ok "lxc.hook.pre-start → $PREFLIGHT_CHECK_SCRIPT"
        else
            host_ok "lxc.hook.pre-start already set"
        fi
    fi
    if [ -n "$DATA_MOUNT_SRC" ] && [ -n "$DATA_MP" ]; then
        if ! grep -q "^mp0:" "$conf" 2>/dev/null; then
            echo "mp0: $DATA_MOUNT_SRC,mp=$DATA_MP" >> "$conf"
            host_ok "mp0 mount: $DATA_MOUNT_SRC → $DATA_MP"
        else
            host_ok "mp0 already configured"
        fi
    fi
    # ── Nesting config ──
    step2_needed || { host_skip "LXC config already adjusted"; return 0; }
    sed -i '/^lxc\.apparmor\.profile/d; /^lxc\.cgroup\.devices\.allow/d; /^lxc\.cap\.drop/d; /^lxc\.mount\.auto/d' "$conf"
    sed -i '/^rootfs/i\lxc.apparmor.profile: unconfined\nlxc.cgroup.devices.allow: a\nlxc.cap.drop:\nlxc.mount.auto: proc:rw sys:rw' "$conf"
    host_ok "LXC config patched"
    host_info "Starting container…"
    pct start "$VMID" || die "pct start failed"
    wait_container_ready
    host_ok "Container $VMID is running"
}

step3() {
    echo "=== Step 3: Base packages & LXC fixes ==="
    step3_needed || { host_skip "/etc/rc.local already configured"; return 0; }
    pct_exec apt update || die "apt update failed"
    [ "${APT_UPGRADE:-false}" = "true" ] && pct_exec apt upgrade -y
    pct_exec apt install -y $PACKAGES
    pct_exec_stdin <<'SCRIPT'
cat > /etc/rc.local <<'EOF'
#!/bin/sh -e
if [ ! -e /dev/kmsg ]; then
    ln -s /dev/console /dev/kmsg
fi
mount --make-rshared /
EOF
chmod +x /etc/rc.local
SCRIPT
    host_ok "rc.local set up"
    pct_exec_stdin <<'SCRIPT'
echo 'PS1="\[\e[34m\]'"${CLUSTER_LABEL}"' \u@\h:\w\$ \[\e[0m\]"' >> /root/.bashrc
SCRIPT
    host_ok "PS1 set"
    host_info "Rebooting container…"
    pct reboot "$VMID" || true
    sleep 3
    wait_container_ready
    host_ok "Container restarted"
}

step4() {
    echo "=== Step 4: Install k3s ==="
    step4_needed || { host_skip "k3s already installed"; return 0; }
    if [ "$DISABLE_TRAEFIK" = "true" ]; then
        pct_exec sh -c "curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode=644"
    else
        pct_exec sh -c "curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode=644"
    fi
    host_ok "k3s installed"
}

step5() {
    echo "=== Step 5: Set up kubeconfig ==="
    step5_needed || { host_skip "kubeconfig already exists"; return 0; }
    pct_exec_stdin <<'SCRIPT'
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /root/.kube/config
grep -q 'KUBECONFIG' /root/.bashrc || \
    echo 'export KUBECONFIG=/root/.kube/config' >> /root/.bashrc
SCRIPT
    host_ok "kubeconfig set up"
}

step6() {
    echo "=== Step 6: Install Helm ==="
    step6_needed || { host_skip "Helm already installed"; return 0; }
    pct_exec sh -c "curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    host_ok "Helm installed"
}

step7() {
    echo "=== Step 7: Install ArgoCD ==="
    step7_needed || { host_skip "ArgoCD already installed"; return 0; }
    pct_exec helm repo add argo https://argoproj.github.io/argo-helm
    pct_exec helm install argocd argo/argo-cd --namespace argocd --create-namespace
    host_ok "ArgoCD installed"
}

step8() {
    echo "=== Step 8: ArgoCD Service ==="
    step8_needed || { host_skip "Service already on $ARGOCD_SERVICE_MODE"; return 0; }
    case "${ARGOCD_SERVICE_MODE:-NodePort}" in
        ClusterIP|clusterip)
            host_ok "Service stays on ClusterIP (default)"
            return 0
            ;;
        NodePort|nodeport)
            pct_exec kubectl patch svc argocd-server -n argocd --type='json' \
                -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"replace","path":"/spec/ports/1/nodePort","value":'$ARGOCD_NODEPORT'}]'
            host_ok "Service set to NodePort ($ARGOCD_NODEPORT)"
            ;;
        LoadBalancer|loadbalancer)
            pct_exec kubectl patch svc argocd-server -n argocd --type='json' \
                -p='[{"op":"replace","path":"/spec/type","value":"LoadBalancer"}]'
            host_ok "Service set to LoadBalancer"
            ;;
        *)
            die "Unknown ARGOCD_SERVICE_MODE: $ARGOCD_SERVICE_MODE (allowed: ClusterIP, NodePort, LoadBalancer)"
            ;;
    esac
}

step10() {
    echo "=== Step 10: Prepare SSH key + ArgoCD CLI ==="
    step10_needed || { host_skip "SSH key and ArgoCD CLI already exist"; return 0; }
    local keyfile="/root/.ssh/argocd"
    if [ ! -f "$keyfile" ]; then
        ssh-keygen -t ed25519 -f "$keyfile" -N "" -C "argocd@$HOSTNAME"
        host_ok "SSH key $keyfile created"
        echo ""
        echo "  >>> Add the PUBLIC KEY to Gitea: <<<"
        cat "${keyfile}.pub"
        echo ""
        echo "  Then: copy the key to the LXC and install ArgoCD CLI."
        read -rp "  Press Enter after adding the key to Gitea..."
    else
        host_ok "SSH key $keyfile already exists"
    fi
    pct_push "$keyfile" "/root/.ssh/argocd"
    host_ok "SSH key copied to LXC"
    pct_exec curl -sSL -o /usr/local/bin/argocd \
        https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    pct_exec chmod +x /usr/local/bin/argocd
    host_ok "ArgoCD CLI installed"
}

step11() {
    echo "=== Step 11: ArgoCD login + SSH host key + repo server restart ==="
    step11_needed || { host_skip "ArgoCD already logged in"; return 0; }
    local ip_clean="${IP%/*}"
    local gitea_host="${GITEA_REPO_URL#ssh://git@}"
    gitea_host="${gitea_host%%/*}"
    local gitea_port="${gitea_host##*:}"
    [ "$gitea_host" = "$gitea_port" ] && gitea_port=22
    local pass
    pass=$(pct_exec kubectl get secret argocd-initial-admin-secret \
        -n argocd -o jsonpath="{.data.password}" 2>/dev/null || echo "")
    if [ -z "$pass" ]; then
        host_info "argocd initial admin secret not found – may have been changed"
        host_info "Please run manually: argocd login $ip_clean:$ARGOCD_NODEPORT --name root"
        return 0
    fi
    pct_exec_stdin <<SCRIPT
. /etc/profile
set -x
export ARGOCD_OPTS="--grpc-web"
argocd login $ip_clean:$ARGOCD_NODEPORT --name root --username admin \
    --password $(printf '%s' "$pass" | base64 -d) --insecure
ssh-keyscan -p $gitea_port '${gitea_host%:*}' 2>/dev/null | argocd cert add-ssh --batch --upsert
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=60s
SCRIPT
    host_ok "ArgoCD login + certificate + repo server done"
}

step12() {
    echo "=== Step 12: Connect repository in ArgoCD ==="
    step12_needed || { host_skip "Repository $GITEA_REPO_URL already connected"; return 0; }
    pct_exec_stdin <<SCRIPT
. /etc/profile
set -x
export ARGOCD_OPTS="--grpc-web"
argocd repo add $GITEA_REPO_URL --ssh-private-key-path /root/.ssh/argocd
SCRIPT
    host_ok "Repository $GITEA_REPO_URL connected"
}

step13() {
    echo "=== Step 13: Create Root App in ArgoCD ==="
    step13_needed || { host_skip "Root App already exists"; return 0; }
    pct_exec_stdin <<SCRIPT
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $GITEA_REPO_URL
    path: argocd/$CLUSTER_NAME
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
SCRIPT
    host_ok "Root App created – ArgoCD starts auto-deploy"
}

# ── Main ──────────────────────────────────────────────────────────

echo "=== Provisioning: $HOSTNAME (VMID $VMID, $IP) ==="

[ "$STEP" -le 0 ] && step0
[ "$STEP" -le 1 ] && step1
[ "$STEP" -le 2 ] && step2
[ "$STEP" -le 3 ] && step3
[ "$STEP" -le 4 ] && step4
[ "$STEP" -le 5 ] && step5
[ "$STEP" -le 6 ] && step6
[ "$STEP" -le 7 ] && step7
[ "$STEP" -le 8 ] && step8
[ "$STEP" -le 10 ] && step10
[ "$STEP" -le 11 ] && step11
[ "$STEP" -le 12 ] && step12
[ "$STEP" -le 13 ] && step13

echo ""
echo "=== Provisioning complete ==="
echo "  Cluster: $HOSTNAME"
echo "  IP:      $IP"
echo "  ArgoCD:  https://${IP%/*}:$ARGOCD_NODEPORT"
echo "  Root App will sync automatically (ArgoCD)"
