
## 🧊 Snapshot Support via `vmctl.sh`

`vmmgr.sh` now supports snapshot management by delegating to a companion script, [`vmctl.sh`](https://github.com/your-org/vmctl.sh), which handles offline and live QEMU snapshots for `.utm`-style VM bundles.

This lets you use a unified CLI for both lifecycle control and snapshot creation, restoration, listing, and deletion.

---

### 📦 How It Works

If you call `vmmgr.sh` with `snapshot` as the first argument, it forwards the remaining command-line arguments to `vmctl.sh`, which is expected to live in the sibling `../vmctl/vmctl.sh` path relative to `vmmgr.sh`.

```sh
vmmgr.sh snapshot <vmname> <snapshot-subcommand> [args...]
```

This is handled by this block near the top of the script:

```sh
# Handle snapshot subcommand early (relative path)
if [ "$1" = "snapshot" ]; then
  shift
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  exec "$SCRIPT_DIR/../vmctl/vmctl.sh" "$@"
fi
```

---

### 🛠 Supported Snapshot Subcommands

These subcommands are defined in `vmctl.sh` and can vary depending on your setup, but typically include:

| Command         | Description                                |
|----------------|--------------------------------------------|
| `list-disk`     | List available disk snapshots              |
| `save-disk`     | Create a new snapshot with a label         |
| `restore-disk`  | Restore a snapshot by label or timestamp   |
| `delete-disk`   | Delete a snapshot by label or ID           |

---

### 📋 Examples

```sh
# List snapshots for a VM
vmmgr.sh snapshot alpinevm list-disk

# Save a snapshot before a risky change
vmmgr.sh snapshot alpinevm save-disk "pre-upgrade"

# Restore a snapshot
vmmgr.sh snapshot alpinevm restore-disk "pre-upgrade"

# Delete an old snapshot
vmmgr.sh snapshot alpinevm delete-disk "pre-upgrade"
```

---

### ✅ Requirements

- `vmctl.sh` must exist in `../vmctl/vmctl.sh` relative to `vmmgr.sh`
- `vmctl.sh` should be executable: `chmod +x vmctl.sh`
- It requires tools like `qemu-img`, `socat`, `jq`, and `doas`
