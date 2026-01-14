#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts
# Author: Community Scripts
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

function header_info {
  clear
  cat <<"EOF"
    __ __      __         _    ____  ___
   / //_/___  / /  ____ _| |  / /  |/  /
  / ,<  / _ \/ __ \/ __ `/ | / / /|_/ / 
 / /| |/ // / / / / /_/ /| |/ / /  / /  
/_/ |_|\___/_/ /_/\__,_/ |___/_/  /_/   
                                        
EOF
}
header_info
echo -e "\n Loading..."
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="Koha"
var_os="debian-12"
var_version="n.d."

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")

CL=$(echo "\033[m")
BOLD=$(echo "\033[1m")
BFR="\\r\\033[K"
HOLD=" "
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"
OS="${TAB}🖥️${TAB}${CL}"
CONTAINERTYPE="${TAB}📦${TAB}${CL}"
DISKSIZE="${TAB}💾${TAB}${CL}"
CPUCORE="${TAB}🧠${TAB}${CL}"
RAMSIZE="${TAB}🛠️${TAB}${CL}"
CONTAINERID="${TAB}🆔${TAB}${CL}"
HOSTNAME="${TAB}🏠${TAB}${CL}"
BRIDGE="${TAB}🌉${TAB}${CL}"
GATEWAY="${TAB}🌐${TAB}${CL}"
DEFAULT="${TAB}⚙️${TAB}${CL}"
MACADDRESS="${TAB}🔗${TAB}${CL}"
VLANTAG="${TAB}🏷️${TAB}${CL}"
CREATING="${TAB}🚀${TAB}${CL}"
ADVANCED="${TAB}🧩${TAB}${CL}"
CLOUD="${TAB}☁️${TAB}${CL}"

THIN="discard=on,ssd=1,"
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "INTERRUPTED"' SIGINT
trap 'post_update_to_api "failed" "TERMINATED"' SIGTERM
function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  post_update_to_api "failed" "${command}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null
  post_update_to_api "done" "none"
  rm -rf $TEMP_DIR
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null
if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Koha VM" --yesno "This will create a New Koha VM. Proceed?" 10 58; then
  :
else
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}

function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root."
    echo -e "\nExiting..."
    sleep 2
    exit
  fi
}

# This function checks the version of Proxmox Virtual Environment (PVE) and exits if the version is not supported.
# Supported: Proxmox VE 8.0.x – 8.9.x, 9.0 and 9.1
pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"

  # Check for Proxmox VE 8.x: allow 8.0–8.9
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if ((MINOR < 0 || MINOR > 9)); then
      msg_error "This version of Proxmox VE is not supported."
      msg_error "Supported: Proxmox VE version 8.0 – 8.9"
      exit 1
    fi
    return 0
  fi

  # Check for Proxmox VE 9.x: allow 9.0 and 9.1
  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if ((MINOR < 0 || MINOR > 1)); then
      msg_error "This version of Proxmox VE is not supported."
      msg_error "Supported: Proxmox VE version 9.0 – 9.1"
      exit 1
    fi
    return 0
  fi

  # All other unsupported versions
  msg_error "This version of Proxmox VE is not supported."
  msg_error "Supported versions: Proxmox VE 8.0 – 8.x or 9.0 – 9.1"
  exit 1
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${INFO}${YWB}This script will not work with PiMox! \n"
    echo -e "\n ${YWB}Visit https://github.com/asylumexp/Proxmox for ARM64 support. \n"
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH, since SSH can create issues while gathering variables. Would you like to proceed with using SSH?" 10 62; then
        echo "you've been warned"
      else
        clear
        exit
      fi
    fi
  fi
}

function exit-script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit
}

function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_SIZE="20G"
  DISK_CACHE=""
  HN="koha-vm"
  CPU_TYPE=""
  CORE_COUNT="2"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"
  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}i440fx${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${CREATING}${BOLD}${DGN}Creating a Koha VM using the above default settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$VMID" ]; then
        VMID=$(get_valid_nextid)
      fi
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"
        sleep 2
        continue
      fi
      echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
      break
    else
      exit-script
    fi
  done

  if MACH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" --radiolist --cancel-button Exit-Script "Choose Type" 10 58 2 \
    "i440fx" "Machine i440fx" ON \
    "q35" "Machine q35" OFF \
    3>&1 1>&2 2>&3); then
    if [ $MACH = q35 ]; then
      echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}$MACH${CL}"
      FORMAT=""
      MACHINE=" -machine q35"
    else
      echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}$MACH${CL}"
      FORMAT=",efitype=4m"
      MACHINE=""
    fi
  else
    exit-script
  fi

  if DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size in GiB (e.g., 20, 40)" 8 58 "20" --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    DISK_SIZE=$(echo "$DISK_SIZE" | tr -d ' ')
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then
      DISK_SIZE="${DISK_SIZE}G"
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
    elif [[ "$DISK_SIZE" =~ ^[0-9]+G$ ]]; then
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
    else
      echo -e "${DISKSIZE}${BOLD}${RD}Invalid Disk Size. Please use a number (e.g., 20 or 20G).${CL}"
      exit-script
    fi
  else
    exit-script
  fi

  if DISK_CACHE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "None (Default)" ON \
    "1" "Write Through" OFF \
    3>&1 1>&2 2>&3); then
    if [ $DISK_CACHE = "1" ]; then
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}Write Through${CL}"
      DISK_CACHE="cache=writethrough,"
    else
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
      DISK_CACHE=""
    fi
  else
    exit-script
  fi

  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 koha-vm --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VM_NAME ]; then
      HN="koha-vm"
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    else
      HN=$(echo ${VM_NAME,,} | tr -d ' ')
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    fi
  else
    exit-script
  fi

  if CPU_TYPE1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "KVM64 (Default)" ON \
    "1" "Host" OFF \
    3>&1 1>&2 2>&3); then
    if [ $CPU_TYPE1 = "1" ]; then
      echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}Host${CL}"
      CPU_TYPE=" -cpu host"
    else
      echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
      CPU_TYPE=""
    fi
  else
    exit-script
  fi

  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 2 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $CORE_COUNT ]; then
      CORE_COUNT="2"
      echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
    else
      echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
    fi
  else
    exit-script
  fi

  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 4096 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $RAM_SIZE ]; then
      RAM_SIZE="4096"
      echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE${CL}"
    else
      echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE${CL}"
    fi
  else
    exit-script
  fi

  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $BRG ]; then
      BRG="vmbr0"
      echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
    else
      echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
    fi
  else
    exit-script
  fi

  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a MAC Address" 8 58 $GEN_MAC --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC1 ]; then
      MAC="$GEN_MAC"
      echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC${CL}"
    else
      MAC="$MAC1"
      echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC1${CL}"
    fi
  else
    exit-script
  fi

  if VLAN1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Vlan(leave blank for default)" 8 58 --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VLAN1 ]; then
      VLAN1="Default"
      VLAN=""
      echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}$VLAN1${CL}"
    else
      VLAN=",tag=$VLAN1"
      echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}$VLAN1${CL}"
    fi
  else
    exit-script
  fi

  if MTU1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Interface MTU Size (leave blank for default)" 8 58 --title "MTU SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MTU1 ]; then
      MTU1="Default"
      MTU=""
      echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}$MTU1${CL}"
    else
      MTU=",mtu=$MTU1"
      echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}$MTU1${CL}"
    fi
  else
    exit-script
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 58); then
    echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
    START_VM="yes"
  else
    echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}no${CL}"
    START_VM="no"
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create a Koha VM?" --no-button Do-Over 10 58); then
    echo -e "${CREATING}${BOLD}${DGN}Creating a Koha VM using the above advanced settings${CL}"
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info
    echo -e "${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

check_root
arch_check
pve_check
ssh_check
start_script

post_to_api_vm

msg_info "Validating Storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location."
  exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."
msg_info "Retrieving Debian 12 (Bookworm) Cloud Image"
URL=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
sleep 2
msg_ok "${CL}${BL}${URL}${CL}"
wget -q --show-progress $URL
echo -en "\e[1A\e[0K"
FILE=$(basename $URL)
msg_ok "Downloaded ${CL}${BL}${FILE}${CL}"

STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs | dir)
  DISK_EXT=".raw"
  DISK_REF="$VMID/"
  DISK_IMPORT="-format raw"
  THIN=""
  ;;
btrfs)
  DISK_EXT=".raw"
  DISK_REF="$VMID/"
  DISK_IMPORT="-format raw"
  FORMAT=",efitype=4m"
  THIN=""
  ;;
esac
for i in {0,1}; do
  disk="DISK$i"
  eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}
  eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
done

msg_info "Creating Koha VM"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios seabios${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
pvesm alloc $STORAGE $VMID $DISK0 4M 1>&/dev/null
qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} 1>&/dev/null
qm set $VMID \
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN} \
  -boot order=scsi0 \
  -serial0 socket >/dev/null
msg_ok "Created Koha VM ${CL}${BL}(${HN})"

msg_info "Adding Cloud-Init Drive"
qm set $VMID -ide2 $STORAGE:cloudinit >/dev/null
msg_ok "Added Cloud-Init Drive"

msg_info "Configuring Cloud-Init Settings"
# Prompt for root password
while true; do
  ROOT_PASS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox "Set root password for Koha VM (min 8 chars)" 8 58 --title "ROOT PASSWORD" 3>&1 1>&2 2>&3)
  if [ ${#ROOT_PASS} -lt 8 ]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox "Password must be at least 8 characters long!" 8 58 --title "ERROR"
    continue
  fi
  ROOT_PASS_CONFIRM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox "Confirm root password" 8 58 --title "CONFIRM PASSWORD" 3>&1 1>&2 2>&3)
  if [ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox "Passwords do not match!" 8 58 --title "ERROR"
    continue
  fi
  break
done

# Prompt for MariaDB root password
while true; do
  DB_ROOT_PASS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox "Set MariaDB root password (min 8 chars)" 8 58 --title "DATABASE PASSWORD" 3>&1 1>&2 2>&3)
  if [ ${#DB_ROOT_PASS} -lt 8 ]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox "Password must be at least 8 characters long!" 8 58 --title "ERROR"
    continue
  fi
  DB_ROOT_PASS_CONFIRM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox "Confirm MariaDB root password" 8 58 --title "CONFIRM PASSWORD" 3>&1 1>&2 2>&3)
  if [ "$DB_ROOT_PASS" != "$DB_ROOT_PASS_CONFIRM" ]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox "Passwords do not match!" 8 58 --title "ERROR"
    continue
  fi
  break
done

# Prompt for Koha instance name
KOHA_INSTANCE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Koha instance name (e.g., library)" 8 58 "library" --title "KOHA INSTANCE NAME" 3>&1 1>&2 2>&3)
if [ -z "$KOHA_INSTANCE" ]; then
  KOHA_INSTANCE="library"
fi

# Configure SSH key if available
SSH_KEY=""
if [ -f ~/.ssh/id_rsa.pub ]; then
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SSH KEY" --yesno "Found SSH public key. Add it to VM?" 10 58); then
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
  fi
fi

# Create cloud-init user-data
cat > user-data <<EOF
#cloud-config
users:
  - name: root
    lock_passwd: false
    passwd: $(openssl passwd -6 "$ROOT_PASS")
$([ -n "$SSH_KEY" ] && echo "    ssh_authorized_keys:
      - $SSH_KEY")
package_update: true
package_upgrade: true
packages:
  - gnupg2
  - wget
  - curl
runcmd:
  - echo "deb http://debian.koha-community.org/koha stable main" > /etc/apt/sources.list.d/koha.list
  - wget -qO - http://debian.koha-community.org/koha/gpg.asc | apt-key add -
  - apt-get update
  - echo "mariadb-server mysql-server/root_password password $DB_ROOT_PASS" | debconf-set-selections
  - echo "mariadb-server mysql-server/root_password_again password $DB_ROOT_PASS" | debconf-set-selections
  - DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server
  - systemctl enable mariadb
  - systemctl start mariadb
  - apt-get install -y koha-common xmlstarlet
  - a2enmod rewrite
  - a2enmod cgi
  - a2enmod headers proxy_http
  - koha-create --create-db --request-db root:$DB_ROOT_PASS $KOHA_INSTANCE
  - a2ensite $KOHA_INSTANCE
  - systemctl restart apache2
  - echo "Koha installation complete!" >> /root/koha-install.log
  - echo "OPAC URL: http://\$(hostname -I | awk '{print \$1}')" >> /root/koha-install.log
  - echo "Staff URL: http://\$(hostname -I | awk '{print \$1}'):8080" >> /root/koha-install.log
  - sleep 5
  - KOHA_PASS=\$(xmlstarlet sel -t -v 'yazgfs/config/pass' /etc/koha/sites/$KOHA_INSTANCE/koha-conf.xml 2>/dev/null || koha-passwd $KOHA_INSTANCE 2>/dev/null || echo "Run 'koha-passwd $KOHA_INSTANCE' to get password")
  - echo "Koha Instance: $KOHA_INSTANCE" > /root/koha-credentials.txt
  - echo "Koha Admin User: koha_$KOHA_INSTANCE" >> /root/koha-credentials.txt
  - echo "Koha Admin Password: \$KOHA_PASS" >> /root/koha-credentials.txt
  - echo "MariaDB Root Password: $DB_ROOT_PASS" >> /root/koha-credentials.txt
  - chmod 600 /root/koha-credentials.txt
  - echo "Installation completed at \$(date)" >> /root/koha-install.log
EOF

msg_ok "Configured Cloud-Init Settings"

msg_info "Uploading Cloud-Init Configuration"
SNIPPET_STORAGE="local"
SNIPPET_PATH=$(pvesm path ${SNIPPET_STORAGE}:snippets 2>/dev/null | sed 's|/snippets.*||')

# If local doesn't support snippets, try to find one that does
if [ -z "$SNIPPET_PATH" ]; then
  # Enable snippets on local storage if possible
  pvesm set local --content vztmpl,iso,snippets 2>/dev/null
  SNIPPET_PATH=$(pvesm path ${SNIPPET_STORAGE}:snippets 2>/dev/null | sed 's|/snippets.*||')
fi

if [ -z "$SNIPPET_PATH" ]; then
  msg_error "Cannot find storage that supports snippets"
  exit 1
fi

mkdir -p ${SNIPPET_PATH}/snippets
cp user-data ${SNIPPET_PATH}/snippets/koha-user-data-${VMID}.yml
chmod 644 ${SNIPPET_PATH}/snippets/koha-user-data-${VMID}.yml

# Set cloud-init configuration
qm set $VMID --cicustom "user=${SNIPPET_STORAGE}:snippets/koha-user-data-${VMID}.yml" >/dev/null
msg_ok "Uploaded Cloud-Init Configuration"

if [ -n "$DISK_SIZE" ]; then
  msg_info "Resizing disk to $DISK_SIZE"
  qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null
  msg_ok "Resized disk to $DISK_SIZE"
fi

DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <a href='https://Helper-Scripts.com' target='_blank' rel='noopener noreferrer'>
    <img src='https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo-81x112.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>Koha VM</h2>

  <p style='margin: 16px 0;'>Library Management System</p>

  <p style='margin: 16px 0;'>
    <a href='https://ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>
      <img src='https://img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='Buy Coffee' />
    </a>
  </p>
  
  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-book fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://koha-community.org/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Koha Docs</a>
  </span>
</div>

<hr>

<h3>Access Information</h3>
<ul>
  <li><strong>Instance Name:</strong> $KOHA_INSTANCE</li>
  <li><strong>OPAC URL:</strong> http://[VM-IP]</li>
  <li><strong>Staff Interface:</strong> http://[VM-IP]:8080</li>
  <li><strong>Credentials:</strong> Located in /root/koha-credentials.txt</li>
</ul>

<h3>Post-Installation Steps</h3>
<ol>
  <li>SSH into the VM: <code>ssh root@[VM-IP]</code></li>
  <li>Get admin password: <code>cat /root/koha-credentials.txt</code></li>
  <li>Access staff interface at http://[VM-IP]:8080</li>
  <li>Complete the web installer</li>
</ol>
EOF
)
qm set $VMID -description "$DESCRIPTION" >/dev/null
msg_ok "Set VM Description"

if [ "$START_VM" == "yes" ]; then
  msg_info "Starting Koha VM"
  qm start $VMID
  msg_ok "Started Koha VM"
  
  echo -e "\n${INFO}${YW}Waiting for VM to boot and complete installation...${CL}"
  echo -e "${INFO}${YW}This may take 5-10 minutes depending on network speed.${CL}"
  echo -e "${INFO}${YW}You can monitor progress in the VM console.${CL}\n"
  
  sleep 10
  
  # Try to get IP address
  for i in {1..30}; do
    VM_IP=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null | grep -oP '(?<="ip-address":")[^"]*' | grep -v "127.0.0.1" | head -n1)
    if [ -n "$VM_IP" ]; then
      break
    fi
    sleep 10
  done
  
  if [ -n "$VM_IP" ]; then
    echo -e "${INFO}${GN}Koha VM is accessible at:${CL}"
    echo -e "${TAB}${BL}OPAC: http://$VM_IP${CL}"
    echo -e "${TAB}${BL}Staff Interface: http://$VM_IP:8080${CL}"
    echo -e "${TAB}${BL}Instance: $KOHA_INSTANCE${CL}"
    echo -e "\n${INFO}${YW}To get Koha admin credentials:${CL}"
    echo -e "${TAB}${BL}ssh root@$VM_IP${CL}"
    echo -e "${TAB}${BL}cat /root/koha-credentials.txt${CL}\n"
  else
    echo -e "${INFO}${YW}VM is starting. Check ProxMox console for IP address.${CL}"
    echo -e "${INFO}${YW}Once booted, credentials will be in /root/koha-credentials.txt${CL}\n"
  fi
fi

post_update_to_api "done" "none"
msg_ok "Completed successfully!\n"