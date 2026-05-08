# Fetch a server's public TLS certificate and save it as PEM into
# services/pki/trusted/clients/. Uses Windows' native TLS stack so it
# works without openssl, on PowerShell 5.1 or 7+.
#
# Usage:
#   .\scripts\fetch-server-cert.ps1                                       # defaults: engine-demo.chariot.io:8060
#   .\scripts\fetch-server-cert.ps1 my-hub.example.com                    # custom host, default port 8060
#   .\scripts\fetch-server-cert.ps1 my-hub.example.com 8060               # explicit host + port
#
# Output: services\pki\trusted\clients\<hostname>.crt
# Drop into the repo with `git add` and commit; public certs aren't sensitive.

param(
    [string] $Hostname = "engine-demo.chariot.io",
    [int]    $Port     = 8060
)

$ErrorActionPreference = "Stop"

# Resolve repo root assuming this script lives in <repo>\scripts\
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutFile  = Join-Path $RepoRoot "services\pki\trusted\clients\$Hostname.crt"

# Ensure the target directory exists
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

Write-Host "Connecting to $Hostname`:$Port..." -ForegroundColor Cyan

# Connect and accept any cert (we're capturing it, not validating)
$tcp = New-Object System.Net.Sockets.TcpClient
$tcp.Connect($Hostname, $Port)

$validateCallback = { param($s, $c, $ch, $e) $true }
$ssl = New-Object System.Net.Security.SslStream(
    $tcp.GetStream(),
    $false,
    [System.Net.Security.RemoteCertificateValidationCallback]$validateCallback
)
$ssl.AuthenticateAsClient($Hostname)

$bytes = $ssl.RemoteCertificate.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
)
$ssl.Dispose()
$tcp.Dispose()

# PEM-encode
$b64 = [Convert]::ToBase64String($bytes, [System.Base64FormattingOptions]::InsertLineBreaks)
$pem = "-----BEGIN CERTIFICATE-----`r`n$b64`r`n-----END CERTIFICATE-----`r`n"
Set-Content -Path $OutFile -Value $pem -Encoding ASCII

# Inspect
$x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, $bytes)

Write-Host ""
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host ""
Write-Host "Subject:    $($x509.Subject)"
Write-Host "Issuer:     $($x509.Issuer)"
Write-Host "Not Before: $($x509.NotBefore)"
Write-Host "Not After:  $($x509.NotAfter)"
Write-Host "Thumbprint: $($x509.Thumbprint)"

if ($x509.NotAfter -lt (Get-Date)) {
    Write-Warning "This cert has EXPIRED. The remote host needs to renew before it's worth trusting."
}

Write-Host ""
Write-Host "Next: git add `"$OutFile`"; git commit -m `"Pre-trust $Hostname GAN cert`"; git push" -ForegroundColor Cyan
