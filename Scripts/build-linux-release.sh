#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="mb"
PACKAGE_NAME="metabrain"
VERSION="${METABRAIN_RELEASE_VERSION:-}"
TAG="${METABRAIN_RELEASE_TAG:-}"
DIST_DIR="${METABRAIN_DIST_DIR:-${ROOT_DIR}/dist}"
BUILD_ROOT="${METABRAIN_RELEASE_BUILD_DIR:-${ROOT_DIR}/.build/release-linux}"
REPO="${METABRAIN_GITHUB_REPO:-}"
UPLOAD=0

usage() {
  cat <<'USAGE'
Usage: Scripts/build-linux-release.sh --version <version> [options]

Build Ubuntu/Linux release artifacts for the mb CLI:
  - dist/mb-<version>-linux-x86_64.tar.gz
  - dist/metabrain_<version>_amd64.deb
  - SHA-256 checksum files for both artifacts

Options:
  --version <version>    Release version, for example 1.1.1.
  --tag <tag>            GitHub release tag. Defaults to the version.
  --dist-dir <path>      Output directory. Defaults to ./dist.
  --build-root <path>    Build scratch root. Defaults to ./.build/release-linux.
  --repo <owner/name>    GitHub repository for upload. Defaults from git remote origin.
  --upload               Create/update the GitHub release and upload artifacts with gh.
  -h, --help             Show this help.

Environment aliases:
  METABRAIN_RELEASE_VERSION, METABRAIN_RELEASE_TAG, METABRAIN_DIST_DIR,
  METABRAIN_RELEASE_BUILD_DIR, METABRAIN_GITHUB_REPO

Example:
  Scripts/build-linux-release.sh --version 1.1.1 --upload
USAGE
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

write_checksum() {
  local path="$1"
  (
    cd "$(dirname "$path")"
    sha256sum "$(basename "$path")"
  ) > "${path}.sha256"
}

infer_repo() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  case "$remote" in
    git@github.com:*.git)
      remote="${remote#git@github.com:}"
      remote="${remote%.git}"
      ;;
    https://github.com/*.git)
      remote="${remote#https://github.com/}"
      remote="${remote%.git}"
      ;;
    https://github.com/*)
      remote="${remote#https://github.com/}"
      ;;
    *)
      remote=""
      ;;
  esac
  printf '%s\n' "$remote"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:?--version requires a value}"
      shift 2
      ;;
    --tag)
      TAG="${2:?--tag requires a value}"
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
    --repo)
      REPO="${2:?--repo requires a value}"
      shift 2
      ;;
    --upload)
      UPLOAD=1
      shift
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

if [[ -z "$VERSION" ]]; then
  echo "--version is required." >&2
  usage >&2
  exit 2
fi

if [[ -z "$TAG" ]]; then
  TAG="$VERSION"
fi

cd "$ROOT_DIR"

require_tool swift
require_tool tar
require_tool dpkg-deb
require_tool install
require_tool sha256sum
require_tool strip

machine="$(uname -m)"
case "$machine" in
  x86_64|amd64)
    platform_slug="linux-x86_64"
    deb_arch="amd64"
    ;;
  aarch64|arm64)
    platform_slug="linux-aarch64"
    deb_arch="arm64"
    ;;
  *)
    echo "Unsupported Linux architecture: $machine" >&2
    exit 1
    ;;
esac

if [[ "$UPLOAD" -eq 1 ]]; then
  require_tool gh
  if [[ -z "$REPO" ]]; then
    REPO="$(infer_repo)"
  fi
  if [[ -z "$REPO" ]]; then
    echo "Could not infer GitHub repo. Pass --repo owner/name." >&2
    exit 1
  fi
fi

echo "Building ${PRODUCT_NAME} ${VERSION} for ${platform_slug}..."
swift build -c release --product "$PRODUCT_NAME" --static-swift-stdlib
bin_dir="$(swift build -c release --product "$PRODUCT_NAME" --show-bin-path)"
built_binary="${bin_dir}/${PRODUCT_NAME}"

if [[ ! -x "$built_binary" ]]; then
  echo "Expected executable not found: $built_binary" >&2
  exit 1
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$DIST_DIR" "$BUILD_ROOT"

archive_name="${PRODUCT_NAME}-${VERSION}-${platform_slug}"
archive_dir="${BUILD_ROOT}/${archive_name}"
archive_path="${DIST_DIR}/${archive_name}.tar.gz"
deb_name="${PACKAGE_NAME}_${VERSION}_${deb_arch}"
deb_root="${BUILD_ROOT}/${deb_name}"
deb_path="${DIST_DIR}/${deb_name}.deb"

rm -rf "$archive_dir" "$deb_root" "$archive_path" "${archive_path}.sha256" "$deb_path" "${deb_path}.sha256"

install -d "$archive_dir/bin"
install -m 0755 "$built_binary" "$archive_dir/bin/$PRODUCT_NAME"
strip "$archive_dir/bin/$PRODUCT_NAME"
install -m 0644 README.md "$archive_dir/README.md"
install -m 0644 LICENSE "$archive_dir/LICENSE"

tar -C "$BUILD_ROOT" -czf "$archive_path" "$archive_name"
write_checksum "$archive_path"

install -d "$deb_root/DEBIAN" "$deb_root/usr/bin" "$deb_root/usr/share/doc/$PACKAGE_NAME"
install -m 0755 "$archive_dir/bin/$PRODUCT_NAME" "$deb_root/usr/bin/$PRODUCT_NAME"
install -m 0644 README.md "$deb_root/usr/share/doc/$PACKAGE_NAME/README.md"
install -m 0644 LICENSE "$deb_root/usr/share/doc/$PACKAGE_NAME/LICENSE"

installed_size="$(du -sk "$deb_root/usr" | awk '{print $1}')"
cat > "$deb_root/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $deb_arch
Depends: libc6, libstdc++6, libgcc-s1
Installed-Size: $installed_size
Maintainer: OpenCow42 <noreply@github.com>
Description: AI-native local memory store CLI
 metaBrain provides the mb command line tool for storing, inspecting,
 searching, and linking structured local memory documents.
EOF

dpkg-deb --root-owner-group --build "$deb_root" "$deb_path"
write_checksum "$deb_path"

echo "Built artifacts:"
printf '  %s\n' "$archive_path" "${archive_path}.sha256" "$deb_path" "${deb_path}.sha256"

if [[ "$UPLOAD" -eq 1 ]]; then
  notes_file="${BUILD_ROOT}/release-notes.md"
  cat > "$notes_file" <<EOF
Initial Ubuntu/Linux packaging support for metaBrain.

Artifacts:
- ${archive_name}.tar.gz: portable Linux CLI archive
- ${deb_name}.deb: Ubuntu/Debian package installing /usr/bin/mb

The Linux binary is built with --static-swift-stdlib and only depends on standard Ubuntu runtime libraries.
EOF

  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$archive_path" "${archive_path}.sha256" "$deb_path" "${deb_path}.sha256" --repo "$REPO" --clobber
  else
    gh release create "$TAG" "$archive_path" "${archive_path}.sha256" "$deb_path" "${deb_path}.sha256" \
      --repo "$REPO" \
      --title "metaBrain ${VERSION}" \
      --notes-file "$notes_file"
  fi
fi
