;;; disaster.el --- Disassemble C, C++ or Fortran code under cursor -*- lexical-binding: t; -*-

;; Copyright (C) 2013-2022 Justine Tunney.

;; Author: Justine Tunney <jtunney@gmail.com>
;;         Abdelhak Bougouffa <abougouffa@fedoraproject.org>
;;         Gabriel Veiga <gabriellopvei@gmail.com>
;; Maintainer: Gabriel Veiga <gabriellopvei@gmail.com>
;; Created: 2013-03-02
;; Version: 1.0
;; Package-Requires: ((emacs "27"))
;; Keywords: tools c
;; URL: https://github.com/veigaribo/disaster

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; ![Screenshot of a C example](screenshot-c.png)
;;
;; ![Screenshot of a Fortran example](screenshot-fortran.png)
;;
;; Disaster lets you press `C-c d` to see the compiled assembly code for the
;; C, C++ or Fortran file you're currently editing. It even jumps to and
;; highlights the line of assembly corresponding to the line beneath your cursor.
;;
;; It works by creating a `.o` file using the default system
;; compiler. It then runs that file through `objdump` to generate the
;; human-readable assembly.

;;; Installation:

;; Make sure to place `disaster.el` somewhere in the `load-path`, then you should
;; be able to run `M-x disaster`. If you want, you add the following lines to
;; your `.emacs` file to register the `C-c d` shortcut for invoking `disaster`:
;;
;; ```elisp
;; (add-to-list 'load-path "/PATH/TO/DISASTER")
;; (require 'disaster)
;; (define-key c-mode-map (kbd "C-c d") 'disaster)
;; (define-key fortran-mode-map (kbd "C-c d") 'disaster)
;; ```

;; #### Doom Emacs

;; For Doom Emacs users, you can add this snippet to your `packages.el`.
;;
;; ```elisp
;; (package! disaster
;;   :recipe (:host github :repo "jart/disaster"))
;; ```
;;
;; And this to your `config.el`:
;;
;; ```elisp
;; (use-package! disaster
;;   :commands (disaster)
;;   :init
;;   ;; If you prefer viewing assembly code in `nasm-mode` instead of `asm-mode`
;;   (setq disaster-assembly-mode 'nasm-mode)
;;
;;   (map! :localleader
;;         :map (c++-mode-map c-mode-map fortran-mode-map)
;;         :desc "Disaster" "d" #'disaster))
;; ```

;;; Code:

