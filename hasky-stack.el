;;; hasky-stack.el --- Interface to the Stack Haskell development tool -*- lexical-binding: t; -*-
;;
;; Copyright © 2017–2019 Mark Karpov <markkarpov92@gmail.com>
;; Copyright © 2020 Marc Berkowitz <mberkowitz7@gmail.com>
;;
;; Author: Mark Karpov <markkarpov92@gmail.com>
;; URL: https://github.com/hasky-mode/hasky-stack
;; Version: 0.9.0
;; Package-Requires: ((emacs "24.4") (f "0.18.0") (magit-popup "2.10"))
;; Keywords: tools, haskell
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
;; Public License for more details.
;;
;; You should have received a copy of the GNU General Public License along
;; with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is an Emacs interface to the Stack Haskell development tool.  Bind
;; the following useful commands:
;;
;;     (global-set-key (kbd "<next> h e") #'hasky-stack-execute)
;;     (global-set-key (kbd "<next> h h") #'hasky-stack-package-action)
;;     (global-set-key (kbd "<next> h i") #'hasky-stack-new)
;;
;; * `hasky-stack-execute' opens a popup with a collection of stack commands
;;   you can run.  Many commands have their own sub-popups like in Magit.
;;
;; * `hasky-stack-package-action' allows to perform actions on package that
;;   the user selects from the list of all available packages.
;;
;; * `hasky-stack-new' allows to create a new project in current directory
;;   using a Stack template.

;;; Code:

(require 'cl-lib)
(require 'f)
(require 'magit-popup)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Settings & Variables

;; Nomenclature:
;;
;; Both stack and cabal manage PACKAGES: the units of downloading, building,
;; installing locally and uploading. There are various ways to classify
;; packages: local vs remote; hackage vs stackage vs other; parts of the project
;; vs its dependencies vs unrelated packages. Some packages are simple (defined
;; by one cabal file) and some are compound (defined by a cabal.project and
;; several cabal files). (And hasky-stack is an emacs package.)
;;
;; Hasky-stack is a tool for inspecting and building stack packages. We will
;; call the unit for building code a PROJECT, since the word has no specical
;; meaning to stack, and does suggest cabal.project. (TARGET will mean stack
;; build target). For purposes of download and upload, a project is one stack
;; package. For purposes of building and testing, a project may be a simple
;; stack package, or a compound with subpackages. We assume that the subpackages
;; make a list and not a tree.

(defgroup hasky-stack nil
  "Interface to the Stack Haskell development tool."
  ;; group=haskell if it exists
  :group  (if (get 'haskell 'custom-group) 'haskell 'programming)
  :tag    "Hasky Stack"
  :prefix "hasky-stack-"
  :link   '(url-link :tag "GitHub" "https://github.com/hasky-mode/hasky-stack"))

(defface hasky-stack-project-name
  '((t (:inherit font-lock-function-name-face)))
  "Face used to display name of current project.")

(defface hasky-stack-project-version
  '((t (:inherit font-lock-doc-face)))
  "Face used to display version of current project.")

;; the next 6 vars are set by `hasky-stack--prepare`:
(defvar hasky-stack--project-directory nil "Path to top of current stack project")
(defvar hasky-stack--project-name nil "Name of current stack project")
(defvar hasky-stack--project-version nil "Version of current stack project")
(defvar hasky-stack--project-is-compound nil "Does current stack project contain subpackages?")
(defvar hasky-stack--cabal-project-mod-time nil "Time of last mod to cabal.project, if any")
  
(defvar hasky-stack--project-packages nil
  "A list of the packages contained in the current project, with their attributes.
   Each item corresponds to a .cabal file in the project. Each
   item is an a-list, made by (hasky-stack--parse-cabal-file).
   The attributes of a package are: name, version, targets, dir,
   cabal-file-name, cabal-file-mod-time.")

(defvar hasky-stack--current-package nil
  "Defines the package that is the current scope for `stack build' and the like.
   An item from the list hasky-stack--project-packages.")

(defvar hasky-stack--package-action-package nil
  "This variable is temporarily bound to name of a package.")

(defcustom hasky-stack-executable nil
  "Path to Stack executable.

If it's not NIL, this value is used in invocation of Stack
commands instead of the standard \"stack\" string.  Set this
variable if your Stack is not on PATH.

Note that the path is quoted with `shell-quote-argument' before
being used to compose command line."
  :tag  "Path to Stack Executable"
  :type '(choice (file :must-match t)
                 (const :tag "Use Default" nil)))

(defcustom hasky-stack-config-dir "~/.stack"
  "Path to Stack configuration directory."
  :tag  "Path to Stack configuration directory"
  :type 'directory)

(defcustom hasky-stack-read-function #'completing-read
  "Function to be called when user has to choose from list of alternatives."
  :tag  "Completing Function"
  :type '(radio (function-item completing-read)))

(defcustom hasky-stack-ghc-versions '("8.6.3" "8.4.4" "8.2.2" "8.0.2" "7.10.3" "7.8.4")
  "GHC versions to pick from (for commands like \"stack setup\")."
  :tag  "GHC versions"
  :type '(repeat (string :tag "Extension name")))

(defcustom hasky-stack-edit-the-command nil
  "Whether to let user edit each stack command before running it."
  :tag "Edit each stack command before running it"
  :type 'boolean)

(defcustom hasky-stack-auto-target nil
  "Whether to automatically select the default build target."
  :tag  "Build auto-target"
  :type 'boolean)

(defcustom hasky-stack-auto-open-coverage-reports nil
  "Whether to attempt to automatically open coverage report in browser."
  :tag  "Automatically open coverage reports"
  :type 'boolean)

(defcustom hasky-stack-auto-open-haddocks nil
  "Whether to attempt to automatically open Haddocks in browser."
  :tag  "Automatically open Haddocks"
  :type 'boolean)

(defcustom hasky-stack-auto-newest-version nil
  "Whether to install newest version of package without asking.

This is used in `hasky-stack-package-action'."
  :tag  "Automatically install newest version"
  :type 'boolean)

(defcustom hasky-stack-templates
  '("chrisdone"
    "foundation"
    "franklinchen"
    "ghcjs"
    "ghcjs-old-base"
    "hakyll-template"
    "haskeleton"
    "hspec"
    "new-template"
    "protolude"
    "quickcheck-test-framework"
    "readme-lhs"
    "rio"
    "rubik"
    "scotty-hello-world"
    "scotty-hspec-wai"
    "servant"
    "servant-docker"
    "simple"
    "simple-hpack"
    "simple-library"
    "spock"
    "tasty-discover"
    "tasty-travis"
    "unicode-syntax-exe"
    "unicode-syntax-lib"
    "yesod-minimal"
    "yesod-mongo"
    "yesod-mysql"
    "yesod-postgres"
    "yesod-simple"
    "yesod-sqlite")
  "List of known templates to choose from when creating new project."
  :tag "List of known stack templates"
  :type '(repeat (string :tag "Template name")))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Various utilities

(defun hasky-stack--package-targets(&optional pkg)
  (cdr (assq 'targets (or pkg hasky-stack--current-package))))

(defun hasky-stack--package-version(&optional pkg)
  (cdr (assq 'version (or pkg hasky-stack--current-package))))

(defun hasky-stack--package-name(&optional pkg)
  (cdr (assq 'name (or pkg hasky-stack--current-package))))

(defun hasky-stack--package-directory(&optional pkg)
  (cdr (assq 'dir (or pkg hasky-stack--current-package))))

(defun hasky-stack--all-matches (regexp)
  "Return list of all stings matching REGEXP in current buffer."
  (let (matches
        (case-fold-search t))
    (goto-char (point-min))
    (while (re-search-forward regexp nil t)
      (push (match-string-no-properties 1) matches))
    (reverse matches)))

(defun hasky-stack--parse-cabal-file (filename)
  "Parse the \"*.cabal\" file with name FILENAME and return an
  a-list, with the fields name, version, targets,
  cabal-file-name, cabal-file-mod-time. This is used by
  `hasky-stack--prepare'."
  (let (name version targets)
    (with-temp-buffer
      (insert-file-contents filename)
      ;; project name
      (setq name
            (car (hasky-stack--all-matches
                  "^[[:blank:]]*name:[[:blank:]]+\\([[:word:]-]+\\)")))
      ;; project version
      (setq version
            (car (hasky-stack--all-matches
                  "^[[:blank:]]*version:[[:blank:]]+\\([[:digit:]\\.]+\\)")))
      ;; project targets
      (setq
       targets
       (append
        ;; library
        (mapcar (lambda (_) (format "%s:lib" name))
                (hasky-stack--all-matches
                 "^[[:blank:]]*library[[:blank:]]*"))
        ;; executables
        (mapcar (lambda (x) (format "%s:exe:%s" name x))
                (hasky-stack--all-matches
                 "^[[:blank:]]*executable[[:blank:]]+\\([[:word:]-]+\\)"))
        ;; test suites
        (mapcar (lambda (x) (format "%s:test:%s" name x))
                (hasky-stack--all-matches
                 "^[[:blank:]]*test-suite[[:blank:]]+\\([[:word:]-]+\\)"))
        ;; benchmarks
        (mapcar (lambda (x) (format "%s:bench:%s" name x))
                (hasky-stack--all-matches
                 "^[[:blank:]]*benchmark[[:blank:]]+\\([[:word:]-]+\\)")))))
    `((name . ,name) (version . ,version) (targets ,@targets)
      (dir . ,(f-dirname (f-canonical filename)))
      (cabal-file-name . ,filename)
      (cabal-file-mod-time . ,(hasky-stack--mod-time filename)))))

(defun hasky-stack--maybe-reload-package (pkg)
  "PKG is an a-list describing a cabal package, as returned by hasky-stack--parse-cabal-file.
   If the cabal file has changed since its timestamp saved in the
   a-list, parse it again and return the new value. If not, just
   return PKG."
  (let ((file (cdr (assq 'cabal-file-name pkg)))
        (time (cdr (assq 'cabal-file-mod-time pkg))))
    (if (time-less-p time (hasky-stack--mod-time file))
        (hasky-stack--parse-cabal-file file)
      pkg)))

(defun hasky-stack--home-page-from-cabal-file (filename)
  "Parse package home page from \"*.cabal\" file with FILENAME."
  (with-temp-buffer
    (insert-file-contents filename)
    (or
     (car (hasky-stack--all-matches
           "^[[:blank:]]*homepage:[[:blank:]]+\\(.+\\)"))
     (let ((without-scheme
            (car
             (hasky-stack--all-matches
              "^[[:blank:]]*location:[[:blank:]]+.*:\\(.+\\)\\(\\.git\\)?"))))
       (when without-scheme
         (concat "https:" without-scheme))))))

(defun hasky-stack--find-dir-of-file (regexp)
  "Find file whose name satisfies REGEXP traversing upwards.

Return absolute path to directory containing that file or NIL on
failure.  Returned path is guaranteed to have trailing slash."
  (let ((dir (f-traverse-upwards
              (lambda (path)
                (directory-files path t regexp t))
              (f-full default-directory))))
    (when dir
      (f-slash dir))))

(defun hasky-stack--mod-time (filename)
  "Return time of last modification of file FILENAME."
  (and filename (nth 5 (file-attributes filename 'integer))))

(defun hasky-stack--executable ()
  "Return path to stack executable if it's available and NIL otherwise."
  (let ((default "stack")
        (custom  hasky-stack-executable))
    (cond
     ((and custom (f-executable? custom)) custom)
     ((executable-find default) default))))

(defvar hasky-stack--all-packages nil
  "(cached) list of all local stack packages")
(defvar hasky-stack--all-packages-with-versions nil
  "(cached) list of all local stack packages with versions;
   an association list with elements (PKG VERSIONS+)")

(defun hasky-stack--get-all-packages ()
  "Loads the lists of all local stack packages."
  (let* (index                                  ; list of (PACKAGE VERSION+)
         pairs                                  ; list of (PACKAGE . VERSION)
         (pattern "\\(\\w+\\)-\\([0-9.]+\\)"))   ; PACKAGE-VERSION
    ;; call ghc-pkg:
    (with-temp-buffer
      (shell-command "stack exec -- ghc-pkg --simple-output list" t)
      (goto-char (point-min))
      (while (re-search-forward pattern nil t)
        (setq pairs (cons (cons (match-string 1) (match-string 2)) pairs)))
      (setq pairs (nreverse pairs)))
    ;; convert the list of pairs to an association list keys on packages
    (mapc
     (lambda (pair)
       (let* ((pkg (car pair))
              (ver (cdr pair))
              (item (assq pkg index)))
         (if item (setcdr item (cons ver (cdr item)))
           (setq index (cons (list pkg ver) index)))))
     pairs)
    (setq hasky-stack--all-packages-with-versions index)
    (setq hasky-stack--all-packages (mapcar #'car index))))

(defun hasky-stack--all-packages ()
  "Return list of all local stack packages"
  (unless hasky-stack--all-packages
    (hasky-stack--get-all-packages))
  hasky-stack--all-packages)

(defun hasky-stack--package-versions (package)
  "Return list of all available versions of PACKAGE."
  (unless hasky-stack--all-packages-with-versions
    (hasky-stack--get-all-packages))
  (cdr (assq package hasky-stack--all-packages-with-versions)))

(defun hasky-stack--latest-version (versions)
  "Return latest version from VERSIONS."
  (cl-reduce (lambda (x y) (if (version< y x) x y))
             versions))

(defun hasky-stack--package-with-version (package version)
  "Render identifier of PACKAGE with VERSION."
  (concat package "-" version))

(defun hasky-stack--completing-read (prompt &optional collection require-match)
  "Read user's input using `hasky-stack-read-function'.

PROMPT is the prompt to show and COLLECTION represents valid
choices.  If REQUIRE-MATCH is not NIL, don't let user input
something different from items in COLLECTION.

COLLECTION is allowed to be a string, in this case it's
automatically wrapped to make it one-element list.

If COLLECTION contains \"none\", and user selects it, interpret
it as NIL.  If user aborts entering of the input, return NIL.

Finally, if COLLECTION is nil, plain `read-string' is used."
  (let* ((collection
          (if (listp collection)
              collection
            (list collection)))
         (result
          (if collection
              (funcall hasky-stack-read-function
                       prompt
                       collection
                       nil
                       require-match
                       nil
                       nil
                       (car collection))
            (read-string prompt))))
    (unless (and (string= result "none")
                 (member result collection))
      result)))

(defun hasky-stack-set-current-package (pkg)
  "Select a package in the current package to be the focus of stack build commands.
PKG is a cabal package description returned by `hasky-stack--parse-cabal-file'.
Interactively (and from root popup) lets the user pick from a list."
  (interactive (list (hasky-stack--select-project-package "package: ")))
  (setq hasky-stack--current-package pkg))

(defun hasky-stack--select-project-package (prompt)
  (let* ((all hasky-stack--project-packages)
         (names (mapcar #'hasky-stack--package-name all))
         (chosen (hasky-stack--completing-read prompt names)))
    (cl-find-if
     (lambda (item) (equal chosen (hasky-stack--package-name item)))
     all)))

(defun hasky-stack--select-target (prompt &optional fragment)
  "Present the user with a choice of build target using PROMPT.

If given, FRAGMENT will be as a filter so only targets that
contain this string will be returned."
  (if hasky-stack-auto-target
      (hasky-stack--package-name)
    (hasky-stack--completing-read
     prompt
     (cons (hasky-stack--package-name)
           (if fragment
               (cl-remove-if
                (lambda (x)
                  (not (string-match-p (regexp-quote fragment) x)))
                (hasky-stack--package-targets))
             (hasky-stack--package-targets))
           )
     t)))

(defun hasky-stack--select-package-version (package)
  "Present the user with a choice of PACKAGE version."
  (let ((versions (hasky-stack--package-versions package)))
    (if hasky-stack-auto-newest-version
        (hasky-stack--latest-version versions)
      (hasky-stack--completing-read
       (format "Version of %s: " package)
       (cl-sort versions (lambda (x y) (version< y x)))
       t))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Preparation

(defun hasky-stack--prepare ()
  "Locate, read, and parse configuration files and set various variables.

This command finds and parses all .cabal files in the current
project. Starting from the current directory, and moving upwards,
it looks for stack.yaml, package.yaml, or cabal.project; this is
taken to be the top directory of the project. It then searches
downwards for .cabal files, but ignores any directory that
appears to be another project tree (ie that containes stack.yaml,
package.yaml, or cabal.project).

Each cabal file is parsed into a list of package attributes,
which is appended to the variable hasky-stack--project-packages.
This function avoids reparsing unchanged cabal files.
Fails by throwing an error."

  (cl-flet ((find-cabal-files (dir) 
             ;;find DIR -name \*.cabal
             ;; TODO: should check results vs dir/cabal.project
             (f-files dir (lambda (f) (equal (f-ext f) "cabal")) t))
            (find-project-directory ()
             (f-traverse-upwards
              (lambda (dir)
                (or (f-exists? (f-expand "cabal.project" dir))
                    (f-exists? (f-expand "project.yaml" dir))
                    (f-exists? (f-expand "stack.yaml" dir)))))))
    (let* ((project-directory (find-project-directory))
           (cabal-file
            (and project-directory
                 (car (f-glob "*.cabal" project-directory))))
           (cabal-project-file
            (and project-directory (f-expand "cabal.project" project-directory)))
           (compound-project (f-exists? cabal-project-file))
           (project-name
            (if compound-project (f-base project-directory) (f-base cabal-file)))
           (different-project
            (or (not hasky-stack--project-directory)
                (not (f-same? hasky-stack--project-directory project-directory))))
           (reload-all
            (or different-project
                (and compound-project
                     (time-less-p
                      hasky-stack--cabal-project-mod-time
                      (hasky-stack--mod-time cabal-project-file))))))
      (unless (or compound-project (f-exists? cabal-file))
        (error "%s" "Cannot find a .cabal file"))
      (when different-project
        (setq hasky-stack--project-directory project-directory
              hasky-stack--project-name project-name
              hasky-stack--project-version nil
              hasky-stack--project-packages nil
              hasky-stack--current-package nil
              hasky-stack--cabal-project-mod-time
              (hasky-stack--mod-time cabal-project-file)))
      (cond (reload-all
             ;; find and parse all .cabal files in this project:
             (let ((cabal-files
                    (if compound-project
                        (find-cabal-files project-directory)
                      (list cabal-file))))
               (setq hasky-stack--project-packages
                     (mapcar #'hasky-stack--parse-cabal-file cabal-files))))
            (t
             ;; otherwise, the list of cabal files is up to date, read the changed
             ;; ones again:
             (setq hasky-stack--project-packages
                   (mapcar #'hasky-stack--maybe-reload-package
                           hasky-stack--project-packages))))
      (setq hasky-stack--project-is-compound
            (consp (cdr hasky-stack--project-packages)))
      (when different-project
        (setq hasky-stack--current-package (car hasky-stack--project-packages)
              hasky-stack--project-version (hasky-stack--package-version))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Low-level construction of individual commands

(defun hasky-stack--format-command (command &rest args)
  "Generate textual representation of a command.

COMMAND is the name of command and ARGS are arguments (strings).
Result is expected to be used as argument of `compile'."
  (mapconcat
   #'identity
   (append
    (list (shell-quote-argument (hasky-stack--executable))
          command)
    (mapcar #'shell-quote-argument
            (remove nil args)))
   " "))

(defun hasky-stack--exec-command (package dir command &rest args)
  "Call stack for PACKAGE as if from DIR performing COMMAND with arguments ARGS.

Arguments are quoted if necessary and NIL arguments are ignored.
When hasky-stack-edit-the-command is true, let the user edit the
stack command first. This uses `compile' internally."
  (let ((default-directory dir)
        (compilation-buffer-name-function
         (lambda (_major-mode)
           (format "*%s-%s*"
                   (downcase
                    (replace-regexp-in-string
                     "[[:space:]]"
                     "-"
                     (or package "hasky")))
                   "stack")))
        (stack-command (apply #'hasky-stack--format-command command args)))
    (if hasky-stack-edit-the-command
      (setq stack-command (compilation-read-command stack-command)))
    (compile stack-command)
    nil))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Variables

(defun hasky-stack--cycle-bool-variable (symbol)
  "Cycle value of variable named SYMBOL."
  (custom-set-variables
   (list symbol (not (symbol-value symbol)))))

(defun hasky-stack--format-bool-variable (symbol label)
  "Format a Boolean variable named SYMBOL, label it as LABEL."
  (let ((val (symbol-value symbol)))
    (concat
     (format "%s " label)
     (propertize
      (if val "enabled" "disabled")
      'face
      (if val
          'magit-popup-option-value
        'magit-popup-disabled-argument)))))

(defun hasky-stack--acp (fun &rest args)
  "Apply FUN to ARGS partially and return a command."
  (lambda (&rest args2)
    (interactive)
    (apply fun (append args args2))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Popups

(magit-define-popup hasky-stack-build-popup
  "Show popup for the \"stack build\" command."
  'hasky-stack
  :variables `((?a "auto-target"
                   ,(hasky-stack--acp
                     #'hasky-stack--cycle-bool-variable
                     'hasky-stack-auto-target)
                   ,(hasky-stack--acp
                     #'hasky-stack--format-bool-variable
                     'hasky-stack-auto-target
                     "Auto target"))
               (?c "auto-open-coverage-reports"
                   ,(hasky-stack--acp
                     #'hasky-stack--cycle-bool-variable
                     'hasky-stack-auto-open-coverage-reports)
                   ,(hasky-stack--acp
                     #'hasky-stack--format-bool-variable
                     'hasky-stack-auto-open-coverage-reports
                     "Auto open coverage reports"))
               (?d "auto-open-haddocks"
                   ,(hasky-stack--acp
                     #'hasky-stack--cycle-bool-variable
                     'hasky-stack-auto-open-haddocks)
                   ,(hasky-stack--acp
                     #'hasky-stack--format-bool-variable
                     'hasky-stack-auto-open-haddocks
                     "Auto open Haddocks")))
  :switches '((?r "Dry run"           "--dry-run")
              (?t "Pedantic"          "--pedantic")
              (?f "Fast"              "--fast")
              (?F "File watch"        "--file-watch")
              (?s "Only snapshot"     "--only-snapshot")
              (?d "Only dependencies" "--only-dependencies")
              (?p "Profile"           "--profile")
              (?c "Coverage"          "--coverage")
              (?b "Copy bins"         "--copy-bins")
              (?g "Copy compiler tool" "--copy-compiler-tool")
              (?l "Library profiling" "--library-profiling")
              (?e "Executable profiling" "--executable-profiling"))
  :options  '((?o "GHC options"         "--ghc-options=")
              (?b "Benchmark arguments" "--benchmark-arguments=")
              (?t "Test arguments"      "--test-arguments=")
              (?h "Haddock arguments"   "--haddock-arguments="))
  :actions  '((?b "Build"   hasky-stack-build)
              (?e "Bench"   hasky-stack-bench)
              (?t "Test"    hasky-stack-test)
              (?h "Haddock" hasky-stack-haddock))
  :default-action 'hasky-stack-build)

(defun hasky-stack-build (target &optional args)
  "Execute \"stack build\" command for TARGET with ARGS."
  (interactive
   (list (hasky-stack--select-target "Build target: ")
         (hasky-stack-build-arguments)))
  (apply
   #'hasky-stack--exec-command
   (hasky-stack--package-name)
   (hasky-stack--package-directory)
   "build"
   target
   args))

(defun hasky-stack-bench (target &optional args)
  "Execute \"stack bench\" command for TARGET with ARGS."
  (interactive
   (list (hasky-stack--select-target "Bench target: " ":bench:")
         (hasky-stack-build-arguments)))
  (apply
   #'hasky-stack--exec-command
   (hasky-stack--package-name)
   (hasky-stack--package-directory)
   "bench"
   target
   args))

(defun hasky-stack-test (target &optional args)
  "Execute \"stack test\" command for TARGET with ARGS."
  (interactive
   (list (hasky-stack--select-target "Test target: " ":test:")
         (hasky-stack-build-arguments)))
  (apply
   #'hasky-stack--exec-command
   (hasky-stack--package-name)
   (hasky-stack--package-directory)
   "test"
   target
   args))

(defun hasky-stack-haddock (&optional args)
  "Execute \"stack haddock\" command for TARGET with ARGS."
  (interactive
   (list (hasky-stack-build-arguments)))
  (apply
   #'hasky-stack--exec-command
   (hasky-stack--package-name)
   (hasky-stack--package-directory)
   "haddock"
   args))

(magit-define-popup hasky-stack-init-popup
  "Show popup for the \"stack init\" command."
  'hasky-stack
  :switches '((?s "Solver"         "--solver")
              (?o "Omit packages"  "--omit-packages")
              (?f "Force"          "--force")
              (?i "Ignore subdirs" "--ignore-subdirs"))
  :actions  '((?i "Init" hasky-stack-init))
  :default-action 'hasky-stack-init)

(defun hasky-stack-init (&optional args)
  "Execute \"stack init\" with ARGS."
  (interactive
   (list (hasky-stack-init-arguments)))
  (apply
   #'hasky-stack--exec-command
   (hasky-stack--package-name)
   (hasky-stack--package-directory)
   "init"
   args))

(magit-define-popup hasky-stack-setup-popup
  "Show popup for the \"stack setup\" command."
  'hasky-stack
  :switches '((?r "Reinstall"     "--reinstall")
              (?c "Upgrade Cabal" "--upgrade-cabal"))
  :actions  '((?s "Setup" hasky-stack-setup))
  :default-action 'hasky-stack-setup)

(defun hasky-stack-setup (ghc-version &optional args)
  "Execute \"stack setup\" command to install GHC-VERSION with ARGS."
  (interactive
   (list (hasky-stack--completing-read
          "GHC version: "
          (cons "implied-by-resolver"
                hasky-stack-ghc-versions)
          t)
         (hasky-stack-setup-arguments)))
  (apply
   #'hasky-stack--exec-command
   (hasky-stack--package-name)
   (hasky-stack--package-directory)
   "setup"
   (unless (string= ghc-version "implied-by-resolver")
     ghc-version)
   args))

(magit-define-popup hasky-stack-upgrade-popup
  "Show popup for the \"stack upgrade\" command."
  'hasky-stack
  :switches '((?s "Source only" "--source-only")
              (?b "Binary only" "--binary-only")
              (?f "Force download" "--force-download")
              (?g "Git" "--git"))
  :options  '((?p "Binary platform" "--binary-platform=")
              (?v "Binary version" "--binary-version=")
              (?r "Git repo" "--git-repo="))
  :actions  '((?g "Upgrade" hasky-stack-upgrade))
  :default-arguments '("--git-repo=https://github.com/commercialhaskell/stack")
  :default-action 'hasky-stack-upgrade)

(defun hasky-stack-upgrade (&optional args)
  "Execute \"stack upgrade\" command with ARGS."
  (interactive
   (list (hasky-stack-upgrade-arguments)))
  (apply
   #'hasky-stack--exec-command
   hasky-stack--project-name
   hasky-stack--project-directory
   "upgrade"
   args))

(magit-define-popup hasky-stack-upload-popup
  "Show popup for the \"stack upload\" command."
  'hasky-stack
  :switches '((?i "Ignore check" "--ignore-check")
              (?n "No signature" "--no-signature")
              (?t "Test tarball" "--test-tarball"))
  :options  '((?s "Sig server" "--sig-server="))
  :actions  '((?p "Upload" hasky-stack-upload))
  :default-arguments '("--no-signature")
  :default-action 'hasky-stack-upload)

(defun hasky-stack-upload (&optional args)
  "Execute \"stack upload\" command with ARGS."
  (interactive
   (list (hasky-stack-upload-arguments)))
  (apply
   #'hasky-stack--exec-command
   hasky-stack--project-name
   hasky-stack--project-directory
   "upload"
   "."
   args))

(magit-define-popup hasky-stack-sdist-popup
  "Show popup for the \"stack sdist\" command."
  'hasky-stack
  :switches '((?i "Ignore check" "--ignore-check")
              (?s "Sign"         "--sign")
              (?t "Test tarball" "--test-tarball"))
  :options  '((?s "Sig server"   "--sig-server="))
  :actions  '((?d "SDist" hasky-stack-sdist))
  :default-action 'hasky-stack-sdist)

(defun hasky-stack-sdist (&optional args)
  "Execute \"stack sdist\" command with ARGS."
  (interactive
   (list (hasky-stack-sdist-arguments)))
  (apply
   #'hasky-stack--exec-command
   hasky-stack--project-name
   hasky-stack--project-directory
   "sdist"
   args))

(defun hasky-stack-exec (cmd)
  "Execute \"stack exec\" command running CMD."
  (interactive
   (list (read-string "Command to run: ")))
  (cl-destructuring-bind (app . args)
      (progn
        (string-match
         "^[[:blank:]]*\\(?1:[^[:blank:]]+\\)[[:blank:]]*\\(?2:.*\\)$"
         cmd)
        (cons (match-string 1 cmd)
              (match-string 2 cmd)))
    (hasky-stack--exec-command
     (hasky-stack--package-name)
     (hasky-stack--package-directory)
     (if (string= args "")
         (concat "exec " app)
       (concat "exec " app " -- " args)))))

(defun hasky-stack-run (cmd)
  "Execute \"stack run\" command running CMD."
  (interactive
   (list (read-string "Command to run: ")))
  (cl-destructuring-bind (app . args)
      (progn
        (string-match
         "^[[:blank:]]*\\(?1:[^[:blank:]]+\\)[[:blank:]]*\\(?2:.*\\)$"
         cmd)
        (cons (match-string 1 cmd)
              (match-string 2 cmd)))
    (hasky-stack--exec-command
     (hasky-stack--package-name)
     (hasky-stack--package-directory)
     (if (string= args "")
         (concat "run " app)
       (concat "run " app " -- " args)))))

(magit-define-popup hasky-stack-clean-popup
  "Show popup for the \"stack clean\" command."
  'hasky-stack
  :switches '((?f "Full"  "--full"))
  :actions  '((?c "Clean" hasky-stack-clean))
  :default-action 'hasky-stack-clean)

(defun hasky-stack-clean (&optional args)
  "Execute \"stack clean\" command with ARGS."
  (interactive
   (list (hasky-stack-clean-arguments)))
  (apply
   #'hasky-stack--exec-command
   (hasky-stack--package-name)
   (hasky-stack--package-directory)
   "clean"
   (if (member "--full" args)
       args
     (list (hasky-stack--package-name)))))

(defun hasky-stack--root-heading()
  (concat
   (propertize
    (if hasky-stack--project-is-compound
        (format "%s/%s"
                hasky-stack--project-name
                (hasky-stack--package-name))
      (hasky-stack--package-name))
    'face 'hasky-stack-project-name)
   " "
   (propertize (hasky-stack--package-version)
               'face 'hasky-stack-project-version)
   "\n\n"
   (propertize "Commands" 'face 'magit-popup-heading)))

(magit-define-popup hasky-stack-root-popup
  "Show root popup with all supported commands."
  'hasky-stack
  :actions  '((lambda () (hasky-stack--root-heading))
              (?b "Build"   hasky-stack-build-popup)
              (?i "Init"    hasky-stack-init-popup)
              (?s "Setup"   hasky-stack-setup-popup)
              (?u "Update"  hasky-stack-update)
              (?g "Upgrade" hasky-stack-upgrade-popup)
              (?p "Upload"  hasky-stack-upload-popup)
              (?d "SDist"   hasky-stack-sdist-popup)
              (?x "Exec"    hasky-stack-exec)
              (?r "Run"     hasky-stack-run)
              (?c "Clean"   hasky-stack-clean-popup)
              (?l "Edit Cabal file" hasky-stack-edit-cabal)
              (?y "Edit stack.yaml" hasky-stack-edit-stack-yaml)
              (?z "Change current sub-package" hasky-stack-set-current-package))
  :default-action 'hasky-stack-build-popup
  :max-action-columns 3)

(defun hasky-stack-update ()
  "Execute \"stack update\"."
  (interactive)
  (hasky-stack--exec-command
   hasky-stack--project-name
   hasky-stack--project-directory
   "update"))

(defun hasky-stack-edit-cabal ()
  "Open Cabal file of current project for editing."
  (interactive)
  (let ((cabal-file
         (car (and (hasky-stack--package-directory)
                   (f-glob "*.cabal" (hasky-stack--package-directory))))))
    (when cabal-file
      (find-file cabal-file))))

(defun hasky-stack-edit-stack-yaml ()
  "Open \"stack.yaml\" of current project for editing."
  (interactive)
  (let* ((pkgdir (hasky-stack--package-directory))
         (prodir  hasky-stack--project-directory)
         (stack-yaml-file
          (or (car (and pkgdir (f-glob "stack.yaml" pkgdir)))
              (car (and prodir (f-glob "stack.yaml" prodir))))))
    (when stack-yaml-file
      (find-file stack-yaml-file))))

(magit-define-popup hasky-stack-package-action-popup
  "Show package action popup."
  'hasky-stack
  :variables `((?a "auto-newest-version"
                   ,(hasky-stack--acp
                     #'hasky-stack--cycle-bool-variable
                     'hasky-stack-auto-newest-version)
                   ,(hasky-stack--acp
                     #'hasky-stack--format-bool-variable
                     'hasky-stack-auto-newest-version
                     "Auto newest version"))
               (?E "edit-command"
                   ,(hasky-stack--acp
                     #'hasky-stack--cycle-bool-variable
                     'hasky-stack-edit-the-command)
                   ,(hasky-stack--acp
                     #'hasky-stack--format-bool-variable
                     'hasky-stack-edit-the-command
                     "Edit command before running.")))
  :options   '((?r "Resolver to use" "--resolver="))
  :actions   '((?i "Install"      hasky-stack-package-install)
               (?h "Hackage"      hasky-stack-package-open-hackage)
               (?s "Stackage"     hasky-stack-package-open-stackage)
               (?m "Build matrix" hasky-stack-package-open-build-matrix)
               (?g "Home page"    hasky-stack-package-open-home-page)
               (?c "Changelog"    hasky-stack-package-open-changelog))
  :default-action 'hasky-stack-package-install
  :max-action-columns 3)

(defun hasky-stack-package-install (package version &optional args)
  "Install PACKAGE of VERSION globally using ARGS."
  (interactive
   (list hasky-stack--package-action-package
         (hasky-stack--select-package-version
          hasky-stack--package-action-package)
         (hasky-stack-package-action-arguments)))
  (apply
   #'hasky-stack--exec-command
   hasky-stack--package-action-package
   hasky-stack-config-dir
   "install"
   (hasky-stack--package-with-version package version)
   args))

(defun hasky-stack--browse-url (url)
  (when hasky-stack-edit-the-command
    (setq url (read-string "Browse: " url nil url)))
  (browse-url url))

(defun hasky-stack-package-open-hackage (package)
  "Open Hackage page for PACKAGE."
  (interactive (list hasky-stack--package-action-package))
  (hasky-stack--browse-url
   (concat "https://hackage.haskell.org/package/"
           (url-hexify-string package))))

(defun hasky-stack-package-open-stackage (package)
  "Open Stackage page for PACKAGE."
  (interactive (list hasky-stack--package-action-package))
  (hasky-stack--browse-url
   (concat "https://www.stackage.org/package/"
           (url-hexify-string package))))

(defun hasky-stack-package-open-build-matrix (package)
  "Open Hackage build matrix for PACKAGE."
  (interactive (list hasky-stack--package-action-package))
  (hasky-stack--browse-url
   (concat "https://matrix.hackage.haskell.org/package/"
           (url-hexify-string package))))

(defun hasky-stack-package-open-home-page (package)
  "Open home page of PACKAGE."
  (interactive (list hasky-stack--package-action-package))
  (let* ((result
          (shell-command-to-string
           (concat "stack exec -- ghc-pkg field " package " homepage")))
         (url (and (string-match "^homepage: \\(.+\\)$" result)
                   (match-string 1 result))))
    (if url (hasky-stack--browse-url url))))

(defun hasky-stack-package-open-changelog (package)
  "Open Hackage build matrix for PACKAGE."
  (interactive (list hasky-stack--package-action-package))
  (hasky-stack--browse-url
   (concat "https://hackage.haskell.org/package/"
           (url-hexify-string
            (hasky-stack--package-with-version
             package
             (hasky-stack--latest-version
              (hasky-stack--package-versions package))))
           "/changelog")))

;; add to all popups: E toggles hasky-stack-edit-the-command
(let ((cmd
       (hasky-stack--acp
        #'hasky-stack--cycle-bool-variable
        'hasky-stack-edit-the-command))
      (fmt
       (hasky-stack--acp
        #'hasky-stack--format-bool-variable
        'hasky-stack-edit-the-command
        "Edit the stack command before it runs"))
      (stack-popups
       '(hasky-stack-build-popup
         hasky-stack-init-popup
         hasky-stack-setup-popup
         hasky-stack-upgrade-popup
         hasky-stack-upload-popup
         hasky-stack-sdist-popup
         hasky-stack-clean-popup)))
  (mapc
   (lambda (p) (magit-define-popup-variable p ?E nil cmd fmt))
   stack-popups))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; High-level interface

;;;###autoload
(defun hasky-stack-execute ()
  "Show the root-level popup allowing to choose and run a Stack command."
  (interactive)
  (unless (hasky-stack--executable)
    (error "%s" "Cannot locate Stack executable on this system"))
  (hasky-stack--prepare)
  (hasky-stack-root-popup))

;;;###autoload
(defun hasky-stack-new (project-name template)
  "Initialize the current directory by using a Stack template.

PROJECT-NAME is the name of project and TEMPLATE is quite
obviously template name."
  (interactive
   (list (hasky-stack--completing-read
          "Project name: "
          (file-name-nondirectory
           (directory-file-name
            default-directory)))
         (hasky-stack--completing-read
          "Use template: "
          (cons "none" hasky-stack-templates)
          t)))
  (if (f-exists? (f-expand "stack.yaml" default-directory))
      (message "The directory is already initialized, it seems")
    (hasky-stack--exec-command
     project-name
     default-directory
     "new"
     "--bare"
     project-name
     template)))

;;;###autoload
(defun hasky-stack-package-action (package)
  "Open a popup allowing to install or request information about PACKAGE."
  (interactive
   (list (hasky-stack--completing-read
          "Package: "
          (hasky-stack--all-packages)
          t)))
  (setq hasky-stack--package-action-package package)
  (hasky-stack-package-action-popup))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Setting up post-compilation magic

(defun hasky-stack--compilation-finish-function (buffer str)
  "Function that is called when a compilation process in BUFFER finishes.

STR describes how the process finished."
  (when (and (string-match "^\\*.*-stack\\*$" (buffer-name buffer))
             (string= str "finished\n"))
    (with-current-buffer buffer
      ;; Coverage report
      (goto-char (point-min))
      (when (and hasky-stack-auto-open-coverage-reports
                 (re-search-forward
                  "^The coverage report for .+'s test-suite \".+\" is available at \\(.*\\)$" nil t))
        (hasky-stack--browse-url (match-string-no-properties 1)))
      (cl-flet ((open-haddock
                 (regexp)
                 (goto-char (point-min))
                 (when (and hasky-stack-auto-open-haddocks
                            (re-search-forward regexp nil t))
                   (hasky-stack--browse-url
                    (f-expand (match-string-no-properties 1) (hasky-stack--package-directory)))
                   t)))
        (or (open-haddock "^Documentation created:\n\\(.*\\),$")
            (open-haddock "^Haddock index for local packages already up to date at:\n\\(.*\\)$")
            (open-haddock "^Updating Haddock index for local packages in\n\\(.*\\)$"))))))

(add-to-list 'compilation-finish-functions
             #'hasky-stack--compilation-finish-function)

(provide 'hasky-stack)
;;; hasky-stack.el ends here
