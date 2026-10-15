#!/bin/bash
# Installs a Swift toolchain in Claude Code cloud sessions so the ControlFlowCore
# tests can run (`swift test --package-path Packages/ControlFlowCore`).
#
# download.swift.org is not reachable from the cloud sandbox, but Docker Hub is,
# so this takes the toolchain layer from the official `swift` image (the same
# toolchain CI's `swift:6.1` container uses) and unpacks it into /opt/swift.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

SWIFT_TAG="${SWIFT_TAG:-6.1-noble}"
PREFIX=/opt/swift

link_tools() {
  for tool in "$PREFIX"/usr/bin/*; do
    ln -sf "$tool" /usr/local/bin/
  done
}

if [ -x "$PREFIX/usr/bin/swift" ]; then
  link_tools
  exit 0
fi

# The libraries the official image installs alongside the toolchain.
export DEBIAN_FRONTEND=noninteractive
apt-get -q update
apt-get -q install -y --no-install-recommends \
  binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev \
  libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config \
  tzdata zlib1g-dev

case "$(dpkg --print-architecture)" in
  amd64) ARCH=amd64 ;;
  arm64) ARCH=arm64 ;;
  *) echo "Unsupported architecture" >&2; exit 1 ;;
esac

REGISTRY=https://registry-1.docker.io/v2/library/swift
TOKEN=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/swift:pull" | jq -r .token)
auth=(-H "Authorization: Bearer $TOKEN")

MANIFEST_DIGEST=$(curl -fsS "${auth[@]}" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  "$REGISTRY/manifests/$SWIFT_TAG" \
  | jq -r --arg arch "$ARCH" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest')

# The toolchain is by far the image's largest layer.
LAYER_DIGEST=$(curl -fsS "${auth[@]}" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
  "$REGISTRY/manifests/$MANIFEST_DIGEST" \
  | jq -r '.layers | max_by(.size) | .digest')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "${auth[@]}" -o "$TMP/layer.tar.gz" "$REGISTRY/blobs/$LAYER_DIGEST"
echo "${LAYER_DIGEST#sha256:}  $TMP/layer.tar.gz" | sha256sum -c --quiet

mkdir -p "$TMP/root"
tar -xzf "$TMP/layer.tar.gz" -C "$TMP/root" usr
if [ ! -x "$TMP/root/usr/bin/swift" ]; then
  echo "Layer $LAYER_DIGEST of swift:$SWIFT_TAG has no usr/bin/swift" >&2
  exit 1
fi
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
mv "$TMP/root/usr" "$PREFIX/usr"

link_tools
swift --version
