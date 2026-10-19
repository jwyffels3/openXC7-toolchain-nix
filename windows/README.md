# Windows: build and flash from the toolchain container

Uses Podman (WSL machine) for the toolchain and usbipd-win to pass the board's USB
programmer into the container. Run from PowerShell, not Git Bash (Git Bash rewrites
`/paths` in arguments).

## Once per PC
```powershell
.\windows\setup.ps1
```
Installs Git, usbipd-win and Podman (pinned versions via winget), then uses your
**running** podman machine: start it first (`podman machine start`, or
`podman machine init --now` if you have none). The scripts never start, stop or
create machines. Setup adds a rootful connection to that machine named
`open-xc7-toolchain-rootful` (your default connection is left alone) and builds the
toolchain image from this checkout (`container/Containerfile`).

## Every time
From your project folder, start the toolchain with your board attached:
```powershell
<path to this repo>\windows\run.ps1                  # board found by serial number
<path to this repo>\windows\run.ps1 -Board basys3    # first time: register a basys3
```
Your project is mounted at `/workspaces/<project folder name>`.

`run.ps1` is a small example built on `setup_board.ps1`, which attaches the board and
returns what a container needs to use it: `ConnectionArgs`, podman's `--connection`
flag for setup's rootful connection (checked to point at the running machine), and
the `RunArgs` flags. Use it the same way in your own scripts, with any image, mounts
and command:
```powershell
$board = <path to this repo>\windows\setup_board.ps1
podman $board.ConnectionArgs run --rm -it $board.RunArgs <your image> <command>
```
The flags give the container live access to the board (it keeps working across
replugs): USB devices for JTAG at `/dev/bus/usb`, the UART at `/dev/host/ttyUSB*`
(usually `ttyUSB1`), and `BOARD`, `PART` and `FAMILY` from `boards.json`.

The first time a board is used, you are asked to unplug and replug it; its serial
number, VID and PID are then remembered in `%LOCALAPPDATA%\openXC7\boards.local.json`,
so it is found on any USB port afterwards. Sharing the board with usbipd needs one
admin prompt per PC. With several registered boards connected, pass `-Serial`.

## Adding a board model
Add an entry to `boards.json` with its openFPGALoader board name, FPGA part and family.
