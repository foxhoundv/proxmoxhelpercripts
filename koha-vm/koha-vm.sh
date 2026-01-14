#!/usr/bin/env bash
#
# koha-vm.sh
#
# Helper to create a Debian 12 (Bookworm) VM on a Proxmox host and install Koha (MariaDB backend).
# This script follows the style/formation of:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func
#
# Behavior overview:
#  - Downloads and sources the referenced api.func (if available) for helper functions.
#  - Creates a new VM using qm with sensible defaults (prompts for values).
#  - Configures cloud-init on the VM so you can set an SSH password or inject an SSH key.
#  - Starts the VM and optionally waits for you to provide the VM IP.
#  - Copies and runs an installer script on the VM to install Koha on Debian 12 with MariaDB.
#
# Requirements (on the Proxmox host):
#  - Run this script as root on the Proxmox host.
#  - 'qm' CLI available (Proxmox VE).
#  - 'ssh' and 'scp' available.
#  - Network/DHCP in place for the VM so you can reach it by IP.
#
# Notes:
#  - The script will prompt for any passwords (VM cloud-init password, MariaDB Koha user password,
#    and Koha SYSTEM/admin password).
#  - The script does not attempt to fully automate obtaining the VM IP from the Proxmox guest agent.
#    You can either:
#      * Provide the IP when prompted (recommended), or
#      * Install the guest agent and enter the IP later.
#
set -euo pipefail
PROGNAME="$(basename "$0")"
API_FUNC_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---- Basic logging and helper functions (keeps same formation style) ----
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

prompt() {
  # prompt <varname> <prompt text> [default]
  local __var="$1"; shift
  local text="$1"; shift
  local default="${1:-}"
  local reply
  if [[ -n "$default" ]]; then
    read -rp "$text [$default]: " reply
    reply="${reply:-$default}"
  else
    read -rp "$text: " reply
  fi
  printf -v "$__var" '%s' "$reply"
}

prompt_password() {
  # prompt_password <varname> <prompt text>
  local __var="$1"; shift
  local text="$1"; shift
  local pw pw2
  while true; do
    read -rs -p "$text: " pw; echo
    read -rs -p "Confirm $text: " pw2; echo
    if [[ "$pw" == "$pw2" ]]; then
      printf -v "$__var" '%s' "$pw"
      break
    else
      warn "Passwords do not match, try again."
    fi
  done
}

# ---- Try to download and source api.func (best-effort) ----
info "Attempting to download helper functions from api.func..."
if command -v curl >/dev/null 2>&1; then
  if curl -fsSL "$API_FUNC_URL" -o "$TMP_DIR/api.func"; then
    # shellcheck disable=SC1090
    source "$TMP_DIR/api.func" || warn "Sourcing downloaded api.func failed; continuing with local helpers."
    ok "Downloaded and sourced api.func successfully."
  else
    warn "Could not download api.func; continuing with local helpers."
  fi
else
  warn "curl not found; skipping download of api.func."
fi

# ---- Verify running as root ----
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root on the Proxmox host."
fi

# ---- Collect VM creation parameters (with sensible defaults) ----
DEFAULT_NODE="$(pvesh get /nodes 2>/dev/null | head -n1 | awk '{print $1}' || true)"
# If pvesh isn't present or didn't return a node, default to 'pve'
if [[ -z "$DEFAULT_NODE" ]]; then DEFAULT_NODE="pve"; fi

prompt VM_NODE "Proxmox node to create VM on" "$DEFAULT_NODE"
prompt VM_ID "VMID (numeric, unique) e.g. 9001" ""
if [[ -z "$VM_ID" ]]; then die "VMID is required."; fi
prompt VM_NAME "VM name" "koha-${VM_ID}"
prompt VM_CORES "Cores" "2"
prompt VM_MEM "Memory (MB)" "2048"
prompt VM_DISK "Disk size (GB)" "32"
prompt VM_STORAGE "Storage (Proxmox storage id) to place disk and cloud-init (e.g. local-lvm)" "local-lvm"
prompt VM_BRIDGE "Bridge for VM networking (e.g. vmbr0)" "vmbr0"

# Debian 12 ISO or cloud image path on storage. You may pre-upload an ISO to local storage,
# or use a local Debian 12 cloud image and create a cloud-init enabled VM.
info "Please provide the path to a Debian 12 (Bookworm) ISO or cloud image available to Proxmox."
info "Common ISO path example: local:iso/debian-bookworm-NN.iso"
prompt VM_ISO "ISO or image (leave blank to skip ISO attach and assume you'll install OS manually later)" ""

# cloud-init user and password
prompt CI_USER "Cloud-init user to create on the VM" "debian"
prompt_password CI_PASS "Cloud-init password for the VM user (will be set as root_password if using root)"

# optional SSH public key
read -rp "Optional: path to an SSH public key to inject into cloud-init (leave blank to skip): " SSH_PUBKEY_PATH
SSH_PUBKEY_CONTENT=""
if [[ -n "$SSH_PUBKEY_PATH" && -f "$SSH_PUBKEY_PATH" ]]; then
  SSH_PUBKEY_CONTENT="$(<"$SSH_PUBKEY_PATH")"
