#!/bin/bash
set -e

# Bash script to create a Kubernetes VM in Proxmox VE with cloud-init
# Kubernetes 1.36 - Ubuntu 26.04 LTS - Single Node Cluster

# Configuration
# ===========================================

# Check if config file exists
if [ -z "$1" ]; then
    echo "ERROR: No config file specified!"
    echo "Usage: $0 <config-file>"
    echo "Available configs: default.conf, default-argocd.conf, default-fast.conf, debug.conf"
    exit 1
fi

CONFIG="$1"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file $CONFIG not found!"
    echo "Available configs: default.conf, default-argocd.conf, default-fast.conf, debug.conf"
    exit 1
fi

# Load configuration
echo "Loading configuration from $CONFIG..."
source "$CONFIG"

# Validate required variables
REQUIRED_VARS="VMID VM_NAME MEMORY CORES CPU STORAGE DISK_SIZE CLOUD_IMAGE_URL CLOUD_IMAGE_PATH SSH_KEY_PATH IP_ADDRESS GATEWAY DNS_SERVER POD_NETWORK_CIDR"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        echo "ERROR: Required variable $var not set in config file!"
        exit 1
    fi
done

# Set defaults for optional variables
K8S_VERSION="${K8S_VERSION:-1.36}"
PACKAGE_UPGRADE="${PACKAGE_UPGRADE:-true}"
case "$PACKAGE_UPGRADE" in
    true|false) ;;
    *) echo "ERROR: PACKAGE_UPGRADE must be 'true' or 'false'!"; exit 1 ;;
esac
CLOUD_INIT_TEMPLATE="${CLOUD_INIT_TEMPLATE:-k8s-cloud-init.yaml}"
K8S_CONVENIENCE="${K8S_CONVENIENCE:-false}"
case "$K8S_CONVENIENCE" in
    true|false) ;;
    *) echo "ERROR: K8S_CONVENIENCE must be 'true' or 'false'!"; exit 1 ;;
esac

PROVISION_STATUS="${PROVISION_STATUS:-false}"
case "$PROVISION_STATUS" in
    true|false) ;;
    *) echo "ERROR: PROVISION_STATUS must be 'true' or 'false'!"; exit 1 ;;
esac
PROVISION_ROLE="${PROVISION_ROLE:-k8s-vm}"

# ArgoCD bootstrap (GitOps) defaults
ARGOCD_ENABLED="${ARGOCD_ENABLED:-false}"
case "$ARGOCD_ENABLED" in
    true|false) ;;
    *) echo "ERROR: ARGOCD_ENABLED must be 'true' or 'false'!"; exit 1 ;;
esac
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.11.6}"
ARGOCD_NODEPORT="${ARGOCD_NODEPORT:-30444}"
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-}"
ARGOCD_REPO_KEY="${ARGOCD_REPO_KEY:-}"
ARGOCD_ROOT_APP_PATH="${ARGOCD_ROOT_APP_PATH:-argocd/k8s-lain}"
ARGOCD_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-main}"

GATEWAY_ENABLED="${GATEWAY_ENABLED:-false}"
case "$GATEWAY_ENABLED" in
    true|false) ;;
    *) echo "ERROR: GATEWAY_ENABLED must be 'true' or 'false'!"; exit 1 ;;
esac
if [ "$GATEWAY_ENABLED" = "true" ]; then
    ARGOCD_DIRECTORY_EXCLUDE="__none__"
else
    ARGOCD_DIRECTORY_EXCLUDE="gateway/*"
fi

ARGOCD_REPO_KEY_B64=""
ARGOCD_REPO_HOST=""
ARGOCD_REPO_PORT=22
if [ "$ARGOCD_ENABLED" = "true" ]; then
    [ -n "$ARGOCD_REPO_URL" ] || { echo "ERROR: ARGOCD_REPO_URL is empty!"; exit 1; }
    case "$ARGOCD_REPO_URL" in
        ssh://*)
            ARGOCD_REPO_KEY="${ARGOCD_REPO_KEY:-/root/.ssh/argocd}"
            [ -f "$ARGOCD_REPO_KEY" ] || {
                echo "ERROR: ArgoCD repo key $ARGOCD_REPO_KEY not found!"
                echo "Create one with: ssh-keygen -t ed25519 -f $ARGOCD_REPO_KEY -N '' -C 'argocd@$VM_NAME'"
                echo "and add ${ARGOCD_REPO_KEY}.pub as a read-only deploy key in your Git server."
                exit 1
            }
            ARGOCD_REPO_KEY_B64="$(base64 -w0 "$ARGOCD_REPO_KEY")"
            ARGOCD_REPO_HOST="$(printf '%s' "$ARGOCD_REPO_URL" | sed -E 's#^[a-z]+://[^@]+@([^/:]+).*#\1#')"
            ARGOCD_REPO_PORT="$(printf '%s' "$ARGOCD_REPO_URL" | sed -nE 's#^[a-z]+://[^@]+@[^/:]+:([0-9]+)/.*#\1#p')"
            [ -n "$ARGOCD_REPO_PORT" ] || ARGOCD_REPO_PORT=22
            ;;
        https://*)
            # Public HTTPS repository: anonymous read, no deploy key
            ARGOCD_REPO_KEY=""
            ARGOCD_REPO_KEY_B64=""
            ARGOCD_REPO_HOST=""
            ARGOCD_REPO_PORT=22
            ;;
        *)
            echo "ERROR: ARGOCD_REPO_URL must start with ssh:// or https://"
            exit 1
            ;;
    esac
