#!/usr/bin/env bash
#
# koha-vm.sh
#
# Create a Debian 12 (Bookworm) VM on a Proxmox host and install Koha (MariaDB backend).
# Modeled after: https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/vm/nextcloud-vm.sh
# Also attempts to source helper functions from:
#   https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func
#
# Intended to be run as root on the Proxmox host.
#
# High-level flow:
#  - gather parameters (VMID, name, resources, storage, ISO/cloud image)
#  - create VM (cloud-init disk)
#  - start VM
#  - optionally copy and run an installer script on the VM via SSH
#
# Prompts the user for:
#  - cloud-init user/password (or SSH key)
#  - VM IP (required for automatic remote install)
#  - MariaDB Koha DB password
#  - Koha SYSTEM (admin) password
#
set -euo pipefail
PROGNAME="$(basename "$0")"
API_FUNC_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---- Basic logging & helpers (small, similar style to nextcloud-vm.sh) ----
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

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

# ---- Try to source api.func (best-effort) ----
info "Attempting to fetch helper functions from api.func..."
if command -v curl >/dev/null 2>&1; then
  if curl -fsSL "$API_FUNC_URL" -o "$TMPDIR/api.func"; then
    # shellcheck disable=SC1090
    source "$TMPDIR/api.func" || warn "Sourcing api.func failed; continuing without it."
    info "Sourced api.func (best-effort)."
  else
    warn "Could not download api.func; continuing without it."
  fi
else
  warn "curl not found; skipping api.func download."
fi

# ---- Ensure running as root ----
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root on the Proxmox host."
fi

# ---- Defaults & prompts for VM creation ----
DEFAULT_NODE="$(pvesh get /nodes 2>/dev/null | awk 'NR==1{print $1}' || true)"
DEFAULT_NODE="${DEFAULT_NODE:-pve}"

prompt NODE "Proxmox node to create VM on" "$DEFAULT_NODE"
prompt VMID "VMID (numeric, unique) e.g. 9001" ""
if [[ -z "$VMID" ]]; then die "VMID is required."; fi
prompt NAME "VM name" "koha-${VMID}"
prompt CORES "Cores" "2"
prompt MEMORY "Memory (MB)" "4096"
prompt DISK "Disk size (GB)" "32"
prompt STORAGE "Storage (Proxmox storage id) for disk/cloud-init" "local-lvm"
prompt BRIDGE "Network bridge" "vmbr0"

info "Provide ISO or cloud image that exists on Proxmox storage, or leave blank to skip attaching ISO."
prompt ISO "ISO (e.g. local:iso/debian-12.iso) or cloud image (leave blank to skip)" ""

# cloud-init user/password and optional SSH pubkey
prompt CI_USER "Cloud-init user to create on the VM" "debian"
prompt_password CI_PASS "Cloud-init password for the VM user"
read -rp "Optional: path to SSH public key to inject (leave blank to skip): " SSH_PUBKEY_PATH
SSH_PUBKEY_CONTENT=""
if [[ -n "$SSH_PUBKEY_PATH" && -f "$SSH_PUBKEY_PATH" ]]; then
  SSH_PUBKEY_CONTENT="$(<"$SSH_PUBKEY_PATH")"
fi

# Koha specifics (ask for DB and admin passwords)
prompt KOHA_SITE "Koha site identifier (e.g. library)" "library"
prompt_password KOHA_DB_PASSWORD "MariaDB Koha DB password (for 'koha' user)"
prompt_password KOHA_ADMIN_PASSWORD "Koha SYSTEM (admin) password"

# ---- Create the VM ----
info "Creating VM ${VMID} on node ${NODE}..."

qm_cmd=(qm create "$VMID" --name "$NAME" --cores "$CORES" --memory "$MEMORY" --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-pci)
qm_cmd+=("--scsi0" "${STORAGE}:${DISK}G")
qm_cmd+=("--ide2" "${STORAGE}:cloudinit")
qm_cmd+=("--serial0" "socket" "--vmgenid" "1" "--boot" "order=scsi0")

