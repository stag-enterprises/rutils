;; For license see LICENSE

(in-package #:rutils.readtable)
(eval-when (:compile-toplevel)
  (declaim #.+default-opts+))


(eval-when (:compile-toplevel :load-toplevel :execute)

(defun |#v-reader| (stream char arg)
  "Literal syntax for vectors.
   Unlike #() evaluates its contents before vector creation

   Examples:

      CL-USER> #v(1 2 3)
      #(1 2 3)

      CL-USER> #v((+ 1 2))
      #(3)
  "
  (declare (ignore char arg))
  (read-char stream)
  (let* ((vals (read-delimited-list #\) stream t)))
    `(make-array ,(length vals) :initial-contents (list ,@vals)
                 :adjustable t)))

(defun |#h-reader| (stream char arg)
  "Literal syntax for hash-tables.

   Examples:

      CL-USER> #h(:a 1 :b 2)
      #<HASH-TABLE :TEST EQL :COUNT 2>
      ;; holding 2 key/value pairs: ((:a . 1) (:b . 2))

      CL-USER> #h(equalp \"a\" 1 \"b\" 2)
      #<HASH-TABLE :TEST EQUALP :COUNT 2>
      ;; holding 2 key/value pairs: ((\"a\" . 1) ...)
  "
  (declare (ignore char arg))
  (read-char stream)
  (let* ((sexp (read-delimited-list #\) stream t))
         (test (when (oddp (length sexp))
                 (car sexp)))
         (kvs (if test (cdr sexp) sexp))
         (ht (gensym)))
    `(let ((,ht (make-hash-table :test ',(or test 'eql))))
       ,@(loop :for tail :on kvs :by #'cddr :while kvs
            :collect `(setf (gethash ,(car tail) ,ht) ,(cadr tail)))
       ,ht)))

(defun |#{-reader| (stream char arg)
  "Literal syntax for fixed-size hash-tables.

   Examples:

      CL-USER> #{:a 1 :b 2}
      #<HASH-TABLE :TEST EQL :COUNT 2>
      ;; holding 2 key/value pairs: ((:a . 1) (:b . 2))

      CL-USER> #{equalp \"a\" 1 \"b\" 2}
      #<HASH-TABLE :TEST EQUALP :COUNT 2>
      ;; holding 2 key/value pairs: ((\"a\" . 1) ...)
  "
  (declare (ignore char arg))
  (let* ((sexp (read-delimited-list #\} stream t))
         (test (when (oddp (length sexp))
                 (car sexp)))
         (kvs (if test (cdr sexp) sexp))
         (ht (gensym)))
    `(let ((,ht (make-hash-table :test ',(or test 'eql)
                                 :size ,(/ (length kvs) 2))))
       ,@(loop :for tail :on kvs :by #'cddr :while kvs
            :collect `(setf (gethash ,(car tail) ,ht) ,(cadr tail)))
       ,ht)))

(defun |#`-reader| (stream char arg)
  "Literal syntax for zero/one/two argument lambdas.
   Use % as the function's argument, %% as the second.

   Examples:

   - #`(+ 2 %) => (lambda (&optional x y) (+ 2 x))
   - #`((print %) (1+ %)) => (lambda (&optional x) (print x) (1+ x))
   - #`(+ 1 2) => (lambda (&optional x y) (+ 1 2))
   - #`(+ % %%) => (lambda (&optional x y) (+ x y))
  "
  (declare (ignore char arg))
  (let ((sexp (read stream t nil t)))
    `(trivial-positional-lambda ,(if (and (listp sexp) (listp (car sexp)))
                                     (cons 'progn sexp)
                                     sexp))))

(defun |^-reader| (stream char)
  "Literal syntax for zero/one/two argument lambdas.
   Use % as the function's argument, %% as the second.

   Examples:

   - ^(+ 2 %) => (lambda (&optional x y) (+ 2 x))
   - ^((print %) (1+ %)) => (lambda (&optional x) (print x) (1+ x))
   - ^(+ 1 2) => (lambda (&optional x y) (+ 1 2))
   - ^(+ % %%) => (lambda (&optional x y) (+ x y))
  "
  (declare (ignore char))
  (let ((sexp (read stream t nil t)))
    `(trivial-positional-lambda ,(if (and (listp sexp) (listp (car sexp)))
                                     (cons 'progn sexp)
                                     sexp))))

(defmacro trivial-positional-lambda (body)
  (let ((% (intern "%"))
        (%% (intern "%%")))
    `(lambda (&optional ,% ,%%)
       (declare (ignorable ,%) (ignorable ,%%))
       ,body)))

(defun |#/-reader| (stream char arg)
  "Literal syntax for raw strings (which don't need escapin of control chars).

   Example:

       CL-USER> #/This is a \"test\" string/#
       \"This is a \\\"test\\\" string\"
       ;; here \" are actually unescaped, but you can't write it in a docstring :)
  "
  (declare (ignore char arg))
  (with-output-to-string (str)
    (loop :for char := (read-char stream) :do
         (if (and (char= #\/ char)
                  (char= #\# (peek-char nil stream)))
             (progn (read-char stream)
                    (loop-finish))
             (write-char char str)))))

(defun |@-reader| (stream char)
  "Short slot and sequence elements access syntax.

   Examples:

       CL-USER> (defclass foo () ((bar :initform 42)))
       CL-USER> (defvar *foo* (make 'foo))
       CL-USER> @*foo*.bar
       42
       CL-USER> (defvar *baz* #(1 *foo*))
       CL-USER> @*baz*#1.bar
       42
  "
  (declare (ignore char))
  (if (member (peek-char nil stream)
              '(#\Space #\Newline #\Tab #\Return #\Linefeed #\)))
      '@
      (let ((whole (symbol-name (read stream)))
            sep
            acc)
        (flet ((next-sep (str start)
                 (position-if (lambda (x) (member x '(#\. #\#)))
                              str :start (1+ start))))
          (do* ((prev 0 (1+ next))
                (next (next-sep whole prev) (next-sep whole prev)))
               ((null next) (push (cons sep (subseq whole prev)) acc))
            (push (cons sep (subseq whole prev next))
                  acc)
            (setf sep (char whole next))))
        (setf acc (reverse acc))
        (let ((rez (intern (cdar acc))))
          (dolist (pair (rest acc))
            (ecase (car pair)
              (#\. (setf rez `(rutils.generic:smart-slot-value ,rez ',(intern (cdr pair)))))
              (#\# (setf rez `(elt ,rez ,(parse-integer (cdr pair)))))))
          rez))))

(defreadtable rutils-readtable
    (:merge :standard)
  (:macro-char #\} (get-macro-character #\)))
  (:macro-char #\^ #'|^-reader|)
  (:macro-char #\@ #'|@-reader| t)
  (:dispatch-macro-char #\# #\v #'|#v-reader|)
  (:dispatch-macro-char #\# #\h #'|#h-reader|)
  (:dispatch-macro-char #\# #\{ #'|#{-reader|)
  (:dispatch-macro-char #\# #\` #'|#`-reader|)
  (:dispatch-macro-char #\# #\/ #'|#/-reader|))

(defreadtable standard-readtable
  (:merge :standard))

)