fi

# Koha database and admin passwords (will be prompted later if not supplied now)
prompt KOHA_SITE "Koha site identifier (e.g. library)" "library"
prompt_password KOHA_DB_PASSWORD "MariaDB Koha DB password (for 'koha' user)"
prompt_password KOHA_ADMIN_PASSWORD "Koha SYSTEM (admin) password"

# ---- Create the VM with qm ----
info "Creating VM ${VM_ID} on node ${VM_NODE}..."

# Build qm create command
# We'll create a VM with virtio-scsi, cloud-init drive and a scsi disk for OS.
# Many Proxmox setups use 'scsi0' with local-lvm; adjust storage names as needed.
QM_CMD=(qm create "$VM_ID" --name "$VM_NAME" --cores "$VM_CORES" --memory "$VM_MEM" --net0 "virtio,bridge=${VM_BRIDGE}" --scsihw virtio-scsi-pci)

# Add boot disk
# Proxmox expects disk definitions like <storage>:<size> or <storage>:vm-${VMID}-disk-0
QM_CMD+=("--scsi0" "${VM_STORAGE}:$((VM_DISK))G")

# Add cloud-init drive
QM_CMD+=("--ide2" "${VM_STORAGE}:cloudinit")
# Use serial for console
QM_CMD+=("--serial0" "socket" "--vmgenid" "1" "--boot" "order=scsi0")
info "Running: ${QM_CMD[*]}"
if ! "${QM_CMD[@]}"; then
  die "qm create failed."
fi
ok "VM ${VM_ID} created."

# If ISO provided, set it as cdrom
if [[ -n "$VM_ISO" ]]; then
  info "Setting CD-ROM to $VM_ISO"
  qm set "$VM_ID" --cdrom "$VM_ISO"
fi

# Configure cloud-init user/password and sshkey
info "Configuring cloud-init for VM..."
qm set "$VM_ID" --ciuser "$CI_USER" --cipassword "$CI_PASS"
if [[ -n "$SSH_PUBKEY_CONTENT" ]]; then
  tmpkey="$TMP_DIR/id_pubkey"
  printf '%s\n' "$SSH_PUBKEY_CONTENT" > "$tmpkey"
  qm set "$VM_ID" --sshkey "$tmpkey"
fi

# Enable agent (guest agent useful later)
qm set "$VM_ID" --agent 1

# Start VM
info "Starting VM ${VM_ID}..."
qm start "$VM_ID"

ok "VM ${VM_ID} started."

# ---- Wait for the VM to be reachable / or get IP from user ----
info "Next we need the VM's IP address so we can SSH into it and run the Koha installer."
info "If you have a DHCP server / console, obtain the IP now. Optionally you can install the OS manually."
read -rp "Enter VM IP address (or leave empty to skip remote install): " VM_IP

if [[ -z "$VM_IP" ]]; then
  warn "No VM IP provided. The script created the VM and set cloud-init. To finish the Koha install:"
  cat <<EOF

  1) Install Debian 12 on the VM (or boot cloud image which will create user '${CI_USER}').
  2) Make sure SSH is enabled and you can SSH as '${CI_USER}' (or root).
  3) Then run the included Koha installer script manually on the VM, or re-run this script and provide the VM IP.

EOF
  exit 0
fi

# SSH connection info
prompt SSH_USER "SSH user to connect as" "$CI_USER"
read -rp "SSH auth method: 1) password  2) key (enter 1 or 2) [1]: " SSH_METHOD
SSH_METHOD="${SSH_METHOD:-1}"
if [[ "$SSH_METHOD" == "1" ]]; then
  prompt_password SSH_PASS "SSH password for $SSH_USER@$VM_IP"
  SSH_AUTH="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  SCP_AUTH="$SSH_AUTH"
  SSH_AUTH_TYPE="password"
else
  read -rp "Path to private key file for SSH: " SSH_KEY_PATH
  if [[ ! -f "$SSH_KEY_PATH" ]]; then die "SSH key not found at $SSH_KEY_PATH"; fi
  SSH_AUTH="-i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  SCP_AUTH="$SSH_AUTH"
  SSH_AUTH_TYPE="key"
fi

# helper to run remote command
run_ssh() {
  if [[ "$SSH_AUTH_TYPE" == "password" ]]; then
    # Use sshpass if available
    if command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SSH_PASS" ssh $SSH_AUTH "$SSH_USER@$VM_IP" "$@"
    else
      warn "sshpass not found: falling back to interactive ssh for remote commands. Install sshpass to allow password-based automation."
      ssh $SSH_AUTH "$SSH_USER@$VM_IP" "$@"
    fi
  else
    ssh $SSH_AUTH "$SSH_USER@$VM_IP" "$@"
  fi
}

