#!/bin/sh
# FUCK YOU
# vmmgr.sh — VM lifecycle manager (start, stop, status, restart)
# Requires: doas, tmux, screen, qemu
# sudo launchctl enable system/com.sara.alpinevm
# sudo launchctl enable system/com.sara.spacebsdvm
# sudo chown root:wheel /Library/LaunchDaemons/com.sara.alpinevm.plist
# sudo chmod 644 /Library/LaunchDaemons/com.sara.alpinevm.plist

# FUNCTIONS:
# 1. show_help            — Display usage info and list VMsz
# 2. require              — Ensure required binaries exist
# 3. load_conf            — Load per-VM config from vm.conf
# 4. start_qemu           — Low-level QEMU launcher
# 5. start_vm             — Start VM and optionally attach
# 6. start_all            — Start All VMs 
# 7. launchd_safe_start_vm — Launch VM safely under launchd via tmux
# 8. stop_vm              — Gracefully shutdown VM
# 9. status_vm            — Report single VM status
# 10. restart_vm           — Stop + start
# 11. list_vms            — Show all valid VMs
# 12. status_all          — Show statuses for all VMs
# 13. start_attach_vm     — Start and attach to tmux
# 14. stop_all            — Stop all running VMs
# 15. attach_tmux_only    — Attach to tmux session if running

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
BASE_DIR="/Users/mcapella/VMs"
DOAS="/usr/local/bin/doas"
TMUX="/opt/homebrew/bin/tmux"

# Detect TTY for colors
if [ -t 1 ] || [ "${FORCE_COLOR:-0}" = "1" ]; then
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  CYAN="\033[36m"
  WHITE="\033[37m"
  BOLD_RED="\033[1;31m"
  RESET="\033[0m"
else
  GREEN= RED= YELLOW= BLUE= CYAN= WHITE= BOLD_RED= RESET=
fi

# 2-space indent helper
indent="  "
TIMESTAMP=$(date)

short_help() {
  echo ""
  echo "USAGE:" 
  echo "  vmmgr.sh <vmname> <subcommand>"
  echo "  vmmgr.sh snapshot <vmname> <snapshot-subcommand> [label]"
  echo ""
  echo "Try 'vmmgr.sh --help' or 'vmmgr.sh man' for more information."
  echo ""
  exit 1
}

