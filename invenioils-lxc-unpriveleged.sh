#!/usr/bin/env bash
# create-invenioils-lxc-unprivileged.sh
# Usage: sudo ./create-invenioils-lxc-unprivileged.sh <VMID> <CT_NAME> [STORAGE] [BRIDGE] [TEMPLATE]
#
# Example:
# sudo ./create-invenioils-lxc-unprivileged.sh 210 invenio-ils-unpriv local-lvm vmbr0 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
#
# This creates an UNPRIVILEGED LXC on Proxmox and provisions rootless Podman + podman-compose
# to run the invenio-app-ils repository's docker-compose.full.yml stack.
#
# NOTES / REQUIREMENTS:
# - Run on Proxmox host as root (pct must be available).
# - Template should be a systemd-enabled distro (Ubuntu 22.04 recommended).
# - We enable nesting and keyctl; Proxmox will set up uid/gid mappings for the unprivileged container.
# - OpenSearch requires vm.max_map_count >= 262144 on the HOST. The script will try to set it.
# - Some services in the upstream docker-compose may require privileged containers or kernel features
#   not available in rootless Podman. See caveats below.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  cat <<EOF
Usage: $0 <VMID> <CT_NAME> [STORAGE] [BRIDGE] [TEMPLATE]

Defaults:
 STORAGE = local-lvm
 BRIDGE  = vmbr0
 TEMPLATE = local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst

Example:
 sudo $0 210 invenio-ils-unpriv local-lvm vmbr0 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
EOF
  exit 1
fi

VMID="$1"
CT_NAME="$2"
STORAGE="${3:-local-lvm}"
BRIDGE="${4:-vmbr0}"
TEMPLATE="${5:-local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst}"

# Resources (tune as needed)
CORES=2
MEM_MB=6144
DISK_GB=30

# Ensure host vm.max_map_count >= 262144 for OpenSearch
echo "Checking host vm.max_map_count (OpenSearch requirement)..."
HOST_CUR=$(sysctl -n vm.max_map_count || echo 0)
if [ "$HOST_CUR" -lt 262144 ]; then
  echo "Setting vm.max_map_count=262144 on host (temporary and persistent)..."
  sysctl -w vm.max_map_count=262144
  if ! grep -q "^vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
  else
    sed -i 's/^vm.max_map_count.*/vm.max_map_count=262144/' /etc/sysctl.conf
  fi
fi

echo "Creating UNPRIVILEGED LXC container $VMID ($CT_NAME) from template $TEMPLATE..."
# Create unprivileged container with nesting enabled
pct create "$VMID" "$TEMPLATE" \
  --hostname "$CT_NAME" \
  --cores "$CORES" \
  --memory "$MEM_MB" \
  --rootfs "${STORAGE}:${DISK_GB}G" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 1

echo "Starting container $VMID..."
pct start "$VMID"

echo "Waiting a few seconds for the container to start..."
sleep 6

echo "Provisioning container: installing Podman, pip, git and podman-compose..."
# Install Podman and podman-compose inside the unprivileged container
pct exec "$VMID" -- bash -lc "set -euo pipefail
# Use noninteractive frontend
export DEBIAN_FRONTEND=noninteractive

# Update and install helpers
apt-get update
apt-get install -y software-properties-common curl gnupg2 apt-transport-https ca-certificates git sudo python3-pip

# Install Podman (Ubuntu 22.04 should have podman; otherwise add upstream repos)
apt-get install -y podman uidmap slirp4netns

# Create a non-root user to run rootless Podman
id -u invenio >/dev/null 2>&1 || useradd -m -s /bin/bash invenio
echo 'invenio ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/invenio || true

# Give invenio user a few seconds for subuid/subgid mapping to be effective.
# Install podman-compose (community) via pip in system site-packages (or consider a venv).
pip3 install --no-cache-dir podman-compose

# Configure user lingering for systemd --user (helps with user services)
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger invenio || true
fi

