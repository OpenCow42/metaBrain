#!/usr/bin/env bash
set -euo pipefail
commit="$1"
unset METABRAIN_VERSION
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf'
export GIT_CONFIG_VALUE_0='git@github.com:'
work=$(mktemp -d "$HOME/metabrain-1.3.0.XXXXXX")
echo "BUILD_DIR=$work"
git clone --quiet --no-checkout https://github.com/OpenCow42/metaBrain.git "$work"
cd "$work"
git checkout --quiet --detach "$commit"
[[ "$(git rev-parse HEAD)" == "$commit" ]]
uname -sm
swift --version
bash Scripts/build-linux-release.sh --version 1.3.0
case "$(uname -m)" in
  x86_64) deb_arch=amd64; tar_arch=x86_64 ;;
  aarch64) deb_arch=arm64; tar_arch=aarch64 ;;
  *) exit 1 ;;
esac
cd dist
sha256sum -c ./*.sha256
archive="mb-1.3.0-linux-$tar_arch.tar.gz"
deb="metabrain_1.3.0_$deb_arch.deb"
test "$(dpkg-deb -f "$deb" Architecture)" = "$deb_arch"
test "$(dpkg-deb -f "$deb" Version)" = 1.3.0
scratch=$(mktemp -d "$work/validate.XXXXXX")
tar -xzf "$archive" -C "$scratch"
dpkg-deb -x "$deb" "$scratch/deb"
for binaries in "$scratch/mb-1.3.0-linux-$tar_arch/bin" "$scratch/deb/usr/bin"; do
  version=$("$binaries/mb" version --no-server --no-release-check)
  printf '%s\n' "$version" | grep -Fq '"currentTag":"1.3.0"'
  version=$("$binaries/mbd" version)
  printf '%s\n' "$version" | grep -Fq '"currentTag":"1.3.0"'
  "$binaries/mb" init --no-server --store "$scratch/store.leveldb" >/dev/null
  "$binaries/mb" put --no-server --store "$scratch/store.leveldb" /release 'release smoke passed' >/dev/null
  content=$("$binaries/mb" get --no-server --store "$scratch/store.leveldb" /release)
  printf '%s\n' "$content" | grep -Fq 'release smoke passed'
done
cd "$work"
METABRAIN_DAEMON_BIN="$scratch/deb/usr/bin/mbd" METABRAIN_CLIENT_BIN="$scratch/deb/usr/bin/mb" \
  bash Tests/MetaBrainServerTests/daemon-smoke.sh
printf 'VERIFIED=%s %s\n' "$deb_arch" "$commit"