# helper to copy file
copy_file() {
  local src="$1" dst="$2"
  if [[ "$SSH_AUTH_TYPE" == "password" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SSH_PASS" scp $SCP_AUTH "$src" "$SSH_USER@$VM_IP:$dst"
    else
      warn "sshpass not found: falling back to interactive scp."
      scp $SCP_AUTH "$src" "$SSH_USER@$VM_IP:$dst"
    fi
  else
    scp $SCP_AUTH "$src" "$SSH_USER@$VM_IP:$dst"
  fi
}

# ---- Prepare the Koha installer script to run on the VM ----
INSTALLER_REMOTE_PATH="/root/koha_install_on_debian12.sh"
cat > "$TMP_DIR/koha_install_on_debian12.sh" <<'EOS'
#!/usr/bin/env bash
# koha_install_on_debian12.sh
# Run on Debian 12 (Bookworm) VM as root. Installs MariaDB and Koha packages (koha-common, koha-intranet)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
# Collect variables passed via env or prompt for them
KOHA_SITE="${KOHA_SITE:-library}"
KOHA_DB_PASSWORD="${KOHA_DB_PASSWORD:-}"
KOHA_ADMIN_PASSWORD="${KOHA_ADMIN_PASSWORD:-}"
if [[ -z "$KOHA_DB_PASSWORD" ]]; then
  read -rs -p "MariaDB Koha DB password: " KOHA_DB_PASSWORD; echo
fi
if [[ -z "$KOHA_ADMIN_PASSWORD" ]]; then
  read -rs -p "Koha SYSTEM/admin password: " KOHA_ADMIN_PASSWORD; echo
fi

info "Updating apt and installing prerequisites..."
apt update -y
apt install -y --no-install-recommends wget gnupg ca-certificates lsb-release apt-transport-https software-properties-common mariadb-server mariadb-client

systemctl enable --now mariadb

# Create Koha DB and user
run_mysql(){
  if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -u root -e "$1"
  else
    # try with sudo mysql -- but if root has password this will fail; interactive fallback
    mysql -u root -e "$1"
  fi
}

info "Creating Koha database and user..."
KOHA_DBNAME="koha"
KOHA_DBUSER="koha"
run_mysql "CREATE DATABASE IF NOT EXISTS \`${KOHA_DBNAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
run_mysql "CREATE USER IF NOT EXISTS '${KOHA_DBUSER}'@'localhost' IDENTIFIED BY '${KOHA_DB_PASSWORD}';"
run_mysql "GRANT ALL PRIVILEGES ON \`${KOHA_DBNAME}\`.* TO '${KOHA_DBUSER}'@'localhost';"
run_mysql "FLUSH PRIVILEGES;"

info "Adding Koha APT repository and key..."
KOHA_KEYRING="/usr/share/keyrings/koha-archive-keyring.gpg"
wget -q -O- https://debian.koha-community.org/koha/gpg.asc | gpg --dearmor -o "${KOHA_KEYRING}"
KOHA_CODENAME="bookworm"
echo "deb [signed-by=${KOHA_KEYRING}] https://debian.koha-community.org/koha ${KOHA_CODENAME} main" > /etc/apt/sources.list.d/koha.list
apt update -y
apt install -y --no-install-recommends koha-common koha-intranet

systemctl reload apache2 || true

if command -v koha-create >/dev/null 2>&1; then
  info "Running koha-create --create-db ${KOHA_SITE}"
  koha-create --create-db "${KOHA_SITE}" || err "koha-create failed."
  if command -v koha-passwd >/dev/null 2>&1; then
    koha-passwd "${KOHA_SITE}" admin "${KOHA_ADMIN_PASSWORD}" || err "koha-passwd failed."
  else
    err "koha-passwd not found; set SYSTEM password manually via Koha tools or web UI."
  fi
else
  err "koha-create not found; please run 'koha-create --create-db ${KOHA_SITE}' manually."
fi

info "Koha installation finished (or attempted). Check logs and web UI."
EOS
chmod +x "$TMP_DIR/koha_install_on_debian12.sh"

# Replace placeholders in installer with values we've collected by exporting env when executing remotely.
export KOHA_SITE KOHA_DB_PASSWORD KOHA_ADMIN_PASSWORD

info "Copying installer script to VM..."
copy_file "$TMP_DIR/koha_install_on_debian12.sh" "$INSTALLER_REMOTE_PATH"

ok "Installer copied to $SSH_USER@$VM_IP:$INSTALLER_REMOTE_PATH"

info "Running Koha installer on VM (remote) as root. The remote user will be used to sudo if not root."
# Execute remote script. If remote user is not root, we use sudo.
if run_ssh "test -w /root" >/dev/null 2>&1; then
  REMOTE_RUN_CMD="bash $INSTALLER_REMOTE_PATH"
else
  REMOTE_RUN_CMD="sudo bash $INSTALLER_REMOTE_PATH"
fi

info "Executing remote installer (you may be prompted for SSH password or sudo password)..."
run_ssh "$REMOTE_RUN_CMD"

ok "Remote installer finished (or attempted). If anything failed, check logs on the VM:"
echo " - /var/log/koha/"
echo " - /var/log/apache2/"
echo " - /var/log/mysql/ or /var/log/mariadb/"

info "Done. VM ($VM_ID) created and Koha installer attempted on $VM_IP."
exit 0