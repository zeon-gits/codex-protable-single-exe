param([string]$ExpectedSha256 = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location (Split-Path $PSScriptRoot -Parent)
New-Item -ItemType Directory -Force build, dist, reports | Out-Null
$url = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
$msix = Join-Path $PWD 'build/ChatGPT-x64.msix'
if ($ExpectedSha256 -and $ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'ExpectedSha256 must be 64 hexadecimal characters or empty.'
}
& curl.exe --fail --location --retry 3 --connect-timeout 30 --max-time 900 --output $msix $url
if ($LASTEXITCODE -ne 0) { throw "Download failed: $LASTEXITCODE" }
$hash = (Get-FileHash $msix -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.ToLowerInvariant()) { throw 'MSIX SHA-256 mismatch.' }

# Verify the vendor package signature before using its payload. Do not install it.
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}/Windows Kits/10/bin/*/x64/signtool.exe" |
    Sort-Object FullName -Descending | Select-Object -First 1
if (!$signtool) { throw 'Windows SDK signtool.exe is required.' }
& $signtool.FullName verify /pa /v $msix 2>&1 | Tee-Object reports/signature.txt
if ($LASTEXITCODE -ne 0) { throw 'Official MSIX signature verification failed.' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($msix)
try {
    $entry = $zip.GetEntry('AppxManifest.xml')
    if (!$entry -or !$zip.GetEntry('app/ChatGPT.exe')) { throw 'Unexpected MSIX layout.' }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    [xml]$manifest = $manifestText
    $identity = $manifest.Package.Identity
    if ($identity.Name -ne 'OpenAI.Codex' -or $identity.ProcessorArchitecture -ne 'x64' -or
        $identity.Publisher -ne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B') {
        throw 'Upstream package identity changed; inspect before updating the build.'
    }
    $manifestText | Set-Content reports/AppxManifest.xml -Encoding utf8
    [long]$expanded = ($zip.Entries | Where-Object FullName -Like 'app/*' |
        Measure-Object Length -Sum).Sum
} finally { $zip.Dispose() }

$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (!(Test-Path $compiler)) { throw '.NET Framework x64 C# compiler is missing.' }
$stub = Join-Path $PWD 'build/Launcher.exe'
& $compiler /nologo /target:exe /platform:x64 /optimize+ "/out:$stub" `
    /win32manifest:src/launcher.manifest `
    "/reference:$framework/System.IO.Compression.dll" src/Launcher.cs
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed: $LASTEXITCODE" }

# Streaming append avoids embedding a ~1 GB resource in the compiler process.
$output = Join-Path $PWD 'dist/ChatGPT-Portable.exe'
$destination = [IO.File]::Create($output)
try {
    $source = [IO.File]::OpenRead($stub)
    try { $source.CopyTo($destination) } finally { $source.Dispose() }
    [long]$offset = $destination.Position
    $source = [IO.File]::OpenRead($msix)
    try { $source.CopyTo($destination) } finally { $source.Dispose() }
    [long]$length = $destination.Position - $offset
    $writer = [IO.BinaryWriter]::new($destination, [Text.Encoding]::UTF8, $true)
    try {
        $writer.Write($offset)
        $writer.Write($length)
        $writer.Write([Convert]::FromHexString($hash))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('CGPTPORTABLE0001'))
        $writer.Flush()
    } finally { $writer.Dispose() }
} finally { $destination.Dispose() }
$exeHash = (Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant()
"$exeHash  ChatGPT-Portable.exe" | Set-Content reports/SHA256SUMS.txt
[ordered]@{
    source_url = $url
    source_sha256 = $hash
    source_bytes = (Get-Item $msix).Length
    package_identity = [string]$identity.Name
    package_version = [string]$identity.Version
    app_expanded_bytes = $expanded
    output_sha256 = $exeHash
    output_bytes = (Get-Item $output).Length
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    commit = $env:GITHUB_SHA
    validation = 'Packaging only; interactive application validation required.'
} | ConvertTo-Json | Set-Content reports/build-info.json -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) {
    @"
## Experimental portable build
- Package: $($identity.Name) $($identity.Version)
- MSIX SHA-256: $hash
- EXE SHA-256: $exeHash
- Expanded app bytes: $expanded
- Download the **ChatGPT-Portable-experimental-x64** artifact after tests pass.
- EXE is an unsigned experimental launcher; Windows services and package registration are not installed.
- Build success does not prove application login or feature compatibility.
"@ | Add-Content $env:GITHUB_STEP_SUMMARY
}
