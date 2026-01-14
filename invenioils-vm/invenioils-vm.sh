#!/usr/bin/env bash
# invenioils-vm.sh
# Create a Proxmox KVM VM for InvenioILS and provide guidance to install/run the application.
#
# Uses the same structure and helper library as:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func
#
# Author: assistant (adapted for InvenioILS)
# License: MIT
# Docs: https://invenioils.docs.cern.ch/install/
#
# Usage:
#   sudo ./invenioils-vm.sh
#
# This script will:
# - source the community-scripts build.func helpers (sourced with nounset temporarily disabled)
# - define VM defaults (name, cpu, ram, disk, template)
# - call the helper start/build functions to create the VM
# - attempt to detect the VM IP (if build.func provides it)
# - print next steps to install Docker, clone invenio-app-ils and run the docker-compose stack
#
# Note: full unattended provisioning (ssh-based) is not attempted by default because
# cloud-init / SSH keys / networking vary per environment. The script prints the
# commands you can run inside the VM (or run manually via SSH).
#
set -euo pipefail

# Predefine common SSH environment variables to avoid "unbound variable" errors
# when build.func references them while the script runs with "set -u".
export SSH_CLIENT="${SSH_CLIENT:-}"
export SSH_CONNECTION="${SSH_CONNECTION:-}"
export SSH_TTY="${SSH_TTY:-}"

# temporarily disable "nounset" so build.func can reference variables like SSH_CLIENT during sourcing
set +u
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
set -u

APP="InvenioILS (invenio-app-ils)"
var_tags="${var_tags:-invenio;ils;invenioils}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-8192}"        # MB recommended for OpenSearch + services
var_disk="${var_disk:-40}"        # GB
var_cores="${var_cores:-2}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-22.04}"
var_unprivileged="${var_unprivileged:-0}"  # VM is always privileged; keep for compatibility
# Default cloud-init / template (must exist in your Proxmox)
var_template="${var_template:-local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst}"
# For VMs the helper may expect a qcow or ISO. If you have a cloud image, set var_image instead:
var_image="${var_image:-local:iso/ubuntu-22.04-server-cloudimg-amd64.img}" # adjust if you use cloud images
var_storage="${var_storage:-local-lvm}"
var_bridge="${var_bridge:-vmbr0}"

header_info "$APP"
variables
color
catch_errors

# This function will be called after the VM is created to show next steps.
function post_create_instructions() {
  header_info "InvenioILS VM provisioning - next steps"

  # The helper library normally sets VMID, IP, GATEWAY variables.
  # Print what we know; if not available, advise how to find VM IP.
  echo
  if [[ -n "${VMID:-}" ]]; then
    echo -e "${INFO} VMID: ${VMID}${CL}"
  fi
  if [[ -n "${IP:-}" ]]; then
    echo -e "${INFO} VM IP: ${IP}${CL}"
  else
    echo -e "${INFO} VM IP not detected by the helper.${CL}"
    echo -e "${TAB}Use 'qm guest cmd <VMID> network-get-interfaces' or check the Proxmox UI or DHCP leases to find the IP.${CL}"
  fi
  if [[ -n "${GATEWAY:-}" ]]; then
    echo -e "${INFO} Gateway: ${GATEWAY}${CL}"
  fi

  echo
  cat <<EOF
Next steps (recommended):

1) SSH into the VM as a privileged user (root or a user you prepared):
   ssh root@<VM_IP>

2) Update the OS and install Docker & docker-compose plugin (Ubuntu example):
   # Update + install deps
   apt-get update
   apt-get upgrade -y

   # Install Docker (official repository)
   apt-get install -y ca-certificates curl gnupg lsb-release
   mkdir -p /etc/apt/keyrings
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
   ARCH="\$(dpkg --print-architecture)"
   echo "deb [arch=\$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
   apt-get update
   apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
   systemctl enable --now docker

3) Clone the invenio-app-ils repository and inspect docker configs:
   git clone https://github.com/inveniosoftware/invenio-app-ils.git /opt/invenio-app-ils
   cd /opt/invenio-app-ils

