# Generate a multi-SAN fleet identity metro-keystore for Ignition GAN.
#
# Follows the workflow documented in
# "Setting Up Your Own Gateway Network Certificate" (IA), adapted for a
# self-signed (no external CA) fleet model.
#
# Reads config\fleet.txt for the hostnames to put in the SAN. IP SANs
# are NOT supported by this PowerShell version (Windows native
# New-SelfSignedCertificate emits all -DnsName entries as DNS-typed
# SANs, not IP-typed). For a cert with explicit IP SANs, use
# scripts\generate-fleet-cert.sh on a Linux/WSL host with openssl.
#
# Outputs (in build\edgeGwBuild\):
#   metro-keystore       PKCS12 keystore. Alias 'metro-key', containing
#                        the cert + private key. NEVER commit.
#   fleet-cert.crt       Public cert (PEM). Hand to the Hub admin once.
#                        Safe to commit.
#
# Usage:
#   .\scripts\generate-fleet-cert.ps1
#   .\scripts\generate-fleet-cert.ps1 -Password "strongerthandefault"
#   .\scripts\generate-fleet-cert.ps1 -Subject "CN=chevron-edge-fleet"

param(
    [string] $Subject   = "CN=edge-fleet",
    [string] $Password  = "changeit",
    [int]    $ValidDays = 1825    # 5 years
)

$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$BuildDir   = Join-Path $RepoRoot "build\edgeGwBuild"
$FleetFile  = Join-Path $RepoRoot "config\fleet.txt"
$CrtFile    = Join-Path $BuildDir "fleet-cert.crt"
$KsFile     = Join-Path $BuildDir "metro-keystore"

if (-not (Test-Path $BuildDir)) {
    Write-Error "Build directory not found: $BuildDir"
    exit 1
}

# Build SAN entries from fleet.txt (one DNS per line, '#' comments stripped)
$dnsNames = @()
$cnDnsName = ($Subject -replace '^CN=', '').Trim()
if (Test-Path $FleetFile) {
    Get-Content $FleetFile | ForEach-Object {
        $line = ($_ -replace '#.*', '').Trim()
        if ($line) { $dnsNames += $line }
    }
}
if ($dnsNames.Count -eq 0) {
    Write-Warning "config/fleet.txt empty -- falling back to single DNS:$cnDnsName SAN"
    $dnsNames = @($cnDnsName)
}

Write-Host "Generating fleet metro-keystore..." -ForegroundColor Cyan
Write-Host "  Subject:  $Subject"
Write-Host "  Alias:    metro-key  (required by Ignition)"
Write-Host "  Validity: $ValidDays days"
Write-Host "  SAN:      $($dnsNames -join ', ')"
Write-Host ""

$cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Subject `
    -DnsName $dnsNames `
    -KeyAlgorithm RSA `
    -KeyLength 4096 `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -KeyExportPolicy Exportable `
    -CertStoreLocation "cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddDays($ValidDays) `
    -FriendlyName "metro-key" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2")
    # ExtendedKeyUsage: serverAuth + clientAuth

# Export public cert as PEM (.crt)
$b64 = [Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
$pem = "-----BEGIN CERTIFICATE-----`r`n$b64`r`n-----END CERTIFICATE-----`r`n"
Set-Content -Path $CrtFile -Value $pem -Encoding ASCII

# Export PKCS12 keystore (cert + private key + alias 'metro-key')
$securePass = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $KsFile -Password $securePass | Out-Null

# Clean up the cert from the user's cert store
Remove-Item -Path "cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey

Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "  Public cert (give to Hub admin):"
Write-Host "    $CrtFile"
Write-Host ""
Write-Host "  Keystore (baked into image, NEVER commit):"
Write-Host "    $KsFile"
Write-Host "  Keystore password: $Password"
Write-Host "  Keystore alias:    metro-key"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Hand fleet-cert.crt to whoever runs the Hub (one-time approval)."
Write-Host "  2. Set IGN_FLEET_KEYSTORE_PASSWORD=$Password in your .env (or repo Secret)."
Write-Host "  3. Local build:  .\run-build-edge.ps1  then  .\run-push-edge.ps1"
Write-Host "  4. CI build:     base64-encode metro-keystore and set as the"
Write-Host "                   FLEET_KEYSTORE_BASE64 repo Secret."
Write-Host ""
Write-Host "  base64 for the Secret:" -ForegroundColor DarkGray
Write-Host "    [Convert]::ToBase64String([System.IO.File]::ReadAllBytes('$KsFile')) | Set-Clipboard" -ForegroundColor DarkGray