(require 'json)
(require 'vc)

(defgroup disaster nil
  "Disassemble C/C++ under cursor (Works best with Clang)."
  :prefix "disaster-"
  :group 'tools)

(defcustom disaster-assembly-mode 'asm-mode
  "Which mode to use to view assembly code."
  :group 'disaster
  :type '(choice asm-mode nasm-mode))

(defcustom disaster-cc (or (getenv "CC") "cc")
  "The command for your C compiler."
  :group 'disaster
  :type 'string)

(defcustom disaster-cxx (or (getenv "CXX") "c++")
  "The command for your C++ compiler."
  :group 'disaster
  :type 'string)


(defcustom disaster-fortran (or (getenv "FORTRAN") "gfortran")
  "The command for your Fortran compiler."
  :group 'disaster
  :type 'string)

(defcustom disaster-cflags (or (getenv "CFLAGS")
                               "-march=native")
  "Command line options to use when compiling C."
  :group 'disaster
  :type 'string)

(defcustom disaster-cxxflags (or (getenv "CXXFLAGS")
                                 "-march=native")
  "Command line options to use when compiling C++.!"
  :group 'disaster
  :type 'string)


(defcustom disaster-fortranflags (or (getenv "FORTRANFLAGS")
                                     "-march=native")
  "Command line options to use when compiling Fortran."
  :group 'disaster
  :type 'string)

(defcustom disaster-objdump
  (concat (if (eq system-type 'darwin) "gobjdump" "objdump")
          " -d -M att -Sl --no-show-raw-insn")
  "The command name and flags for running objdump."
  :group 'disaster
  :type 'string)

(defcustom disaster-buffer-compiler "*disaster-compilation*"
  "Buffer name to use for assembler output."
  :group 'disaster
  :type 'string)

(defcustom disaster-buffer-assembly "*disaster-assembly*"
  "Buffer name to use for objdump assembly output."
  :group 'disaster
  :type 'string)

(defcustom disaster-c-regexp "\\.c$"
  "Regexp for C source files."
  :group 'disaster
  :type 'regexp)

(defcustom disaster-cpp-regexp "\\.c\\(c\\|pp\\|xx\\)$"
  "Regexp for C++ source files."
  :group 'disaster
  :type 'regexp)

(defcustom disaster-fortran-regexp "\\.f\\(or\\|90\\|95\\|0[38]\\)?$"
  "Regexp for Fortran source files."
  :group 'disaster
  :type 'regexp)

(defcustom disaster-obj-path (concat "/tmp/emacs-disaster-" (user-login-name) "/output.o")
  "Path to write the object file to."
  :group 'disaster
  :type 'string)

(defun disaster-create-compile-command (file)
  "Create compile command for a Make-based project.
FILE: path to the file to compile."
  (cond ((string-match-p disaster-cpp-regexp file)
         (format "%s %s -g -c -o %s %s"
                 disaster-cxx disaster-cxxflags
                 (shell-quote-argument disaster-obj-path) (shell-quote-argument file)))
        ((string-match-p disaster-c-regexp file)
         (format "%s %s -g -c -o %s %s"
                 disaster-cc disaster-cflags
                 (shell-quote-argument disaster-obj-path) (shell-quote-argument file)))
        ((string-match-p disaster-fortran-regexp file)
         (format "%s %s -g -c -o %s %s"
                 disaster-fortran disaster-fortranflags
                 (shell-quote-argument disaster-obj-path) (shell-quote-argument file)))
        (t (warn "File %s do not seems to be a C, C++ or Fortran file." file))))

;;;###autoload
(defun disaster (&optional file line)
  "Show assembly code for current line of C/C++ file.

Here's the logic path it follows:

- Or is this a C file? Run `cc -g -c -o bufname.o bufname.c`
- Or is this a C++ file? Run `c++ -g -c -o bufname.o bufname.c`
- Or is this a Fortran file? Run `gfortran -g -c -o bufname.o bufname.c`
- If build failed, display errors in compile-mode.
- Run objdump inside a new window while maintaining focus.
- Jump to line matching current line.

If FILE and LINE are not specified, the current editing location
is used."
  (interactive)
  (save-buffer)
  (let* ((file      (or file (file-name-nondirectory (buffer-file-name))))
         (line      (or line (line-number-at-pos)))
         (file-line (format "%s:%d" file line))
         (makebuf   (get-buffer-create disaster-buffer-compiler))
         (asmbuf    (get-buffer-create disaster-buffer-assembly)))
    (if (or (string-match-p disaster-c-regexp file)
            (string-match-p disaster-cpp-regexp file)
            (string-match-p disaster-fortran-regexp file))
        (let* ((cc        (disaster-create-compile-command file))
               (dump      (format "%s %s" disaster-objdump
                                  (shell-quote-argument disaster-obj-path)))
               (line-text (buffer-substring-no-properties
                           (point-at-bol)
                           (point-at-eol))))

          (make-directory (file-name-directory disaster-obj-path) t)
          ;; delete potential old file so we can check for creation later
          (delete-file disaster-obj-path nil)

          (if (and (eq 0 (progn
                           (message (format "Running: %s" cc))
                           (shell-command cc makebuf)))
                   (file-exists-p disaster-obj-path))
              (when (eq 0 (progn
                            (message (format "Running: %s" dump))
                            (shell-command dump asmbuf)))
                (kill-buffer makebuf)
                (with-current-buffer asmbuf
                  ;; saveplace.el will prevent us from hopping to a line.
                  (set (make-local-variable 'save-place-mode) nil)
                  ;; Call the configured mode `asm-mode' or `nasm-mode'
                  (when (fboundp disaster-assembly-mode)
                    (funcall disaster-assembly-mode))
                  (disaster--shadow-non-assembly-code))
                (let ((oldbuf (current-buffer)))
                  (switch-to-buffer-other-window asmbuf)
                  (goto-char 0)
                  (if (or (search-forward line-text nil t)
                          (search-forward file-line nil t))
                      (progn
                        (recenter)
                        (overlay-put (make-overlay (point-at-bol)
                                                   (1+ (point-at-eol)))
                                     'face 'region))
                    (message "Couldn't find corresponding assembly line."))
                  (switch-to-buffer-other-window oldbuf)))
            (with-current-buffer makebuf
              (save-excursion
                (goto-char 0)
                (insert (concat cc "\n")))
              (compilation-mode)
              (display-buffer makebuf))))
      (message "Not a C, C++ or Fortran source file"))))

(defun disaster--shadow-non-assembly-code ()
  "Scans current buffer, which should be in `asm-mode'.
Uses the standard `shadow' face for lines that don't appear to contain
assembly code."
  (remove-overlays)
  (save-excursion
    (goto-char 0)
    (while (not (eobp))
      (beginning-of-line)
      (if (not (looking-at "[ \t]+[a-f0-9]+:[ \t]+"))
          (let ((eol (save-excursion (end-of-line) (point))))
            (overlay-put (make-overlay (point) eol)
                         'face 'shadow)))
      (forward-line))))

(defun disaster-find-project-root ()
  "Detect bottom directory of project.

This will try to use `(vc-root-dir)' to guess the project
root directory.
`disaster-project-root-files'."
  (let* ((buffer (get-file-buffer (buffer-file-name)))
         (res (when buffer
                (with-current-buffer buffer
                  (when (vc-root-dir)
                    (expand-file-name (vc-root-dir)))))))
    res))

(provide 'disaster)

;;; disaster.el ends here
