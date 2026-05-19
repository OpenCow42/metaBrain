#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="mb"
DIST_DIR="${METABRAIN_DIST_DIR:-${ROOT_DIR}/dist}"
BUILD_ROOT="${METABRAIN_RELEASE_BUILD_DIR:-${ROOT_DIR}/.build/release-macos}"
VERSION="${METABRAIN_RELEASE_VERSION:-}"
SIGN_IDENTITY="${METABRAIN_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${METABRAIN_NOTARY_PROFILE:-}"
APPLE_ID="${METABRAIN_APPLE_ID:-}"
TEAM_ID="${METABRAIN_TEAM_ID:-}"
APP_PASSWORD="${METABRAIN_APP_PASSWORD:-}"
ENTITLEMENTS="${METABRAIN_ENTITLEMENTS:-}"
SKIP_SIGN=0
SKIP_NOTARIZATION=0
ARCHS=("arm64" "x86_64")

usage() {
  cat <<'USAGE'
Usage: Scripts/build-release.sh [options]

Build a universal macOS release binary named mb, sign it with Developer ID, and
submit a zip archive to Apple's notary service.

Options:
  --identity <name>          Developer ID Application signing identity.
                             Defaults to METABRAIN_SIGN_IDENTITY, or the first
                             available Developer ID Application identity.
  --notary-profile <name>    notarytool keychain profile name.
                             Defaults to METABRAIN_NOTARY_PROFILE.
  --apple-id <email>         Apple ID for notarytool credential mode.
  --team-id <id>             Apple Developer Team ID for notarytool credential mode.
  --app-password <password>  App-specific password for notarytool credential mode.
  --entitlements <path>      Optional entitlements plist for codesign.
  --version <version>        Release version label used in the zip filename.
  --dist-dir <path>          Output directory. Defaults to ./dist.
  --build-root <path>        Build scratch root. Defaults to ./.build/release-macos.
  --skip-sign                Build only; do not codesign.
  --skip-notarization        Do not submit the zip to Apple.
  --arch <arch>              Build one architecture. Repeat for multiple arches.
                             Defaults to arm64 and x86_64.
  -h, --help                 Show this help.

Environment aliases:
  METABRAIN_SIGN_IDENTITY, METABRAIN_NOTARY_PROFILE, METABRAIN_APPLE_ID,
  METABRAIN_TEAM_ID, METABRAIN_APP_PASSWORD, METABRAIN_ENTITLEMENTS,
  METABRAIN_RELEASE_VERSION, METABRAIN_DIST_DIR, METABRAIN_RELEASE_BUILD_DIR

Example:
  Scripts/build-release.sh \
    --identity "Developer ID Application: Example, Inc. (ABCDE12345)" \
    --notary-profile metabrain-notary

Create a notary profile once with:
  xcrun notarytool store-credentials metabrain-notary \
    --apple-id you@example.com --team-id ABCDE12345 --password app-specific-password
USAGE
}

discover_sign_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application/ { print $2; exit }'
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

