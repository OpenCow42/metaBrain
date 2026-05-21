param(
    [string]$Version = $env:METABRAIN_RELEASE_VERSION,
    [string]$DistDir = $env:METABRAIN_DIST_DIR,
    [string]$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\\..")).Path,
    [string]$Product = "mb",
    [string]$PackageName = "metabrain",
    [string]$Platform = "windows-x86_64",
    [switch]$SkipBuild,
    [string]$BinaryPath,
    [string]$VisualStudioDevCmd
)

$ErrorActionPreference = "Stop"

if (-not $Version) {
    $Version = (git -C $PackageRoot describe --tags --always --dirty 2>$null)
    if (-not $Version) {
        $Version = "local"
    }
}

if (-not $DistDir) {
    $DistDir = Join-Path $PackageRoot "dist"
}

if (-not $SkipBuild) {
    $buildArgs = @{
        PackageRoot = $PackageRoot
        Product = $Product
    }

    if ($VisualStudioDevCmd) {
        $buildArgs.VisualStudioDevCmd = $VisualStudioDevCmd
    }

    $BinaryPath = & (Join-Path $PSScriptRoot "build.ps1") @buildArgs | Select-Object -Last 1
}

if (-not $BinaryPath) {
    throw "BinaryPath is required when -SkipBuild is used."
}

$BinaryPath = (Resolve-Path $BinaryPath).Path
if (-not (Test-Path $BinaryPath)) {
    throw "Binary not found: $BinaryPath"
}

Set-Location $PackageRoot

$artifactName = "$PackageName-$Version-$Platform"
$stageDir = Join-Path $DistDir $artifactName
$zipPath = Join-Path $DistDir "$artifactName.zip"
$checksumPath = "$zipPath.sha256"

Remove-Item -Recurse -Force $stageDir, $zipPath, $checksumPath -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

Copy-Item -Force $BinaryPath (Join-Path $stageDir "$Product.exe")
Copy-Item -Force (Join-Path $PackageRoot "README.md") (Join-Path $stageDir "README.md")
Copy-Item -Force (Join-Path $PackageRoot "LICENSE") (Join-Path $stageDir "LICENSE")

Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force

$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
$checksumLine = "$hash  $(Split-Path -Leaf $zipPath)" + [char]10
[System.IO.File]::WriteAllText(
    $checksumPath,
    $checksumLine,
    [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    Binary = $BinaryPath
    StagingDirectory = $stageDir
    Archive = $zipPath
    Sha256File = $checksumPath
    Sha256 = $hash
}
