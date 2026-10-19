# Shared by setup.ps1, setup_board.ps1 and run.ps1 (dot-sourced).

$Connection = 'open-xc7-toolchain-rootful'   # created by setup.ps1; rootful, so containers can open USB devices
$Image      = 'openxc7/toolchain-nix'

function Get-RunningMachine {
    # Only one podman machine can run at a time; starting or creating one is left to the user
    $machine = (podman machine list --format json | Out-String | ConvertFrom-Json) |
        Where-Object { $_.Running } | Select-Object -First 1
    if (-not $machine) {
        throw "No podman machine is running. Start yours with 'podman machine start', or create one with 'podman machine init --now'."
    }
    $machine
}

function Get-Connection([string]$Name) {
    (podman system connection list --format json | Out-String | ConvertFrom-Json) |
        Where-Object { $_.Name -eq $Name }
}

function Test-SameConnection($A, $B) {
    # Same address and key, i.e. both reach the same podman service
    $A -and $B -and $A.URI -eq $B.URI -and $A.Identity -eq $B.Identity
}
