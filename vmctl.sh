#!/bin/sh
# vmctl.sh — QEMU snapshot manager via QMP + qemu-img offline snapshots
# Supports multi-disk .utm VMs
# Requires: socat, jq, qemu-img, doas

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Detect TTY for colors
if [ -t 1 ]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  CYAN="\033[36m"
  RESET="\033[0m"
else
  RED= GREEN= YELLOW= BLUE= CYAN= RESET=
fi

# 2-space indent helper
indent="  "

require() {
  command -v "$1" >/dev/null || { echo "${RED}[ERROR]${RESET} Missing: $1"; exit 1; }
}
require socat
require jq
require qemu-img

list_vms() {
  echo "${CYAN}[INFO]${RESET} Available VMs:"
  find "$HOME/VMs" -type d -name "*.utm" | while read -r bundle; do
    vm=$(basename "$bundle" .utm)
    echo "${indent}- $vm"
  done
}

usage() {
  echo ""
  echo "OVERVIEW: CLI tool for managing UTM/QEMU snapshots."
  echo ""
  echo "USAGE: vmctl.sh <vm> <subcommand> [options]"
  echo ""
  echo "OPTIONS:"
  echo "  -h, --help              Show help information."
  echo ""
  echo "SUBCOMMANDS:"
  echo "  status                  Show the current status of the VM."
  echo "  save-disk <label>       Create a disk snapshot with the given label."
  echo "  list-disk               List available disk snapshots."
  echo "  restore-disk <label>    Restore a disk snapshot by label."
  echo "  delete-disk <label>     Delete a disk snapshot by label."
  echo "  man                     Show the manual page."
  echo "  help                    Show this usage message."
  echo ""
  echo "AVAILABLE VMs"
  echo "============="
  i=1
  find "$HOME/VMs" -type d -name "*.utm" 2>/dev/null | while read -r bundle; do
    vm=$(basename "$bundle" .utm)
    echo "${indent}$i. -> $vm"
    i=$((i + 1))
  done
  echo ""
  exit 1
}

if [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ "$1" = "help" ]; then
  usage
fi

if [ "$1" = "man" ]; then
  man "$(dirname "$0")/vmctl.1"
  exit 0
fi

VM_NAME="$1"
COMMAND="$2"
ARG="$3"

[ -n "$VM_NAME" ] || usage

QMP_SOCKET="/tmp/${VM_NAME}.qmp"
VM_BASE=${VM_NAME%.vm}
VM_BUNDLE=$(find "$HOME/VMs" -type d -name "$VM_BASE.utm" | head -n 1)
[ -d "$VM_BUNDLE" ] || { echo "${RED}[ERROR]${RESET} Could not locate .utm bundle for $VM_NAME"; exit 1; }

META_DIR="$HOME/VMs/meta"
META_FILE="$META_DIR/${VM_NAME}.json"
mkdir -p "$META_DIR"

qmp() {
  for i in $(seq 1 10); do
    OUT=$(doas socat - UNIX-CONNECT:"$QMP_SOCKET" 2>/dev/null <<EOF
{ "execute": "qmp_capabilities" }
$1
EOF
)
    [ -n "$OUT" ] && echo "$OUT" && return 0
    sleep 0.2
  done
  return 1
}

warn_unsupported_qmp() {
  echo "${YELLOW}[WARNING]${RESET} QMP live snapshots are not supported with -accel hvf."
  echo "${CYAN}[INFO]${RESET} Use save-disk / restore-disk / list-disk instead."
  exit 1
}

list_snapshots() {
  warn_unsupported_qmp
}

save_snapshot() {
  warn_unsupported_qmp
}

delete_snapshot() {
  warn_unsupported_qmp
}

restore_snapshot() {
  warn_unsupported_qmp
}

status() {
  if doas pgrep -f "qemu.*-name $VM_NAME" >/dev/null; then
    echo "${GREEN}[OK]${RESET} $VM_NAME is running."
  else
    echo "${RED}[INFO]${RESET} $VM_NAME is not running."
  fi
}