info "Running: ${qm_cmd[*]}"
if ! "${qm_cmd[@]}"; then
  die "qm create failed"
fi
info "VM $VMID created."

if [[ -n "$ISO" ]]; then
  info "Setting CD-ROM to $ISO"
  qm set "$VMID" --cdrom "$ISO"
fi

info "Configuring cloud-init..."
qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"
if [[ -n "$SSH_PUBKEY_CONTENT" ]]; then
  tmpkey="$TMPDIR/id_pubkey"
  printf '%s\n' "$SSH_PUBKEY_CONTENT" > "$tmpkey"
  qm set "$VMID" --sshkey "$tmpkey"
fi
qm set "$VMID" --agent 1

info "Starting VM $VMID..."
qm start "$VMID"
info "VM started."

# ---- Ask for VM IP (necessary to do remote install) ----
info "To perform an automated Koha install we need the VM's IP address (DHCP or static)."
read -rp "Enter VM IP address now (leave empty to skip remote installation): " VM_IP
if [[ -z "$VM_IP" ]]; then
  info "No VM IP provided. VM has been created and started. Install OS and Koha manually or run this script again once VM is reachable."
  exit 0
fi

# ---- SSH connection details ----
prompt SSH_USER "SSH user to connect as" "$CI_USER"
read -rp "SSH auth method: 1) password  2) key (enter 1 or 2) [1]: " SSH_METHOD
SSH_METHOD="${SSH_METHOD:-1}"
if [[ "$SSH_METHOD" == "1" ]]; then
  prompt_password SSH_PASS "SSH password for ${SSH_USER}@${VM_IP}"
  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  SCP_OPTS="$SSH_OPTS"
  SSH_AUTH_TYPE="password"
else
  read -rp "Path to private key file for SSH: " SSH_KEY_PATH
  [[ -f "$SSH_KEY_PATH" ]] || die "SSH private key not found"
  SSH_OPTS="-i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  SCP_OPTS="$SSH_OPTS"
  SSH_AUTH_TYPE="key"
fi

