;;; Publish cl-protobufs with native-library + generated-source overlays.
;;; Packager loads via ensure-packager.lisp (setup-lisp + ensure-systems).
;;;
;;; Env: PKG_VERSION OCI_REGISTRY REGISTRY_URL OCI_NAMESPACE
;;;      GITHUB_ACTOR GITHUB_TOKEN OVERLAY_ROOT SOURCE_DIR
;;;      PLATFORMS_FILE (optional; default darwin/arm64 + linux/amd64)
;;;      SKIP_CATALOG (default true for GHCR, false otherwise)
;;;      PACKAGER_VERSION (empty / latest → client default)

(require :asdf)
(load (merge-pathnames "ensure-packager.lisp" *load-truename*))
(load (merge-pathnames "publish-oci-impl.lisp" *load-truename*))
