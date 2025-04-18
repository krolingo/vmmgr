# vmctl.sh — Snapshot Manager for QEMU/UTM Virtual Machines

## NAME
`vmctl.sh` - snapshot manager for QEMU .utm virtual machines

## SYNOPSIS
```sh
vmctl.sh <vm-name> <command> [label]
```

## DESCRIPTION
`vmctl.sh` is a shell utility for managing internal disk snapshots of QEMU virtual machines using `qemu-img`. It supports multi-disk `.utm` bundles and allows saving, restoring, listing, and deleting snapshots.

Snapshots are stored internally in each `.qcow2` disk and do not require separate files or folders. The tool ensures metadata is logged for traceability and integrates with launch-time VM configurations.

## Why This Script Exists
QEMU's `-accel hvf` does not support live snapshots via QMP, so this tool focuses on **offline disk snapshots** using `qemu-img`. Unlike other snapshot tools, it handles multiple `.qcow2` disks, indexes metadata, and provides a unified interface for:
- Listing all installed VMs
- Saving/restoring/deleting disk snapshots
- Logging metadata to JSON
- Verifying snapshot consistency

## Features
- Works with multi-disk `.utm` VMs
- Offline snapshots only (when VM is not running)
- Per-disk snapshot creation and restoration
- Metadata file for tracking snapshot history
- Optionally maps drive IDs from custom launch scripts

## Requirements
- `qemu-img`
- `jq`
- `socat`
- `doas` (or substitute `sudo`)

## File Layout
- VMs: `~/VMs/*.utm`
- Disk images: `~/VMs/<vm>.utm/Data/*.qcow2`
- Metadata: `~/VMs/meta/<vm>.json`

## COMMANDS
- `status`               — Show whether the specified VM is currently running
- `save-disk [label]`    — Save an internal snapshot of each `.qcow2` disk (label optional)
- `list-disk`            — List all internal snapshots in each `.qcow2` disk
- `restore-disk <label>`— Revert all `.qcow2` disks to the specified snapshot
- `delete-disk <label>` — Delete the named internal snapshot from each disk
- `help` / `--help`      — Show help and usage info
- `man`                  — Show the manual page

## EXAMPLES
```sh
# Check VM status
vmctl.sh spacebsdvm status

# Save a disk snapshot with optional label
vmctl.sh alpinevm save-disk nightly

# Restore a snapshot
vmctl.sh alpinevm restore-disk 2025-04-14T10-00-00-auto

# Delete a snapshot
vmctl.sh alpinevm delete-disk 2025-04-14T10-00-00-auto

# List snapshots
vmctl.sh alpinevm list-disk
```

## NOTES
- Snapshot labels include a timestamp prefix for uniqueness
- Never use this while the VM is running — always shut down first
- All disks in `Data/` will be snapshotted or restored as a unit

## How It Works
### Snapshot Save (save-disk)
- Uses `qemu-img snapshot -c <name>` on each `.qcow2` disk
- Generates a label: `YYYY-MM-DDTHH-MM-SS-label`
- Saves metadata in `~/VMs/meta/<vm>.json`

### Snapshot Restore (restore-disk)
- Uses `qemu-img snapshot -a <label>` on each `.qcow2` disk

### Snapshot Delete (delete-disk)
- Uses `qemu-img snapshot -d <label>` on each `.qcow2` disk
- Removes metadata entry from JSON (if implemented)

### Snapshot List (list-disk)
- Calls `qemu-img snapshot -l <disk>`
- Maps drive IDs from any custom `-drive` lines found in the launcher script
- Outputs drive ID, snapshot name, and date

## Output Format
Each snapshot listing shows:
```text
📦   [drive_id] diskname.qcow2
ID   TAG                                      DATE
---  ---------------------------------------  ------------------------
1    2024-04-09T12-00-00-nightly              Tue Apr  9 12:00:00 2024
```

## QMP Support
While QMP commands for live snapshots exist, they do not work with `-accel hvf`. Therefore, the `save`, `restore`, `delete`, and `list` QMP-based commands currently emit warnings and exit. Support for TCG-based QMP snapshots may be added later.

## Metadata File Format
Each disk snapshot is logged as a JSON object like:
```json
{
  "snapshot": "2024-04-09T12-00-00-nightly",
  "time": "2024-04-09T12:00:00",
  "disks": [
    "/Users/mcapella/VMs/alpinevm.utm/Data/disk0.qcow2",
    "/Users/mcapella/VMs/alpinevm.utm/Data/disk1.qcow2"
  ]
}
```

## Conclusion
`vmctl.sh` is a lightweight snapshot controller for `.utm` VMs that works reliably under macOS. It is best used in combination with lifecycle scripts like `vmmgr.sh` to enforce safe shutdown before snapshot operations. Future work may include automatic pruning, tagging, or rollback chains.

---
For questions or updates, refer to the companion script `vmmgr.sh` for lifecycle control.

