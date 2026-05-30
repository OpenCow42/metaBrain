param(
    [string]$Version = $env:METABRAIN_RELEASE_VERSION,
    [string]$DistDir = $env:METABRAIN_DIST_DIR,
    [string]$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\\..")).Path,
    [string]$Product,
    [string[]]$Products = @(),
    [string]$PackageName = "metabrain",
    [string]$Platform = "windows-x86_64",
    [string[]]$SwiftRuntimeLibraryPaths = @(),
    [switch]$SkipBuild,
    [string]$BinaryPath,
    [string[]]$BinaryPaths = @(),
    [string]$VisualStudioDevCmd
)

$ErrorActionPreference = "Stop"

function Add-ExistingDirectory {
    param(
        [System.Collections.Generic.List[string]]$Directories,
        [string]$Path
    )

    if (-not $Path) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not $Directories.Contains($resolved)) {
        $Directories.Add($resolved)
    }
}

function Get-SwiftRuntimeLibraryPaths {
    param(
        [string[]]$ExplicitPaths
    )

    $directories = [System.Collections.Generic.List[string]]::new()

    foreach ($path in $ExplicitPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "Swift runtime library path not found: $path"
        }
        Add-ExistingDirectory -Directories $directories -Path $path
    }

    if ($directories.Count -gt 0) {
        return $directories.ToArray()
    }

    if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) {
        throw "swiftc was not found on PATH. Install the Swift toolchain for Windows first."
    }

    $targetInfoJson = (& swiftc -print-target-info) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or -not $targetInfoJson) {
        throw "Could not read Swift target information with swiftc -print-target-info."
    }

    $targetInfo = $targetInfoJson | ConvertFrom-Json

    foreach ($path in @($targetInfo.paths.runtimeLibraryPaths)) {
        Add-ExistingDirectory -Directories $directories -Path $path
    }
    foreach ($path in @($targetInfo.paths.runtimeLibraryImportPaths)) {
        Add-ExistingDirectory -Directories $directories -Path $path
    }

    $runtimeResourcePath = $targetInfo.paths.runtimeResourcePath
    if ($runtimeResourcePath) {
        $windowsRuntimePath = Join-Path $runtimeResourcePath "windows"
        Add-ExistingDirectory -Directories $directories -Path $windowsRuntimePath

        $architecture = $targetInfo.target.arch
        if ($architecture) {
            Add-ExistingDirectory -Directories $directories -Path (Join-Path $windowsRuntimePath $architecture)
        }
    }

    if ($directories.Count -eq 0) {
        throw "Could not find Swift runtime library directories from swiftc -print-target-info."
    }

    return $directories.ToArray()
}

function Copy-SwiftRuntimeLibraries {
    param(
        [Parameter(Mandatory = $true)][string[]]$RuntimeLibraryPaths,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $copied = [System.Collections.Generic.List[string]]::new()

    foreach ($path in $RuntimeLibraryPaths) {
        $libraries = Get-ChildItem -LiteralPath $path -Filter "*.dll" -File -ErrorAction SilentlyContinue
        foreach ($library in $libraries) {
            $destinationPath = Join-Path $Destination $library.Name
            if (-not (Test-Path -LiteralPath $destinationPath)) {
                Copy-Item -Force $library.FullName $destinationPath
            }
            if (-not $copied.Contains($library.Name)) {
                $copied.Add($library.Name)
            }
        }
    }

    if ($copied.Count -eq 0) {
        throw "No Swift runtime DLLs were found in: $($RuntimeLibraryPaths -join ', ')"
    }

    $swiftCorePath = Join-Path $Destination "swiftCore.dll"
    if (-not (Test-Path -LiteralPath $swiftCorePath)) {
        throw "swiftCore.dll was not staged from Swift runtime paths: $($RuntimeLibraryPaths -join ', ')"
    }

    return $copied.ToArray()
}

if (-not $Version) {
    $Version = (git -C $PackageRoot describe --tags --always --dirty 2>$null)
    if (-not $Version) {
        $Version = "local"
    }
}

if (-not $DistDir) {
    $DistDir = Join-Path $PackageRoot "dist"
}

if ($Product -and $Products.Count -eq 0) {
    $Products = @($Product)
}

if ($Products.Count -eq 0) {
    $Products = @("mb", "mbd")
}

$resolvedBinaryPaths = [System.Collections.Generic.List[string]]::new()

if (-not $SkipBuild) {
    foreach ($productName in $Products) {
        $buildArgs = @{
            PackageRoot = $PackageRoot
            Product = $productName
        }

        if ($VisualStudioDevCmd) {
            $buildArgs.VisualStudioDevCmd = $VisualStudioDevCmd
        }

        $builtBinaryPath = & (Join-Path $PSScriptRoot "build.ps1") @buildArgs | Select-Object -Last 1
        $resolvedBinaryPaths.Add($builtBinaryPath)
    }
} else {
    if ($BinaryPath -and $BinaryPaths.Count -eq 0) {
        $BinaryPaths = @($BinaryPath)
    }

    if ($BinaryPaths.Count -ne $Products.Count) {
        throw "BinaryPaths must contain one path per product when -SkipBuild is used."
    }

    foreach ($existingBinaryPath in $BinaryPaths) {
        $resolvedBinaryPaths.Add($existingBinaryPath)
    }
}

if ($resolvedBinaryPaths.Count -ne $Products.Count) {
    throw "Expected one binary path per product."
}

for ($index = 0; $index -lt $resolvedBinaryPaths.Count; $index++) {
    $resolvedBinaryPath = (Resolve-Path $resolvedBinaryPaths[$index]).Path
    if (-not (Test-Path $resolvedBinaryPath)) {
        throw "Binary not found: $resolvedBinaryPath"
    }
    $resolvedBinaryPaths[$index] = $resolvedBinaryPath
}

Set-Location $PackageRoot

$artifactName = "$PackageName-$Version-$Platform"
$stageDir = Join-Path $DistDir $artifactName
$zipPath = Join-Path $DistDir "$artifactName.zip"
$checksumPath = "$zipPath.sha256"

Remove-Item -Recurse -Force $stageDir, $zipPath, $checksumPath -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

for ($index = 0; $index -lt $Products.Count; $index++) {
    Copy-Item -Force $resolvedBinaryPaths[$index] (Join-Path $stageDir "$($Products[$index]).exe")
}
Copy-Item -Force (Join-Path $PackageRoot "README.md") (Join-Path $stageDir "README.md")
Copy-Item -Force (Join-Path $PackageRoot "LICENSE") (Join-Path $stageDir "LICENSE")

$swiftRuntimePaths = Get-SwiftRuntimeLibraryPaths -ExplicitPaths $SwiftRuntimeLibraryPaths
$swiftRuntimeLibraries = Copy-SwiftRuntimeLibraries -RuntimeLibraryPaths $swiftRuntimePaths -Destination $stageDir

Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force

$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
$checksumLine = "$hash  $(Split-Path -Leaf $zipPath)" + [char]10
[System.IO.File]::WriteAllText(
    $checksumPath,
    $checksumLine,
    [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    Binaries = $resolvedBinaryPaths.ToArray()
    StagingDirectory = $stageDir
    Archive = $zipPath
    Sha256File = $checksumPath
    Sha256 = $hash
    SwiftRuntimeLibraries = $swiftRuntimeLibraries
}
