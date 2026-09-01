#!/usr/bin/env bash
# Test the full OCI publish pipeline locally for cl-protobufs.
# Builds both darwin/arm64 (natively) and linux/amd64 (via Docker) overlays,
# publishes to a local OCI registry, and verifies the resulting image index.
#
# Prerequisites: docker, ros (setup-lisp / cl-repository-client), oras, brew (protobuf, cmake, pkg-config)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="localhost:5050"
NAMESPACE="cl-systems"
VERSION="${1:-2.0}"
CONTAINER_NAME="cl-oci-test-registry"
BUILD_IMAGE="cl-protobufs-builder:latest"
# Stage overlays OUTSIDE the checkout: build-package tars the whole source
# dir into the source layer, so lib/ and generated/ staged in the repo would
# be swept into the published source tarball. /tmp is docker-shareable.
OVERLAY_ROOT="$(mktemp -d /tmp/cl-pb-overlays.XXXXXX)"
# Official static protoc shipped in the native overlay (brew's protoc is
# dynamically linked against brew libs and breaks on machines without them).
PROTOC_VERSION="34.1"

fetch_protoc() {
  local platform="$1" dest_dir="$2" zip
  zip="$(mktemp -t protoc-zip)"
  curl -fsSL -o "$zip" \
    "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-${platform}.zip"
  unzip -j -o -q "$zip" bin/protoc -d "$dest_dir"
  chmod 755 "${dest_dir}/protoc"
  rm -f "$zip"
}

cleanup() {
  echo "==> Cleanup"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$OVERLAY_ROOT"
}
trap cleanup EXIT

# ── Prerequisites ────────────────────────────────────────────────────
echo "==> Checking prerequisites"
for cmd in docker ros oras cmake protoc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found. Install it first." >&2
    exit 1
  fi
done

# ── Helper: pre-generate well-known-types .lisp files ────────────────
generate_wkt() {
  local out_dir="$1" plugin_path="$2"
  mkdir -p "$out_dir"
  # Use --proto_path=google/protobuf/ with bare filenames to match
  # how ASDF's proto-to-lisp invokes protoc (bare add-file-descriptor names)
  for proto in descriptor any source_context type api duration empty field_mask timestamp wrappers struct; do
    protoc --proto_path=google/protobuf/ \
      --plugin=protoc-gen-cl-pb="$plugin_path" \
      "--cl-pb_out=output-file=${proto}.lisp:${out_dir}/" \
      "${proto}.proto" \
      --experimental_allow_proto3_optional
  done
}

# ══════════════════════════════════════════════════════════════════════
# darwin/arm64 — native build
# ══════════════════════════════════════════════════════════════════════
echo "==> Building protoc-gen-cl-pb (darwin/arm64)"
cd "${PROJECT_DIR}/protoc"
cmake . -DCMAKE_CXX_STANDARD=17 > /tmp/cl-pb-cmake.log 2>&1
cmake --build . --parallel "$(sysctl -n hw.ncpu)" >> /tmp/cl-pb-cmake.log 2>&1
echo "    Built: $(file protoc-gen-cl-pb | cut -d: -f2)"
cd "${PROJECT_DIR}"

echo "==> Pre-generating well-known-types .lisp (darwin/arm64)"
generate_wkt "${OVERLAY_ROOT}/generated/darwin-arm64" protoc/protoc-gen-cl-pb
echo "    Generated $(ls "${OVERLAY_ROOT}"/generated/darwin-arm64/*.lisp | wc -l | tr -d ' ') .lisp files"

echo "==> Collecting native overlay artifacts (darwin/arm64)"
mkdir -p "${OVERLAY_ROOT}/lib/darwin-arm64"
scripts/bundle-protoc-plugin.sh protoc/protoc-gen-cl-pb "${OVERLAY_ROOT}/lib/darwin-arm64" > /tmp/cl-pb-bundle.log 2>&1 \
  || { tail -20 /tmp/cl-pb-bundle.log; exit 1; }
fetch_protoc osx-aarch_64 "${OVERLAY_ROOT}/lib/darwin-arm64"

