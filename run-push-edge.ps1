# Loads .env and pushes the prebuilt Edge image tar
# (build\edgeGwBuild\edgeWithTransmission.tar) to GHCR as
# ghcr.io/<GHCR_OWNER>/ignition-edge:<IGN_RELEASE>.
#
# Prerequisites:
#   - Docker Desktop running
#   - .env exists and contains GHCR_OWNER and GHCR_PAT
#     (IGN_RELEASE is optional; defaults to 8.3.6)
#   - The tar already exists at build\edgeGwBuild\edgeWithTransmission.tar
#
# Usage:
#   .\run-push-edge.ps1

if (Test-Path .env) {
    Get-Content .env | ForEach-Object {
        $name, $value = $_.Split('=', 2)
        if ($name -and $value) {
            [System.Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim())
        }
    }
    Write-Host "Variables loaded from .env" -ForegroundColor Green
} else {
    Write-Error ".env file not found!"
    exit 1
}

$Tar     = "build\edgeGwBuild\edgeWithTransmission.tar"
$Release = if ($env:IGN_RELEASE) { $env:IGN_RELEASE } else { "8.3.6" }
$DestTag = "ignition-edge:$Release"

if (-not (Test-Path $Tar)) {
    Write-Error "Tar file not found: $Tar"
    exit 1
}

Write-Host "Pushing $Tar -> ghcr.io/$($env:GHCR_OWNER)/$DestTag" -ForegroundColor Cyan
.\scripts\push-image-to-ghcr.ps1 $Tar $DestTag