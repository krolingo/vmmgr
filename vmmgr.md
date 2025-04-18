# VM Manager (`vmmgr.sh`) Documentation

![screenshot_2025-04-16_at_18.52.57.png](/images/vmmgr/screenshot_2025-04-16_at_18.52.57.png)


## OVERVIEW
CLI tool for managing QEMU virtual machines using `.utm` bundles on macOS. Designed to be used with `tmux`, `screen`, `launchd`, and optionally `doas`.

## USAGE
```sh
vmmgr.sh <vmname> <subcommand>
```

## OPTIONS
```
-h, --help              Show help information.
```

## SUBCOMMANDS
| Command         | Description                                             |
|----------------|---------------------------------------------------------|
| start          | Start VM using launchd or fallback to manual           |
| start-all      | Loop through all .utm bundles and start each           |
| tmuxed         | Start a VM then attach to its tmux session             |
| attach         | Attach to an existing VM tmux session                  |
| stop           | Gracefully shut down the specified VM                  |
| stop-all       | Shut down all VMs found in the base directory          |
| restart        | Stop then start the specified VM                       |
| status         | Show current status of a VM                            |
| status-all     | Show statuses of all VMs                               |
| list           | List all detected VMs                                  |

## EXAMPLES
```sh
vmmgr.sh alpinevm start
vmmgr.sh alpinevm tmuxed
doas tmux attach -t alpinevm
vmmgr.sh alpinevm attach
```

<img src="/images/vmmgr/screenshot_2025-04-16_at_18.44.37.png" alt="screenshot" width="600">

![screenshot_2025-04-16_at_18.52.57.png](/images/vmmgr/screenshot_2025-04-16_at_18.52.57.png)
![screenshot_2025-04-16_at_18.52.57.png](/images/vmmgr/screenshot_2025-04-16_at_18.44.37.png)

## SUBCOMMAND DETAILS

| Subcommand         | Description                                                                                         |
|--------------------|-----------------------------------------------------------------------------------------------------|
| `start`            | Starts a VM using `launchd` if available; otherwise runs QEMU manually via `screen` and `tmux`. Skips if already running. |
| `start-all`        | Loops through all `.utm` bundles and runs `start` on each.                                          |
| `tmuxed`           | Runs `start` and attaches to the VM’s `tmux` session once active.                                   |
| `attach`           | Attaches to the existing `tmux` session for a running VM.                                           |
| `stop`             | Sends `system_powerdown` via QEMU monitor; falls back to `poweroff` via `tmux`; cleans up files.    |
| `stop-all`         | Runs `stop` on all `.utm` bundles found.                                                            |
| `restart`          | Runs `stop`, waits for full shutdown, then runs `start` again.                                      |
| `status`           | Displays whether QEMU is running, `tmux` is active, and `launchd` is loaded for a given VM.         |
| `status-all` / `all` | Runs `status` on every VM and presents a system-wide overview.                                   |
| `list`             | Lists all `.utm` VMs and their states (running, stopped, or disabled).                              |



## QEMU VM CREATION WORKFLOW

Virtual machines are defined and launched via QEMU directly. A typical creation workflow looks like this:

QEMU Command Line First — You manually test and construct a working QEMU command to launch your VM using flags like `-machine`, `-cpu`, `-drive`, `-nographic`, etc.

Export to vm.conf — Once validated, this command is broken down into variables and saved in a vm.conf file under the corresponding .utm bundle:

```
VM_NAME="alpinevm"
QEMU="/opt/homebrew/bin/qemu-system-x86_64"
QEMU_ARGS="-m 512 -smp 2 -hda alpine.qcow2 -nographic -serial mon:unix:/tmp/alpinevm.monitor,server,nowait"
```

Bundle Layout — Each VM lives in ~/VMs/<vmname>.utm/. Inside this directory:

vm.conf defines how to launch it

The main disk (`*.qcow2`) and support files (UEFI firmware, efivars, etc.) live in Data/

Driver Pool — A separate directory `~/VMs/qemu/` acts as a shared pool of reusable QEMU drivers and firmware:

OVMF UEFI images

VirtIO drivers

Optional kernel/initrd for Linux VMs

Launch Integration — vmmgr.sh reads vm.conf and executes the defined QEMU binary with args inside a controlled tmux+screen session, optionally launched by macOS launchd.

This approach enables precise, minimal QEMU usage while remaining organized and reboot-persistent.




## VM CREATION USING UTM + QEMU ARG EXPORT

You can create new virtual machines using the UTM app on macOS, then extract and reuse the QEMU arguments to run them directly via `vmmgr.sh`.

