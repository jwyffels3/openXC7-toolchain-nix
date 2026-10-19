<#
.SYNOPSIS
Example: starts the openXC7 toolchain on the current folder with your board attached.

.DESCRIPTION
Shows how setup_board.ps1 is meant to be used: it attaches the board and returns the
podman flags, and this script adds them to a `podman run` of the toolchain image.
Arguments are passed to setup_board.ps1 (e.g. -Board basys3, -Serial ...).

.EXAMPLE
run.ps1                  # registered board, found by serial
run.ps1 -Board basys3    # first time: registers a basys3
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
$board = & (Join-Path $PSScriptRoot 'setup_board.ps1') @args
$mount = '/workspaces/' + (Split-Path $PWD.Path -Leaf)

podman $board.ConnectionArgs run --rm -it $board.RunArgs -v "$($PWD.Path):$mount" -w $mount $Image
