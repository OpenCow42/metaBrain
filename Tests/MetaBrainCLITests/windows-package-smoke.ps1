Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $Root

function Assert-Path {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Expected path to exist: $Path"
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string[]]$Values,
        [Parameter(Mandatory = $true)][string]$Needle
    )

    if ($Values -notcontains $Needle) {
        throw "Expected values to contain '$Needle', got: $($Values -join ', ')"
    }
}

$TmpParent = if ($env:METABRAIN_TMPDIR) { $env:METABRAIN_TMPDIR } else { [System.IO.Path]::GetTempPath() }
$TmpDir = Join-Path $TmpParent ("metabrain-windows-package." + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

    $runtimeDir = Join-Path $TmpDir "runtime"
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

    $binaryPath = Join-Path $TmpDir "mb-source.exe"
    [System.IO.File]::WriteAllText($binaryPath, "dummy executable")
    [System.IO.File]::WriteAllText((Join-Path $runtimeDir "swiftCore.dll"), "dummy swift core")
    [System.IO.File]::WriteAllText((Join-Path $runtimeDir "swiftFoundation.dll"), "dummy swift foundation")

    $distDir = Join-Path $TmpDir "dist"
    $result = & (Join-Path $Root "Scripts\windows\package.ps1") `
        -Version "smoke" `
        -DistDir $distDir `
        -PackageRoot $Root `
        -SkipBuild `
        -BinaryPath $binaryPath `
        -SwiftRuntimeLibraryPaths $runtimeDir

    $stageDir = Join-Path $distDir "metabrain-smoke-windows-x86_64"
    $archivePath = Join-Path $distDir "metabrain-smoke-windows-x86_64.zip"
    $checksumPath = "$archivePath.sha256"

    Assert-Path (Join-Path $stageDir "mb.exe")
    Assert-Path (Join-Path $stageDir "README.md")
    Assert-Path (Join-Path $stageDir "LICENSE")
    Assert-Path (Join-Path $stageDir "swiftCore.dll")
    Assert-Path (Join-Path $stageDir "swiftFoundation.dll")
    Assert-Path $archivePath
    Assert-Path $checksumPath

    Assert-Contains -Values $result.SwiftRuntimeLibraries -Needle "swiftCore.dll"
    Assert-Contains -Values $result.SwiftRuntimeLibraries -Needle "swiftFoundation.dll"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName })
    } finally {
        $zip.Dispose()
    }

    Assert-Contains -Values $entries -Needle "mb.exe"
    Assert-Contains -Values $entries -Needle "swiftCore.dll"
    Assert-Contains -Values $entries -Needle "swiftFoundation.dll"

    $checksum = Get-Content -Raw $checksumPath
    $archiveName = Split-Path -Leaf $archivePath
    if (-not $checksum.Contains($archiveName)) {
        throw "Expected checksum file to reference $archiveName, got: $checksum"
    }

    Write-Output "windows package smoke passed"
    exit 0
} finally {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
