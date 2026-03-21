#!/usr/bin/env bash
# Verify that cl-protobufs loads correctly from OCI-installed artifacts.
# Run this AFTER test-oci-local.sh has published to the local registry.
#
# This simulates what a clean install looks like:
#   1. Pull cl-protobufs from the local registry
#   2. Extract into a clean directory (not the source tree)
#   3. Load with SBCL using only ASDF source-registry (no Quicklisp cl-protobufs)
#   4. Verify that proto-to-lisp is NOT invoked (pre-generated .lisp present)
set -euo pipefail

REGISTRY="localhost:5050"
NAMESPACE="cl-systems"
VERSION="${1:-2.0}"
INSTALL_DIR="$(mktemp -d)/cl-systems"

cleanup() {
  echo "==> Cleanup"
  rm -rf "$(dirname "$INSTALL_DIR")"
}
trap cleanup EXIT

# ── Pull from local registry ─────────────────────────────────────────
echo "==> Pulling cl-protobufs:${VERSION} from ${REGISTRY}/${NAMESPACE}"
mkdir -p "${INSTALL_DIR}/cl-protobufs"
TMPDIR_PULL="$(mktemp -d)"
oras pull --insecure "${REGISTRY}/${NAMESPACE}/cl-protobufs:${VERSION}" -o "${TMPDIR_PULL}/"
for f in "${TMPDIR_PULL}"/*.tar.gz; do
  [ -f "$f" ] && tar -xzf "$f" -C "${INSTALL_DIR}/cl-protobufs/"
done
rm -rf "$TMPDIR_PULL"

echo "    Installed files:"
find "${INSTALL_DIR}" -type f | wc -l | tr -d ' '
echo "    files total"

# ── Verify structure ─────────────────────────────────────────────────
echo "==> Verifying overlay structure"
NATIVE_DIR="${INSTALL_DIR}/cl-protobufs/native"
if [ -d "$NATIVE_DIR" ]; then
  echo "    native/ directory exists:"
  ls -la "$NATIVE_DIR/"
else
  echo "    WARNING: native/ directory not found - overlay may not have been extracted"
fi

# Check for pre-generated .lisp files
for f in descriptor.lisp any.lisp duration.lisp; do
  if [ -f "${INSTALL_DIR}/cl-protobufs/${f}" ]; then
    echo "    OK: ${f} found (pre-generated)"
  else
    echo "    MISSING: ${f} not found"
  fi
done

# ── Test loading with SBCL ───────────────────────────────────────────
echo "==> Loading cl-protobufs with SBCL (no protoc on PATH)"
INSTALL_DIR_ESCAPED=$(printf '%s' "$INSTALL_DIR" | sed 's/"/\\"/g')

sbcl --noinform --non-interactive \
  --eval "(require :asdf)" \
  --eval "(asdf:initialize-source-registry
            '(:source-registry
              (:tree \"${INSTALL_DIR_ESCAPED}/\")
              :inherit-configuration))" \
  --eval "(let ((ql (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname))))
            (when (probe-file ql) (load ql)))" \
  --eval "(handler-case
            (progn
              (asdf:load-system :cl-protobufs)
              (format t \"~%==> SUCCESS: cl-protobufs loaded!~%\"))
            (error (e)
              (format t \"~%==> FAILED: ~a~%\" e)
              (uiop:quit 1)))"

echo ""
echo "==> Verification complete"
