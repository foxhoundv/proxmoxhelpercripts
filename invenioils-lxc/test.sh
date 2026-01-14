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
# It creates a PRIVILEGED LXC and provisions Docker + docker-compose inside it
# to run the invenio-app-ils docker-compose.full.yml stack.

APP="InvenioILS"
var_tags="${var_tags:-invenio;ils;invenioils}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-6144}"        # MB
var_disk="${var_disk:-30}"        # GB
var_os="${var_os:-ubuntu}"
var_version="${var_version:-22.04}"
# Force privileged container creation
var_unprivileged="${var_unprivileged:-0}"
var_template="${var_template:-local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst}"
var_storage="${var_storage:-local-lvm}"
var_bridge="${var_bridge:-vmbr0}"

header_info "$APP"
variables
color
catch_errors

# Install & start Docker and the docker-compose stack inside the privileged container (CTID).
function install_app_privileged() {
  header_info "Provisioning (privileged) in container $CTID"

  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not set. Cannot provision privileged container."
    return 1
  fi

  check_container_storage
  check_container_resources

  msg_info "Installing Docker & docker-compose plugin (inside CT $CTID)"
  if ! pct exec "$CTID" -- bash -lc "set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release git sudo apt-transport-https gnupg2 software-properties-common || true
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
    msg_error "Failed installing Docker in CT $CTID"
    return 2
  fi
  msg_ok "Docker installed in CT $CTID"

  msg_info "Cloning invenio-app-ils repo (inside CT $CTID)"
  if ! pct exec "$CTID" -- bash -lc "set -euo pipefail
    REPO_DIR=/opt/invenio-app-ils
    if [ -d \"\$REPO_DIR/.git\" ]; then
      cd \$REPO_DIR && git pull || true
    else
      git clone https://github.com/inveniosoftware/invenio-app-ils.git \$REPO_DIR
      cd \$REPO_DIR && git checkout main || true
    fi
    chown -R 1000:1000 \$REPO_DIR || true
  "; then
    msg_error "Failed cloning repo in CT $CTID"
    return 3
  fi
  msg_ok "Repository ready in CT $CTID"

  msg_info "Reminder: edit /opt/invenio-app-ils/docker-services.yml or create an .env in /opt/invenio-app-ils to set INVENIO_SECRET_KEY and database passwords before starting the stack."

  msg_info "Starting Docker compose stack (inside CT $CTID)"
  if ! pct exec "$CTID" -- bash -lc "set -euo pipefail
    REPO_DIR=/opt/invenio-app-ils
    cd \$REPO_DIR
    docker compose -f docker-compose.full.yml pull || true
    docker compose -f docker-compose.full.yml up -d --build
  "; then
    msg_error "docker compose start failed inside CT $CTID"
    return 4
  fi

  msg_ok "Docker stack requested to start in CT $CTID"
  return 0
}

# Update routine: updates repo and restarts the stack inside privileged container
function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local target_ct="${CTID:-}"
  if [[ -z "$target_ct" ]]; then
    msg_error "No CTID found to update"
    exit 1
  fi

  msg_info "Updating repository and Docker stack inside CT $target_ct"
  pct exec "$target_ct" -- bash -lc "set -euo pipefail
    REPO_DIR=/opt/invenio-app-ils
    if [ -d \"\$REPO_DIR/.git\" ]; then
      cd \$REPO_DIR && git pull || true
      docker compose -f docker-compose.full.yml pull || true
      docker compose -f docker-compose.full.yml up -d --build || true
    else
      echo 'Repository not found at \$REPO_DIR' 1>&2
      exit 1
    fi
  "

  msg_ok "Update requested for CT $target_ct"
  exit
}

# post-create hook: called after build_container to provision the privileged CT
function post_create_hook() {
  # Wait for CTID to be defined by build.func (max wait ~30s)
  local retries=30
  while [[ -z "${CTID:-}" && $retries -gt 0 ]]; do
    sleep 1
    retries=$((retries-1))
  done

  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not detected; cannot run provisioning."
    return 1
  fi

  install_app_privileged
}

# If called with "update", run update_script
if [[ "${1:-}" == "update" ]]; then
  update_script
  exit
fi

# Main flow (mirrors community-scripts template)
start
# build_container will create the LXC according to variables above (var_unprivileged=0 ensures privileged)
build_container

# Run provisioning inside the created privileged container
post_create_hook || true

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL (example):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:80 (or mapped ports as configured in compose)${CL}"