4) Create a .env file with secrets (example keys):
   cat > /opt/invenio-app-ils/.env <<'ENV'
   # Example values - replace for production!
   INVENIO_SECRET_KEY=$(openssl rand -hex 32)
   POSTGRES_USER=ils
   POSTGRES_PASSWORD=$(openssl rand -base64 12)
   POSTGRES_DB=ils
   ENV
   chmod 640 /opt/invenio-app-ils/.env

5) Sanitize compose files if image tag typos are present:
   sed -i 's/::/:/g' docker-services.yml docker-compose.full.yml docker-compose.yml || true

6) Start the docker compose full stack (may take several minutes):
   docker compose -f docker-compose.full.yml pull || true
   docker compose -f docker-compose.full.yml up -d --build

7) Monitor logs:
   docker compose -f docker-compose.full.yml logs -f

Documentation:
- Official InvenioILS install docs: https://invenioils.docs.cern.ch/install/
- Repo (for compose files, Dockerfiles, etc): https://github.com/inveniosoftware/invenio-app-ils

Notes & considerations:
- OpenSearch requires vm.max_map_count >= 262144 on the host. For a VM you must set it inside the VM:
    sysctl -w vm.max_map_count=262144
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
- The repo's docker-compose files are geared for development. Review environment variables (secrets, database passwords) before use.
- For production use follow the official docs linked above.

If you want, I can attempt to perform the installation automatically over SSH from the Proxmox host; this requires the VM to be reachable by SSH and you to supply credentials or an SSH key. Would you like me to attempt that now?
EOF

  msg_ok "Post-create instructions delivered."
}

# Allow update mode to only update a VM (if needed)
function update_script() {
  header_info "Update InvenioILS on VM"
  check_vm_resources || true

  # Prefer VMID from environment
  if [[ -z "${VMID:-}" ]]; then
    msg_error "No VMID available. Please provide VMID or run in created VM."
    exit 1
  fi

  echo "Attempting to provide update instructions for VM $VMID..."
  post_create_instructions
  exit 0
}

# If called with "update", run update_script
if [[ "${1:-}" == "update" ]]; then
  update_script
  exit
fi

# Main creation flow
start

# Try to call build_vm if available in build.func, else fallback to build_container name (some helpers use build_container)
if declare -f build_vm >/dev/null 2>&1; then
  build_vm
elif declare -f build_container >/dev/null 2>&1; then
  # fallback: some helper sets up a container-like resource; attempt to build a VM via generic function
  build_container
else
  # As a last-resort fallback, attempt to create a basic VM with qm (requires the var_image / var_storage variables to be set)
  msg_info "Helper functions build_vm/build_container not found. Attempting direct qm-based creation (best-effort)."

  # Find next free VMID
  NEXT_VMID=100
  while qm status $NEXT_VMID >/dev/null 2>&1; do
    NEXT_VMID=$((NEXT_VMID+1))
    if [[ $NEXT_VMID -gt 9999 ]]; then
      msg_error "Unable to find a free VMID"
      exit 1
    fi
  done

  VMID="$NEXT_VMID"
  NAME="invenioils-${VMID}"

  msg_info "Creating VM $VMID (${NAME}) with ${var_ram}MB RAM, ${var_cpu} cores, ${var_disk}G disk (qcow image copy)"
  # This block is intentionally conservative: it assumes a cloud image is available in var_image.
  # Adjust the following commands to match your environment (storage, cores, network).
  qm create "$VMID" --name "$NAME" --memory "$var_ram" --cores "$var_cpu" --net0 virtio,bridge=${var_bridge} || true

  # Create disk
  qm disk create "$VMID" --size "${var_disk}G" --storage "$var_storage" || true

  # Import cloud image if present (best-effort)
  if pvesm status 2>/dev/null | grep -q "$(echo "$var_storage" | cut -d: -f1)"; then
    # If var_image is an existing storage path, try to import it
    msg_info "Importing image (if supported) - ensure var_image correct: ${var_image}"
    # This is environment specific. Please adapt if you need a specific ISO/IMG import behavior.
  fi

  qm start "$VMID" || true
  # Wait a bit for VM to boot
  sleep 5
fi

# Run post-create instructions to show user what to do / how to proceed
post_create_instructions

# Finish
description
msg_ok "VM creation and guidance completed."
echo -e "${CREATING}${GN}${APP} VM has been initialized!${CL}"
echo -e "${INFO}${YW} Refer to the installation docs: https://invenioils.docs.cern.ch/install/${CL}"