fi

# Provisioning metadata injected into the VM (/var/lib/provisioning/start.env)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_FILE="$(basename "$0")"
SCRIPT_SHA256="$(sha256sum "$0" | awk '{print $1}')"
CONF_FILE="$(basename "$CONFIG")"
CONF_SHA256="$(sha256sum "$CONFIG" 2>/dev/null | awk '{print $1}')"
TEMPLATE_FILE="$(basename "$CLOUD_INIT_TEMPLATE")"
TEMPLATE_SHA256="$(sha256sum "$CLOUD_INIT_TEMPLATE" 2>/dev/null | awk '{print $1}')"
PROVISION_START="$(date -u -Is)"
PROVISION_START_EPOCH="$(date +%s)"

if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REPO_NAME="$(basename "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)")"
    GIT_BRANCH="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)"
    GIT_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)"
    GIT_COMMIT_DATE="$(git -C "$SCRIPT_DIR" show -s --format=%cI HEAD)"
    if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain -- .)" ]; then
        GIT_DIRTY="yes"
    else
        GIT_DIRTY="no"
    fi
else
    echo "NOTE: no git repository at $SCRIPT_DIR - branch/commit will be 'unknown'"
    REPO_NAME="unknown"; GIT_BRANCH="unknown"; GIT_COMMIT="unknown"
    GIT_COMMIT_DATE="unknown"; GIT_DIRTY="unknown"
fi

# # Read ALL SSH keys (filter out comments and empty lines, keep newlines for YAML list)
# # Cloud-init expects a list of keys, one per line
# # The keys must start with "  - " to be valid YAML list items
# # Remove inline comments (everything after the key type) to avoid YAML parsing issues
# SSH_KEY_YAML=$(grep -v '^#' $SSH_KEY_PATH | grep -v '^$' | sed 's/ #.*//;s/^[[:space:]]*//' | sed 's/^/  - /')

# Download cloud image if not present
echo "download OS image of not exist (no deletion or overwriting)"
if [ ! -f "$CLOUD_IMAGE_PATH" ]; then
    wget -O "$CLOUD_IMAGE_PATH" "$CLOUD_IMAGE_URL" || exit 1
fi

# Create VM
echo "Creating VM $VM_NAME (ID: $VMID)..."
qm create $VMID \
  --name $VM_NAME \
  --memory $MEMORY \
  --cores $CORES \
  --cpu $CPU \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --agent enabled=1 \
  --ostype l26

# Import cloud image
echo "Importing cloud image..."
qm disk import $VMID $CLOUD_IMAGE_PATH $STORAGE



# ## Version 1 STATIC works for ZFS not NOT for LOCAL storage
# ##qm set $VMID  --scsi0 $STORAGE:$VMID/vm-$VMID-disk-0.raw --boot order=scsi0
# echo OLD1: qm set $VMID  --scsi0 $STORAGE:$VMID/vm-$VMID-disk-0.raw --boot order=scsi0

# # Version 2 - works for LOCAL but NOT for ZFS storage
# DISK_ID=$(qm config $VMID | grep "unused0" | awk -F"'" '{print $2}' | awk -F: '{print $2}')
# # echo "Configuring disk: $STORAGE:$DISK_ID"
# # qm set $VMID --scsi0 "$STORAGE:$DISK_ID" --boot order=scsi0
# echo OLD2: qm set $VMID --scsi0 "$STORAGE:$DISK_ID" --boot order=scsi0


# # Version 3 - Extract disk path from import output (works for all storage types)
# DISK_PATH=$(qm config $VMID | grep "unused0" | awk -F"'" '{print $2}')

# Configure disk
#qm set $VMID --scsi0 "$STORAGE:vm-$VMID-disk-0" --boot order=scsi0  # Old way - only works for LVM
echo OLD3: qm set $VMID --scsi0 "$DISK_PATH" --boot order=scsi0  # New way - works for all storage types

