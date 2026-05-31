# Daemon Autostart

`mbd` is the optional local metaBrain daemon. It lets `mb` reuse a running
server at `127.0.0.1:6374` instead of opening the LevelDB store directly for
each command.

Package installs are passive: they install `mb` and `mbd`, but they do not
create a store, install a service, or start the daemon automatically.

## Shared Config

The daemon config file uses the same keys on every platform:

```json
{
  "storePath": "~/.metabrain/store.leveldb",
  "loopbackHost": "127.0.0.1",
  "loopbackPort": 6374,
  "storeIdleTimeoutSeconds": 30,
  "logLevel": "info"
}
```

`loopbackHost` and `loopbackPort` expose the default endpoint that the CLI
auto-probes. `storeIdleTimeoutSeconds` releases an idle store's LevelDB lock
while the daemon keeps listening for later requests.

## macOS

Homebrew installs both `mb` and `mbd`:

```sh
brew tap OpenCow42/tap
brew install mb
```

Create a config file:

```sh
mkdir -p ~/.config/metabrain ~/.metabrain

cat > ~/.config/metabrain/mbd.json <<'JSON'
{
  "storePath": "~/.metabrain/store.leveldb",
  "loopbackHost": "127.0.0.1",
  "loopbackPort": 6374,
  "storeIdleTimeoutSeconds": 30,
  "logLevel": "info"
}
JSON
```

Install and start the user LaunchAgent:

```sh
mbd service install --user --config ~/.config/metabrain/mbd.json --now
mbd service status --user
mb version
```

Useful service commands:

```sh
mbd service start --user
mbd service stop --user
mbd service status --user
mbd service uninstall --user
```

To inspect the generated LaunchAgent before installing it:

```sh
mbd service print --user --config ~/.config/metabrain/mbd.json
```

## Linux

Install the package on Ubuntu 24.04 or 26.04:

```sh
echo 'deb [trusted=yes] https://opencow42.github.io/apt-repo ubuntu24.04 main' | sudo tee /etc/apt/sources.list.d/opencow.list
sudo apt update
sudo apt install metabrain
```

Create a config file:

```sh
mkdir -p ~/.config/metabrain ~/.metabrain

cat > ~/.config/metabrain/mbd.json <<'JSON'
{
  "storePath": "~/.metabrain/store.leveldb",
  "loopbackHost": "127.0.0.1",
  "loopbackPort": 6374,
  "storeIdleTimeoutSeconds": 30,
  "logLevel": "info"
}
JSON
```

Install and start the user systemd unit:

```sh
mbd service install --user --config ~/.config/metabrain/mbd.json --now
mbd service status --user
mb version
```

If the daemon should keep running after logout, enable user lingering:

```sh
loginctl enable-linger "$USER"
```

Useful service commands:

```sh
mbd service start --user
mbd service stop --user
mbd service status --user
mbd service uninstall --user
```

To inspect the generated systemd user unit before installing it:

```sh
mbd service print --user --config ~/.config/metabrain/mbd.json
```

## Windows

Windows can run `mbd` over the same loopback endpoint. Native `mbd service`
management currently covers macOS launchd and Linux systemd only, so use a
per-user Windows Task Scheduler task for autostart.

The task points at the absolute `mbd.exe` path returned by `Get-Command`.
If you installed from a portable archive, keep that extracted directory in
place; moving or deleting it will break the scheduled task.

Create a config file in PowerShell:

```powershell
$ConfigDir = Join-Path $env:LOCALAPPDATA "metaBrain"
$StoreDir = Join-Path $env:USERPROFILE ".metabrain"
New-Item -ItemType Directory -Force -Path $ConfigDir, $StoreDir | Out-Null

$Config = @{
  storePath = Join-Path $StoreDir "store.leveldb"
  loopbackHost = "127.0.0.1"
  loopbackPort = 6374
  storeIdleTimeoutSeconds = 30
  logLevel = "info"
}

$Config | ConvertTo-Json | Set-Content -Encoding UTF8 -Path (Join-Path $ConfigDir "mbd.json")
```

Start it manually:

```powershell
mbd serve --config "$env:LOCALAPPDATA\metaBrain\mbd.json"
```

Register a per-user logon task. The task starts `mbd` when the current user
logs in, keeps it running without a time limit, and asks Task Scheduler to
restart it if it exits unexpectedly:

```powershell
$Mbd = (Get-Command mbd.exe).Source
$Config = Join-Path $env:LOCALAPPDATA "metaBrain\mbd.json"

$Settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

$Action = New-ScheduledTaskAction `
  -Execute $Mbd `
  -Argument "serve --config `"$Config`""

$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

Register-ScheduledTask `
  -TaskName "metaBrain mbd" `
  -Action $Action `
  -Trigger $Trigger `
  -Settings $Settings `
  -Description "Start the metaBrain daemon at user logon." `
  -Force

Start-ScheduledTask -TaskName "metaBrain mbd"
```

Check status and CLI connectivity:

```powershell
Get-ScheduledTask -TaskName "metaBrain mbd"
Get-ScheduledTaskInfo -TaskName "metaBrain mbd"
Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 6374 -State Listen
mb version
```

`Get-ScheduledTask` should report `Running` after `Start-ScheduledTask`.
`mb version` should include a reachable `server` object for
`http://127.0.0.1:6374`.

Stop or remove the task:

```powershell
Stop-ScheduledTask -TaskName "metaBrain mbd"
Unregister-ScheduledTask -TaskName "metaBrain mbd" -Confirm:$false
```

## Verify The Daemon

On every platform, `mb version` probes `http://127.0.0.1:6374`. A running
daemon reports `serverReachable` as true in text output, or includes a
reachable `server` object in JSON output.

```sh
mb version
mb version --format json
```
