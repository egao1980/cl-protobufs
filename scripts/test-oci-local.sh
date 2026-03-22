#!/usr/bin/env bash
# Test the full OCI publish pipeline locally for cl-protobufs.
# Builds both darwin/arm64 (natively) and linux/amd64 (via Docker) overlays,
# publishes to a local OCI registry, and verifies the resulting image index.
#
# Prerequisites: docker, sbcl, oras, brew (protobuf, cmake, pkg-config)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="localhost:5050"
NAMESPACE="cl-systems"
VERSION="${1:-2.0}"
CONTAINER_NAME="cl-oci-test-registry"
CL_SYSTEMS_DIR="${HOME}/.local/share/cl-systems"
TMPDIR_PULL="$(mktemp -d)"
BUILD_IMAGE="cl-protobufs-builder:latest"

cleanup() {
  echo "==> Cleanup"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$TMPDIR_PULL"
  rm -rf "${PROJECT_DIR}/lib" "${PROJECT_DIR}/generated"
}
trap cleanup EXIT

# ── Prerequisites ────────────────────────────────────────────────────
echo "==> Checking prerequisites"
for cmd in docker sbcl oras cmake protoc; do
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
generate_wkt generated/darwin-arm64 protoc/protoc-gen-cl-pb
echo "    Generated $(ls generated/darwin-arm64/*.lisp | wc -l | tr -d ' ') .lisp files"

echo "==> Collecting native overlay artifacts (darwin/arm64)"
rm -rf lib/darwin-arm64
mkdir -p lib/darwin-arm64
install -m 755 "$(realpath "$(brew --prefix)/bin/protoc")" lib/darwin-arm64/protoc
install -m 755 protoc/protoc-gen-cl-pb lib/darwin-arm64/protoc-gen-cl-pb

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
  -w /src \
  "$BUILD_IMAGE" \
  bash -c '
    set -euo pipefail
    # Out-of-source build; stale .pb.h from host must not shadow generated ones
    rm -f protoc/proto2-descriptor-extensions.pb.{h,cc}
    cmake -S protoc -B /tmp/protoc-build -DCMAKE_CXX_STANDARD=17 > /dev/null 2>&1
    cmake --build /tmp/protoc-build --parallel "$(nproc)" 2>&1 | tail -3
    echo "Built: $(file /tmp/protoc-build/protoc-gen-cl-pb | cut -d: -f2)"

    mkdir -p generated/linux-amd64
    for proto in descriptor any source_context type api duration empty field_mask timestamp wrappers struct; do
      protoc --proto_path=google/protobuf/ \
        --plugin=protoc-gen-cl-pb=/tmp/protoc-build/protoc-gen-cl-pb \
        "--cl-pb_out=output-file=${proto}.lisp:generated/linux-amd64/" \
        "${proto}.proto" \
        --experimental_allow_proto3_optional
    done
    echo "Generated $(ls generated/linux-amd64/*.lisp | wc -l) .lisp files"

    mkdir -p lib/linux-amd64
    install -m 755 "$(realpath "$(brew --prefix)/bin/protoc")" lib/linux-amd64/protoc
    install -m 755 /tmp/protoc-build/protoc-gen-cl-pb lib/linux-amd64/protoc-gen-cl-pb
  '

echo "==> Built artifacts:"
find "${PROJECT_DIR}/lib" -type f
find "${PROJECT_DIR}/generated" -name '*.lisp' | wc -l | xargs -I{} echo "    {} generated .lisp files total"

# ── Start local OCI registry ─────────────────────────────────────────
echo "==> Starting local OCI registry on ${REGISTRY}"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d -p 5050:5000 --name "$CONTAINER_NAME" registry:2
sleep 1

# ── Pull cl-repository-packager ──────────────────────────────────────
CL_REPO_TAG="0.8.0"
CL_REPO_IMAGE="ghcr.io/egao1980/cl-repository/cl-repository-packager"
echo "==> Pulling cl-repository-packager:${CL_REPO_TAG} from GHCR"
rm -rf "$TMPDIR_PULL"
mkdir -p "$TMPDIR_PULL"
mkdir -p "$CL_SYSTEMS_DIR"
rm -rf "$CL_SYSTEMS_DIR"/cl-oci-*
oras pull "${CL_REPO_IMAGE}:${CL_REPO_TAG}" -o "$TMPDIR_PULL/"

