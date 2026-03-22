;;; Copyright 2012-2020 Google LLC
;;;
;;; Use of this source code is governed by an MIT-style
;;; license that can be found in the LICENSE file or at
;;; https://opensource.org/licenses/MIT.

(defpackage #:protobuf-config
  (:documentation "Configuration information for PROTOBUF.")
  (:use #:common-lisp)
  (:export *protoc-relative-path*))

(in-package #:protobuf-config)

(defvar *protoc-relative-path* nil
  "Supply relative proto file paths to protoc, the protobuf compiler?")

(defpackage #:protobuf-system
  (:documentation "System definitions for protocol buffer code.")
  (:use #:common-lisp
        #:asdf
        #:protobuf-config)
  (:export #:protobuf-source-file
           #:proto-pathname
           #:search-path))

(in-package #:protobuf-system)

(defclass protobuf-source-file (cl-source-file)
  ((relative-proto-pathname :initarg :proto-pathname
                            :initform nil
                            :reader proto-pathname
                            :documentation
                            "Relative pathname that specifies the location of a .proto file.")
   (search-path :initform ()
                :initarg :proto-search-path
                :reader search-path
                :documentation
"List containing directories where the protocol buffer compiler should search
for imported protobuf files.  Non-absolute pathnames are treated as relative to
the directory containing the DEFSYSTEM form in which they appear."))
  (:documentation "A protocol buffer definition file."))

(setf (find-class 'asdf::protobuf-source-file) (find-class 'protobuf-source-file))

(defclass proto-to-lisp (downward-operation selfward-operation)
  ((selfward-operation :initform 'prepare-op :allocation :class))
  (:documentation
"An ASDF operation that compiles a .proto file containing protocol buffer
definitions into a Lisp source file."))

(defmethod component-depends-on ((operation compile-op) (proto-def-file protobuf-source-file))
  "Specifies the dependencies of a compile OPERATION on PROTO-DEF-FILE.
Compiling a protocol buffer file depends on generating Lisp source code for
the protobuf, but also on loading package definitions and in-line function
definitions that the machine-generated protobuf Lisp code uses."
  `((proto-to-lisp ,(component-name proto-def-file))
    ,@(call-next-method)))

(defmethod component-depends-on ((operation load-op) (proto-def-file protobuf-source-file))
  "Specifies the dependencies of a load OPERATION on PROTO-DEF-FILE.
Loading a protocol buffer file depends on generating Lisp source code for the
protobuf, but also on loading package definitions and in-line function
definitions that the machine-generated protobuf Lisp code uses."
  `((proto-to-lisp ,(component-name proto-def-file))
    ,@(call-next-method)))

(defun proto-input (protobuf-source-file)
  "Returns the pathname of PROTOBUF-SOURCE-FILE which must be
translated into Lisp source code for this PROTO-FILE component."
  (if (proto-pathname protobuf-source-file)
      ;; Path of the protobuf file was specified with :PROTO-PATHNAME.
      (merge-pathnames
       (make-pathname :type "proto")
       (merge-pathnames (pathname (proto-pathname protobuf-source-file))
                        (component-pathname (component-parent protobuf-source-file))))
      ;; No :PROTO-PATHNAME was specified, so the path of the protobuf
      ;; defaults to that of the Lisp file, but with a ".proto" suffix.
      (let ((lisp-pathname (component-pathname protobuf-source-file)))
        (merge-pathnames (make-pathname :type "proto") lisp-pathname))))

(defmethod input-files ((operation proto-to-lisp) (component protobuf-source-file))
  (list (proto-input component)))

(defmethod output-files ((operation proto-to-lisp) (component protobuf-source-file))
  "Arranges for the Lisp output file of a proto-to-lisp OPERATION on a
PROTOBUF-SOURCE-FILE COMPONENT to be stored where fasl files are located."
  (values (list (component-pathname component))
          nil))                     ; allow around methods to translate

(defun resolve-relative-pathname (path parent-path)
  "When PATH doesn't have an absolute directory component, treat it as relative
to PARENT-PATH."
  (let* ((pathname (pathname path))
         (directory (pathname-directory pathname)))
    (if (and (list directory) (eq (car directory) :absolute))
        pathname
        (let ((resolved-path (merge-pathnames pathname parent-path)))
          (make-pathname :directory (pathname-directory resolved-path)
                         :name nil
                         :type nil
                         :defaults resolved-path)))))

(defun resolve-search-path (protobuf-source-file)
  "Resolves the search path of PROTOBUF-SOURCE-FILE."
  (let ((search-path (search-path protobuf-source-file)))
    (let ((parent-path (component-pathname (component-parent protobuf-source-file))))
      (mapcar (lambda (path)
                (resolve-relative-pathname path parent-path))
              search-path))))

(defun get-search-paths (protobuf-source-file)
  "For a given PROTOBUF-SOURCE-FILE, generate the search paths that should be used.
To do this, it creates a search path from the component, as well as the
:proto-search-path specified in the asd component.

If there's a :proto-pathname specified in the component, the generated search
path will be the absolute directory of the :proto-pathname.
If there's not a :proto-pathname specified in the component, the generated
search path will be the directory of the parent component."
  (cons
   (if (proto-pathname protobuf-source-file)
       ;; If there's a pathname specified, use the absolute directory of the pathname.
       (directory-namestring (proto-input protobuf-source-file))
       ;; If there's no pathname, use the directory of the parent component.
       (asdf/component:component-parent-pathname protobuf-source-file))
   ;; Attach the other search paths on the back
   (resolve-search-path protobuf-source-file)))

(define-condition protobuf-compile-failed (compile-failed-error)
  ()
  (:documentation "Condition signalled when translating a .proto file into Lisp code fails."))

(defun find-protobuf-tool (name)
  "Find NAME (e.g. \"protoc\") in the cl-protobufs native/ dir installed by cl-repository.
Falls back to NIL if not found, letting callers use PATH lookup instead."
  (let* ((sys (asdf:find-system :cl-protobufs.asdf nil))
         (src-dir (when sys (asdf:system-source-directory sys)))
         (native (when src-dir (merge-pathnames "native/" src-dir)))
         (path (when native (merge-pathnames name native))))
    (when (and path (probe-file path))
      ;; OCI tarballs may strip execute bits; ensure the binary is executable
      (let ((ns (namestring path)))
        (ignore-errors
          (uiop:run-program (list "chmod" "+x" ns)
                            :ignore-error-status t))
        ns))))

(defmethod perform :before ((operation proto-to-lisp) (component protobuf-source-file))
  (map nil #'ensure-directories-exist (output-files operation component)))

(defmethod perform ((operation proto-to-lisp) (component protobuf-source-file))
  (let* ((source-file (first (input-files operation component)))
         (source-lisp (component-pathname component))
         (output-file (first (output-files operation component))))
    ;; When a pre-generated .lisp exists at the source location (e.g. from
    ;; cl-repository overlay) and is at least as fresh as the .proto input,
    ;; use it directly instead of invoking protoc.  ASDF output-translations
    ;; may redirect output-file to the cache; in that case, copy the
    ;; pre-generated file there.
    (when (and (probe-file source-lisp)
               (or (not (probe-file source-file))
                   (>= (file-write-date source-lisp)
                       (file-write-date source-file))))
      (unless (equal (namestring source-lisp) (namestring output-file))
        (ensure-directories-exist output-file)
        (uiop:copy-file source-lisp output-file))
      (return-from perform))
    (let* ((source-file-argument (if (proto-pathname component)
                                     (file-namestring source-file)
                                     (namestring source-file)))
           (search-path (get-search-paths component))
           (protoc-bin (or (find-protobuf-tool "protoc") "protoc"))
           (plugin-path (find-protobuf-tool "protoc-gen-cl-pb"))
           (plugin-arg (if plugin-path
                           (format nil " --plugin=protoc-gen-cl-pb=~A" plugin-path)
                           ""))
           (command (format nil "~A --proto_path=~{~A~^:~} --cl-pb_out=output-file=~A:~A ~A~A ~
                                 --experimental_allow_proto3_optional"
                            protoc-bin
                            search-path
                            (file-namestring output-file)
                            (directory-namestring output-file)
                            source-file-argument
                            plugin-arg)))
      (multiple-value-bind (output error-output status)
          (uiop:run-program command :output '(:string :stripped t)
                                    :error-output :output
                                    :ignore-error-status t)
        (declare (ignore error-output))
        (unless (zerop status)
          (error 'protobuf-compile-failed
                 :description (format nil "Failed to compile proto file. Command: ~S Error: ~S"
                                      command output)
                 :context-format "~/asdf-action::format-action/"
                 :context-arguments `((,operation . ,component))))))))

(defmethod asdf::component-self-dependencies :around ((op load-op) (c protobuf-source-file))
  "Removes PROTO-TO-LISP operations from self dependencies.  Otherwise, the Lisp
output files of PROTO-TO-LISP are considered to be input files for LOAD-OP,
which means ASDF loads both the .lisp file and the .fasl file."
  (remove-if (lambda (x)
               (eq (car x) 'proto-to-lisp))
             (call-next-method)))

(defmethod input-files ((operation compile-op) (c protobuf-source-file))
  (output-files 'proto-to-lisp c))

(pushnew :cl-protobufs *features*)
