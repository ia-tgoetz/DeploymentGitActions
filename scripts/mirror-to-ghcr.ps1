# Prerequisites: 
# 1. Docker Desktop must be running.
# 2. GHCR_OWNER, IGN_RELEASE, and GHCR_PAT environment variables set.

$Owner   = $env:GHCR_OWNER
$Release = if ($env:IGN_RELEASE) { $env:IGN_RELEASE } else { "8.3.6" }
$Pat     = $env:GHCR_PAT

if (-not $Owner -or -not $Pat) {
    Write-Error "GHCR_OWNER and GHCR_PAT environment variables must be set."
    exit 1
}

$Source = "inductiveautomation/ignition:$Release"
$Target = "ghcr.io/$($Owner.ToLower())/ignition:$Release"

Write-Host "Logging in to ghcr.io..." -ForegroundColor Cyan
$Pat | docker login ghcr.io -u $Owner --password-stdin

Write-Host "Pulling $Source..." -ForegroundColor Cyan
docker pull $Source

Write-Host "Tagging as $Target..." -ForegroundColor Cyan
docker tag $Source $Target

Write-Host "Pushing to GHCR..." -ForegroundColor Cyan
docker push $Target

Write-Host "`nDone! Image available at: https://github.com/users/$Owner/packages/container/ignition" -ForegroundColor Green