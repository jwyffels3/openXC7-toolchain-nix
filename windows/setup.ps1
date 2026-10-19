# One-time setup per PC: usbipd-win + Podman, a connection to the running podman
# machine, and the openXC7 toolchain image. Boards are handled by setup_board.ps1.
# Safe to re-run: every step checks before acting.

$ErrorActionPreference = 'Stop'

# Uses whichever podman machine is running, through our own rootful connection to it,
# so the user's default connection (rootless or rootful) is never changed.
. (Join-Path $PSScriptRoot 'common.ps1')
$RepoRoot      = Split-Path $PSScriptRoot -Parent
$Containerfile = Join-Path $RepoRoot 'container\Containerfile'

function Update-SessionPath {
    # winget installs update the registry PATH, not this session's
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-Package([string]$Id, [string]$Command, [string]$Version) {
    # winget reports "already installed" as a failure exit code, so success is
    # judged by the command being available afterwards
    winget install --id $Id --exact --version $Version --accept-package-agreements --accept-source-agreements
    Update-SessionPath
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "$Id installed but '$Command' is not on PATH yet. Open a new terminal and re-run this script."
    }
}

# 1. Tools
Install-Package 'Git.Git'            'git'    '2.55.0.5'
Install-Package 'dorssel.usbipd-win' 'usbipd' '5.3.0'
Install-Package 'Podman.CLI'         'podman' '6.0.2'

# 2. Podman machine: the running one
$machine = Get-RunningMachine
Write-Host "Using running podman machine '$($machine.Name)'"

# 3. Our connection: a copy of that machine's own rootful connection under our name.
#    Re-created if it points elsewhere (another machine, or the machine was recreated).
$machineRoot = Get-Connection "$($machine.Name)-root"
$ours        = Get-Connection $Connection
if (-not $machineRoot) { throw "Podman machine '$($machine.Name)' has no rootful connection '$($machine.Name)-root'" }
if (Test-SameConnection $ours $machineRoot) {
    Write-Host "Connection '$Connection' OK"
} else {
    if ($ours) {
        podman system connection rm $Connection
        if ($LASTEXITCODE -ne 0) { throw "Could not remove the outdated podman connection '$Connection'" }
    }
    podman system connection add --identity $machineRoot.Identity $Connection $machineRoot.URI
    if ($LASTEXITCODE -ne 0) { throw "Could not add podman connection '$Connection'" }
    Write-Host "Connection '$Connection' -> $($machineRoot.URI)"
}

# 4. Toolchain image, built from this checkout (see container/Containerfile)
podman --connection $Connection image exists $Image
if ($LASTEXITCODE -ne 0) {
    Write-Host "Building $Image (first build is slow)"
    podman --connection $Connection build -t $Image -f $Containerfile $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw 'podman build failed' }
} else {
    Write-Host "Image $Image present"
}

Write-Host ''
Write-Host 'Setup done. Without a board, start the toolchain from your project folder with:'
Write-Host "  podman --connection $Connection run --rm -it -v `"`${PWD}:/workspaces/project`" -w /workspaces/project $Image"
Write-Host "With a board: $(Join-Path $PSScriptRoot 'run.ps1') -Board <model>   (see README.md)"
