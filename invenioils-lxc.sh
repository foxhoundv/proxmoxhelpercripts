#!/usr/bin/env bash
# create-invenioils-lxc.sh
# Usage: sudo ./create-invenioils-lxc.sh <VMID> <CT_NAME> [STORAGE] [BRIDGE] [TEMPLATE]
#
# Example:
# sudo ./create-invenioils-lxc.sh 110 invenio-ils local-lvm vmbr0 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
#
# Requirements: run as root on Proxmox host (pve), pct available, internet access, enough disk/ram.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  cat <<EOF
Usage: $0 <VMID> <CT_NAME> [STORAGE] [BRIDGE] [TEMPLATE]
Creates an LXC container and provisions it to run the invenio-app-ils docker stack.

Defaults:
 STORAGE = local-lvm
 BRIDGE  = vmbr0
 TEMPLATE = local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst

Note: Adjust resources below (CORES, MEM_MB, DISK_GB) as needed.
EOF
  exit 1
fi

VMID="$1"
CT_NAME="$2"
STORAGE="${3:-local-lvm}"
BRIDGE="${4:-vmbr0}"
TEMPLATE="${5:-local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst}"

# Resources (tune these)
CORES=2
MEM_MB=4096
DISK_GB=20

# Host sysctl required for OpenSearch
echo "Ensuring host vm.max_map_count >= 262144..."
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

echo "Creating LXC container $VMID ($CT_NAME) from template $TEMPLATE..."
pct create "$VMID" "$TEMPLATE" \
  --hostname "$CT_NAME" \
  --cores "$CORES" \
  --memory "$MEM_MB" \
  --rootfs "${STORAGE}:${DISK_GB}G" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 0

echo "Starting container..."
pct start "$VMID"

echo "Waiting 6s for container to come up..."
sleep 6

echo "Installing Docker & dependencies inside container..."
pct exec "$VMID" -- bash -lc "set -euo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg lsb-release git sudo apt-transport-https
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
ARCH=\$(dpkg --print-architecture)
echo \"deb [arch=\$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
# start docker
systemctl enable --now docker || true
# ensure docker group exists
groupadd -f docker || true
# create an admin user 'invenio' (optional)
id -u invenio >/dev/null 2>&1 || useradd -m -s /bin/bash invenio
usermod -aG docker invenio || true
"

echo "Cloning invenio-app-ils inside container and starting docker compose..."
pct exec "$VMID" -- bash -lc "set -euo pipefail
# Clone repository (or pull updates if exists)
REPO_DIR=/opt/invenio-app-ils
if [ -d \"\$REPO_DIR/.git\" ]; then
  echo 'Repo already exists, pulling latest...'
  cd \$REPO_DIR && git pull
else
  git clone https://github.com/inveniosoftware/invenio-app-ils.git \$REPO_DIR
fi

cd \$REPO_DIR

# Make sure env values (secrets) are set - user will need to edit docker-services.yml or provide an .env file.
echo 'NOTE: You may want to edit docker-services.yml to set INVENIO_SECRET_KEY and other env vars before starting the stack.'

# Build & start the full stack (images may take time)
docker compose -f docker-compose.full.yml pull || true
docker compose -f docker-compose.full.yml up -d --build
"

echo "Done. Container $VMID started and InvenioILS docker stack requested to start."
echo
echo "Next manual tasks / notes:"
cat <<EOF
- Connect to container: pct enter $VMID  OR use SSH if you configured networking.
- Edit docker-services.yml (in /opt/invenio-app-ils) to set INVENIO_SECRET_KEY and production values.
- Ensure ports and firewall rules allow required access (the default docker stack maps ports).
- If docker in the LXC has issues with systemd, you may need to run dockerd manually or use a slightly different template.
- OpenSearch requires vm.max_map_count >= 262144 (the script sets this on the host).
- Monitor logs: pct exec $VMID -- docker compose -f /opt/invenio-app-ils/docker-compose.full.yml logs -f
- The stack can take multiple minutes to build/pull all images.

Caveats:
- This script creates a privileged container (unprivileged=0). Running Docker inside an unprivileged LXC is more complex and out of scope for this helper script.
- You may prefer to run the Docker stack directly on the Proxmox host or use a KVM VM instead of LXC if you need stronger isolation.
- The invenio-app-ils docker compose stack expects multiple services (Postgres, OpenSearch, RabbitMQ, Redis). Adjust resources (RAM/CPU) accordingly.
EOF