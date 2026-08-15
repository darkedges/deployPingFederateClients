[CmdletBinding()]
param(
    [string]$Image = "darkedges/pingfeddeploy-arc-runner:test"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("pingfeddeploy-ca-" + [guid]::NewGuid())
$rootCertificate = Join-Path $temporaryDirectory "darkedges-idam-root.crt"
$intermediateCertificate = Join-Path $temporaryDirectory "darkedges-idam-intermediate.crt"

try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

    vault read -field=certificate darkedges_idam_root/cert/ca |
        Set-Content -LiteralPath $rootCertificate -Encoding ascii -NoNewline
    if ($LASTEXITCODE -ne 0) { throw "Unable to read the DarkEdges root CA from Vault." }

    vault read -field=certificate darkedges_idam_intermediate/cert/ca |
        Set-Content -LiteralPath $intermediateCertificate -Encoding ascii -NoNewline
    if ($LASTEXITCODE -ne 0) { throw "Unable to read the DarkEdges intermediate CA from Vault." }

    foreach ($certificate in @($rootCertificate, $intermediateCertificate)) {
        $pem = Get-Content -LiteralPath $certificate -Raw
        if ($pem -notmatch "-----BEGIN CERTIFICATE-----[\s\S]+-----END CERTIFICATE-----") {
            throw "Vault did not return a valid PEM certificate for $certificate."
        }
    }

    docker build --pull `
        --file (Join-Path $PSScriptRoot "Dockerfile") `
        --secret "id=darkedges_idam_root_ca,src=$rootCertificate" `
        --secret "id=darkedges_idam_intermediate_ca,src=$intermediateCertificate" `
        --tag $Image `
        $repositoryRoot
    if ($LASTEXITCODE -ne 0) { throw "Runner image build failed." }
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
