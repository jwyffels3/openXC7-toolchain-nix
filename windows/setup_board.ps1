<#
.SYNOPSIS
Attaches your FPGA board to WSL and returns what a podman container needs to use it.

.DESCRIPTION
Finds the board, shares and attaches it with usbipd, and returns an object with:
  ConnectionArgs  podman's --connection flag for setup.ps1's rootful connection,
                  checked to point at the running podman machine
  RunArgs         the flags to add to `podman run` (any image, entrypoint, command or mounts)
See run.ps1 for an example.

The flags give the container live access to the board: USB devices (JTAG, for
openFPGALoader) at /dev/bus/usb and serial ports (the UART) at /dev/host/ttyUSB*,
plus BOARD, PART and FAMILY from boards.json.

Boards are identified by their USB serial number. The first time a board is used on
this PC, it is registered in %LOCALAPPDATA%\openXC7\boards.local.json
(serial -> board, vid, pid) by asking you to unplug and replug it. After that it is
found automatically on any USB port, from any project.

.PARAMETER Board
Board model from boards.json. Required to register a new board; otherwise it narrows
the search to registered boards of that model.

.PARAMETER Serial
Use the connected board with this USB serial. With -Board, registers it without
prompting (for automation).

.EXAMPLE
$board = setup_board.ps1                                  # registered board, found by serial
$board = setup_board.ps1 -Board basys3                    # registers a new basys3 if none is known
$board = setup_board.ps1 -Serial 210183BD45BB -Board basys3
podman $board.ConnectionArgs run --rm -it $board.RunArgs <your image> <command>
#>
param(
    [string]$Board,
    [string]$Serial
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
$Setup       = Join-Path $PSScriptRoot 'setup.ps1'
$BoardsFile  = Join-Path $PSScriptRoot 'boards.json'
$LocalFile   = Join-Path $env:LOCALAPPDATA 'openXC7\boards.local.json'   # per PC, shared by all projects
$Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

function Get-UsbDevices {
    # Connected USB devices from usbipd. InstanceId looks like USB\VID_0403&PID_6010\<serial>;
    # when a device has no serial, Windows generates one containing '&'.
    foreach ($d in (usbipd state | Out-String | ConvertFrom-Json).Devices) {
        if (-not $d.BusId) { continue }   # shared but not plugged in

        $prefix, $ids, $serial = $d.InstanceId.Split('\')
        $vendorId, $productId = $ids.Split('&')
        if ($serial.Contains('&')) { $serial = $null }

        [pscustomobject]@{
            InstanceId = $d.InstanceId
            BusId      = $d.BusId
            Vid        = $vendorId.Replace('VID_', '')
            Pid        = $productId.Replace('PID_', '')
            Serial     = $serial
            Name       = $d.Description
            Shared     = [bool]$d.PersistedGuid
            Attached   = [bool]$d.ClientIPAddress
            Board      = $null   # board model, once known
        }
    }
}

function Read-Registry {
    $reg = @{}
    if (Test-Path $LocalFile) {
        $json = Get-Content $LocalFile -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $reg[$p.Name] = $p.Value }
    }
    $reg
}

function Register-Device($Device, [string]$Model) {
    if (-not $Device.Serial) {
        Write-Warning "This board has no USB serial number, so it can't be remembered. You'll be asked again next run."
        return
    }
    $reg = Read-Registry
    $reg[$Device.Serial] = [pscustomobject]@{ board = $Model; vid = $Device.Vid; pid = $Device.Pid }
    New-Item -ItemType Directory -Force (Split-Path $LocalFile) | Out-Null
    $reg | ConvertTo-Json | Set-Content $LocalFile -Encoding utf8
    Write-Host "Registered $Model (serial $($Device.Serial), $($Device.Vid):$($Device.Pid)) in $LocalFile"
}

function Read-Choice([string[]]$Items, [string]$Prompt) {
    # Numbered menu; returns the chosen item's index
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host "  [$($i + 1)] $($Items[$i])" }
    $n = 0
    if (-not [int]::TryParse((Read-Host $Prompt), [ref]$n) -or $n -lt 1 -or $n -gt $Items.Count) {
        throw 'Invalid choice'
    }
    $n - 1
}

