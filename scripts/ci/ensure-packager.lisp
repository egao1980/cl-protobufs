;;;; Keep in sync with cl-repository/scripts/ci/ensure-packager.lisp until
;;;; generated-source overlays land on publish-native-package.yml.
;;;; Requires setup-lisp (cl-repository-client on CL_SOURCE_REGISTRY).
;;;; Do not colon-qualify packager/oci-client symbols here.

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

(%ci-muffle (lambda () (asdf:load-system "cl-repository-client")))

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
  (cl-repository-client/asdf-integration:load-system-init-files)
  (%ci-muffle
   (lambda ()
     (asdf:load-system "cl-repository-packager")
     (asdf:load-system "cl-oci-client"))))

(%ensure-packager)