# Ensure .config/containers exists for invenio user (optional)
runuser -l invenio -c 'mkdir -p ~/.config/containers || true'
"

echo "Cloning the invenio-app-ils repository into /home/invenio/invenio-app-ils..."
pct exec "$VMID" -- bash -lc "set -euo pipefail
REPO_DIR=/home/invenio/invenio-app-ils
if [ -d \"\$REPO_DIR/.git\" ]; then
  runuser -l invenio -c 'cd \$REPO_DIR && git pull'
else
  runuser -l invenio -c 'git clone https://github.com/inveniosoftware/invenio-app-ils.git \$REPO_DIR'
  runuser -l invenio -c 'cd \$REPO_DIR && git checkout main || true'
fi
chown -R 1000:1000 /home/invenio/invenio-app-ils || true
"

echo "Starting the stack with podman-compose (as user 'invenio')."
pct exec "$VMID" -- bash -lc "set -euo pipefail
REPO_DIR=/home/invenio/invenio-app-ils
COMPOSE_FILE=\$REPO_DIR/docker-compose.full.yml

if [ ! -f \"\$COMPOSE_FILE\" ]; then
  echo 'docker-compose.full.yml not found; aborting start.' >&2
  exit 1
fi

# IMPORTANT: user may want to edit docker-services.yml to inject secrets before running.
echo 'Reminder: edit docker-services.yml or create an .env file in \$REPO_DIR to set INVENIO_SECRET_KEY and DB passwords.'

# Run podman-compose (this will create pods/containers as rootless Podman)
runuser -l invenio -c 'cd \$REPO_DIR && podman-compose -f docker-compose.full.yml up -d --build' || {
  echo 'podman-compose start failed. Check logs. You may need to adjust compose files for rootless Podman.' >&2
}
"

cat <<EOF

Done: unprivileged LXC ($VMID) created and Podman startup attempted.

Follow-up & debugging
- Enter the container: pct enter $VMID
- Switch to the invenio user inside container: su - invenio
- Check podman containers: podman ps -a
- Logs for a pod/container: podman logs <container_id>
- To tail podman-compose logs: runuser -l invenio -c 'cd /home/invenio/invenio-app-ils && podman-compose -f docker-compose.full.yml logs -f'

Caveats & guidance
- Podman (rootless) works well for many stacks, but some images/services require kernel capabilities, privileged mode, or specific cgroup features that are not available in unprivileged rootless Podman (notably some OpenSearch/Elasticsearch images). If you see failures like "cannot allocate memory" or permission/privilege errors for OpenSearch, you may need to:
  - Run a privileged LXC (fallback), OR
  - Provision a small KVM VM and run Docker there, OR
  - Modify the docker-compose files to run those services as non-privileged alternatives (not always possible).
- The repo docker-compose is authored for Docker Compose; podman-compose is mostly compatible but not 100%. If podman-compose fails:
  - Consider installing the legacy docker-compose (python) and providing a Docker daemon (not possible rootlessly), OR
  - Use a small privileged LXC or KVM VM instead.
- OpenSearch requires vm.max_map_count >= 262144 on the HOST (script attempts to set it).
- If networking problems occur (rootless Podman uses slirp4netns by default), you can configure rootless network with CNI; this can affect how published ports behave. The script uses default rootless networking which forwards ports for published ports but may behave differently from Docker host networking.
- If you want higher fidelity Docker compatibility inside an unprivileged container, the only reliable course is a privileged LXC or a KVM VM.

Next steps I can take for you (pick one):
- Try to automatically detect common Podman incompatibilities and fall back to creating a privileged LXC/KVM.
- Produce a variant script that sets up a small KVM (qm) VM instead (simpler for Docker).
- Add an automated .env generator and edit docker-services.yml to fill secrets before starting the stack.
- Attempt to convert docker-compose.full.yml into a podman-ready compose (best-effort) and report which services need manual changes.

Which would you like next? 
EOF