# Version 4 try catch except both Versions
echo ""
echo "NEW4:"
echo DISK_PATH:
echo qm config $VMID | grep "unused0" | awk '{print $2}'
qm config $VMID | grep "unused0" | awk '{print $2}'
DISK_PATH=$(qm config $VMID | grep "unused0" | awk '{print $2}')

echo DISK_PATH: $DISK_PATH:

if [ -n "$DISK_PATH" ]; then
    echo "DISK_PATH not empty - version 41:"
    echo qm set $VMID --scsi0 "$DISK_PATH" --boot order=scsi0
    qm set $VMID --scsi0 "$DISK_PATH" --boot order=scsi0
else
    echo "DISK_PATH empty - version 42:"
    echo qm set $VMID --scsi0 "$STORAGE:vm-$VMID-disk-0" --boot order=scsi0
    qm set $VMID --scsi0 "$STORAGE:vm-$VMID-disk-0" --boot order=scsi0
fi
# qm set $VMID --scsi0 "$DISK_PATH" --boot order=scsi0

# Add cloud-init drive
qm set $VMID \
  --ide2 $STORAGE:cloudinit

# Configure serial console
qm set $VMID \
  --serial0 socket \
  --vga serial0

# Resize disk
qm resize $VMID scsi0 $DISK_SIZE

# Use existing cloud-init YAML file
CLOUD_INIT_SNIPPET_DIR="/var/lib/vz/snippets"
CLOUD_INIT_SNIPPET_PATH="$CLOUD_INIT_SNIPPET_DIR/$CLOUD_INIT_TEMPLATE"

# Check if file exists locally
if [ ! -f "$CLOUD_INIT_TEMPLATE" ]; then
    echo "ERROR: Cloud-init file $CLOUD_INIT_TEMPLATE not found in current directory!"
    echo "Please ensure the file exists next to the script."
    exit 1
fi

# Ensure snippet directory exists
if [ ! -d "$CLOUD_INIT_SNIPPET_DIR" ]; then
    mkdir -p $CLOUD_INIT_SNIPPET_DIR
fi

# Copy and substitute variables directly
echo "Processing cloud-init template..."
# Use a temp file to handle variable substitution
TEMP_FILE=$(mktemp)
cp "$CLOUD_INIT_TEMPLATE" "$TEMP_FILE"

# Escape sed replacement characters (&, |, \)
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Replace variables
sed -i \
    -e "s|\${VM_NAME}|$VM_NAME|g" \
    -e "s|\${IP_ADDRESS%/*}|${IP_ADDRESS%/*}|g" \
    -e "s|\${POD_NETWORK_CIDR}|$POD_NETWORK_CIDR|g" \
    -e "s|\${K8S_VERSION}|$K8S_VERSION|g" \
    -e "s|\${PACKAGE_UPGRADE}|$PACKAGE_UPGRADE|g" \
    -e "s|\${K8S_CONVENIENCE}|$K8S_CONVENIENCE|g" \
    -e "s|\${ARGOCD_ENABLED}|$(sed_escape "$ARGOCD_ENABLED")|g" \
    -e "s|\${ARGOCD_CHART_VERSION}|$(sed_escape "$ARGOCD_CHART_VERSION")|g" \
    -e "s|\${ARGOCD_NODEPORT}|$(sed_escape "$ARGOCD_NODEPORT")|g" \
    -e "s|\${ARGOCD_REPO_URL}|$(sed_escape "$ARGOCD_REPO_URL")|g" \
    -e "s|\${ARGOCD_REPO_KEY_B64}|$(sed_escape "$ARGOCD_REPO_KEY_B64")|g" \
    -e "s|\${ARGOCD_REPO_HOST}|$(sed_escape "$ARGOCD_REPO_HOST")|g" \
    -e "s|\${ARGOCD_REPO_PORT}|$(sed_escape "$ARGOCD_REPO_PORT")|g" \
    -e "s|\${ARGOCD_ROOT_APP_PATH}|$(sed_escape "$ARGOCD_ROOT_APP_PATH")|g" \
    -e "s|\${ARGOCD_TARGET_REVISION}|$(sed_escape "$ARGOCD_TARGET_REVISION")|g" \
    -e "s|\${ARGOCD_DIRECTORY_EXCLUDE}|$(sed_escape "$ARGOCD_DIRECTORY_EXCLUDE")|g" \
    -e "s|\${PROVISION_STATUS}|$(sed_escape "$PROVISION_STATUS")|g" \
    -e "s|\${PROVISION_ROLE}|$(sed_escape "$PROVISION_ROLE")|g" \
    -e "s|\${REPO_NAME}|$(sed_escape "$REPO_NAME")|g" \
    -e "s|\${GIT_BRANCH}|$(sed_escape "$GIT_BRANCH")|g" \
    -e "s|\${GIT_COMMIT}|$(sed_escape "$GIT_COMMIT")|g" \
    -e "s|\${GIT_COMMIT_DATE}|$(sed_escape "$GIT_COMMIT_DATE")|g" \
    -e "s|\${GIT_DIRTY}|$(sed_escape "$GIT_DIRTY")|g" \
    -e "s|\${PROVISION_START}|$(sed_escape "$PROVISION_START")|g" \
    -e "s|\${PROVISION_START_EPOCH}|$(sed_escape "$PROVISION_START_EPOCH")|g" \
    -e "s|\${SCRIPT_FILE}|$(sed_escape "$SCRIPT_FILE")|g" \
    -e "s|\${SCRIPT_SHA256}|$(sed_escape "$SCRIPT_SHA256")|g" \
    -e "s|\${CONF_FILE}|$(sed_escape "$CONF_FILE")|g" \
    -e "s|\${CONF_SHA256}|$(sed_escape "$CONF_SHA256")|g" \
    -e "s|\${TEMPLATE_FILE}|$(sed_escape "$TEMPLATE_FILE")|g" \
    -e "s|\${TEMPLATE_SHA256}|$(sed_escape "$TEMPLATE_SHA256")|g" \
    "$TEMP_FILE"