# ══════════════════════════════════════════════════════════════════════
# linux/amd64 — Docker build
# ══════════════════════════════════════════════════════════════════════
echo "==> Ensuring Docker build image (${BUILD_IMAGE})"
if ! docker image inspect "$BUILD_IMAGE" &>/dev/null; then
  echo "    Building image from Dockerfile.protobuf-builder (this takes a while the first time)..."
  docker build --platform linux/amd64 -t "$BUILD_IMAGE" \
    -f "${PROJECT_DIR}/Dockerfile.protobuf-builder" "${PROJECT_DIR}" \
    > /tmp/cl-pb-docker-build.log 2>&1 \
    || { tail -50 /tmp/cl-pb-docker-build.log; exit 1; }
fi

echo "==> Building protoc-gen-cl-pb + generating .lisp (linux/amd64) via Docker"
docker run --rm --platform linux/amd64 \
  -v "${PROJECT_DIR}:/src" \
  -v "${OVERLAY_ROOT}:/out" \
  -w /src \
  "$BUILD_IMAGE" \
  bash -c '
    set -euo pipefail
    # Out-of-source build; stale .pb.h from host must not shadow generated ones
    rm -f protoc/proto2-descriptor-extensions.pb.{h,cc}
    cmake -S protoc -B /tmp/protoc-build -DCMAKE_CXX_STANDARD=17 > /dev/null 2>&1
    cmake --build /tmp/protoc-build --parallel "$(nproc)" 2>&1 | tail -3
    echo "Built: $(file /tmp/protoc-build/protoc-gen-cl-pb | cut -d: -f2)"

    mkdir -p /out/generated/linux-amd64
    for proto in descriptor any source_context type api duration empty field_mask timestamp wrappers struct; do
      protoc --proto_path=google/protobuf/ \
        --plugin=protoc-gen-cl-pb=/tmp/protoc-build/protoc-gen-cl-pb \
        "--cl-pb_out=output-file=${proto}.lisp:/out/generated/linux-amd64/" \
        "${proto}.proto" \
        --experimental_allow_proto3_optional
    done
    echo "Generated $(ls /out/generated/linux-amd64/*.lisp | wc -l) .lisp files"

    mkdir -p /out/lib/linux-amd64
    scripts/bundle-protoc-plugin.sh /tmp/protoc-build/protoc-gen-cl-pb /out/lib/linux-amd64 | tail -2
    curl -fsSL -o /tmp/protoc.zip \
      "https://github.com/protocolbuffers/protobuf/releases/download/v'"${PROTOC_VERSION}"'/protoc-'"${PROTOC_VERSION}"'-linux-x86_64.zip"
    unzip -j -o -q /tmp/protoc.zip bin/protoc -d /out/lib/linux-amd64
    chmod 755 /out/lib/linux-amd64/protoc
  '

echo "==> Built artifacts:"
find "${OVERLAY_ROOT}/lib" -type f
find "${OVERLAY_ROOT}/generated" -name '*.lisp' | wc -l | xargs -I{} echo "    {} generated .lisp files total"

# ── Start local OCI registry ─────────────────────────────────────────
echo "==> Starting local OCI registry on ${REGISTRY}"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d -p 5050:5000 --name "$CONTAINER_NAME" registry:2
sleep 1

# ── Publish OCI package (setup-lisp client + ensure-systems, no QL) ──
echo "==> Publishing OCI package to ${REGISTRY}/${NAMESPACE}/cl-protobufs:${VERSION}"
if [[ -z "${CL_SOURCE_REGISTRY:-}" ]]; then
  echo "ERROR: CL_SOURCE_REGISTRY unset. Bootstrap cl-repository-client first (setup-lisp / setup-client)." >&2
  exit 1
fi

PKG_VERSION="$VERSION" \
OCI_REGISTRY="${REGISTRY}" \
REGISTRY_URL="http://${REGISTRY}" \
OCI_NAMESPACE="$NAMESPACE" \
SOURCE_DIR="${PROJECT_DIR}/" \
OVERLAY_ROOT="${OVERLAY_ROOT}/" \
SKIP_CATALOG=false \
ros -l "${PROJECT_DIR}/scripts/ci/publish-oci.lisp" -q

# ── Verify ────────────────────────────────────────────────────────────
echo "==> Verifying published artifact"
oras manifest fetch "${REGISTRY}/${NAMESPACE}/cl-protobufs:${VERSION}" --insecure

echo ""
echo "==> Success! Published cl-protobufs:${VERSION} to ${REGISTRY}/${NAMESPACE}"
echo "    Pull with: oras pull --insecure ${REGISTRY}/${NAMESPACE}/cl-protobufs:${VERSION}"