for f in "$TMPDIR_PULL"/*.tar.gz; do
  [ -f "$f" ] && tar -xzf "$f" -C "$CL_SYSTEMS_DIR/"
done
echo "    Extracted to ${CL_SYSTEMS_DIR}:"
ls "$CL_SYSTEMS_DIR/"

# ── Publish OCI package ──────────────────────────────────────────────
echo "==> Publishing OCI package to ${REGISTRY}/${NAMESPACE}/cl-protobufs:${VERSION}"
cat > "${TMPDIR_PULL}/publish.lisp" <<'LISP'
(require :asdf)

(asdf:initialize-source-registry
  '(:source-registry
    (:tree (:home ".local/share/cl-systems/"))
    :inherit-configuration))

(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup) (load ql-setup)))

(ql:quickload :cl-repository-packager)

(let* ((version (uiop:getenv "PKG_VERSION"))
       (registry-url (uiop:getenv "OCI_REGISTRY"))
       (namespace (uiop:getenv "OCI_NAMESPACE"))
       (source-dir (uiop:getenv "SOURCE_DIR"))
       (reg (cl-oci-client/registry:make-registry registry-url))
       (generated-files '(("descriptor.lisp" . "descriptor.lisp")
                          ("any.lisp" . "any.lisp")
                          ("source_context.lisp" . "source_context.lisp")
                          ("type.lisp" . "type.lisp")
                          ("api.lisp" . "api.lisp")
                          ("duration.lisp" . "duration.lisp")
                          ("empty.lisp" . "empty.lisp")
                          ("field_mask.lisp" . "field_mask.lisp")
                          ("timestamp.lisp" . "timestamp.lisp")
                          ("wrappers.lisp" . "wrappers.lisp")
                          ("struct.lisp" . "struct.lisp")))
       (spec (make-instance 'cl-repository-packager/build-matrix:package-spec
               :name "cl-protobufs"
               :version version
               :source-dir (pathname source-dir)
               :license "MIT"
               :description "Protocol Buffers for Common Lisp"
               :depends-on '("closer-mop" "alexandria" "trivial-garbage"
                             "cl-base64" "local-time" "float-features")
               :provides '("cl-protobufs" "cl-protobufs.asdf")
               :overlays
               (flet ((make-overlay (os arch)
                        (let ((prefix (format nil "~a-~a" os arch)))
                          (make-instance 'cl-repository-packager/build-matrix:overlay-spec
                            :os os :arch arch
                            :layers
                            (list
                             (list :role "native-library"
                                   :files (list
                                           (cons (format nil "lib/~a/protoc" prefix) "protoc")
                                           (cons (format nil "lib/~a/protoc-gen-cl-pb" prefix)
                                                 "protoc-gen-cl-pb")))
                             (list :role "generated-source"
                                   :files (mapcar (lambda (pair)
                                                    (cons (format nil "generated/~a/~a" prefix (car pair))
                                                          (cdr pair)))
                                                  generated-files)))))))
                 (list (make-overlay "darwin" "arm64")
                       (make-overlay "linux" "amd64")))))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (cl-repository-packager/publisher:publish-package
    reg namespace version result spec)
  (format t "~%Published cl-protobufs:~a to ~a/~a~%" version registry-url namespace))
LISP

PKG_VERSION="$VERSION" \
OCI_REGISTRY="http://${REGISTRY}" \
OCI_NAMESPACE="$NAMESPACE" \
SOURCE_DIR="${PROJECT_DIR}/" \
sbcl --noinform --non-interactive --load "${TMPDIR_PULL}/publish.lisp"

# ── Verify ────────────────────────────────────────────────────────────
echo "==> Verifying published artifact"
oras manifest fetch "${REGISTRY}/${NAMESPACE}/cl-protobufs:${VERSION}" --insecure

echo ""
echo "==> Success! Published cl-protobufs:${VERSION} to ${REGISTRY}/${NAMESPACE}"
echo "    Pull with: oras pull --insecure ${REGISTRY}/${NAMESPACE}/cl-protobufs:${VERSION}"
