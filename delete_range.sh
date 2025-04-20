#!/bin/sh
# delete_snapshots_range.sh — Bulk snapshot deletion for vmmgr.sh-based VMs

# --------------------------
# USAGE & ARGUMENT CHECKING
# --------------------------

if [ "$#" -ne 2 ]; then
  echo ""
  echo "Bulk delete QEMU VM snapshots by index range"
  echo
  echo "USAGE:"
  echo "  $0 <vmname> <start-end>"
  echo
  echo "EXAMPLE:"
  echo "  $0 spacebsdvm 55-82"
  echo "    => Deletes snapshots #55 through #82 for VM 'spacebsdvm'"
  echo
  echo "NOTE:"
  echo "  Index numbers are taken from './vmmgr.sh snapshot <vm> list'"
  echo "  This script assumes 'vmmgr.sh' is in the current directory."
  echo ""
  exit 1
fi

VM="$1"
RANGE="$2"

START=$(echo "$RANGE" | cut -d- -f1)
END=$(echo "$RANGE" | cut -d- -f2)

# Input validation
if ! echo "$START" | grep -qE '^[0-9]+$' || ! echo "$END" | grep -qE '^[0-9]+$'; then
  echo "[ERROR] Invalid range format: must be numeric, e.g. 10-15"
  exit 1
fi

if [ "$START" -gt "$END" ]; then
  echo "[ERROR] Start index must be less than or equal to end index"
  exit 1
fi

echo "[INFO] Deleting snapshots for VM '$VM' from index $START to $END..."
echo

# --------------------------
# MAIN LOOP: DELETE SNAPSHOTS
# --------------------------

for i in $(seq "$START" "$END"); do
  SNAP=$(./vmmgr.sh snapshot "$VM" list | awk -v n="$i" '$1 == n {print $2}')
  if [ -n "$SNAP" ]; then
    echo "[INFO] Deleting snapshot #$i: $SNAP"
    ./vmmgr.sh snapshot "$VM" delete "$SNAP"
  else
    echo "[WARN] Snapshot with index $i not found for $VM, skipping."
  fi
done