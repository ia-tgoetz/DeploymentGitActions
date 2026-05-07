# Fetch third-party Ignition modules into services/modules/.
# Run once on the IPC (or on a workstation, then copy the .modl files over).
# The .modl files are gitignored - they live alongside the repo, not inside it.
#
# Usage: .\scripts\fetch-modules.ps1

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Dest     = Join-Path $RepoRoot "services\modules"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

# --- Modules to fetch ---
$Modules = @(
    @{
        Filename = "MQTT-Transmission-signed.modl"
        Url      = "https://files.inductiveautomation.com/third-party/cirrus-link/5.0.3/MQTT-Transmission-signed.modl"
    }
)

foreach ($m in $Modules) {
    $target = Join-Path $Dest $m.Filename
    if (Test-Path $target) {
        Write-Host "Already present: $($m.Filename) - skipping." -ForegroundColor Yellow
        continue
    }
    Write-Host "Downloading $($m.Filename)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $m.Url -OutFile $target
    Write-Host "Saved: $target" -ForegroundColor Green
}

Write-Host "`nDone. Modules in $Dest:" -ForegroundColor Green
Get-ChildItem $Dest -Filter "*.modl" | Format-Table Name, Length
