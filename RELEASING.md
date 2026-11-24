# Releasing metaBrain

This document is for maintainers preparing `mb` CLI and `mbd` daemon release
builds. Release archives and Linux packages include both binaries.

Public macOS releases **must** be Developer ID signed and Apple-notarized before
they are uploaded or referenced from Homebrew. Do not publish a macOS archive
that was built with `--skip-sign` or `--skip-notarization`; those flags are only
for local smoke checks.

## Before Release

Before cutting a new release, update the bundled version returned by
`MetaBrainVersion.currentSoftwareTag()` by changing `bundledTag` in
`Sources/MetaBrainServerSupport/MetaBrainVersion.swift` to the release tag.
This keeps `mb version` and `mbd version` accurate before the tag exists and in
installed builds.

Build each platform from the same reviewed release commit. Verify both binaries
and the artifact checksums before publishing. Install the project skills from the
tagged source checkout using the [skill installation guide](docs/skills.md#install-into-a-project).

## macOS Release

The release helper builds universal macOS binaries named `mb` and `mbd` for
Apple silicon and Intel Macs, signs both with Developer ID, and submits a zip
archive to Apple's notary service:

~~~bash
Scripts/build-release.sh \
  --version 1.3.0 \
  --identity <developer-id-sha-or-name> \
  --notary-profile metabrain-notary
~~~

Create the notary profile once with:

~~~bash
xcrun notarytool store-credentials metabrain-notary \
  --apple-id you@example.com \
  --team-id ABCDE12345 \
  --password app-specific-password
~~~

Pass a specific signing certificate with `--identity` or
`METABRAIN_SIGN_IDENTITY`. If multiple Developer ID identities have the same
display name, pass the certificate SHA-1 hash from:

~~~bash
security find-identity -v -p codesigning
~~~

Before uploading, confirm notarization was accepted:

~~~bash
xcrun notarytool info <submission-id> --keychain-profile metabrain-notary
~~~

The expected status is:

~~~text
status: Accepted
~~~

Standalone zip archives are not stapled. Distribute the notarized zip returned
by Apple's notary service.

## Local macOS Checks

For local build checks without Apple signing or notarization credentials, run:

~~~bash
Scripts/build-release.sh --skip-sign --skip-notarization
~~~

Do not upload artifacts from this command.

## macOS Output

By default, macOS artifacts are written under `dist/`:

~~~text
dist/mb-<version>-macos-universal/
dist/mb-<version>-macos-universal/bin/mb
dist/mb-<version>-macos-universal/bin/mbd
dist/mb-<version>-macos-universal/README.md
dist/mb-<version>-macos-universal/LICENSE
dist/mb-<version>-macos-universal.zip
dist/mb-<version>-macos-universal.zip.sha256
~~~

Upload both the zip and `.sha256` file to the GitHub release. Homebrew formula
updates can use the zip URL and the SHA-256 value from either the checksum file
or GitHub's release asset digest.

After uploading the macOS zip, update
[OpenCow42/homebrew-tap](https://github.com/OpenCow42/homebrew-tap):

1. Set the formula `version` to the release version.
2. Set `sha256` to the notarized zip checksum.
3. Confirm the formula installs both `bin/mb` and `bin/mbd`.
4. Do not auto-start `mbd` in `post_install`; print passive next steps that
   point users to `mbd service install --user --config <path> --now` when they
   want an opt-in LaunchAgent.
5. If the formula uses GitHub's release asset API URL, update the asset id.
6. Commit and push the tap.

Verify the uploaded macOS asset:

~~~bash
tmp="$(mktemp -d)"
cd "$tmp"
gh release download 1.3.0 --repo OpenCow42/metaBrain --pattern 'mb-1.3.0-macos-universal.zip*'
shasum -a 256 -c mb-1.3.0-macos-universal.zip.sha256
unzip -q mb-1.3.0-macos-universal.zip
codesign --verify --verbose mb-1.3.0-macos-universal/bin/mb
codesign --verify --verbose mb-1.3.0-macos-universal/bin/mbd
mb-1.3.0-macos-universal/bin/mb --help
mb-1.3.0-macos-universal/bin/mbd --help
~~~

## macOS Helper Options

- `--version <version>` sets the release version label used in the zip filename.
- `--dist-dir <path>` writes artifacts somewhere other than `./dist`.
- `--build-root <path>` changes the scratch build root.
- `--arch <arch>` builds one architecture; repeat it to build multiple.
- `--entitlements <path>` passes an optional entitlements plist to `codesign`.

The helper also reads these environment variables:

~~~text
METABRAIN_SIGN_IDENTITY
METABRAIN_NOTARY_PROFILE
METABRAIN_APPLE_ID
METABRAIN_TEAM_ID
METABRAIN_APP_PASSWORD
METABRAIN_ENTITLEMENTS
METABRAIN_RELEASE_VERSION
METABRAIN_DIST_DIR
METABRAIN_RELEASE_BUILD_DIR
~~~

## Linux / Ubuntu Release

Ubuntu release artifacts should be built on Ubuntu, using the Linux release
helper. The `mb` and `mbd` binaries are built with a statically linked Swift
standard library so the package does not require Swift to be installed on
end-user machines. Run the helper on both amd64 and arm64 build hosts.

~~~bash
Scripts/build-linux-release.sh --version 1.3.0
~~~

This writes:

~~~text
dist/mb-<version>-linux-x86_64.tar.gz
dist/mb-<version>-linux-x86_64.tar.gz.sha256
dist/metabrain_<version>_amd64.deb
dist/metabrain_<version>_amd64.deb.sha256
dist/mb-<version>-linux-aarch64.tar.gz
dist/mb-<version>-linux-aarch64.tar.gz.sha256
dist/metabrain_<version>_arm64.deb
dist/metabrain_<version>_arm64.deb.sha256
~~~

To create or update the GitHub release and upload artifacts, run:

~~~bash
Scripts/build-linux-release.sh --version 1.3.0 --upload
~~~

The upload mode requires GitHub CLI authentication and infers the repository
from `origin`. Pass `--repo owner/name` when building from a checkout without a
GitHub remote.

Verify the generated artifacts before upload:

~~~bash
sha256sum -c dist/mb-1.3.0-linux-x86_64.tar.gz.sha256
sha256sum -c dist/metabrain_1.3.0_amd64.deb.sha256
tar -tzf dist/mb-1.3.0-linux-x86_64.tar.gz
dpkg-deb -I dist/metabrain_1.3.0_amd64.deb
dpkg-deb -c dist/metabrain_1.3.0_amd64.deb | grep -E '/usr/bin/(mb|mbd)$'
~~~

The `.deb` installs `/usr/bin/mb` and `/usr/bin/mbd` plus documentation. It
must not auto-enable, auto-start, or install a user service for `mbd`; user
services require per-user config and should be created explicitly with
`mbd service install --user --config <path> --now`. On Linux, users may also
need `loginctl enable-linger "$USER"` when the user service should keep
running after logout.

## Ubuntu APT Repository

Ubuntu packages are also published through the public APT repository:

~~~text
https://github.com/OpenCow42/apt-repo
https://opencow42.github.io/apt-repo
~~~

The repository explicitly supports these suites:

~~~text
ubuntu24.04
ubuntu26.04
stable
~~~

`stable` is a compatibility alias. Prefer the explicit Ubuntu suite in user
instructions and automated setup.

Ubuntu 24.04 install command:

~~~bash
echo 'deb [trusted=yes] https://opencow42.github.io/apt-repo ubuntu24.04 main' | sudo tee /etc/apt/sources.list.d/opencow.list
sudo apt update
sudo apt install metabrain
~~~

Ubuntu 26.04 install command:

~~~bash
echo 'deb [trusted=yes] https://opencow42.github.io/apt-repo ubuntu26.04 main' | sudo tee /etc/apt/sources.list.d/opencow.list
sudo apt update
sudo apt install metabrain
~~~

To publish a new Ubuntu release to the existing APT repo:

1. Build both Debian packages with `Scripts/build-linux-release.sh --version <version>`
   on their respective amd64 and arm64 hosts.
2. Copy both packages into `OpenCow42/apt-repo` under
   `pool/main/m/metabrain/`.
3. Regenerate `Packages` and `Packages.gz` for both architectures, then generate
   `Release` for each suite (`ubuntu24.04`, `ubuntu26.04`, and `stable`).
4. Commit and push the apt repo.
5. Confirm GitHub Pages builds successfully.

Useful commands from inside `OpenCow42/apt-repo`:

~~~bash
mkdir -p pool/main/m/metabrain
cp /path/to/metabrain_1.3.0_{amd64,arm64}.deb pool/main/m/metabrain/

for suite in ubuntu24.04 ubuntu26.04 stable; do
  for arch in amd64 arm64; do
    index_dir="dists/$suite/main/binary-$arch"
    mkdir -p "$index_dir"
    dpkg-scanpackages --arch "$arch" pool > "$index_dir/Packages"
    gzip -kf "$index_dir/Packages"
  done
  release_file=$(mktemp)
  apt-ftparchive release "dists/$suite" > "$release_file"
  chmod 644 "$release_file"
  mv "$release_file" "dists/$suite/Release"
done
~~~

Keep `.nojekyll` in the apt repo root so GitHub Pages serves the APT metadata
as static files.

Verify the published APT metadata:

~~~bash
for suite in ubuntu24.04 ubuntu26.04 stable; do
  curl -fsSL "https://opencow42.github.io/apt-repo/dists/$suite/Release"
  for arch in amd64 arm64; do
    curl -fsSL "https://opencow42.github.io/apt-repo/dists/$suite/main/binary-$arch/Packages"
  done
done
~~~

The repository currently uses `trusted=yes` until a signing key and signed
`InRelease` metadata are added.

## Windows Release

Windows releases are distributed as a portable zip containing `mb.exe`,
`mbd.exe`, and Swift runtime DLLs at the archive root. This layout works for manual
installs, supports systems without the Swift toolchain installed, and maps
cleanly to WinGet's portable zip manifest format.

Build and package on a Windows machine with Swift for Windows and Visual Studio
2022 installed:

~~~powershell
Scripts\windows\package.ps1 -Version 1.3.0
~~~

This writes:

~~~text
dist\metabrain-<version>-windows-x86_64\
dist\metabrain-<version>-windows-x86_64\mb.exe
dist\metabrain-<version>-windows-x86_64\mbd.exe
dist\metabrain-<version>-windows-x86_64\swiftCore.dll
dist\metabrain-<version>-windows-x86_64\*.dll
dist\metabrain-<version>-windows-x86_64\README.md
dist\metabrain-<version>-windows-x86_64\LICENSE
dist\metabrain-<version>-windows-x86_64.zip
dist\metabrain-<version>-windows-x86_64.zip.sha256
~~~

The helper loads the Visual Studio developer environment, resolves packages,
builds `mb` and `mbd` in release mode, stages the portable layout, copies Swift
runtime DLLs from the active Swift toolchain, creates the zip, and writes a SHA-256
checksum file. Packaging fails if `swiftCore.dll` cannot be staged. If Visual
Studio is installed somewhere unusual, pass the developer command prompt path
explicitly:

~~~powershell
Scripts\windows\package.ps1 `
  -Version 1.3.0 `
  -VisualStudioDevCmd "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
~~~

To build without packaging:

~~~powershell
Scripts\windows\build.ps1
~~~

To package an already-built binary:

~~~powershell
Scripts\windows\package.ps1 `
  -Version 1.3.0 `
  -SkipBuild `
  -BinaryPath .build\x86_64-unknown-windows-msvc\release\mb.exe
~~~

When packaging from a shell where `swiftc -print-target-info` cannot discover
the runtime locations, pass `-SwiftRuntimeLibraryPaths` with the Swift runtime
directories that contain `swiftCore.dll` and the other runtime DLLs.

Manual install users can unzip the archive anywhere and add that directory to
`PATH`.

Verify the generated Windows artifact on a machine without Swift before upload:

~~~powershell
Expand-Archive dist\metabrain-1.3.0-windows-x86_64.zip -DestinationPath $env:TEMP\metabrain-check -Force
if (-not (Test-Path $env:TEMP\metabrain-check\swiftCore.dll)) { throw "swiftCore.dll missing" }
& $env:TEMP\metabrain-check\mb.exe --help
& $env:TEMP\metabrain-check\mbd.exe --help
Get-FileHash -Algorithm SHA256 dist\metabrain-1.3.0-windows-x86_64.zip
Get-Content dist\metabrain-1.3.0-windows-x86_64.zip.sha256
~~~

### WinGet

After uploading the Windows zip and checksum to a GitHub release, submit a
manifest PR to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs).
Use the zip release asset URL and the SHA-256 value from the generated checksum
file.

The installer manifest should use WinGet's portable zip support:

~~~yaml
PackageIdentifier: OpenCow42.metaBrain
PackageVersion: 1.3.0
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
  - RelativeFilePath: mb.exe
    PortableCommandAlias: mb
Installers:
  - Architecture: x64
    InstallerUrl: https://github.com/OpenCow42/metaBrain/releases/download/1.3.0/metabrain-1.3.0-windows-x86_64.zip
    InstallerSha256: <SHA256>
ManifestType: installer
ManifestVersion: 1.9.0
~~~

Windows does not require Apple-style notarization. Authenticode signing is not
required for the zip to work, but it is recommended for public releases because
unsigned downloaded executables can trigger SmartScreen warnings. Keep signing
as an optional packaging step until a certificate is available.
