# Build the derived Edge image from the repo root.
#
# Reads .env for IGN_RELEASE, downloads any .modl files listed in
# build\edgeGwBuild\modules.txt that aren't already staged, runs
# docker build, and saves the result as
# build\edgeGwBuild\edgeWithTransmission.tar so .\run-push-edge.ps1
# can ship it to GHCR.
#
# Prerequisites:
#   - Docker Desktop running
#   - .env exists (only IGN_RELEASE is used by this script; defaults to 8.3.6)
#   - Internet access to inductiveautomation.com (or whatever your modules.txt
#     URLs point at) for any .modl that isn't already on disk
#
# Usage:
#   .\run-build-edge.ps1

$ErrorActionPreference = "Stop"

if (Test-Path .env) {
    Get-Content .env | ForEach-Object {
        $name, $value = $_.Split('=', 2)
        if ($name -and $value) {
            [System.Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim())
        }
    }
    Write-Host "Variables loaded from .env" -ForegroundColor Green
}

$Release  = if ($env:IGN_RELEASE) { $env:IGN_RELEASE } else { "8.3.6" }
$BuildDir = "build\edgeGwBuild"
$ImageTag = "edge-with-transmission:$Release"
$TarPath  = Join-Path $BuildDir "edgeWithTransmission.tar"
$Manifest = Join-Path $BuildDir "modules.txt"

if (-not (Test-Path $BuildDir)) {
    Write-Error "Build directory not found: $BuildDir"
    exit 1
}

if (Test-Path $Manifest) {
    Write-Host ""
    Write-Host "==> Staging .modl files from modules.txt..." -ForegroundColor Cyan
    Get-Content $Manifest | ForEach-Object {
        $url = ($_ -split '#', 2)[0].Trim()
        if ($url) {
            $filename = [System.IO.Path]::GetFileName($url)
            $target = Join-Path $BuildDir $filename
            if (Test-Path $target) {
                Write-Host "  Already present: $filename" -ForegroundColor DarkGray
            } else {
                Write-Host "  Downloading: $url" -ForegroundColor Cyan
                Invoke-WebRequest -Uri $url -OutFile $target
            }
        }
    }
} else {
    Write-Host "No modules.txt found — building with whatever .modl files are already in $BuildDir" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==> Building $ImageTag..." -ForegroundColor Cyan
docker build `
    -t $ImageTag `
    --build-arg "IGNITION_VERSION=$Release" `
    $BuildDir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "==> Saving to $TarPath..." -ForegroundColor Cyan
docker save $ImageTag -o $TarPath
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Image: $ImageTag"
Write-Host "  Tar:   $TarPath"
Write-Host ""
Write-Host "Next: .\run-push-edge.ps1   # to upload to GHCR" -ForegroundColor Cyan
