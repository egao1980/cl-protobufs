;;;; Keep in sync with cl-repository/scripts/ci/ensure-packager.lisp until
;;;; generated-source overlays land on publish-native-package.yml.
;;;; Load packager + oci-client the same way canned `ci` phase:publish does.
;;;; Requires setup-lisp (client tree in CL_REPOSITORY_DEST; see %client-registry).
;;;; Do not colon-qualify packager/oci-client symbols here — this file is
;;;; LOADed before those systems exist.

(require :asdf)

(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&UNHANDLED: ~A~%" c)
        (uiop:quit 1)))

#+sbcl (sb-ext:disable-debugger)

(setf asdf:*compile-file-failure-behaviour* :warn)

(defun %ci-muffle (fn)
  #+sbcl
  (handler-bind ((sb-ext:defconstant-uneql
                  (lambda (c)
                    (let ((r (find-restart 'continue c)))
                      (when r (invoke-restart r))))))
    (funcall fn))
  #-sbcl
  (funcall fn))

(defun %client-registry ()
  "setup-lisp no longer exports CL_SOURCE_REGISTRY (5c8af8c); the client tree is
   CL_REPOSITORY_DEST. Register it (and the checkout) the same way the canned ci
   action's %load-client does, inheriting whatever else the job configured."
  (let ((dest (uiop:getenv "CL_REPOSITORY_DEST")))
    (when (and dest (plusp (length dest)))
      (asdf:initialize-source-registry
       `(:source-registry
         (:tree ,(uiop:ensure-directory-pathname dest))
         (:tree ,(uiop:getcwd))
         :inherit-configuration)))))

(%client-registry)
(%ci-muffle (lambda ()
              (asdf:load-system "cl-repository-client")
              ;; Choose the HTTP backend while only the client tree is on
              ;; the registry, outside ASDF's load of the client.
              (let ((ensure (and (find-package "CL-OCI-CLIENT/HTTP")
                                 (find-symbol "ENSURE-HTTP-BACKEND" "CL-OCI-CLIENT/HTTP"))))
                (when (and ensure (fboundp ensure)) (funcall ensure)))))

(defun %env (name &optional default)
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun %ensure-packager ()
  (cl-repo:add-registry "https://ghcr.io" :namespace "egao1980/cl-repository" :priority :prepend)
  (cl-repo:add-registry "https://ghcr.io" :namespace "egao1980/cl-systems" :priority :append)
  (let ((ver (%env "PACKAGER_VERSION")))
    (when (and ver (string-equal ver "latest"))
      (setf ver nil))
    (%ci-muffle
     (lambda ()
       (if ver
           (cl-repo:ensure-systems "cl-repository-packager" :version ver :default-source :oci)
           (cl-repo:ensure-systems "cl-repository-packager" :default-source :oci))
       (cl-repo:ensure-systems "cl-oci-client" :default-source :oci))))
  (cl-repository-client/asdf-integration:configure-asdf-source-registry)
  (%ci-muffle
   (lambda ()
     (asdf:load-system "cl-repository-packager")
     (asdf:load-system "cl-oci-client"))))

(%ensure-packager)
