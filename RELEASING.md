# Releasing metaBrain

This document is for maintainers preparing signed `mb` CLI builds.

## Release Helper

The release helper builds a universal macOS binary named `mb` for Apple silicon
and Intel Macs, signs it with Developer ID, and submits a zip archive to Apple's
notary service:

```bash
Scripts/build-release.sh --notary-profile metabrain-notary
```

Create the notary profile once with:

```bash
xcrun notarytool store-credentials metabrain-notary \
  --apple-id you@example.com \
  --team-id ABCDE12345 \
  --password app-specific-password
```

Pass a specific signing certificate with `--identity` or
`METABRAIN_SIGN_IDENTITY`.

## Local Release Check

For local build checks without Apple signing or notarization credentials, run:

```bash
Scripts/build-release.sh --skip-sign --skip-notarization
```

## Useful Options

- `--version <version>` sets the release version label used in the zip filename.
- `--dist-dir <path>` writes artifacts somewhere other than `./dist`.
- `--build-root <path>` changes the scratch build root.
- `--arch <arch>` builds one architecture; repeat it to build multiple.
- `--entitlements <path>` passes an optional entitlements plist to `codesign`.

The helper also reads these environment variables:

```text
METABRAIN_SIGN_IDENTITY
METABRAIN_NOTARY_PROFILE
METABRAIN_APPLE_ID
METABRAIN_TEAM_ID
METABRAIN_APP_PASSWORD
METABRAIN_ENTITLEMENTS
METABRAIN_RELEASE_VERSION
METABRAIN_DIST_DIR
METABRAIN_RELEASE_BUILD_DIR
```

## Output

By default, artifacts are written under `dist/`:

```text
dist/mb-<version>-macos-universal/
dist/mb-<version>-macos-universal/bin/mb
dist/mb-<version>-macos-universal/README.md
dist/mb-<version>-macos-universal/LICENSE
dist/mb-<version>-macos-universal.zip
dist/mb-<version>-macos-universal.zip.sha256
```

Standalone CLI zip archives are not stapled. Distribute the notarized zip
returned by Apple's notary service.

Upload both the zip and `.sha256` file to the GitHub release. Homebrew formula
updates can use the zip URL and the SHA-256 value from either the checksum file
or GitHub's release asset digest.

## Linux / Ubuntu Release

Ubuntu release artifacts are built on Linux with a statically linked Swift
standard library:

~~~bash
Scripts/build-linux-release.sh --version 1.1.1
~~~

This writes:

~~~text
dist/mb-<version>-linux-x86_64.tar.gz
dist/mb-<version>-linux-x86_64.tar.gz.sha256
dist/metabrain_<version>_amd64.deb
dist/metabrain_<version>_amd64.deb.sha256
~~~

To create or update the GitHub release and upload artifacts, run:

~~~bash
Scripts/build-linux-release.sh --version 1.1.1 --upload
~~~

The upload mode requires GitHub CLI authentication and infers the repository
from `origin`. Pass `--repo owner/name` when building from a checkout without a
GitHub remote.
