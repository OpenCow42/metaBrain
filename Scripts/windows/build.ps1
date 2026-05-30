param(
    [string]$Configuration = "release",
    [string]$Product = "mb",
    [string]$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\\..")).Path,
    [string]$VisualStudioDevCmd,
    [string]$Architecture = "x64",
    [string]$HostArchitecture = "x64"
)

$ErrorActionPreference = "Stop"

function Find-VisualStudioDevCmd {
    $candidates = @(
        "${env:ProgramFiles}\\Microsoft Visual Studio\\2022\\Community\\Common7\\Tools\\VsDevCmd.bat",
        "${env:ProgramFiles}\\Microsoft Visual Studio\\2022\\Professional\\Common7\\Tools\\VsDevCmd.bat",
        "${env:ProgramFiles}\\Microsoft Visual Studio\\2022\\Enterprise\\Common7\\Tools\\VsDevCmd.bat",
        "${env:ProgramFiles(x86)}\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\Tools\\VsDevCmd.bat"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

if (-not $VisualStudioDevCmd) {
    $VisualStudioDevCmd = Find-VisualStudioDevCmd
}

if (-not $VisualStudioDevCmd -or -not (Test-Path $VisualStudioDevCmd)) {
    throw "Could not find VsDevCmd.bat. Pass -VisualStudioDevCmd with the Visual Studio developer command prompt path."
}

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    throw "swift was not found on PATH. Install the Swift toolchain for Windows first."
}

Set-Location $PackageRoot

$binPathFile = [System.IO.Path]::GetTempFileName()
$buildScript = Join-Path ([System.IO.Path]::GetTempPath()) ("metabrain-build-" + [guid]::NewGuid().ToString("N") + ".cmd")

$buildCommand = @"
@echo off
call "$VisualStudioDevCmd" -arch=$Architecture -host_arch=$HostArchitecture >NUL
if errorlevel 1 exit /b %errorlevel%
swift package resolve
if errorlevel 1 exit /b %errorlevel%
swift build -c $Configuration --product $Product
if errorlevel 1 exit /b %errorlevel%
swift build -c $Configuration --product $Product --show-bin-path > "$binPathFile"
if errorlevel 1 exit /b %errorlevel%
"@

try {
    [System.IO.File]::WriteAllText(
        $buildScript,
        $buildCommand,
        [System.Text.UTF8Encoding]::new($false)
    )

    $commandOutput = & cmd.exe /d /s /c "`"$buildScript`""
    if ($LASTEXITCODE -ne 0) {
        throw "swift build failed with exit code $LASTEXITCODE."
    }

    $binPathLine = Get-Content -Path $binPathFile | Select-Object -Last 1
    $binPath = if ($binPathLine) { $binPathLine.Trim() } else { "" }
    if (-not $binPath) {
        throw "Could not determine SwiftPM release binary path."
    }
} finally {
    Remove-Item -Force $binPathFile -ErrorAction SilentlyContinue
    Remove-Item -Force $buildScript -ErrorAction SilentlyContinue
}
$exePath = Join-Path $binPath "$Product.exe"

if (-not (Test-Path $exePath)) {
    throw "Expected executable not found: $exePath"
}

Write-Output $exePath
