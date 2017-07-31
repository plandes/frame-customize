;;; config-manage.el --- manage buffers

;; Copyright (C) 2017 Paul Landes

;; Version: 0.1
;; Author: Paul Landes
;; Maintainer: Paul Landes
;; Keywords: configuration settings persistable
;; URL: https://github.com/plandes/config-manage
;; Package-Requires: ((emacs "25") (choice-program "0.1"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;;; Code:

(require 'eieio)

;; EIEIO list types can't unpersist as they produce this error:
;;   eieio-persistent-validate/fix-slot-value: In save file, list of object
;;   constructors found, but no :type specified for slot displays of type nil
(defclass config-persistent ()
  ((slots :initarg :slots
	  :initform nil
	  :type list))
  :documentation "\
Super class for objects that want to persist to the file system.")

(cl-defmethod config-persistent-persist-value ((this config-persistent) val)
  (or (and (consp val)
	   (or (let ((fval (car val)))
		 (and fval
		      (eieio-object-p fval)
		      (object-of-class-p fval 'config-persistent)
		      (-map (lambda (val)
			      (config-persistent-persist val))
			    val)))))
      val))

(cl-defmethod config-persistent-persist-slots ((this config-persistent))
  "Persist the slots of the instance."
  (with-slots (slots) this
    (->> slots
	 (-map (lambda (slot)
		 (let ((val (->> (slot-value this slot)
				 (config-persistent-persist-value this))))
		   (cons slot val)))))))

(cl-defmethod config-persistent-persist ((this config-persistent))
  "Persist an object."
  (append `((class . ,(eieio-object-class this))
	    (slots . ,(config-persistent-persist-slots this)))
	  (condition-case nil
	      (cl-call-next-method this)
	    (cl-no-next-method))))

(cl-defmethod config-persistent-unpersist-value ((this config-persistent) val)
  (or (and (consp val)
	   (or (let ((fval (car val)))
		 (and (consp fval)
		      (consp (car fval))
		      (eq 'class (caar fval))
		      (-map (lambda (val)
			      (config-persistent-unpersist val))
			    val)))))
      val))

(cl-defmethod config-persistent-unpersist ((this config-persistent) vals)
  "Persist an object."
  (with-slots (slots) this
    (->> slots
	 (-map (lambda (slot)
		 (let ((val (->> (cdr (assq slot vals))
				 (config-persistent-unpersist-value this))))
		   (setf (slot-value this slot) val)))))))

(cl-defmethod config-persistent-unpersist ((vals list))
  (let* ((class (cdr (assq 'class vals)))
	 (slots (cdr (assq 'slots vals)))
	 (obj (make-instance class)))
    (config-persistent-unpersist obj slots)
    obj))



(defclass config-persistable (config-persistent)
  ((file :initarg :file
	 :initform nil
	 :type (or null string)
	 :documentation "The file to persist the state of the object."))
  :documentation "Subclasses that can persist to a file.")

(cl-defmethod config-persistable-save ((this config-persistable))
  "Persist manager and compiler configuration."
  (with-slots (file) this
    (let ((save-class-name (->> this eieio-object-class eieio-class-name))
	  (state (config-persistent-persist this)))
      (with-temp-buffer
	(insert (format "\
;; -*- emacs-lisp -*- <%s %s>
;; Object: %s.  Don't change this file.\n"
			(time-stamp-string "%02y/%02m/%02d %02H:%02M:%02S")
			file save-class-name))
	(insert (with-output-to-string
		  (pp state)))
	(write-region (point-min) (point-max) file))
      (message "Wrote %s" file))))



;;; config objects
(defclass config-entry (config-persistent)
  ((name :initarg :name
	 :initform nil
	 :type (or null string)
	 :reader config-entry-name
	 :writer config-entry-set-name
 	 :protection :protected)
   (description :initarg :description
		:initform "<none>"
		:type string
		:documentation "
The description of this entry, used in `config-manager-list-entries-buffer'.")
   (manager :initarg :manager
	    :initform nil
	    :protection :protected))
  :abstract true
  :documentation "Abstract class for all configurable entries.")

(cl-defmethod config-entry-description ((this config-entry))
  "Get the description of the configuration entry."
  (oref this :description))

(cl-defmethod config-entry-save ((this config-entry))
  "Save the current entry configuration."
  (error "No implementation of `config-entry-save' for class `%S'"
	 (eieio-object-class this)))

(cl-defmethod config-entry-restore ((this config-entry))
  "Restore the current entry configuration."
  (error "No implementation of `config-entry-restore' for class `%S'"
	 (eieio-object-class this)))

(cl-defmethod object-format ((this config-entry))
  (with-slots (name) this
    name))


(defclass config-manager (config-persistent)
  ((name :initarg :name
	 :initform "untitled"
	 :type string
	 :documentation "Name of this configuration manager.")
   (cycle-method :initarg :cycle-method
		 :initform last-visit
		 :reader config-manager-cycle-method
		 :writer config-manager-set-cycle-method
		 :type symbol
		 :custom (choice :tag "Cycle Method"
				 (const :tag "Last Visited" last-visit)
				 (const :tag "Next In Line" next))
		 :documentation "\
How entries are cycled by default when invoking `buffer-manager-switch'.
This parameter is used as the default for `criteria' \(see
`buffer-manager-switch'), which is `cycle'.")
   (entries :initarg :entries
	    :initform nil		; initialize with 0 entries
	    :type (or null list)
	    :protection :private
	    :documentation
	    "Contains the data structure for the buffer entries.")
   (entry-index :initarg :entry-index
		:initform 0
		:type integer
		:documentation "Index of current entry.")
   (read-history :initform nil
		 :protection :private
		 :documentation "\
Used for history when reading user input when switching to other buffers.")
   ;; careful: this slot keeps stale entries after they've been removed/killed
   (last-switched-to :initform nil
		     :protection :private
		     :documentation "\
Keeps track of the last entry for last-visit cycle method."))
  :documentation "Manages configurations.")

(defconst config-manager-list-col-space 4
  "Space between columns.")

(defconst config-manager-status-defs
  '((alive . " ")
    (to-delete . "D")
    (to-show . "S"))
  "Enumeration of status for buffers in `config-manager-list-entries'.")

(defun config-manager-insert-at-position (seq elt pos)
  "Return SEQ with ELT inserted at position POS."
  (append (cl-subseq seq 0 pos)
	  (list elt)
	  (cl-subseq seq pos)))

(cl-defmethod config-manager-create-default ((this config-manager))
  (error "No implementation of `config-manager-create-default' for class `%S'"
	 (eieio-object-class this)))

(cl-defmethod config-manager-entry-default-name ((this config-manager))
  (error "No implementation of `config-manager-entry-default-name' for class `%S'"
	 (eieio-object-class this)))

(cl-defmethod config-manager-list-header-fields ((this config-manager))
  "*List of fields used in output of `buffer-list'."
  '("C" "Name"  "Description"))

(cl-defmethod config-manager-index ((this config-manager) &optional index)
  "Get the `config-entry' (`entry-index' slot) index.

If INDEX is given, disregard the `entry-index' slot and adjust (mod
it) to the cardinality of the entries."
  (with-slots (entries entry-index) this
    (let ((slen (length entries)))
      (if (= 0 slen)
	  (error "No entries exist--use `tframe-add-or-advance-entry'"))
      (-> (or index entry-index)
	  (mod slen)))))

(cl-defmethod config-manager-set-index ((this config-manager) index)
  "Get the `config-entry' (`entry-index' slot) index.

See `config-manager-index'."
  (with-slots (entry-index) this
    (->> (config-manager-index this index)
	 (setq entry-index))))

(cl-defmethod config-manager-increment-index ((this config-manager)
					      &optional num)
  "Increment the display index by NUM positions, which defaults to 1."
  (with-slots (entry-index) this
    (config-manager-set-index this (+ entry-index (or num 1)))))

(cl-defmethod config-manager-entry ((this config-manager) &optional index)
  "Get the `config-entry' by INDEX."
  (with-slots (entries) this
    (nth (config-manager-index this index) entries)))

(defun config-manager-iterate-name (name names)
  "Create a unique NAME from existing NAMES by iterating FORM<N> integer.

N is an integer.

This is the typical unique name (buffers, files etc) creation."
  (->> names
       (-map (lambda (elt)
	       (if (string-match (concat name "\\(?:<\\([0-9]+\\)>\\)?$") elt)
		   (let ((expr (match-string 1 elt)))
		     (or (and expr (read expr))
			 0)))))
       (-filter #'identity)
       (cons -1)
       (reduce #'max)
       (funcall (lambda (elt)
		  (if (> elt -1)
		      (concat name "<" (-> elt incf prin1-to-string) ">")
		    name)))))

(let ((this a)
      (name "narrow"))
  (with-slots (entries) this
    (->> entries
	 (-map (lambda (elt)
		 (config-entry-name elt)))
	 (config-manager-iterate-name name))))

(cl-defmethod config-manager-insert-entry ((this config-manager)
					   &optional entry)
  "Add and optionally create first a new entry if ENTRY is nil."
  (let* ((entry (or entry (config-manager-create-default this)))
	 (name (config-entry-name entry)))
    (with-slots (entries entry-index) this
      (->> entries
	   (-map (lambda (elt)
		   (config-entry-name elt)))
	   (config-manager-iterate-name name)
	   (config-entry-set-name entry))
      (setq entries
	    (config-manager-insert-at-position entries entry entry-index))
      (cl-incf entry-index))))

(cl-defmethod config-manager-set-name ((this config-manager) &optional new-name)
  "Set the name of this `config-manager' to NEW-NAME."
  (with-slots (name) this
    (let ((new-name (or new-name (config-manager-entry-default-name this))))
      (setq name new-name))))

(cl-defmethod config-manager-entry-restore ((this config-manager)
					    &optional entry)
  "Restore this `config-manager' and contained `config-entry' instances."
  (let ((entry (or entry (config-manager-entry this))))
    (config-entry-restore entry)))

(cl-defmethod config-manager-entries ((this config-manager))
  (oref this :entries))

(cl-defmethod config-manager-switch ((this config-manager))
  (error "No implementation of `config-manager-switch' for class `%S'"
	 (eieio-object-class this)))

(cl-defmethod config-manager-cycle-methods ((this config-manager))
  "All valid cycle methods (see `config-manager-entry-cycle')."
  '(last-visit next))

(cl-defmethod config-manager-toggle-cycle-method ((this config-manager))
  (let* ((methods (config-manager-cycle-methods this))
	 (method (config-manager-cycle-method this)))
    (setq method (or (cadr (member method methods)) (car methods)))
    (config-manager-set-cycle-method this method)
    method))

(cl-defmethod config-manager-list-entries ((this config-manager))
  "Return a multi-listing of the buffer entries contained in this manager."
  (cl-flet* ((get-entries
	      ()
	      (sort (copy-tree (config-manager-entries this))
		    #'(lambda (a b)
			(string< (config-entry-name a)
				 (config-entry-name b)))))
	     (get-max
	      (getter-fn)
	      (let ((entries (get-entries)))
		(when entries
		  (apply #'max
			 (mapcar #'(lambda (entry)
				     (length (funcall getter-fn entry)))
				 (get-entries))))))
	     (get-wd
	      (entry col-space name-len)
	      (let* ((name (config-entry-description entry))
		     (len (length name))
		     (width 79)
		     (max-len (- (- width col-space) name-len 0)))
		(if (> len max-len)
		    (concat (substring name 0 (- max-len 3)) "...")
		  name))))
    (when (not (boundp 'config-entry-status))
      (set (make-local-variable 'config-entry-status)
	   (make-hash-table :test 'equal)))
    (dolist (entry (config-manager-entries this))
      (let ((name (config-entry-name entry)))
	(unless (gethash name config-entry-status)
	  (puthash name 'alive config-entry-status))))
    (let ((name-len (get-max #'config-entry-name))
	  (col-space config-manager-list-col-space))
      (setq name-len (or name-len col-space))
      (let ((entries (get-entries))
	    (headers (config-manager-list-header-fields this))
	    format-meta)
	(setq format-meta (format "%%-%ds %%-%ds%%s"
				  col-space (+ col-space name-len)))
	(insert (apply 'format format-meta headers)
		"\n"
		(apply 'format format-meta
		       (mapcar #'(lambda (arg)
				   (make-string (length arg) ?-))
			       headers))
		"\n")
	(cl-do ((lst entries (setq lst (cdr lst)))
		entry)
	    ((null lst))
	  (setq entry (car lst))
	  (let ((name (copy-sequence (config-entry-name entry)))
		(status (cdr (assq (gethash (config-entry-name entry)
					    config-entry-status)
				   config-manager-status-defs))))
	    (put-text-property 0 (length name) 'mouse-face 'highlight name)
	    (insert (apply #'format format-meta
			   (append (list status name
					 (get-wd entry col-space name-len))))))
	  (if (cdr lst) (insert "\n")))))))

(cl-defmethod config-manager-list-entries-buffer ((this config-manager) buffer-name)
  "Create a listing of buffers used for viewing, renameing, deleting, adding.
BUFFER-NAME is the name of the buffer holding the entries for the mode."
  (let* ((buf (get-buffer buffer-name))
	 (newp (not buf))
	 (buf (or buf (get-buffer-create buffer-name))))
    (save-excursion
      (eval-and-compile
	(let ((msg (concat "we need `save-excursion' since interactively "
			   "called `config-manage-mode-refresh' sets "
			   "the window point")))
	  (display-warning 'config-manage msg :debug)))
      (set-buffer buf)
      (if (not newp)
	  (config-manage-mode-refresh)
	(setq buffer-read-only nil)
	(erase-buffer)
	(config-manage-mode)
	(config-manager-list-entries this)
	(config-manage-mode-first-buffer)
	(set-window-point (get-buffer-window (current-buffer)) (point))
	(set (make-local-variable 'config-manager-instance) this)
	(set-buffer-modified-p nil)
	(setq buffer-read-only t)
	(easy-menu-define config-manage-mode-menu config-manage-mode-map
	  "Menu for Buffer Manage." config-manage-mode-menu-definition)))
    (switch-to-buffer buf)))

(cl-defmethod initialize-instance ((this config-manager) &rest rest)
  (with-slots (slots) this
    (setq slots
	  (append slots '(name id entry-index entries))))
  (apply #'cl-call-next-method this rest)
  (config-manager-set-name this))



;;; modal

(defcustom config-manage-highlight t
  "Whether or not to hightlight buffer using `config-manager-list-entries-buffer'."
  :group 'config-manage
  :type 'boolean)

(defgroup config-manage-font-lock-faces nil
  "Buffer Manage Faces"
  :group 'config-manage
  :prefix "config-manage-font-lock-")

;; face definitions
(defface config-manage-font-lock-headers-face
  '((t (:foreground "red")))
  "Font Lock mode face used to highlight buffer headerss."
  :group 'config-manage-font-lock-faces)
(defface config-manage-font-lock-name-face
  '((t (:foreground "darkcyan")))
  "Font Lock mode face used to highlight buffer names."
  :group 'config-manage-font-lock-faces)
(defface config-manage-font-lock-desc-face
  '((t (:foreground "blue")))
  "Font Lock mode face used to highlight description."
  :group 'config-manage-font-lock-faces)

;; font variables
(defvar config-manage-font-lock-headers-face
  'config-manage-font-lock-headers-face
  "Face headers to use for headerss.")
(defvar config-manage-font-lock-name-face
  'config-manage-font-lock-name-face
  "Face name to use for names.")
(defvar config-manage-font-lock-desc-face
  'config-manage-font-lock-desc-face
  "Face name to use for working directories.")

(defvar config-manage-font-lock-keywords
  `((,(format "^.\\{%d\\}\\(.*?\\)[ \t]+.*$" (1+ config-manager-list-col-space))
     1 config-manage-font-lock-name-face t)
    (,(format "^.\\{%d\\}.*?[ \t]+\\(.*\\)$" (1+ config-manager-list-col-space))
     1 config-manage-font-lock-desc-face t)
    ;; ,(list (format "^\\(%s.*\\)$" (cl-second config-manager-list-header-fields))
    ;; 	   1 config-manage-font-lock-headers-face t)
    ("^\\([- \t]+\\)$" 1 config-manage-font-lock-headers-face t))
  "Additional expressions to highlight in buffer manage mode.")

(defun config-manage-mode-assert ()
  "Throw an error if not in `config-manage-mode'."
  (if (not (eq major-mode 'config-manage-mode))
      (error "Must be in `config-manage-mode' for this command")))

(defun config-manage-mode-quit ()
  "Quit from within the `config-manage-mode'."
  (interactive)
  (config-manage-mode-assert)
  (if t
      (bury-buffer)
    (let ((cfg org-window-config))
      (kill-buffer (current-buffer))
      (set-window-configuration cfg))))

(defun config-manage-mode-name-at-point ()
  "Return the name of the buffer at the current point if there is one."
  (config-manage-mode-assert)
  (save-excursion
    (beginning-of-line)
    (forward-char (+ (length (cdar config-manager-status-defs))
		     config-manager-list-col-space))
    (if (looking-at "\\(.+?\\)[ \t]")
	(match-string-no-properties 1))))

(defun config-manage-mode-mouse-down (event)
  "Call back for mouse down events.
EVENT mouse event data."
  (interactive "e")
  (mouse-set-point event)
  (setq config-manage-on-mouse-down (config-manage-mode-name-at-point)))

(defun config-manage-mode-mouse-up (event)
  "Call back for mouse down events.
EVENT mouse event data."
  (interactive "e")
  (mouse-set-point event)
  (let ((name (config-manage-mode-name-at-point)))
    (if (string= name config-manage-on-mouse-down)
	(config-manage-mode-activate-buffer name))))

(defun config-manage-mode-first-buffer ()
  "Go to the first buffer entry in the buffer listing."
  (goto-char (point-min))
  (forward-line 2))

(defun config-manage-mode-next ()
  "Called by pressing the `tab' key in `config-manage-mode'."
  (interactive)
  (config-manage-mode-assert)
  (beginning-of-line)
  (unless (save-excursion (end-of-line) (eobp))
    (forward-line)))

(defun config-manage-mode-previous ()
  "Called by pressing the `tab' key in `config-manage-mode'."
  (interactive)
  (config-manage-mode-assert)
  (beginning-of-line)
  (if (> (line-number-at-pos (point)) 3)
      (forward-line -1)))

(defun config-manage-mode-activate-buffer (&optional name)
  "Activates the buffer entry with name NAME."
  (interactive)
  (config-manage-mode-assert)
  (setq name (or name (config-manage-mode-name-at-point)))
  (let ((this config-manager-instance))
    (config-manage-mode-assert)
    (config-manager-switch this name)))

(defun config-manage-mode-view (&optional name)
  "Activates the buffer entry with name NAME."
  (interactive)
  (config-manage-mode-assert)
  (setq name (or name (config-manage-mode-name-at-point)))
  (let ((this config-manager-instance))
    (config-manage-mode-assert)
    (config-manager-switch this name nil 'split)))

(defun config-manage-mode-set-status (status)
  "Set the mode status to STATUS for the mode."
  (config-manage-mode-assert)
  (let ((name (config-manage-mode-name-at-point)))
    (when name
      (puthash name status config-entry-status)
      (config-manage-mode-refresh)
      (config-manage-mode-next))))

(defun config-manage-mode-refresh ()
  "Refresh the buffer entry listing buffer."
  (interactive)
  (config-manage-mode-assert)
  (let ((line (1+ (count-lines (point-min) (point)))))
    (setq buffer-read-only nil)
    (erase-buffer)
    (config-manager-list-entries config-manager-instance)
    (setq buffer-read-only t)
    (goto-char (point-min))
    (forward-line (max 3 line))
    (beginning-of-line)
    (set-window-point (get-buffer-window (current-buffer)) (point))))

(defun config-manage-mode-mark-delete ()
  "Delete a buffer (terminate)."
  (interactive)
  (config-manage-mode-set-status 'to-delete))

(defun config-manage-mode-mark-show ()
  "Display \(show) a buffer."
  (interactive)
  (config-manage-mode-set-status 'to-show))

(defun config-manage-mode-mark-undelete ()
  "Unmark a buffer for deletion."
  (interactive)
  (config-manage-mode-set-status 'alive))

(defun config-manage-mode-apply-selected (status replace func)
  "Apply STATUS to the selection.
Replace status for REPLACE and the selection uses the return
value of FUNC."
  (config-manage-mode-assert)
  (let ((this config-manager-instance))
    (maphash #'(lambda (key val)
		 (when (eq status val)
		   (let ((entry (config-manager-entry this key)))
		     (and entry (funcall func this entry)))
		   (if replace
		       (puthash key replace config-entry-status)
		     (remhash key config-entry-status))))
	     config-entry-status)
    (config-manage-mode-refresh)))

(defun config-manage-mode-delete-selected ()
  "Delete all entries that are selected for delete."
  (interactive)
  (config-manage-mode-assert)
  (config-manage-mode-apply-selected 'to-delete nil
				     'config-manager-remove-entry))

(defun config-manage-mode-show-selected ()
  "Show all entries in one frame that are selected."
  (interactive)
  (config-manage-mode-assert)
  (let ((this config-manager-instance)
	entries)
    (cl-flet ((collect
	       (inst entry)
	       (setq entries (append entries (list entry)))))
      (config-manage-mode-apply-selected 'to-show 'to-show 'collect)
      (config-manager-display-given-entries this entries))))

(defun config-manage-mode-rename (new-name)
  "Rename a buffer to NEW-NAME."
  (interactive
   (progn
     (config-manage-mode-assert)
     (let ((this config-manager-instance))
       (list (config-manager-read-new-name this "Rename")))))
  (config-manage-mode-assert)
  (let ((name (config-manage-mode-name-at-point))
	(this config-manager-instance))
    (config-entry-rename (config-manager-entry this name) new-name)
    (config-manage-mode-refresh)))

(defun config-manage-mode-new ()
  "Create a new entry."
  (interactive)
  (let* ((this config-manager-instance)
	 (name (config-manager-read-new-name this)))
    (config-manager-new-entry this name)
    (config-manage-mode-refresh)))

(define-derived-mode config-manage-mode fundamental-mode "Configuration Manager"
  "Major mode for displaying and buffer entries.
Special commands:
\\{config-manage-mode-map}"
  (set (make-local-variable 'font-lock-defaults)
       '(config-manage-font-lock-keywords t))
  (font-lock-mode (if config-manage-highlight 1 0))
  (set (make-local-variable 'org-window-config)
       (current-window-configuration)))

(define-key config-manage-mode-map "q" 'config-manage-mode-quit)
(define-key config-manage-mode-map [down-mouse-2] 'config-manage-mode-mouse-down)
(define-key config-manage-mode-map [mouse-2] 'config-manage-mode-mouse-up)
(define-key config-manage-mode-map [return] 'config-manage-mode-activate-buffer)
(define-key config-manage-mode-map "n" 'config-manage-mode-next)
(define-key config-manage-mode-map "p" 'config-manage-mode-previous)
(define-key config-manage-mode-map [(control down)] 'config-manage-mode-next)
(define-key config-manage-mode-map [(control up)] 'config-manage-mode-previous)
(define-key config-manage-mode-map "d" 'config-manage-mode-mark-delete)
(define-key config-manage-mode-map "s" 'config-manage-mode-mark-show)
(define-key config-manage-mode-map "u" 'config-manage-mode-mark-undelete)
(define-key config-manage-mode-map "i" 'config-manage-mode-new)
(define-key config-manage-mode-map "x" 'config-manage-mode-delete-selected)
(define-key config-manage-mode-map "z" 'config-manage-mode-show-selected)
(define-key config-manage-mode-map "g" 'config-manage-mode-refresh)
(define-key config-manage-mode-map "r" 'config-manage-mode-rename)
(define-key config-manage-mode-map "v" 'config-manage-mode-view)

(defvar config-manage-mode-menu-definition
  (list "Buffer Manager"
	["Create New" config-manage-mode-new t]
	["Goto Entry" config-manage-mode-activate-buffer t]
	"-"
	["Mark Delete" config-manage-mode-mark-delete t]
	["Unmark" config-manage-mode-mark-undelete t]
	["Rename" config-manage-mode-rename t]
	["Delete Selected" config-manage-mode-delete-selected t]
	["Show Selected" config-manage-mode-show-selected t]
	"-"
	["Refresh" config-manage-mode-refresh t]
	["Quit" config-manage-mode-quit t]))

(provide 'config-manage)

;;; config-manage.el ends here