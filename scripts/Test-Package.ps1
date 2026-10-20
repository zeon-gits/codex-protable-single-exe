$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location (Split-Path $PSScriptRoot -Parent)
$exe = Join-Path $PWD 'dist/ChatGPT-Portable.exe'
# Verify the final EXE's shell icon against the original ICO, not just a build flag.
Add-Type -AssemblyName System.Drawing
$actualIcon = [Drawing.Icon]::ExtractAssociatedIcon($exe)
if (!$actualIcon) { throw 'Final EXE has no readable shell icon.' }
$expectedIcon = [Drawing.Icon]::new((Join-Path $PWD 'reports/ChatGPT.ico'), $actualIcon.Width, $actualIcon.Height)
$actualBitmap = $null
$expectedBitmap = $null
try {
    $actualBitmap = $actualIcon.ToBitmap()
    $expectedBitmap = $expectedIcon.ToBitmap()
    if ($actualBitmap.Size -ne $expectedBitmap.Size) { throw 'EXE icon dimensions differ from official ICO.' }
    for ($y = 0; $y -lt $actualBitmap.Height; $y++) {
        for ($x = 0; $x -lt $actualBitmap.Width; $x++) {
            if ($actualBitmap.GetPixel($x, $y).ToArgb() -ne $expectedBitmap.GetPixel($x, $y).ToArgb()) {
                throw "EXE icon differs from official ICO at ($x, $y)."
            }
        }
    }
    "PASS: final EXE shell icon matches official ICO ($($actualIcon.Width)x$($actualIcon.Height))." |
        Set-Content reports/icon-test.txt
} finally {
    if ($actualBitmap) { $actualBitmap.Dispose() }
    if ($expectedBitmap) { $expectedBitmap.Dispose() }
    $actualIcon.Dispose()
    $expectedIcon.Dispose()
}
$root = Join-Path $PWD ('test-output/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$extracted = Join-Path $root 'Unicode 测试 with spaces'
& $exe --verify-payload 2>&1 | Tee-Object reports/payload-test.txt
if ($LASTEXITCODE -ne 0) { throw 'Embedded payload verification failed.' }
& $exe --extract-only $extracted 2>&1 | Tee-Object reports/extraction-test.txt
if ($LASTEXITCODE -ne 0) { throw 'Extraction failed.' }

# Compare every extracted application file against the original archive.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $PWD 'build/ChatGPT-x64.msix'))
$count = 0
try {
    foreach ($entry in $zip.Entries) {
        if (!$entry.FullName.StartsWith('app/') -or $entry.FullName.EndsWith('/')) { continue }
        $path = Join-Path $extracted $entry.FullName
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $($entry.FullName)" }
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = [Convert]::ToHexString($sha.ComputeHash($stream)) }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) {
            throw "Extracted content mismatch: $($entry.FullName)"
        }
        $count++
    }
} finally { $zip.Dispose() }
"Verified $count extracted files against original MSIX." | Add-Content reports/extraction-test.txt

# Mutate one payload byte: loader must refuse before opening the archive or launching the app.
$broken = Join-Path $root 'Corrupt.exe'
Copy-Item $exe $broken
$stream = [IO.File]::Open($broken, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
try {
    $stream.Position = $stream.Length - 64
    $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try { $payloadOffset = $reader.ReadInt64() } finally { $reader.Dispose() }
    $stream.Position = $payloadOffset + 32
    $value = $stream.ReadByte()
    $stream.Position = $payloadOffset + 32
    $stream.WriteByte([byte]($value -bxor 1))
} finally { $stream.Dispose() }
& $broken --verify-payload 2>&1 | Tee-Object reports/corruption-test.txt
if ($LASTEXITCODE -eq 0) { throw 'Corrupt payload was incorrectly accepted.' }
'PASS: corruption rejected.' | Add-Content reports/corruption-test.txt
Remove-Item -LiteralPath $root -Recurse -Force
'Packaging tests passed. Interactive ChatGPT testing was NOT performed.' | Set-Content reports/test-result.txt
# The expected failing native command must not make the entire pwsh step fail.
$global:LASTEXITCODE = 0
