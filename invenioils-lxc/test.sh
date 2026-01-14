#!/usr/bin/env bash
# source the shared build helpers used by community-scripts
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: assistant (adapted for invenio-app-ils)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/inveniosoftware/invenio-app-ils
#
# This script follows the structure and conventions of:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/managemydamnlife.sh
#
# It creates an UNPRIVILEGED LXC and attempts to provision rootless Podman + podman-compose
# to run the invenio-app-ils docker-compose.full.yml stack. If rootless provisioning fails,
# it automatically falls back by creating a new PRIVILEGED LXC and provisioning Docker there.

APP="InvenioILS"
var_tags="${var_tags:-invenio;ils;invenioils}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-6144}"        # MB
var_disk="${var_disk:-30}"        # GB
var_os="${var_os:-ubuntu}"
var_version="${var_version:-22.04}"
var_unprivileged="${var_unprivileged:-1}"   # default create unprivileged
var_template="${var_template:-local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst}"
var_storage="${var_storage:-local-lvm}"
var_bridge="${var_bridge:-vmbr0}"

header_info "$APP"
variables
color
catch_errors

# Attempt to provision rootless Podman inside the unprivileged container.
# Returns 0 on success, non-zero on failure.
function install_app_rootless() {
  header_info "Provisioning (rootless) in container $CTID"

  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not set. Cannot provision rootless."
    return 2
  fi

  check_container_storage
  check_container_resources

  msg_info "Installing Podman + podman-compose and dependencies (inside CT $CTID)"
  if ! pct exec "$CTID" -- bash -lc "set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y software-properties-common curl gnupg2 apt-transport-https ca-certificates git sudo python3-pip uidmap slirp4netns podman || true
    id -u invenio >/dev/null 2>&1 || useradd -m -s /bin/bash invenio
    echo 'invenio ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/invenio || true
    pip3 install --no-cache-dir podman-compose
    if command -v loginctl >/dev/null 2>&1; then
      loginctl enable-linger invenio || true
    fi
  "; then
    msg_error "Failed installing Podman in CT $CTID"
    return 3
  fi
  msg_ok "Podman + podman-compose installed in CT $CTID"

  msg_info "Cloning invenio-app-ils repo (inside CT $CTID)"
  if ! pct exec "$CTID" -- bash -lc "set -euo pipefail
    REPO_DIR=/home/invenio/invenio-app-ils
    if [ -d \"\$REPO_DIR/.git\" ]; then
      runuser -l invenio -c 'cd \$REPO_DIR && git pull' || true
    else
      runuser -l invenio -c 'git clone https://github.com/inveniosoftware/invenio-app-ils.git \$REPO_DIR'
      runuser -l invenio -c 'cd \$REPO_DIR && git checkout main || true'
    fi
    chown -R 1000:1000 /home/invenio/invenio-app-ils || true
  "; then
    msg_error "Failed cloning repo in CT $CTID"
    return 4
  fi
  msg_ok "Repository ready in CT $CTID"

  msg_info "Starting rootless podman-compose stack (inside CT $CTID)"
  # Run as user 'invenio'
  if ! pct exec "$CTID" -- bash -lc "set -euo pipefail
    REPO_DIR=/home/invenio/invenio-app-ils
    if [ ! -f \"\$REPO_DIR/docker-compose.full.yml\" ]; then
      echo 'docker-compose.full.yml not found' 1>&2
      exit 5
    fi
    runuser -l invenio -c 'cd \$REPO_DIR && podman-compose -f docker-compose.full.yml up -d --build'
  "; then
    msg_error "podman-compose failed inside CT $CTID"
    return 5
  fi

  msg_ok "Rootless stack requested to start in CT $CTID"
  return 0
}

# Provision Docker in a privileged container and run docker compose.
function install_app_privileged() {
  local target_ct="$1"
  header_info "Provisioning (privileged) in container $target_ct"

  check_container_storage
  check_container_resources

  msg_info "Installing Docker & docker-compose plugin (inside CT $target_ct)"
  if ! pct exec "$target_ct" -- bash -lc "set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release git sudo apt-transport-https
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
    ARCH=\$(dpkg --print-architecture)
    echo \"deb [arch=\$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
    systemctl enable --now docker || true
    groupadd -f docker || true
    id -u invenio >/dev/null 2>&1 || useradd -m -s /bin/bash invenio
    usermod -aG docker invenio || true
  "; then
    msg_error "Failed installing Docker in CT $target_ct"
    return 6
  fi
  msg_ok "Docker installed in CT $target_ct"

  msg_info "Cloning invenio-app-ils repo (inside CT $target_ct)"
  if ! pct exec "$target_ct" -- bash -lc "set -euo pipefail
    REPO_DIR=/opt/invenio-app-ils
    if [ -d \"\$REPO_DIR/.git\" ]; then
      cd \$REPO_DIR && git pull || true
    else
      git clone https://github.com/inveniosoftware/invenio-app-ils.git \$REPO_DIR
      cd \$REPO_DIR && git checkout main || true
    fi
    chown -R 1000:1000 \$REPO_DIR || true
  "; then
    msg_error "Failed cloning repo in CT $target_ct"
    return 7
  fi
  msg_ok "Repository ready in CT $target_ct"

  msg_info "Starting Docker compose stack (inside CT $target_ct)"
  if ! pct exec "$target_ct" -- bash -lc "set -euo pipefail
    REPO_DIR=/opt/invenio-app-ils
    cd \$REPO_DIR
    # remind user to set secrets
    echo 'Ensure docker-services.yml/.env are configured for production secrets'
    docker compose -f docker-compose.full.yml pull || true
    docker compose -f docker-compose.full.yml up -d --build
  "; then
    msg_error "docker compose start failed inside CT $target_ct"
    return 8
  fi

  msg_ok "Docker stack requested to start in CT $target_ct"
  return 0
}

# Create a privileged container (new ID) to use as fallback.
# Returns new CTID via global variable FALLBACK_CTID and sets FALLBACK_NAME.
function create_privileged_container() {
  header_info "Creating privileged fallback container"

  local base_id="${CTID:-100}"
  # Find next free CTID (start from base_id+1)
  local candidate=$((base_id + 1))
  while pct status "$candidate" >/dev/null 2>&1; do
    candidate=$((candidate + 1))
    if [[ $candidate -gt $((base_id + 500)) ]]; then
      msg_error "Could not find free CTID in range"
      return 9
    fi
  done

  local new_ctid="$candidate"

  # Determine original hostname if available, else compose one
  local orig_name
  orig_name=$(pct config "$CTID" 2>/dev/null | awk -F': ' '/hostname/ {print $2}' || true)
  if [[ -z "$orig_name" ]]; then
    orig_name="invenio-$new_ctid"
  fi
  local new_name="${orig_name}-priv"

  msg_info "Creating privileged container $new_ctid (hostname: $new_name) using template ${var_template}"
  pct create "$new_ctid" "$var_template" \
    --hostname "$new_name" \
    --cores "$var_cpu" \
    --memory "$var_ram" \
    --rootfs "${var_storage}:${var_disk}G" \
    --net0 name=eth0,bridge="$var_bridge,ip=dhcp" \
    --features nesting=1,keyctl=1 \
    --unprivileged 0 || {
      msg_error "Failed to create privileged container $new_ctid"
      return 10
    }

  msg_info "Starting privileged container $new_ctid"
  pct start "$new_ctid" || {
    msg_error "Failed to start privileged container $new_ctid"
    return 11
  }

  # Wait briefly
  sleep 5

  FALLBACK_CTID="$new_ctid"
  FALLBACK_NAME="$new_name"
  msg_ok "Privileged container $FALLBACK_CTID created and started"
  return 0
}

# post-create hook: attempt rootless install; if it fails, create privileged CT and provision it.
function post_create_hook() {
  # Wait for CTID to be defined by build.func (max wait ~30s)
  local retries=30
  while [[ -z "${CTID:-}" && $retries -gt 0 ]]; do
    sleep 1
    retries=$((retries-1))
  done

  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not detected; cannot run post-create provisioning."
    return 1
  fi

  # First attempt: rootless
  if install_app_rootless; then
    msg_ok "Rootless provisioning succeeded in CT $CTID"
    return 0
  fi

  msg_error "Rootless provisioning failed in CT $CTID — falling back to privileged container"

  # Create privileged container
  if ! create_privileged_container; then
    msg_error "Failed to create privileged fallback container. Aborting."
    return 1
  fi

  # Provision privileged container with Docker
  if install_app_privileged "$FALLBACK_CTID"; then
    msg_ok "Privileged provisioning succeeded in CT $FALLBACK_CTID"
    # Optionally: print info for fallback CT
    echo -e "${INFO} Privileged fallback container: CTID=${FALLBACK_CTID}, hostname=${FALLBACK_NAME}${CL}"
    return 0
  else
    msg_error "Privileged provisioning failed in CT $FALLBACK_CTID"
    return 1
  fi
}

# Allow update mode to update stack inside the original CT (or fallback if present)
function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local target_ct="${CTID:-}"
  # Prefer fallback CT if it exists
  if [[ -n "${FALLBACK_CTID:-}" ]]; then
    target_ct="$FALLBACK_CTID"
  fi

  if [[ -z "$target_ct" ]]; then
    msg_error "No container found to update"
    exit 1
  fi

  msg_info "Updating repository and stack inside CT $target_ct"
  # Try podman (rootless) then docker (priv)
  pct exec "$target_ct" -- bash -lc "set -euo pipefail
    if [ -d /home/invenio/invenio-app-ils ]; then
      cd /home/invenio/invenio-app-ils && git pull || true
      runuser -l invenio -c 'cd /home/invenio/invenio-app-ils && podman-compose -f docker-compose.full.yml pull' || true
      runuser -l invenio -c 'cd /home/invenio/invenio-app-ils && podman-compose -f docker-compose.full.yml up -d --build' || true
    fi
    if [ -d /opt/invenio-app-ils ]; then
      cd /opt/invenio-app-ils && git pull || true
      docker compose -f docker-compose.full.yml pull || true
      docker compose -f docker-compose.full.yml up -d --build || true
    fi
  "

  msg_ok "Update requested for CT $target_ct"
  exit
}

# If called with "update", run update_script
if [[ "${1:-}" == "update" ]]; then
  update_script
  exit
fi

# Main flow (follows community-scripts patterns)
start
build_container

# Run post-create provisioning (attempt rootless then fallback to privileged)
post_create_hook || true

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL (example):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:80 (or mapped ports as configured in compose)${CL}"