Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $Root

function Find-Executable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Override
    )

    if ($Override) {
        if (-not (Test-Path $Override)) {
            throw "Configured executable does not exist: $Override"
        }
        return (Resolve-Path $Override).Path
    }

    $Found = Get-ChildItem -Path ".build" -Recurse -Filter $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "\\.build\\coverage-" } |
        Select-Object -First 1
    if ($Found) {
        return $Found.FullName
    }

    return $null
}

function Ensure-BuiltExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$Product,
        [Parameter(Mandatory = $true)][string]$ExecutableName,
        [string]$Override
    )

    $Existing = Find-Executable -Name $ExecutableName -Override $Override
    if ($Existing) {
        return $Existing
    }

    swift build --product $Product
    if ($LASTEXITCODE -ne 0) {
        throw "swift build --product $Product failed with exit code $LASTEXITCODE"
    }

    $Built = Find-Executable -Name $ExecutableName
    if (-not $Built) {
        throw "Unable to locate $ExecutableName. Set METABRAIN_BIN or METABRAIN_DAEMON_BIN."
    }
    return $Built
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Text.Contains($Needle)) {
        throw "Expected $Label to contain '$Needle', got: $Text"
    }
}

$Mb = Ensure-BuiltExecutable -Product "mb" -ExecutableName "mb.exe" -Override $env:METABRAIN_BIN
$Mbd = Ensure-BuiltExecutable -Product "mbd" -ExecutableName "mbd.exe" -Override $env:METABRAIN_DAEMON_BIN

$TmpParent = if ($env:METABRAIN_TMPDIR) { $env:METABRAIN_TMPDIR } else { $env:TEMP }
$TmpDir = Join-Path $TmpParent ("metabrain-windows-server." + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TmpDir | Out-Null

$Store = Join-Path $TmpDir "store.leveldb"
$Stdout = Join-Path $TmpDir "mbd.out"
$Stderr = Join-Path $TmpDir "mbd.err"
$Daemon = $null
$ExpectedPort = "6374"

try {
    $Daemon = Start-Process -FilePath $Mbd -ArgumentList @("serve", "--store", $Store, "--host", "127.0.0.1", "--log-level", "error") -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -NoNewWindow -PassThru

    $Port = $null
    for ($Index = 0; $Index -lt 200; $Index++) {
        if ($Daemon.HasExited) {
            $StderrText = if (Test-Path $Stderr) { Get-Content $Stderr -Raw } else { "" }
            throw "mbd serve exited early: $StderrText"
        }
        if (Test-Path $Stdout) {
            $Line = Get-Content $Stdout -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($Line -match '^mbd serving on loopback http 127\.0\.0\.1:(\d+)$') {
                $Port = $Matches[1]
                break
            }
        }
        Start-Sleep -Milliseconds 50
    }

    if (-not $Port) {
        $StdoutText = if (Test-Path $Stdout) { Get-Content $Stdout -Raw } else { "" }
        $StderrText = if (Test-Path $Stderr) { Get-Content $Stderr -Raw } else { "" }
        throw "mbd serve did not report a loopback port. stdout=$StdoutText stderr=$StderrText"
    }
    if ($Port -ne $ExpectedPort) {
        throw "Expected default loopback port $ExpectedPort, got $Port"
    }

    $Server = "http://127.0.0.1:$Port"
    $Health = Invoke-RestMethod -Uri "$Server/health"
    if ($Health.service -ne "mbd" -or $Health.status -ne "ok") {
        throw "Unexpected health payload: $($Health | ConvertTo-Json -Compress)"
    }

    $Init = & $Mb --server $Server init
    Assert-Contains -Text $Init -Needle '"status":"initialized"' -Label "init"

    $Put = & $Mb --server $Server put /windows/smoke "windows daemon memory" --title Windows --tag smoke --format json
    Assert-Contains -Text $Put -Needle '"status":"created"' -Label "put"

    $Get = & $Mb --server $Server get /windows/smoke --format json
    Assert-Contains -Text $Get -Needle '"body":"windows daemon memory"' -Label "get"
    Assert-Contains -Text $Get -Needle '"tags":["smoke"]' -Label "get"

    $Search = & $Mb --server $Server search windows --format jsonl
    Assert-Contains -Text $Search -Needle '"path":"/windows/smoke"' -Label "search"

    $Delete = & $Mb --server $Server delete /windows/smoke --format json
    Assert-Contains -Text $Delete -Needle '"deleted":true' -Label "delete"

    Write-Output "windows server smoke passed"
    exit 0
} finally {
    if ($Daemon -and -not $Daemon.HasExited) {
        try {
            Stop-Process -Id $Daemon.Id -Force -ErrorAction Stop
        } catch {
        }
    }
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