### 1. **Create the VM in UTM**
- Launch UTM and create a new VM using the GUI.
- Configure the VM's CPU, memory, drives, and networking as desired.
- Boot and verify that the VM works as expected.

### 2. **Export the QEMU Arguments**
- Open UTM, select the VM, and click the **Info** button.
- Go to the **QEMU** tab and copy the full QEMU command.
- This includes the `qemu-system-*` binary and all flags.

### 3. **Convert to `vm.conf`**
Create a new file at `~/VMs/<name>.utm/vm.conf` and convert the copied command into two variables:

```sh
VM_NAME="alpinevm"
QEMU="/opt/homebrew/bin/qemu-system-x86_64"
QEMU_ARGS="-machine q35 -cpu host -m 2048 -smp 2 -hda alpine.qcow2 -nographic -serial mon:unix:/tmp/alpinevm.monitor,server,nowait"
```

### 4. **Copy Required Drivers to `~/VMs/qemu/`**
Some VMs (especially Windows or Linux with UEFI) may rely on drivers or firmware.

You can copy the following into `~/VMs/qemu/`:

```sh
mkdir -p ~/VMs/qemu

# Copy from UTM's cache directory:
cp ~/Library/Containers/com.utmapp.UTM/Data/Library/Caches/qemu/edk2-*.fd ~/VMs/qemu/
cp ~/Library/Containers/com.utmapp.UTM/Data/Library/Caches/qemu/virtio*.iso ~/VMs/qemu/
```

Common files include:
- `edk2-x86_64-code.fd` (UEFI BIOS)
- `virtio-win.iso` (Windows drivers)
- `efi_vars.fd` (UEFI vars file)

### 5. **Run via vmmgr**
Now that `vm.conf` is ready and drivers are staged, you can start the VM with:

```sh
vmmgr.sh alpinevm start
```

This workflow makes VM portability and headless operation easy without launching UTM at all.


## INTERNALS AND WHY THEY WORK
- **`tmux`** keeps session state even after QEMU exits; great for debugging.
- **`screen`** ensures that QEMU attaches to a PTY, giving a terminal interface for systems without framebuffer.
- **`launchd`** integration allows macOS boot-time auto-start.
- **`socat`** lets us talk to QEMU monitor socket for controlled shutdowns.
- **Logs** and **state files** are placed in `/tmp/` to avoid clutter and require no cleanup after reboot.

## EXAMPLE VM CONFIG (`vm.conf`)
```sh
VM_NAME="server2bsd"
QEMU="/opt/local/bin/qemu-system-x86_64"

QEMU_ARGS="\
-machine q35,accel=hvf \
-cpu IvyBridge \
-smp cpus=16,sockets=1,cores=8,threads=2 \
-m 4096 \
-chardev pty,id=char0 -serial chardev:char0 \
-display none \
-monitor unix:/tmp/${VM_NAME}.monitor,server,nowait \
-drive if=pflash,format=raw,unit=0,file=/Users/<$USER>/Library/Containers/com.utmapp.UTM/Data/Library/Caches/qemu/edk2-x86_64-code.fd,readonly=on \
-drive if=pflash,unit=1,file=/Users/<$USER>/VMs/server2bsd.utm/Data/efi_vars.fd \
-drive if=none,id=disk0,file=/Users/<$USER>/VMs/server2bsd.utm/Data/FreeBSD-14.2-RELEASE-amd64-BASIC-CLOUDINIT.zfs.qcow2,format=qcow2,discard=unmap,detect-zeroes=unmap \
-device virtio-blk-pci,drive=disk0,bootindex=1 \
-netdev vmnet-bridged,id=net0,ifname=en0 \
-device virtio-net-pci,mac=26:7C:31:43:15:B6,netdev=net0 \
-device virtio-serial \
-device virtio-rng-pci \
-name ${VM_NAME} \
-uuid A2F3B4C3-8E35-43B9-9C61-78C4D7D01D59 \
-monitor unix:/tmp/${VM_NAME}.monitor,server,nowait"
```

## EXAMPLE LAUNCHDAEMON .PLIST
```XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.sara.server2bsd</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>/Users/<$USER>/bin/vmmgr.sh</string>
		<string>server2bsd</string>
		<string>launchd-start</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/server2bsd.out</string>
	<key>StandardErrorPath</key>
	<string>/tmp/server2bsd.err</string>
</dict>
</plist>
```

## DETECTED VMs
```
  1. -> FreeBSD 14.2 Multi-VNET
  2. -> alpine
```