show_help() {
  echo ""
  echo "OVERVIEW:"
  echo "  CLI tool for managing QEMU VMs using .utm bundles on macOS."
  echo "  Wraps QEMU, tmux, screen, and vmctl.sh into a simple VM lifecycle manager."
  echo ""
  echo "USAGE:"
  echo "  vmmgr.sh <vmname> <subcommand>"
  echo "  vmmgr.sh snapshot <vmname> <snapshot-subcommand> [label]"
  echo ""
  echo "OPTIONS:"
  echo "  -h, --help                Show this help information."
  echo "  man                       View the full manual page (vmmgr.1)"
  echo ""
  echo "SUBCOMMANDS:"
  echo "  start                    Start VM in tmux+screen"
  echo "  start-all                Start all configured VMs"
  echo "  tmuxed                   Start VM and attach to its tmux session"
  echo "  attach                   Attach to existing tmux session for VM"
  echo "  stop                     Gracefully shut down a VM"
  echo "  stop-all                 Stop all VMs"
  echo "  restart                  Restart the VM (stop + start)"
  echo "  status                   Show status of the VM"
  echo "  status-all, all          Show status of all VMs"
  echo "  list                     List available VMs"
  echo "  snapshot                 Delegate to vmctl.sh for snapshots"
  echo ""
  echo "SNAPSHOT SUBCOMMANDS:"
  echo "  list, save <label>, restore <label>, delete <label>"
  echo ""
  echo "EXAMPLES:"
  echo "  vmmgr.sh alpinevm start"
  echo "  vmmgr.sh alpinevm tmuxed"
  echo "  vmmgr.sh alpinevm attach"
  echo "  vmmgr.sh snapshot alpinevm save \"pre-upgrade\""
  echo "  vmmgr.sh snapshot alpinevm restore \"pre-upgrade\""
  echo ""
  echo "AVAILABLE VMs:"
  echo "================================"
  i=1
  for bundle in "$BASE_DIR"/*.utm; do
    [ -d "$bundle" ] || continue
    vm=$(basename "$bundle" .utm)
    echo "  $i. -> $vm"
    i=$((i + 1))
  done
  echo ""

}

# Early help + man handler
if [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ "$1" = "help" ]; then
  show_help
  exit 0
fi

if [ "$1" = "man" ]; then
  MANPAGE="$(dirname "$0")/vmmgr.1"
  if [ -f "$MANPAGE" ]; then
    man "$MANPAGE"
    exit 0
  else
    echo "${RED}[ERROR]${RESET} vmmgr.1 not found at $MANPAGE"
    exit 1
  fi
fi

# If no arguments provided, show short help
[ -z "$1" ] && short_help
##############################
# Handle snapshot subcommand early (relative path)
if [ "$1" = "snapshot" ]; then
  shift
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  #exec "$SCRIPT_DIR/../vmctl/vmctl.sh" "$@"
  exec "$SCRIPT_DIR/vmctl.sh" "$@"
fi
##############################

# Determine action
if [ "$1" = "list" ]       || \
   [ "$1" = "all" ]        || \
   [ "$1" = "status-all" ]  || \
   [ "$1" = "stop-all" ]    || \
   [ "$1" = "start-all" ]; then
  action="$1"
elif [ -z "$1" ] || [ -z "$2" ]; then
  show_help
  exit 1
else
  vm="$1"
  action="$2"
  conf="$BASE_DIR/$vm.utm/vm.conf"
  bundle="$BASE_DIR/$vm.utm"
fi

require() {
  command -v "$1" >/dev/null || { echo "${RED}[ERROR]${RESET} Missing: $1"; exit 1; }
}
require "$TMUX"
require "$DOAS"

load_conf() {
  [ -f "$conf" ] || { echo "${RED}[ERROR]${RESET} Config not found: $conf"; exit 1; }
  . "$conf"
  : "${VM_NAME:?Missing VM_NAME in $conf}"
  : "${QEMU:?Missing QEMU in $conf}"
  : "${QEMU_ARGS:?Missing QEMU_ARGS in $conf}"
  SESSION="$VM_NAME"
  MONITOR="/tmp/${SESSION}.monitor"
  TMUX_SOCKET="/tmp/${SESSION}.sock"
}

is_qemu_running() {
  pgrep -f "qemu.*${VM_NAME}" >/dev/null
}

is_running() {
  $TMUX -S "$TMUX_SOCKET" has-session -t "$SESSION" 2>/dev/null && is_qemu_running
}

start_qemu() {
  LOGFILE="/tmp/${SESSION}.out"
  [ -e "$LOGFILE" ] && $DOAS rm -f "$LOGFILE"
  touch "$LOGFILE"
  chmod 666 "$LOGFILE"
  $DOAS env -i PATH="$PATH" $QEMU $QEMU_ARGS >> "$LOGFILE" 2>&1 &
  QEMU_PID=$!
}

start_vm() {
  load_conf

  LAUNCHD_PLIST="/Library/LaunchDaemons/com.sara.${VM_NAME}.plist"

  # 1) Try launchd bootstrap
  if $DOAS launchctl bootstrap system "$LAUNCHD_PLIST" 2>/dev/null; then
    echo "${indent}${GREEN}[OK]${RESET} Launched ${WHITE}$VM_NAME${RESET} via launchd."
    echo "${indent}${GREEN}[OK]${RESET} QEMU running under launchd (tmux session $SESSION)"
    echo "${indent}${CYAN}[INFO]${RESET} Attach with: $DOAS $TMUX attach -t $SESSION"
    return 0
  else
    echo "${indent}${YELLOW}[WARNING]${RESET} launchd bootstrap failed or already loaded—falling back to manual start."
  fi

  # 2) Manual fallback
  if is_running; then
    echo "${indent}${GREEN}[OK]${RESET} ${WHITE}$VM_NAME${RESET} already running. Skipping start."
    return 0
  fi

  [ -S "$MONITOR" ] && $DOAS rm -f "$MONITOR"
  echo "${indent}${BLUE}[INFO]${RESET} Manually starting ${WHITE}$VM_NAME${RESET}..."

  LOGFILE="/tmp/${SESSION}.out"
  TTY_LOG="/tmp/qemu-${SESSION}-pty.log"
  TTY_WRAPPER="/tmp/${SESSION}-tty.sh"

  $DOAS rm -f "$LOGFILE" "$TTY_LOG" "$TMUX_SOCKET" "$TTY_WRAPPER"
  $DOAS touch "$LOGFILE" "$TTY_LOG"
  $DOAS chmod 666 "$LOGFILE" "$TTY_LOG"

  # Launch QEMU
  $DOAS env -i PATH="$PATH" $QEMU $QEMU_ARGS >> "$TTY_LOG" 2>&1 &

  # Detect PTY
  for i in $(seq 1 25); do
    TTY_PATH=$(grep -o '/dev/ttys[0-9]*' "$TTY_LOG" | head -n 1)
    [ -n "$TTY_PATH" ] && break
    sleep 0.2
  done

  if [ -z "$TTY_PATH" ]; then
    echo "${indent}${YELLOW}[WARNING]${RESET} No PTY detected—headless VM assumed."
    echo "${indent}${CYAN}[INFO]${RESET} QEMU is running in background. Use 'status' to verify."
    return 0
  fi

  # Wait for PTY node
  for i in $(seq 1 20); do
    [ -e "$TTY_PATH" ] && break
    sleep 0.1
  done

  # Wrap in screen + tmux
  echo "#!/bin/sh
sleep 0.5
exec screen $TTY_PATH" | $DOAS tee "$TTY_WRAPPER" >/dev/null
  $DOAS chmod +x "$TTY_WRAPPER"
  $DOAS $TMUX new-session -d -s "$SESSION" "$TTY_WRAPPER"
  $DOAS $TMUX pipe-pane -t "$SESSION" -o "cat > /tmp/${SESSION}_tmux.log"

  echo "${indent}${GREEN}[OK]${RESET} QEMU running on ${WHITE}$TTY_PATH${RESET}"
  echo "${indent}${CYAN}[INFO]${RESET} Attach with: $DOAS $TMUX attach -t $SESSION"
}

launchd_safe_start_vm() {
  load_conf

  LOGFILE="/tmp/${SESSION}.out"
  QEMU_PID_FILE="/tmp/${SESSION}.qemu.pid"
  TMUX_LOG="/tmp/${SESSION}_tmux_error.log"
  TMUX_SOCKET="/tmp/${SESSION}.sock"
  WRAP_SCRIPT="/tmp/${SESSION}-qemu-wrap.sh"

  $DOAS rm -f "$LOGFILE" "$QEMU_PID_FILE" "$TMUX_LOG" "$TMUX_SOCKET" "$WRAP_SCRIPT" 2>/dev/null
  $DOAS touch "$LOGFILE" "$QEMU_PID_FILE" "$TMUX_LOG"
  $DOAS chmod 666 "$LOGFILE" "$QEMU_PID_FILE" "$TMUX_LOG"

  echo "${BLUE}[INFO]${RESET} Starting $VM_NAME (launchd-safe tmux)..." >> "$LOGFILE"

  cat <<EOF | $DOAS tee "$WRAP_SCRIPT" >/dev/null
#!/bin/sh
TTY_LOG="/tmp/qemu-\${SESSION}-pty.log"
$QEMU $QEMU_ARGS >"\$TTY_LOG" 2>&1 &
QEMU_PID=\$!

for i in \$(seq 1 20); do
  TTY_PATH=\$(grep -o '/dev/ttys[0-9]*' "\$TTY_LOG" | head -n 1)
  [ -n "\$TTY_PATH" ] && break
  sleep 0.2
done

[ -n "\$TTY_PATH" ] && echo \$QEMU_PID > "$QEMU_PID_FILE"
echo "QEMU running on \$TTY_PATH" >> "$LOGFILE"
sleep 0.5
screen "\$TTY_PATH"

# prevent tmux from exiting at boot
while :; do sleep 86400; done
EOF

  $DOAS chmod +x "$WRAP_SCRIPT"
  $DOAS $TMUX new-session -d -s "$SESSION" "$WRAP_SCRIPT" 2>>"$TMUX_LOG"
  $DOAS chgrp staff "$TMUX_SOCKET"
  $DOAS chmod 770 "$TMUX_SOCKET"

  sleep 1

  if [ -s "$QEMU_PID_FILE" ] && ps -p "$(cat $QEMU_PID_FILE)" >/dev/null 2>&1; then
    echo "${GREEN}[OK]${RESET} QEMU running in tmux session $SESSION (PID $(cat $QEMU_PID_FILE))"
  else
    echo "${RED}[ERROR]${RESET} QEMU failed to start — check $LOGFILE or $TMUX_LOG"
  fi
}

start_all() {
  echo ""
  echo "${indent}${CYAN}========================${RESET}"
  echo "${indent}Starting all VMs..."
  echo "${indent}${CYAN}========================${RESET}"
  echo ""

  for bundle in "$BASE_DIR"/*.utm; do
    [ -d "$bundle" ] || continue
    vm=$(basename "$bundle" .utm)
    conf="$bundle/vm.conf"

    if [ ! -f "$conf" ]; then
      echo "${indent}${YELLOW}[WARNING]${RESET} $vm — missing vm.conf, skipping."
      continue
    fi

    SESSION="$vm"
    if $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null; then
      echo "${indent}${GREEN}[OK]${RESET} $vm already running. Skipping."
    else
      echo "${indent}-> Starting ${WHITE}$vm${RESET}..."
      FORCE_COLOR=1 "$0" "$vm" start 2>&1 | sed "s/^/${indent}/"
    fi
  done

  echo ""
}

stop_vm() {
  load_conf
  echo "${indent}${BLUE}[INFO]${RESET} Stopping ${WHITE}$VM_NAME${RESET}..."

  for i in $(seq 1 10); do
    [ -S "$MONITOR" ] && break
    sleep 0.2
  done

  if [ -S "$MONITOR" ]; then
    echo "${indent}${BLUE}[INFO]${RESET} Sending ACPI shutdown via QEMU monitor..."
    echo "system_powerdown" | $DOAS socat - UNIX-CONNECT:"$MONITOR" 2>&1 | while IFS= read -r line; do
      echo "${indent}${line}"
    done
  else
    echo "${indent}${YELLOW}[WARNING]${RESET} Monitor socket not available. Fallback to tmux signal..."
    $DOAS $TMUX send-keys -t "$SESSION" "poweroff" C-m 2>&1 | while IFS= read -r line; do
      echo "${indent}${line}"
    done
  fi

  echo "${indent}${BLUE}[INFO]${RESET} Waiting for VM to power down..."
  while pgrep -f "qemu.*$VM_NAME" >/dev/null; do
    sleep 1
  done

  echo "${indent}${GREEN}[OK]${RESET} VM powered down."
  [ -e "$MONITOR" ] && echo "${indent}${GREEN}[OK]${RESET} Monitor socket was cleaned up"

  LAUNCHD_PLIST="/Library/LaunchDaemons/com.sara.${VM_NAME}.plist"
  if [ -f "$LAUNCHD_PLIST" ]; then
    $DOAS launchctl bootout system "$LAUNCHD_PLIST" 2>/dev/null && \
      echo "${indent}${GREEN}[OK]${RESET} launchd service unloaded."
  fi

  $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null && $DOAS $TMUX kill-session -t "$SESSION"
  $DOAS rm -f "/tmp/${SESSION}-qemu-wrap.sh" "/tmp/${SESSION}.sock" "/tmp/${SESSION}_tmux_error.log"

  echo "${indent}${BLUE}[INFO]${RESET} Saving disk snapshot and rotating old ones..."

  SNAP_NAME="$(date +'%Y-%m-%dT%H-%M-%S')-auto"

  for qcow in "$bundle"/Data/*.qcow2; do
    [ -f "$qcow" ] || continue

    if qemu-img snapshot -c "$SNAP_NAME" "$qcow"; then
      echo "${indent}${GREEN}[OK]${RESET} Created snapshot ${WHITE}$SNAP_NAME${RESET} on $(basename "$qcow")"
    else
      echo "${indent}${RED}[ERROR]${RESET} Failed to create snapshot on $(basename "$qcow")"
      continue
    fi

    keep=3
    snaps=$(qemu-img snapshot -l "$qcow" | awk '$2 ~ /-auto$/ {print $2}')
    count=$(echo "$snaps" | wc -l | tr -d ' ')

    if [ "$count" -gt "$keep" ]; then
      delete=$(echo "$snaps" | head -n $(($count - $keep)))
      for snap in $delete; do
        qemu-img snapshot -d "$snap" "$qcow" && \
          echo "${indent}${YELLOW}[DEL]${RESET} Removed old snapshot ${WHITE}$snap${RESET} from $(basename "$qcow")"
      done
    else
      echo "${indent}${CYAN}[INFO]${RESET} Only $count auto snapshots exist on $(basename "$qcow"); nothing to delete."
    fi
  done
}

stop_all() {
echo ""
  echo "${indent}${CYAN}========================${RESET}"
  echo "${indent}Shutting down all VMs..."
  echo "${indent}${CYAN}========================${RESET}"
  
  for bundle in "$BASE_DIR"/*.utm; do
    [ -d "$bundle" ] || continue
    vm=$(basename "$bundle" .utm)
    echo "-> Stopping $vm..."
    "$0" "$vm" stop
  done
}

status_vm() {
  load_conf
  echo ""
  echo "${indent}${CYAN}========================${RESET}"
  echo "${indent}Status for VM: ${WHITE}$VM_NAME${RESET}"
  echo "${indent}${CYAN}========================${RESET}"
  echo ""

  LAUNCHD_LABEL="com.sara.${VM_NAME}"

  if $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null; then
    echo "${indent}${indent}${GREEN}[RUNNING]${RESET} ${WHITE}$VM_NAME${RESET} (tmux)"
  elif [ -f "/tmp/${SESSION}.qemu.pid" ] && ps -p "$(cat /tmp/${SESSION}.qemu.pid)" >/dev/null 2>&1; then
    echo "${indent}${indent}${GREEN}[RUNNING]${RESET} ${WHITE}$VM_NAME${RESET} (headless)"
  else
    echo "${indent}${indent}${RED}[STOPPED]${RESET} ${WHITE}$VM_NAME${RESET}"
  fi

  if $DOAS launchctl list | grep -q "$LAUNCHD_LABEL"; then
    echo "${indent}${indent}${CYAN}[INFO]${RESET}      └── LaunchDaemon ${WHITE}$LAUNCHD_LABEL${RESET} is loaded."
  else
    echo "${indent}${indent}${YELLOW}[WARNING]${RESET}   └── LaunchDaemon ${WHITE}$LAUNCHD_LABEL${RESET} is NOT loaded."
  fi

  echo ""
  printf "${indent}${CYAN}=== VM check at ${WHITE}%s ${CYAN}===${RESET}\n" "$TIMESTAMP"
  echo ""
}

restart_vm() {
  stop_vm && start_vm
}

list_vms() {
  echo ""
  echo "${indent}${CYAN}========================${RESET}"
  echo "${indent}Available VMs:"
  echo "${indent}${CYAN}========================${RESET}"
  echo ""

  for bundle in "$BASE_DIR"/*.utm; do
    [ -d "$bundle" ] || continue
    vm=$(basename "$bundle" .utm)
    conf="$bundle/vm.conf"
    [ ! -f "$conf" ] && echo "${indent}${YELLOW}[WARNING]${RESET} $vm — missing vm.conf" && continue
    [ -f "$bundle/.disabled" ] && echo "${indent}${RED}[DISABLED]${RESET} $vm" && continue
    . "$conf"
    $DOAS $TMUX has-session -t "$VM_NAME" 2>/dev/null && \
      echo "${indent}${GREEN}[RUNNING]${RESET} $vm" || echo "${indent}${RED}[STOPPED]${RESET} $vm"
  done

  echo ""
}

status_all() {
  echo ""
  echo "${indent}${CYAN}========================${RESET}"
  echo "${indent}VM Status Overview:"
  echo "${indent}${CYAN}========================${RESET}"
  echo ""

  for bundle in "$BASE_DIR"/*.utm; do
    [ -d "$bundle" ] || continue
    vm=$(basename "$bundle" .utm)
    conf="$bundle/vm.conf"
    [ ! -f "$conf" ] && echo "${indent}${YELLOW}[WARNING]${RESET} $vm — missing vm.conf" && continue
    . "$conf"
    SESSION="$VM_NAME"
    LAUNCHD_LABEL="com.sara.${VM_NAME}"

    if $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null; then
      echo "${indent}${GREEN}[RUNNING]${RESET} $vm (tmux)"
    elif [ -f "/tmp/${SESSION}.qemu.pid" ] && ps -p "$(cat /tmp/${SESSION}.qemu.pid)" >/dev/null 2>&1; then
      echo "${indent}${GREEN}[RUNNING]${RESET} $vm (headless)"
    else
      echo "${indent}${RED}[STOPPED]${RESET} $vm"
    fi

    if $DOAS launchctl list | grep -q "$LAUNCHD_LABEL"; then
      echo "${indent}${CYAN}[INFO]${RESET}    └── LaunchDaemon $LAUNCHD_LABEL is loaded."
    else
      echo "${indent}${YELLOW}[WARNING]${RESET} └── LaunchDaemon $LAUNCHD_LABEL is NOT loaded."
    fi

    echo ""
  done

  printf "${indent}${CYAN}=== VM check at ${WHITE}%s ${CYAN}===${RESET}\n" "$TIMESTAMP"
  echo ""
}

start_attach_vm() {
  load_conf
  if ! $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null; then
    start_vm
    for i in $(seq 1 6); do
      $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null && break
      sleep 0.5
    done
  fi

  if $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null; then
    exec $DOAS $TMUX attach -t "$SESSION"
  else
    echo "${YELLOW}[WARNING]${RESET} No tmux session found for $VM_NAME — VM is likely headless."
    echo "${CYAN}[INFO]${RESET} Use 'vmmgr.sh $VM_NAME status' or check logs manually."
    exit 0
  fi
}

attach_tmux_only() {
  load_conf
  if $DOAS $TMUX has-session -t "$SESSION" 2>/dev/null; then
    exec $DOAS $TMUX attach -t "$SESSION"
  else
    echo "${RED}[ERROR]${RESET} No tmux session found for $VM_NAME — VM is not running or is headless."
    exit 1
  fi
}



# Dispatch
case "$action" in
  start)          start_vm                ;;
  stop)           stop_vm                 ;;
  restart)        restart_vm              ;;
  status)         status_vm               ;;
  list)           list_vms                ;;
  all|status-all) status_all              ;;
  start-all)      start_all               ;;
  stop-all)       stop_all                ;;
  launchd-start)  launchd_safe_start_vm   ;;
  tmuxed)         start_attach_vm         ;;
  attach)         attach_tmux_only        ;;
  man)            show_man_page            ;;
  *)
    echo "Usage:"
    echo "  $0 <vmssss> {start|stop|restart|status|status-all|tmuxed|attach|list|all}"
    echo "  $0 snapshot <vm> {list|create|restore|delete}"
    exit 1
    ;;
esac