# helpers for ssh/scp using sshpass if needed
run_ssh() {
  local cmd="$*"
  if [[ "$SSH_AUTH_TYPE" == "password" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SSH_PASS" ssh $SSH_OPTS "$SSH_USER@$VM_IP" "$cmd"
    else
      warn "sshpass missing - falling back to interactive ssh (you may be prompted)"
      ssh $SSH_OPTS "$SSH_USER@$VM_IP" "$cmd"
    fi
  else
    ssh $SSH_OPTS "$SSH_USER@$VM_IP" "$cmd"
  fi
}

copy_file() {
  local src="$1" dst="$2"
  if [[ "$SSH_AUTH_TYPE" == "password" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SSH_PASS" scp $SCP_OPTS "$src" "$SSH_USER@$VM_IP:$dst"
    else
      warn "sshpass missing - falling back to interactive scp"
      scp $SCP_OPTS "$src" "$SSH_USER@$VM_IP:$dst"
    fi
  else
    scp $SCP_OPTS "$src" "$SSH_USER@$VM_IP:$dst"
  fi
}

# ---- Prepare installer script that will run on the Debian 12 VM ----
INSTALLER_REMOTE="/root/koha_install_debian12.sh"
cat > "$TMPDIR/koha_install_debian12.sh" <<'EOI'
#!/usr/bin/env bash
# koha_install_debian12.sh
# Run as root on Debian 12 Bookworm. Installs MariaDB and Koha packages per Koha Community wiki.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }

# Read environment variables (expected to be set when invoking the script remotely)
KOHA_SITE="${KOHA_SITE:-library}"
KOHA_DB_PASSWORD="${KOHA_DB_PASSWORD:-}"
KOHA_ADMIN_PASSWORD="${KOHA_ADMIN_PASSWORD:-}"

# If passwords are empty, prompt interactively (best-effort)
if [[ -z "$KOHA_DB_PASSWORD" ]]; then
  read -rs -p "MariaDB Koha DB password: " KOHA_DB_PASSWORD; echo
fi
if [[ -z "$KOHA_ADMIN_PASSWORD" ]]; then
  read -rs -p "Koha SYSTEM (admin) password: " KOHA_ADMIN_PASSWORD; echo
fi

info "Updating apt and installing prerequisites..."
apt update -y
apt install -y --no-install-recommends wget gnupg ca-certificates lsb-release apt-transport-https software-properties-common mariadb-server mariadb-client

info "Starting & enabling MariaDB..."
systemctl enable --now mariadb

# Helper to run mysql as root using unix_socket where possible
run_mysql() {
  local sql="$1"
  if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -u root -e "$sql"
  else
    # Fallback: attempt mysql with no password (may prompt)
    mysql -u root -e "$sql"
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

info "Installing Koha packages..."
apt update -y
apt install -y --no-install-recommends koha-common koha-intranet

info "Reloading Apache to pick up Koha configs..."
systemctl reload apache2 || true

# Try to create a Koha site via koha-create helper
if command -v koha-create >/dev/null 2>&1; then
  info "Running koha-create --create-db ${KOHA_SITE} ..."
  koha-create --create-db "${KOHA_SITE}" || err "koha-create failed (check logs)"
  if command -v koha-passwd >/dev/null 2>&1; then
    info "Setting Koha SYSTEM (admin) password..."
    koha-passwd "${KOHA_SITE}" admin "${KOHA_ADMIN_PASSWORD}" || err "koha-passwd failed"
  else
    err "koha-passwd helper not found; set admin password manually in Koha."
  fi
else
  err "koha-create helper not found; you may need to create the site manually: 'koha-create --create-db ${KOHA_SITE}'"
fi

info "Koha installation script finished. Check the following logs for troubleshooting:"
echo " - /var/log/koha/"
echo " - /var/log/apache2/"
echo " - /var/log/mysql/ or /var/log/mariadb/"

EOI

chmod +x "$TMPDIR/koha_install_debian12.sh"

# ---- Copy installer to VM and execute it ----
info "Copying installer to ${SSH_USER}@${VM_IP}:${INSTALLER_REMOTE} ..."
copy_file "$TMPDIR/koha_install_debian12.sh" "$INSTALLER_REMOTE"

info "Executing installer on remote VM. This will run the Debian 12 Koha installation."
# Export sensitive vars via environment on the remote command (note: visible to processes on remote while running)
REMOTE_ENV="KOHA_SITE='${KOHA_SITE}' KOHA_DB_PASSWORD='${KOHA_DB_PASSWORD}' KOHA_ADMIN_PASSWORD='${KOHA_ADMIN_PASSWORD}'"

# Determine if remote user has root privileges directly
if run_ssh "id -u" >/dev/null 2>&1; then
  # If remote user is root, run directly; otherwise sudo
  if run_ssh "id -u" | grep -q '^0$'; then
    info "Remote user is root; running installer as root."
    run_ssh "${REMOTE_ENV} bash ${INSTALLER_REMOTE}"
  else
    info "Remote user is not root; running installer via sudo."
    run_ssh "sudo ${REMOTE_ENV} bash ${INSTALLER_REMOTE}"
  fi
else
  warn "Could not determine remote user; attempting to run installer via sudo."
  run_ssh "sudo ${REMOTE_ENV} bash ${INSTALLER_REMOTE}"
fi

info "Remote installer executed. If any step failed, review logs on the VM."

info "Summary:"
echo " - VM ID: ${VMID}"
echo " - VM Name: ${NAME}"
echo " - Koha site identifier: ${KOHA_SITE}"
echo " - MariaDB Koha user: koha (password: prompted)"
echo " - Koha SYSTEM/admin: (password: prompted)"
echo ""
echo "If koha-create or koha-passwd were missing the script printed error lines — run the following on the VM as root:"
echo "  koha-create --create-db ${KOHA_SITE}"
echo "  koha-passwd ${KOHA_SITE} admin <password>"

info "Done."
exit 0