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

# Run the logic script
.\scripts\mirror-to-ghcr.ps1