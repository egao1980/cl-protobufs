;;; Loaded after ensure-packager.lisp — packager/oci-client packages exist.
;;; generated-source overlays are why this repo cannot call the reusable
;;; native workflow yet (that one ships native-library + optional grovel).

(defun env (name &optional default)
  (or (uiop:getenv name) default))

(defparameter *generated-files*
  '(("descriptor.lisp" . "descriptor.lisp")
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

(defun %hide-bootstrap (source-dir)
  "Move .cl-repository out of SOURCE-DIR so the packager does not ship it."
  (let* ((root (uiop:ensure-directory-pathname source-dir))
         (bootstrap (merge-pathnames ".cl-repository/" root)))
    (when (uiop:directory-exists-p bootstrap)
      (let* ((stash-parent (uiop:ensure-directory-pathname
                            (or (uiop:getenv "RUNNER_TEMP")
                                (namestring (uiop:temporary-directory)))))
             (dest (merge-pathnames "cl-repository-bootstrap/" stash-parent)))
        (when (uiop:directory-exists-p dest)
          (uiop:delete-directory-tree dest :validate t :if-does-not-exist :ignore))
        (ensure-directories-exist stash-parent)
        (uiop:run-program (list "mv" (namestring bootstrap) (namestring dest))
                          :output t :error-output t)
        (format t "~&; ci: hid .cl-repository -> ~a~%" dest)))))

(defun %platforms (overlay-root)
  (let ((file (env "PLATFORMS_FILE")))
    (if (and file (probe-file file))
        (loop for line in (uiop:read-file-lines file)
              for slash = (position #\/ line)
              when slash
                collect (list (subseq line 0 slash) (subseq line (1+ slash))))
        (let ((found nil))
          (dolist (os '("darwin" "linux"))
            (dolist (arch '("arm64" "amd64"))
              (when (uiop:directory-exists-p
                     (merge-pathnames (format nil "lib/~a-~a/" os arch) overlay-root))
                (push (list os arch) found))))
          (or (nreverse found)
              (error "No overlay platforms under ~a and no PLATFORMS_FILE" overlay-root))))))

(defun %make-overlay (overlay-root os arch)
  (let* ((prefix (format nil "~a-~a" os arch))
         (lib-dir (merge-pathnames (format nil "lib/~a/" prefix) overlay-root))
         (native-files
           (loop for p in (uiop:directory-files lib-dir)
                 collect (cons (namestring p) (file-namestring p)))))
    (unless native-files
      (error "No native files found under ~a" lib-dir))
    (make-instance 'cl-repository-packager/build-matrix:overlay-spec
      :os os :arch arch
      :layers
      (list
       (list :role "native-library" :files native-files)
       (list :role "generated-source"
             :files (mapcar
                     (lambda (pair)
                       (cons (namestring
                              (merge-pathnames
                               (format nil "generated/~a/~a" prefix (car pair))
                               overlay-root))
                             (cdr pair)))
                     *generated-files*))))))

(let* ((version (or (env "PKG_VERSION")
                    (error "PKG_VERSION required")))
       (registry (env "OCI_REGISTRY" "ghcr.io"))
       (registry-url (or (env "REGISTRY_URL")
                         (if (string= registry "ghcr.io")
                             "https://ghcr.io"
                             (format nil "http://~a" registry))))
       (namespace (env "OCI_NAMESPACE" "egao1980/cl-systems"))
       (source-dir (uiop:ensure-directory-pathname
                    (or (env "SOURCE_DIR") (uiop:getcwd))))
       (overlay-root (uiop:ensure-directory-pathname
                      (or (env "OVERLAY_ROOT")
                          (error "OVERLAY_ROOT required"))))
       (use-auth (string= "ghcr.io" registry))
       (skip-catalog (if (env "SKIP_CATALOG")
                         (string-equal "true" (env "SKIP_CATALOG"))
                         use-auth))
       (auth (when use-auth
               (cl-oci-client/auth:make-auth-config
                :username (env "GITHUB_ACTOR")
                :password (env "GITHUB_TOKEN"))))
       (reg (if use-auth
                (cl-oci-client/registry:make-registry registry-url :auth auth)
                (cl-oci-client/registry:make-registry registry-url)))
       (platforms (%platforms overlay-root))
       (overlays (mapcar (lambda (pair)
                           (%make-overlay overlay-root (first pair) (second pair)))
                         platforms)))
  (%hide-bootstrap source-dir)
  (let* ((spec (make-instance 'cl-repository-packager/build-matrix:package-spec
                 :name "cl-protobufs"
                 :version version
                 :source-dir source-dir
                 :license "MIT"
                 :description "Protocol Buffers for Common Lisp"
                 :depends-on '("closer-mop" "alexandria" "trivial-garbage"
                               "cl-base64" "local-time" "float-features")
                 :provides '("cl-protobufs" "cl-protobufs.asdf")
                 :overlays overlays))
         (result (cl-repository-packager/build-matrix:build-package spec)))
    (format t "~%Overlays: ~{~a~^, ~}~%"
            (mapcar (lambda (p) (format nil "~a/~a" (first p) (second p))) platforms))
    (cl-repository-packager/publisher:publish-package
     reg namespace version result spec :skip-catalog skip-catalog)
    (format t "Published cl-protobufs:~a to ~a/~a~%" version registry-url namespace)))
