# Push a locally-built Docker image to the project's private GHCR.
# Source can be either a tar file (will be docker load'd first) or a local
# image reference that's already in Docker.
#
# Prerequisites: Docker Desktop running, GHCR_OWNER and GHCR_PAT env vars set.
#
# Usage:
#   $env:GHCR_OWNER = "ia-tgoetz"
#   $env:GHCR_PAT   = "<your-token>"
#   .\scripts\push-image-to-ghcr.ps1 .\edgeWithTransmission.tar ignition-edge:8.3.6

param(
    [Parameter(Mandatory = $true)] [string] $Source,
    [Parameter(Mandatory = $true)] [string] $DestTag
)

$ErrorActionPreference = "Stop"

$Owner = $env:GHCR_OWNER
$Pat   = $env:GHCR_PAT
if (-not $Owner -or -not $Pat) {
    Write-Error "GHCR_OWNER and GHCR_PAT environment variables must be set."
    exit 1
}

$OwnerLower = $Owner.ToLower()
$Remote = "ghcr.io/${OwnerLower}/${DestTag}"

Write-Host "==> Logging in to ghcr.io..." -ForegroundColor Cyan
$Pat | docker login ghcr.io -u $Owner --password-stdin

$LocalImage = $null
if (Test-Path $Source -PathType Leaf) {
    Write-Host "==> Loading image from tar: $Source" -ForegroundColor Cyan
    $LoadOutput = docker load -i $Source 2>&1
    $LoadOutput | ForEach-Object { Write-Host $_ }
    $LocalImage = ($LoadOutput | Where-Object { $_ -match '^Loaded image: (.+)$' } | Select-Object -Last 1)
    if ($LocalImage) {
        $LocalImage = ($LocalImage -replace '^Loaded image:\s*', '').Trim()
    }
    if (-not $LocalImage) {
        Write-Error "Could not determine loaded image tag from docker load output"
        exit 1
    }
    Write-Host "==> Loaded as: $LocalImage" -ForegroundColor Green
} else {
    $LocalImage = $Source
    docker image inspect $LocalImage 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "'$LocalImage' is not a tar file and is not a local image"
        exit 1
    }
}

Write-Host "==> Tagging $LocalImage -> $Remote" -ForegroundColor Cyan
docker tag $LocalImage $Remote

Write-Host "==> Pushing to GHCR (this can take a few minutes for the first push)..." -ForegroundColor Cyan
docker push $Remote

$PackageName = ($DestTag -split ':')[0]
Write-Host ""
Write-Host "Done. Image available at: $Remote" -ForegroundColor Green
Write-Host ""
Write-Host "First-time setup for this package (do once after first push):"
Write-Host "  1. Mark private: https://github.com/users/$OwnerLower/packages/container/$PackageName/settings"
Write-Host "     -> 'Change visibility' -> Private"
Write-Host "  2. Grant the repo access: same page -> 'Manage Actions access'"
Write-Host "     -> Add 'DeploymentGitActions' (or whichever repo deploys this image)"
Write-Host "     -> Role: Read"
Write-Host "  3. Update docker-compose.yml's image: line if it doesn't already point at: $Remote"
