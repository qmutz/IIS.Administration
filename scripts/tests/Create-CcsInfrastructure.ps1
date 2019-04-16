param(
    [string]
    $TestRoot = "$env:SystemDrive\tests\iisadmin"
)

$CCS_FOLDER_NAME = "CentralCertStore"
$CERTIFICATE_PASS = "abcdefg"
$CERTIFICATE_NAME = "IISAdminLocalTest"
$certStore = "Cert:\LocalMachine\My"

function New-CcsSelfSignedCertificate($certName) {
    $command = Get-Command "New-SelfSignedCertificate"
    $cert = $null

    # Private key should be exportable
    if ($command.Parameters.Keys.Contains("KeyExportPolicy")) {
        $cert = New-SelfSignedCertificate -KeyExportPolicy Exportable -DnsName $certName -CertStoreLocation $certStore
    }
    else {
        $cert = New-SelfSignedCertificate -DnsName $certName -CertStoreLocation $certStore
    }
    $cert
}

$ccsDir = [System.IO.Path]::Combine($TestRoot, $CCS_FOLDER_NAME)

if (-not(Test-Path $ccsDir)) {
    New-Item -Type Directory -Path $ccsDir -ErrorAction Stop | Out-Null
}

$cert = New-CcsSelfSignedCertificate -certName $CERTIFICATE_NAME
Get-ChildItem $certStore | Where-Object {$_.Subject -eq "CN=$CERTIFICATE_NAME"} | Remove-Item
$bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $CERTIFICATE_PASS)
$ccsPath = Join-Path $ccsDir "${CERTIFICATE_NAME}.pfx"
Write-Host "Exported certification at $ccsPath"
[System.IO.File]::WriteAllBytes($ccsPath, $bytes)

Import-PfxCertificate -Password (ConvertTo-SecureString $CERTIFICATE_PASS -AsPlainText -Force) -CertStoreLocation "Cert:\LocalMachine\Root" -FilePath $ccsPath

# Check for ccs entry in hosts file to allow local testing of ccs binding
$hostFile = "C:\Windows\System32\drivers\etc\hosts"
$lines = [System.IO.File]::ReadAllLines($hostFile)
$containsCertHostName = $false
$lines | ForEach-Object {
    if ($_ -match $CERTIFICATE_NAME) { 
        $containsCertHostName = $true
    }
}

if (-not($containsCertHostName)) {
    $lines += "127.0.0.1 $CERTIFICATE_NAME"
    [System.IO.File]::WriteAllLines($hostFile, $lines)
}