cp "$TEMP_FILE" "$CLOUD_INIT_SNIPPET_PATH"
rm "$TEMP_FILE"

# Apply cloud-init configuration as vendor-data (augments generated user-data)
# NOTE: We use vendor= instead of user= because:
# - user= REPLACES the generated user-data completely
# - vendor= AUGMENTS the generated user-data (adds our custom config)
# - This way SSH keys from --sshkeys are preserved!
echo qm set $VMID --cicustom "vendor=local:snippets/$CLOUD_INIT_TEMPLATE"
qm set $VMID --cicustom "vendor=local:snippets/$CLOUD_INIT_TEMPLATE"

# Set SSH keys separately (Proxmox generates the correct user-data for this)
# This is the correct way to set SSH keys with cloud-init
# We need to create a clean file without comments for Proxmox
echo "Preparing SSH keys..."
CLEAN_SSH_KEYS=$(mktemp)
grep -v '^#' "$SSH_KEY_PATH" | grep -v '^$' | sed 's/ #.*//' > "$CLEAN_SSH_KEYS"
echo qm set $VMID --sshkeys "$CLEAN_SSH_KEYS"
qm set $VMID --sshkeys "$CLEAN_SSH_KEYS"
rm "$CLEAN_SSH_KEYS"

# Set IP configuration for cloud-init
echo qm set $VMID --ipconfig0 "ip=$IP_ADDRESS,gw=$GATEWAY"
qm set $VMID --ipconfig0 "ip=$IP_ADDRESS,gw=$GATEWAY"
echo qm set $VMID --nameserver "$DNS_SERVER"
qm set $VMID --nameserver "$DNS_SERVER"

# Set cloud-init user (default is ubuntu, can be overridden in config)
# If CIUSER is set in config, use it, otherwise don't set it (let Proxmox use default)
if [ -n "${CIUSER:-}" ]; then
    echo qm set $VMID --ciuser "$CIUSER"
    qm set $VMID --ciuser "$CIUSER"
fi

# Optional: Disable automatic package upgrade
if [ "${CIUPGRADE:-1}" = "0" ]; then
    echo qm set $VMID --ciupgrade 0
    qm set $VMID --ciupgrade 0
fi

# Start VM
qm start $VMID

echo "=========================================="
echo "Kubernetes VM created successfully!"
echo "=========================================="
echo "VM Name: $VM_NAME"
echo "VM ID: $VMID"
echo "IP Address: $IP_ADDRESS"
echo "Memory: $MEMORY MB"
echo "CPU Cores: $CORES"
echo "Kubernetes Version: $K8S_VERSION"
echo ""
echo "Next steps:"
echo "1. Wait for cloud-init to complete (10-15 minutes)"
echo "2. Monitor progress: qm terminal $VMID"
echo "3. SSH into VM: ssh root@${IP_ADDRESS%/*}"
echo "4. Check cloud-init status: cloud-init status"
echo "5. Check cluster: kubectl get nodes"
echo ""
echo "DNS Test Command (run after cluster is ready):"
echo "kubectl run nettest --image=wbitt/network-multitool --rm -it --restart=Never -- bash -c 'dig api.cheapestinference.com && curl -v --connect-timeout 10 https://api.cheapestinference.com/v1/models && echo DONE'"
echo ""
echo "Cloud-init logs: /var/log/cloud-init-output.log"
echo "Kubeconfig: /root/.kube/config"
echo ""
echo "Debug cloud-init config:"
echo "  qm cloudinit dump $VMID user"
echo "  qm cloudinit dump $VMID network"