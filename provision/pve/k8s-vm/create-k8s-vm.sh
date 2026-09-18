#!/bin/bash
set -e

# Bash script to create a Kubernetes VM in Proxmox VE with cloud-init
# Kubernetes 1.37 - Ubuntu 26.04 LTS - Single Node Cluster

# Configuration
# ===========================================

# Check if config file exists
if [ -z "$1" ]; then
    echo "ERROR: No config file specified!"
    echo "Usage: $0 <config-file>"
    echo "Available configs: default.conf, lain.conf, debug.conf"
    exit 1
fi

CONFIG="$1"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file $CONFIG not found!"
    echo "Available configs: default.conf, lain.conf, debug.conf"
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
K8S_VERSION="${K8S_VERSION:-1.37}"
CLOUD_INIT_TEMPLATE="${CLOUD_INIT_TEMPLATE:-k8s-cloud-init.yaml}"

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

# Replace variables
sed -i \
    -e "s|\${VM_NAME}|$VM_NAME|g" \
    -e "s|\${IP_ADDRESS%/*}|${IP_ADDRESS%/*}|g" \
    -e "s|\${POD_NETWORK_CIDR}|$POD_NETWORK_CIDR|g" \
    -e "s|\${K8S_VERSION}|$K8S_VERSION|g" \
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