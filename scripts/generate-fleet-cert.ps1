# Generate a self-signed fleet identity cert + PKCS12 keystore.
#
# Outputs (in build/edgeGwBuild/):
#   fleet-cert.crt       — public cert. Give to the Hub admin to approve once.
#                          Safe to commit.
#   fleet-keystore.p12   — PKCS12 with cert + private key. Baked into the
#                          Edge image. NEVER commit. Distribute via image
#                          push to private GHCR (the private key is
#                          accessible to anyone with read:packages).
#
# After running this, either:
#   - Run .\run-build-edge.ps1 to bake the keystore into a local image, or
#   - base64-encode the .p12 and store as the FLEET_KEYSTORE_BASE64 GitHub
#     Secret so CI's Build Edge Image workflow can use it.
#
# Usage:
#   .\scripts\generate-fleet-cert.ps1
#   .\scripts\generate-fleet-cert.ps1 -Subject "CN=chevron-edge-fleet"
#   .\scripts\generate-fleet-cert.ps1 -Password "mypass" -ValidDays 3650

param(
    [string] $Subject   = "CN=edge-fleet",
    [string] $Password  = "changeit",
    [int]    $ValidDays = 1825,    # 5 years
    [string] $Alias     = "edge-fleet"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $RepoRoot "build\edgeGwBuild"
$CrtFile  = Join-Path $BuildDir "fleet-cert.crt"
$P12File  = Join-Path $BuildDir "fleet-keystore.p12"

if (-not (Test-Path $BuildDir)) {
    Write-Error "Build directory not found: $BuildDir"
    exit 1
}

$dnsName = ($Subject -replace '^CN=', '').Trim()

Write-Host "Generating fleet identity cert..." -ForegroundColor Cyan
Write-Host "  Subject:  $Subject"
Write-Host "  Alias:    $Alias"
Write-Host "  Validity: $ValidDays days"
Write-Host ""

$cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Subject `
    -DnsName $dnsName `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -KeyExportPolicy Exportable `
    -CertStoreLocation "cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddDays($ValidDays) `
    -FriendlyName $Alias

# Export public cert as PEM (.crt)
$b64 = [Convert]::ToBase64String($cert.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
$pem = "-----BEGIN CERTIFICATE-----`r`n$b64`r`n-----END CERTIFICATE-----`r`n"
Set-Content -Path $CrtFile -Value $pem -Encoding ASCII

# Export PFX (PKCS12 keystore with cert + private key)
$securePass = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $P12File -Password $securePass | Out-Null

# Clean up the cert from the user's cert store (the .p12 is the persistent artifact)
Remove-Item -Path "cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey

Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "  Public cert (give to Hub admin):"
Write-Host "    $CrtFile"
Write-Host ""
Write-Host "  Keystore (gets baked into image, NEVER commit):"
Write-Host "    $P12File"
Write-Host "  Keystore password: $Password"
Write-Host "  Keystore alias:    $Alias"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Send fleet-cert.crt to whoever runs the Hub. They approve it once;"
Write-Host "     every Edge from here on identifies as the same TLS endpoint."
Write-Host "  2. Set IGN_FLEET_KEYSTORE_PASSWORD=$Password in your .env"
Write-Host "  3. Local build:  .\run-build-edge.ps1  then  .\run-push-edge.ps1"
Write-Host "  4. CI build:     base64-encode the .p12 and store as the"
Write-Host "                   FLEET_KEYSTORE_BASE64 repo Secret. Then any push"
Write-Host "                   to build/edgeGwBuild/** will auto-rebuild with it."
Write-Host ""
Write-Host "  To get the base64 for the Secret:" -ForegroundColor DarkGray
Write-Host "    [Convert]::ToBase64String([System.IO.File]::ReadAllBytes('$P12File')) | clip" -ForegroundColor DarkGray
