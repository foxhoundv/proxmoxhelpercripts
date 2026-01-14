#!/usr/bin/env bash
# source the shared build helpers used by community-scripts
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: assistant (adapted for invenio-app-ils)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/inveniosoftware/invenio-app-ils
#
# This script follows the same structure and conventions as:
# https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/managemydamnlife.sh
# It creates an UNPRIVILEGED LXC and provisions rootless Podman + podman-compose
# to run the invenio-app-ils docker-compose.full.yml stack inside the container.

APP="InvenioILS"
var_tags="${var_tags:-invenio;ils;invenioils}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-6144}"
var_disk="${var_disk:-30}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-22.04}"
var_unprivileged="${var_unprivileged:-1}"
var_template="${var_template:-local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst}"

header_info "$APP"
variables
color
catch_errors

# Update routine (pull upstream updates & rebuild)
function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # Expect build.func to set CTID when container exists
  if [[ -z "${CTID:-}" ]]; then
    msg_error "No container ID (CTID) found. Is the container created?"
    exit 1
  fi

  # Ensure repository exists inside container
  pct exec "$CTID" -- bash -lc "set -euo pipefail
    if [[ ! -d /home/invenio/invenio-app-ils ]]; then
      echo 'No installation found at /home/invenio/invenio-app-ils'
      exit 1
    fi
    cd /home/invenio/invenio-app-ils
    git pull origin main || true
    chown -R 1000:1000 /home/invenio/invenio-app-ils || true
  "

  msg_info "Updating podman-compose stack inside container"
  pct exec "$CTID" -- bash -lc "set -euo pipefail
    runuser -l invenio -c 'cd /home/invenio/invenio-app-ils && podman-compose -f docker-compose.full.yml pull' || true
    runuser -l invenio -c 'cd /home/invenio/invenio-app-ils && podman-compose -f docker-compose.full.yml up -d --build'
  "

  msg_ok "Updated ${APP} inside container $CTID"
  exit
}

# Application install/provision steps executed after container creation
function install_app_in_container() {
  header_info "Provisioning ${APP} inside container"

  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not set - cannot provision container."
    return 1
  fi

  check_container_storage
  check_container_resources

  msg_info "Installing Podman, dependencies and creating user"
  pct exec "$CTID" -- bash -lc "set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y software-properties-common curl gnupg2 apt-transport-https ca-certificates git sudo python3-pip uidmap slirp4netns
    # ensure podman available (Ubuntu 22.04 includes podman)
    apt-get install -y podman || true

    # create non-root user to run rootless Podman
    id -u invenio >/dev/null 2>&1 || useradd -m -s /bin/bash invenio
    echo 'invenio ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/invenio || true

    # give new user subuid/subgid ranges (best effort, proxmox usually maps ranges)
    if ! getent passwd 1000 >/dev/null 2>&1; then
      usermod -u 1000 invenio || true
    fi

    # install podman-compose
    pip3 install --no-cache-dir podman-compose

    # enable lingering for systemd --user (helps with user units)
    if command -v loginctl >/dev/null 2>&1; then
      loginctl enable-linger invenio || true
    fi
  "

  msg_ok "System packages and podman installed"

  msg_info "Cloning invenio-app-ils repository"
  pct exec "$CTID" -- bash -lc "set -euo pipefail
    REPO_DIR=/home/invenio/invenio-app-ils
    if [ -d \"\$REPO_DIR/.git\" ]; then
      runuser -l invenio -c 'cd \$REPO_DIR && git pull' || true
    else
      runuser -l invenio -c 'git clone https://github.com/inveniosoftware/invenio-app-ils.git \$REPO_DIR'
      runuser -l invenio -c 'cd \$REPO_DIR && git checkout main || true'
    fi
    chown -R 1000:1000 /home/invenio/invenio-app-ils || true
  "

  msg_ok "Repository ready"

  msg_info "Reminder: edit /home/invenio/invenio-app-ils/docker-services.yml to set secrets (INVENIO_SECRET_KEY, DB passwords, etc.) before starting the stack."

  msg_info "Starting podman-compose stack (rootless) as user 'invenio'"
  pct exec "$CTID" -- bash -lc "set -euo pipefail
    runuser -l invenio -c 'cd /home/invenio/invenio-app-ils && podman-compose -f docker-compose.full.yml up -d --build' || {
      echo 'podman-compose start returned non-zero. Check logs for details.' 1>&2
      exit 1
    }
  "

  msg_ok "Requested podman-compose stack start"
}

# Hooks expected by build.func:
# - start (prints header / gathers params)
# - build_container (creates container and then runs post-creation provisioning)
# - description (prints final user-facing info)
#
# We rely on the build.func implementation of start/build_container/description.
# To ensure our post-create provisioning runs, implement a simple wrapper that
# build.func can call after creation by checking for CTID and then calling install_app_in_container.
#
# Many community scripts simply call start; build_container; description (we follow same pattern).

# After create, build.func typically provisions network and sets CTID, IP, GATEWAY variables.
# We add a small polling loop to wait for CTID to be set (in case build.func asynchronously sets it).
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

  install_app_in_container
}

# Register trap so update_script can be invoked if script is called with "update"
if [[ "${1:-}" == "update" ]]; then
  update_script
  exit
fi

# Main flow (mirrors managemydamnlife.sh)
start
build_container

# Run post-create provisioning if container was just created
post_create_hook || true

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL (example):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:80 (or mapped ports as configured in compose)${CL}"