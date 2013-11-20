;;;; sdl2.lisp

(in-package #:sdl2)

;;; "sdl2" goes here. Hacks and glory await!

(define-condition sdl-error (error) ())

(define-condition sdl-rc-error (sdl-error)
  ((code :initarg :rc :initform nil :accessor sdl-error-code)
   (string :initarg :string :initform nil :accessor sdl-error-string))
  (:report (lambda (c s)
             (with-slots (code string) c
               (format s "SDL Error (~A): ~A" code string)))))

(defun sdl-collect (wrapped-ptr &optional (free-fun #'foreign-free))
  (let ((ptr (autowrap:ptr wrapped-ptr)))
    (tg:finalize wrapped-ptr (lambda () (funcall free-fun ptr)))
    wrapped-ptr))

(defun sdl-cancel-collect (wrapped-ptr)
  (tg:cancel-finalization wrapped-ptr)
  wrapped-ptr)

(defun sdl-true-p (integer-bool)
  "Use this function to convert truth from a low level wrapped SDL function
returning an SDL_true into CL's boolean type system."
  (= (autowrap:enum-value 'sdl2-ffi:sdl-bool :true) integer-bool))

(autowrap:define-bitmask-from-constants (sdl-init-flags)
  sdl2-ffi:+sdl-init-timer+
  sdl2-ffi:+sdl-init-audio+
  sdl2-ffi:+sdl-init-video+
  sdl2-ffi:+sdl-init-joystick+
  sdl2-ffi:+sdl-init-haptic+
  sdl2-ffi:+sdl-init-gamecontroller+
  sdl2-ffi:+sdl-init-noparachute+
  '(:everything . #x0000FFFF))

(defmacro check-rc (form)
  (with-gensyms (rc)
    `(let ((,rc ,form))
       (when (< ,rc 0)
         (error 'sdl-rc-error :rc ,rc :string (sdl-get-error)))
       ,rc)))

(defmacro check-non-zero (form)
  (with-gensyms (rc)
    `(let ((,rc ,form))
       (unless (> ,rc 0)
         (error 'sdl-rc-error :rc ,rc :string (sdl-get-error)))
       ,rc)))

(defmacro check-true (form)
  (with-gensyms (rc)
    `(let ((,rc ,form))
       (unless (sdl-true-p ,rc)
         (error 'sdl-rc-error :rc ,rc :string (sdl-get-error)))
       ,rc)))

(defmacro check-null (form)
  (with-gensyms (wrapper)
    `(let ((,wrapper ,form))
       (if (null-pointer-p (autowrap:ptr ,wrapper))
           (error 'sdl-rc-error :rc ,wrapper :string (sdl-get-error))
           ,wrapper))))

(defvar *main-thread-channel* nil)
(defvar *main-thread* nil)
(defvar *lisp-message-event* nil)
(defvar *wakeup-event* (alloc 'sdl2-ffi:sdl-event))

(defmacro in-main-thread ((&key background) &body b)
  (with-gensyms (fun channel)
    `(let ((,fun (lambda () ,@b)))
       (if *main-thread-channel*
           (if *main-thread*
               (funcall ,fun)
               ,(if background
                    `(progn
                       (sendmsg *main-thread-channel*
                                (cons ,fun nil))
                       (values))
                    `(let ((,channel (make-channel)))
                       (sendmsg *main-thread-channel*
                                (cons ,fun ,channel))
                       (push-event *wakeup-event*)
                       (let ((result (recvmsg ,channel)))
                         (etypecase result
                           (list (values-list result))
                           (error (error result)))))))
           (error "No main thread, did you call SDL_Init?")))))

(defun handle-message (msg)
  (let ((fun (car msg))
        (chan (cdr msg)))
    (handler-case
        (if chan
            (sendmsg chan (multiple-value-list (funcall fun)))
            (funcall fun))
      (error (e)
        (if chan
            (sendmsg chan e)
            (format *error-output* "SDL main-thread error:~%~A~%" e))))))

(defun recv-and-handle-message ()
  (let ((msg (recvmsg *main-thread-channel*)))
    (handle-message msg)))

(defun get-and-handle-messages ()
  (loop as msg = (getmsg *main-thread-channel*)
        while msg do
          (handle-message msg)))

(defun sdl-main-thread ()
  (let ((*main-thread* (bt:current-thread)))
    (loop while *main-thread-channel* do
      (recv-and-handle-message))))

(defun init (&rest sdl-init-flags)
  "Initialize SDL2 with the specified subsystems. Initializes everything by default."
  (if *main-thread-channel*
      (error "SDL already initialized; did you mean INIT-SUBSYSTEM?")
      (setf *main-thread-channel* (make-channel)))
  (unless *lisp-message-event*
    (setf *lisp-message-event* (sdl-register-events 1))
    (setf (c-ref *wakeup-event* sdl2-ffi:sdl-event :type) *lisp-message-event*))
  ;; On OSX, we need to run in the main thread; CCL allows us to
  ;; safely do this.  On other platforms (mainly GLX?), we just need
  ;; to run in a dedicated thread.
  #+(and ccl darwin)
  (let ((thread (find 0 (ccl:all-processes) :key #'ccl:process-serial-number)))
    (ccl:process-interrupt thread (lambda ()
                                    (without-fp-traps (sdl-main-thread)))))
  #-(and ccl darwin)
  (bt:make-thread #'sdl-main-thread)
  (in-main-thread ()
    ;; HACK! glutInit on OSX uses some magic undocumented API to
    ;; correctly make the calling thread the primary thread. This
    ;; allows cl-sdl2 to actually work. Nothing else seemed to
    ;; work at all to be honest.
    #+darwin
    (cl-glut:init)
    #-gamekit
    (let ((init-flags (autowrap:mask-apply 'sdl-init-flags sdl-init-flags)))
      (check-rc (sdl-init init-flags)))))

(defun quit ()
  "Shuts down SDL2."
  #-gamekit
  (in-main-thread ()
    (sdl-quit)
    (setf *main-thread-channel* nil)
    (setf *lisp-message-event* nil)))

(defmacro with-init ((&rest sdl-init-flags) &body body)
  `(progn
     (init ,@sdl-init-flags)
     (unwind-protect
          (in-main-thread () ,@body)
       (quit))))

(defun niy (message)
  (error "SDL2 Error: Construct Not Implemented Yet: ~A" message))

(defun version ()
  (c-let ((ver sdl2-ffi:sdl-version :free t))
    (sdl-get-version (ver &))
    (values (ver :major) (ver :minor) (ver :patch))))

(defun version-wrapped ()
  (values sdl2-ffi:+sdl-major-version+
          sdl2-ffi:+sdl-minor-version+
          sdl2-ffi:+sdl-patchlevel+))