archs_overridden=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      SIGN_IDENTITY="${2:?--identity requires a value}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:?--notary-profile requires a value}"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="${2:?--apple-id requires a value}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:?--team-id requires a value}"
      shift 2
      ;;
    --app-password)
      APP_PASSWORD="${2:?--app-password requires a value}"
      shift 2
      ;;
    --entitlements)
      ENTITLEMENTS="${2:?--entitlements requires a value}"
      shift 2
      ;;
    --version)
      VERSION="${2:?--version requires a value}"
      shift 2
      ;;
    --dist-dir)
      DIST_DIR="${2:?--dist-dir requires a value}"
      shift 2
      ;;
    --build-root)
      BUILD_ROOT="${2:?--build-root requires a value}"
      shift 2
      ;;
    --skip-sign)
      SKIP_SIGN=1
      shift
      ;;
    --skip-notarization)
      SKIP_NOTARIZATION=1
      shift
      ;;
    --arch)
      if [[ "${archs_overridden}" -eq 0 ]]; then
        ARCHS=()
        archs_overridden=1
      fi
      ARCHS+=("${2:?--arch requires a value}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "${ROOT_DIR}"

require_tool swift
require_tool lipo
require_tool ditto
require_tool xcrun

if [[ "${SKIP_SIGN}" -eq 0 ]]; then
  require_tool codesign
fi

if [[ "${#ARCHS[@]}" -eq 0 ]]; then
  echo "At least one --arch value is required." >&2
  exit 2
fi

if [[ -z "${VERSION}" ]]; then
  VERSION="$(git describe --tags --always --dirty 2>/dev/null || date -u +%Y%m%d%H%M%S)"
fi

if [[ "${SKIP_SIGN}" -eq 0 && -z "${SIGN_IDENTITY}" ]]; then
  SIGN_IDENTITY="$(discover_sign_identity || true)"
fi

if [[ "${SKIP_SIGN}" -eq 1 && "${SKIP_NOTARIZATION}" -eq 0 ]]; then
  cat >&2 <<'MESSAGE'
Notarization requires a signed binary.
Rerun without --skip-sign, or use --skip-sign together with --skip-notarization for local build checks.
MESSAGE
  exit 1
fi

if [[ "${SKIP_SIGN}" -eq 0 && -z "${SIGN_IDENTITY}" ]]; then
  cat >&2 <<'MESSAGE'
No Developer ID Application signing identity was provided or discovered.
Pass --identity, set METABRAIN_SIGN_IDENTITY, or rerun with --skip-sign.
MESSAGE
  exit 1
fi

if [[ -n "${ENTITLEMENTS}" && ! -f "${ENTITLEMENTS}" ]]; then
  echo "Entitlements file not found: ${ENTITLEMENTS}" >&2
  exit 1
fi

if [[ "${SKIP_NOTARIZATION}" -eq 0 ]]; then
  NOTARY_ARGS=()
  if [[ -n "${NOTARY_PROFILE}" ]]; then
    NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
  elif [[ -n "${APPLE_ID}" && -n "${TEAM_ID}" && -n "${APP_PASSWORD}" ]]; then
    NOTARY_ARGS=(--apple-id "${APPLE_ID}" --team-id "${TEAM_ID}" --password "${APP_PASSWORD}")
  else
    cat >&2 <<'MESSAGE'
No notarization credentials were provided.
Pass --notary-profile, or pass --apple-id, --team-id, and --app-password.
For local build checks, rerun with --skip-notarization.
MESSAGE
    exit 1
  fi
fi

echo "Building ${PRODUCT_NAME} ${VERSION} for macOS architectures: ${ARCHS[*]}"
rm -rf "${BUILD_ROOT}"
mkdir -p "${DIST_DIR}"

arch_binaries=()
for arch in "${ARCHS[@]}"; do
  scratch_path="${BUILD_ROOT}/${arch}"
  echo "Building ${arch} release binary..."
  swift build \
    -c release \
    --product "${PRODUCT_NAME}" \
    --arch "${arch}" \
    --scratch-path "${scratch_path}"

  bin_path="$(swift build \
    -c release \
    --product "${PRODUCT_NAME}" \
    --arch "${arch}" \
    --scratch-path "${scratch_path}" \
    --show-bin-path)"
  arch_binary="${bin_path}/${PRODUCT_NAME}"

  if [[ ! -x "${arch_binary}" ]]; then
    echo "Expected executable not found: ${arch_binary}" >&2
    exit 1
  fi

  arch_binaries+=("${arch_binary}")
done

release_name="${PRODUCT_NAME}-${VERSION}-macos-universal"
release_dir="${DIST_DIR}/${release_name}"
binary_path="${release_dir}/bin/${PRODUCT_NAME}"
archive_path="${DIST_DIR}/${release_name}.zip"
checksum_path="${archive_path}.sha256"

rm -rf "${release_dir}" "${archive_path}" "${checksum_path}"
mkdir -p "${release_dir}/bin"

if [[ "${#arch_binaries[@]}" -eq 1 ]]; then
  install -m 0755 "${arch_binaries[0]}" "${binary_path}"
else
  echo "Creating universal binary..."
  lipo -create "${arch_binaries[@]}" -output "${binary_path}"
  chmod 0755 "${binary_path}"
fi

install -m 0644 "${ROOT_DIR}/README.md" "${release_dir}/README.md"
install -m 0644 "${ROOT_DIR}/LICENSE" "${release_dir}/LICENSE"

lipo -info "${binary_path}"

if [[ "${SKIP_SIGN}" -eq 0 ]]; then
  sign_args=(
    --force
    --timestamp
    --options runtime
    --sign "${SIGN_IDENTITY}"
  )

  if [[ -n "${ENTITLEMENTS}" ]]; then
    sign_args+=(--entitlements "${ENTITLEMENTS}")
  fi

  echo "Signing ${binary_path}..."
  codesign "${sign_args[@]}" "${binary_path}"
  codesign --verify --strict --verbose=2 "${binary_path}"
else
  echo "Skipping codesign."
fi

echo "Creating notarization archive..."
(
  cd "${DIST_DIR}"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "${release_name}" "${archive_path}"
)

if [[ "${SKIP_NOTARIZATION}" -eq 0 ]]; then
  echo "Submitting ${archive_path} for notarization..."
  xcrun notarytool submit "${archive_path}" --wait "${NOTARY_ARGS[@]}"
  echo "Notarization accepted for ${archive_path}."
  echo "Standalone CLI zip archives are not stapled; distribute this notarized zip."
else
  echo "Skipping notarization."
fi

echo "Writing SHA-256 checksum..."
if command -v shasum >/dev/null 2>&1; then
  (
    cd "${DIST_DIR}"
    shasum -a 256 "$(basename "${archive_path}")" > "${checksum_path}"
  )
else
  checksum="$(swift package compute-checksum "${archive_path}")"
  printf '%s  %s\n' "${checksum}" "$(basename "${archive_path}")" > "${checksum_path}"
fi

echo "Release binary: ${binary_path}"
echo "Release archive: ${archive_path}"
echo "Release checksum: ${checksum_path}"