save_disk_snapshot() {
  TS=$(date +%Y-%m-%dT%H-%M-%S)
  NAME="${TS}-${ARG:-auto}"
  SNAPSHOTS=[]
  for img in "$VM_BUNDLE"/Data/*.qcow2; do
    qemu-img snapshot -c "$NAME" "$img"
    SNAPSHOTS=$(echo "$SNAPSHOTS" | jq --arg f "$img" '. + [$f]')
  done
  echo "${GREEN}[OK]${RESET} Disk snapshot '$NAME' created for all disks."
  echo "{ \"snapshot\": \"$NAME\", \"time\": \"$TS\", \"disks\": $SNAPSHOTS }" >> "$META_FILE"
}

list_disk_snapshots() {
  LAUNCHER="$HOME/bin/LauncherScripts/${VM_NAME}-tmux.sh"
  if [ -f "$LAUNCHER" ]; then
    fullscript="$(tr '\n' ' ' < "$LAUNCHER")"
    echo "$fullscript" | grep -o "\-drive[^ ]*[^']*file='[^']*'[^ ]*" | while read -r block; do
      id=$(echo "$block" | grep -o "id=[^, ]*" | cut -d= -f2)
      file=$(echo "$block" | grep -o "file='[^']*'" | cut -d"'" -f2)
      [ "${file#/}" = "$file" ] && file="$VM_BUNDLE/$file"
      [ -n "$id" ] && [ -n "$file" ] && echo "$id|$file"
    done > /tmp/${VM_NAME}_drive_map.txt
  fi

  for img in "$VM_BUNDLE"/Data/*.qcow2; do
    id="unknown"
    if [ -f /tmp/${VM_NAME}_drive_map.txt ]; then
      img_abs=$(realpath "$img")
      id=$(awk -F'|' -v path="$img_abs" '$2 == path { print $1 }' /tmp/${VM_NAME}_drive_map.txt)
    fi

    echo ""
    echo "${BLUE}[INFO]${RESET} Disk: $(basename "$img") [ID: $id]"
    printf "\n"
    printf "%-4s %-45s %-40s\n" "ID" "TAG" "DATE"
    echo "-----------------------------------------------------------------------"
    qemu-img snapshot -l "$img" | tail -n +3 | awk -F '[[:space:]]+' '
      {
        id = $1
        tag = $2
        date = $5 " " $6
        printf "%-4s %-45s %-40s\n", id, tag, date
      }'
 #   echo "-----------------------------------------------------------------------"
  done
}

restore_disk_snapshot() {
  [ -n "$ARG" ] || { echo "${RED}[ERROR]${RESET} Usage: $0 $VM_NAME restore-disk <name>"; exit 1; }
  for img in "$VM_BUNDLE"/Data/*.qcow2; do
    qemu-img snapshot -a "$ARG" "$img"
  done
  echo "${GREEN}[OK]${RESET} All disks reverted to snapshot '$ARG'."
}

delete_disk_snapshot() {
  [ -n "$ARG" ] || { echo "${RED}[ERROR]${RESET} Usage: $0 $VM_NAME delete-disk <label>"; exit 1; }
  for img in "$VM_BUNDLE"/Data/*.qcow2; do
    echo "${BLUE}[INFO]${RESET} Deleting snapshot '$ARG' from $(basename "$img")..."
    qemu-img snapshot -d "$ARG" "$img" || echo "${YELLOW}[WARNING]${RESET} Failed to delete from $img"
  done
  echo "${GREEN}[OK]${RESET} Deleted snapshot '$ARG' from all disks."
}

case "$COMMAND" in
  list)         list_snapshots       ;;
  save)         save_snapshot        ;;
  restore)      restore_snapshot     ;;
  delete-disk)  delete_disk_snapshot ;;
  status)       status               ;;
  save-disk)    save_disk_snapshot   ;;
  list-disk)    list_disk_snapshots  ;;
  restore-disk) restore_disk_snapshot;;
  *)            usage                ;;
esac