function Select-RegisteredBoard($Candidates) {
    $Candidates = @($Candidates)
    if ($Candidates.Count -eq 1) { return $Candidates[0] }
    $labels = $Candidates | ForEach-Object { "serial $($_.Serial)  board $($_.Board)  bus $($_.BusId)" }
    if (-not $Interactive) {
        throw "Several registered boards connected; pass -Serial to pick one:`n  $($labels -join "`n  ")"
    }
    Write-Host 'Several registered boards connected:'
    $Candidates[(Read-Choice $labels 'Which one')]
}

function Select-BoardModel {
    # Asks which model from boards.json to register; $null if the user doesn't want to
    $models = @($Boards.PSObject.Properties.Name)
    if (-not $Interactive) {
        throw "No registered board connected. Register one with -Board <name> (models: $($models -join ', '))."
    }
    $answer = Read-Host 'No registered board is connected. Register a new board now? [y/N]'
    if ($answer -ne 'y') { return $null }

    Write-Host 'Which board is it?'
    $choice = Read-Choice ($models + 'Not listed') 'Choice'
    if ($choice -lt $models.Count) { return $models[$choice] }

    Write-Host ''
    Write-Host "Your board isn't listed yet. To add it, add an entry to $BoardsFile :"
    Write-Host '  "<name>": {'
    Write-Host '    "openfpgaloader": "<board name from: openFPGALoader --list-boards>",'
    Write-Host '    "part": "<FPGA part, e.g. xc7a35tcpg236-1>",'
    Write-Host '    "family": "<artix7, kintex7, spartan7 or zynq7>"'
    Write-Host '  }'
    Write-Host 'then run this again and pick it.'
    return $null
}

function Find-ByReplug([string]$Model) {
    if (-not $Interactive) {
        throw "Board not registered yet. Run interactively once, or pass -Serial <serial> -Board $Model."
    }
    Read-Host "Unplug the $Model, then press Enter" | Out-Null
    $before = @(Get-UsbDevices | ForEach-Object { $_.InstanceId })
    Write-Host "Now plug it back in (waiting up to 60 s)..."
    for ($t = 0; $t -lt 60; $t++) {
        Start-Sleep -Seconds 1
        $new = @(Get-UsbDevices | Where-Object { $before -notcontains $_.InstanceId })
        if ($new.Count -eq 1) { return $new[0] }
        if ($new.Count -gt 1) { throw 'More than one new USB device appeared; plug in only the board and try again.' }
    }
    throw 'No new USB device appeared within 60 s.'
}

function Resolve-Board([string]$Model, [string]$Serial) {
    $devices  = @(Get-UsbDevices)
    $registry = Read-Registry

    # Registered boards that are connected right now: serial, vid and pid must all match
    $known = @()
    foreach ($dev in $devices) {
        $entry = if ($dev.Serial) { $registry[$dev.Serial] }
        if (-not $entry -or $entry.vid -ne $dev.Vid -or $entry.pid -ne $dev.Pid) { continue }
        if ($Model -and $entry.board -ne $Model) { continue }
        $dev.Board = $entry.board
        $known += $dev
    }

    if ($Serial) {
        $hit = $known | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
        if ($hit) { return $hit }
        $dev = $devices | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
        if (-not $dev) { throw "No connected USB device has serial '$Serial'." }
        if (-not $Model) { throw "Serial '$Serial' is not registered; add -Board <name> to register it." }
        Register-Device $dev $Model
        $dev.Board = $Model
        return $dev
    }

    if ($known) { return Select-RegisteredBoard $known }

    if (-not $Model) { $Model = Select-BoardModel }
    if (-not $Model) { throw 'No board registered.' }
    $dev = Find-ByReplug $Model
    Register-Device $dev $Model
    $dev.Board = $Model
    $dev
}

# Prerequisites from setup.ps1: tools, and our connection pointing at the running machine,
# which is where the board gets attached
foreach ($c in 'podman', 'usbipd') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c not found. Run $Setup first." }
}
$machine = Get-RunningMachine
if (-not (Test-SameConnection (Get-Connection $Connection) (Get-Connection "$($machine.Name)-root"))) {
    throw "Podman connection '$Connection' is missing or doesn't point at the running machine '$($machine.Name)'. Run $Setup."
}

# Board models
$Boards = Get-Content $BoardsFile -Raw | ConvertFrom-Json
if ($Board -and -not $Boards.$Board) {
    throw "Unknown board '$Board'. Known models: $(($Boards.PSObject.Properties.Name) -join ', ')"
}

$dev = Resolve-Board $Board $Serial
Write-Host "Using $($dev.Board) (serial $($dev.Serial), bus $($dev.BusId))"

if (-not $dev.Shared) {
    # sharing a device needs admin once per PC; elevate just this command
    Write-Host "Sharing $($dev.Board) with usbipd (one-time, needs admin)"
    $p = Start-Process usbipd -ArgumentList 'bind', '--busid', $dev.BusId -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw 'usbipd bind failed' }
}
if (-not $dev.Attached) {
    usbipd attach --wsl --busid $dev.BusId | Out-Host   # keep its messages out of the returned flags
    if ($LASTEXITCODE -ne 0) { throw 'usbipd attach failed' }
}

# Bind mounts of the machine's live device folders rather than --device, which only
# copies the device files existing at container start: right after an attach the
# board's files may not exist yet, and a replug creates new ones. The cgroup rules let
# the container open them: major 189 = USB devices, 188 = USB serial ports.
$cfg = $Boards.($dev.Board)
[pscustomobject]@{
    ConnectionArgs = @('--connection', $Connection)
    RunArgs        = @(
        '-v', '/dev/bus/usb:/dev/bus/usb', '--device-cgroup-rule', 'c 189:* rmw'   # JTAG (openFPGALoader)
        '-v', '/dev:/dev/host',            '--device-cgroup-rule', 'c 188:* rmw'   # UART at /dev/host/ttyUSB*
        '-e', "BOARD=$($cfg.openfpgaloader)", '-e', "PART=$($cfg.part)", '-e', "FAMILY=$($cfg.family)"
    )
}
