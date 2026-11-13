;;; etaf-html.el --- Render HTML using the ETAF framework  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Qiqi Jin

;; Author: Qiqi Jin <ginqi7@gmail.com>
;; URL: https://github.com/ginqi7/etaf-html.el
;; Keywords: hypermedia
;; Package-Requires: ((emacs "29.1") (etaf "0.3.5") (ekp "1.0.1"))
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Render HTML with ETAF, the Emacs Text Application Framework.
;;
;; The translation works in two passes:
;;
;; - Block-level content is translated into ETAF Views (`column',
;;   `box', `row', `grid' and `text').  Consecutive inline nodes are
;;   merged into a single propertized string, so that HTML whitespace
;;   collapses the way a browser collapses it.
;; - Inline content is translated into a propertized string, layering
;;   faces for nested markup (`<b>', `<i>', `<code>', ...).  Paragraph
;;   text is then laid out by EKP's Knuth-Plass breaker and aligned to
;;   the configured width before ETAF measures it.
;;
;; Inline text is carried by an ETAF `text' Host.  Ebox preserves the
;; text properties on that string, which means nested faces, links and
;; the `shr-target-id' anchors survive into the rendered buffer.  Block
;; layout, wrapping and indentation are left to ETAF: a list item is a
;; `row' made of a marker and a flexible content box, and a table is a
;; `grid' of text cells.
;;
;; Usage:
;;
;;   (etaf-html-mount "<h1>Hello</h1><p>This is a paragraph.</p>")
;;
;; or mount the View returned by `etaf-html' yourself with `etaf-mount'.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'seq)
(require 'subr-x)
(require 'ekp)
(require 'etaf)

(defgroup etaf-html nil
  "Render HTML using the ETAF framework."
  :group 'text
  :prefix "etaf-html-")

(defcustom etaf-html-buffer-name "*etaf-html*"
  "Default buffer name for rendering HTML."
  :type 'string
  :group 'etaf-html)

(defcustom etaf-html-max-width 80
  "Maximum character width for rendering HTML content."
  :type 'integer
  :group 'etaf-html)

(defcustom etaf-html-use-ekp t
  "Whether to lay out paragraph text with EKP.
When non-nil, paragraph text is broken and justified with EKP before
it is handed to ETAF.  Set it to nil to let Ebox wrap text greedily."
  :type 'boolean
  :group 'etaf-html)

(defcustom etaf-html-alignment 'justify
  "Alignment used by EKP for rendered paragraph text.
The value is passed to EKP's `ekp-alignment'."
  :type '(choice (const :tag "Justify" justify)
                 (const :tag "Ragged right" ragged-right)
                 (const :tag "Ragged left" ragged-left)
                 (const :tag "Center" center))
  :group 'etaf-html)

(defcustom etaf-html-block-spacing 0
  "Number of blank lines between block-level HTML elements.
The spacing is inserted between sibling blocks such as paragraphs,
headings, lists, tables and preformatted blocks.  It is not inserted
between list items or table rows.  Set it to 0 to disable extra
spacing."
  :type 'integer
  :group 'etaf-html)

(defcustom etaf-html-font nil
  "Font used to display rendered HTML.
The value is one of:

- nil, to use the default face's font;
- a font family name (a string);
- a font spec or font object;
- a plist of face attributes, for example
  \(:family \"Noto Serif CJK SC\" :height 140).  `:size' is also
  accepted, in points, and is converted to `:height'.

The font is applied to the text rendered by `etaf-html-mount', and is
in effect while translating and measuring the HTML as well, so that
line breaking matches the font used for display."
  :type '(choice (const :tag "Default font" nil)
                 (string :tag "Font family")
                 (plist :key-type symbol :value-type sexp))
  :group 'etaf-html)

(defcustom etaf-html-mount-options nil
  "Extra options passed to `etaf-mount' by `etaf-html-mount'.
This is a plist, for example `\(:viewport-width 900 :viewport-height 40)'.
When nil, ETAF uses the display window or its batch defaults."
  :type '(repeat sexp)
  :group 'etaf-html)

(defcustom etaf-html-table-border-color "#888888"
  "Color of the border drawn around a rendered `<table>'.
Set it to nil to render tables without a border."
  :type '(choice (const :tag "No border" nil)
                 (color :tag "Border color"))
  :group 'etaf-html)

(defcustom etaf-html-pre-background "#F5F5F5"
  "Background color of rendered `<pre>' blocks.
Set it to nil to inherit the surrounding background."
  :type '(choice (const :tag "No background" nil)
                 (color :tag "Background color"))
  :group 'etaf-html)

(defcustom etaf-html-browse-url #'browse-url
  "Function used to open links found in HTML."
  :type 'function
  :group 'etaf-html)

;;; Faces

(defface etaf-html-strong '((t :weight bold))
  "Face used for HTML <b> and <strong>."
  :group 'etaf-html)

(defface etaf-html-italic '((t :slant italic))
  "Face used for HTML <i>, <em>, <cite> and <dfn>."
  :group 'etaf-html)

(defface etaf-html-underline '((t :underline t))
  "Face used for HTML <u> and <ins>."
  :group 'etaf-html)

(defface etaf-html-strike-through '((t :strike-through t))
  "Face used for HTML <s>, <strike> and <del>."
  :group 'etaf-html)

(defface etaf-html-mark '((t :inherit highlight))
  "Face used for HTML <mark>."
  :group 'etaf-html)

(defface etaf-html-code '((t :family "monospace"))
  "Face used for HTML <code>, <kbd>, <samp> and <tt>."
  :group 'etaf-html)

(defface etaf-html-muted '((t :inherit shadow))
  "Face used for muted HTML content such as captions and quotes."
  :group 'etaf-html)

(defface etaf-html-link '((t :inherit link :underline t))
  "Face used for HTML links."
  :group 'etaf-html)

(defface etaf-html-button '((t :weight bold))
  "Face used for rendered HTML buttons."
  :group 'etaf-html)

(defface etaf-html-field '((t :box (:line-width -1 :style released-button)))
  "Face used for rendered HTML form fields."
  :group 'etaf-html)

(defface etaf-html-placeholder '((t :inherit shadow))
  "Face used for HTML form placeholders."
  :group 'etaf-html)

(defface etaf-html-table-header '((t :weight bold))
  "Face used for HTML table header cells."
  :group 'etaf-html)

(dolist (level (number-sequence 1 8))
  (let ((face (intern (format "etaf-html-heading-%d" level))))
    (unless (facep face)
      (custom-declare-face
       face
       (list (list t :height (+ 1 (* 0.12 (- 9 level)))
                   :weight 'bold))
       (format "Face used for HTML <h%d>." level)))))

;;; Tag classification

(defconst etaf-html--ignored-tags
  '(base col colgroup comment datalist head link map area meta noscript
    optgroup option param script source style template title track)
  "HTML tags that produce no renderable content.")

(defconst etaf-html--inline-tags
  '(a abbr b bdi bdo big br cite code data del dfn em font i ins kbd label
    mark q s samp small span strike strong sub sup time tt u var wbr)
  "HTML tags that participate in inline text flow.")

(defconst etaf-html--inline-or-ignored-tags
  (append etaf-html--inline-tags etaf-html--ignored-tags)
  "Inline tags plus ignored tags, which do not break an inline run.")

;;; Utilities

(defun etaf-html--parse-html (html-string)
  "Parse HTML-STRING using Emacs's libxml parser.
Return a parse tree suitable for translation."
  (with-temp-buffer
    (insert html-string)
    (libxml-parse-html-region (point-min) (point-max))))

(defun etaf-html--attr-p (attrs name)
  "Return non-nil when boolean attribute NAME is present in ATTRS."
  (and (assq name attrs) t))

(defun etaf-html--attr-number (attrs name)
  "Return decimal integer attribute NAME of ATTRS as a number."
  (when-let* ((value (alist-get name attrs)))
    (and (stringp value)
         (string-match-p "\\`[0-9]+\\'" value)
         (string-to-number value))))

(defun etaf-html--input-type (attrs)
  "Return the normalized type of an `<input>' with ATTRS."
  (downcase (or (alist-get 'type attrs) "text")))

(defun etaf-html--normalize-text (text)
  "Collapse runs of whitespace in TEXT to a single space."
  (replace-regexp-in-string "[ \t\r\n\f]+" " " text))

(defun etaf-html--collapse-whitespace (string)
  "Collapse redundant whitespace in STRING, preserving newlines.
Leading and trailing whitespace is removed."
  (let ((result (replace-regexp-in-string "[ \t]+" " " string)))
    (setq result (replace-regexp-in-string "[ \t]*\n[ \t]*" "\n" result))
    (string-trim result)))

(defun etaf-html--raw-text (nodes)
  "Concatenate NODES into a string, preserving whitespace."
  (mapconcat
   (lambda (node)
     (cond
      ((stringp node) node)
      ((eq (car-safe node) 'br) "\n")
      ((memq (car-safe node) etaf-html--ignored-tags) "")
      (t (etaf-html--raw-text (cddr node)))))
   nodes ""))

(defun etaf-html--effective-width ()
  "Return the width used for rules and table layout."
  (or etaf-html-max-width 80))

(defvar etaf-html--available-width nil
  "Character width available to the text currently being translated.
The root binds it to `etaf-html-max-width'; list items, quotes and
definition descriptions bind a narrower value.")

(defun etaf-html--width-pixels (width)
  "Return WIDTH character columns as pixels in the current buffer."
  (when (and width (> width 0))
    (string-pixel-width (make-string width ?0))))

(defun etaf-html--justify-text (text)
  "Return TEXT laid out and aligned with EKP.
When `etaf-html-use-ekp' is nil, or no width is available, return
TEXT unchanged."
  (if (or (not etaf-html-use-ekp)
          (not etaf-html--available-width)
          (<= etaf-html--available-width 0)
          (string-empty-p text))
      text
    (let ((pixel (etaf-html--width-pixels etaf-html--available-width)))
      (if (or (not pixel) (<= pixel 0))
          text
        (condition-case nil
            (let ((ekp-alignment etaf-html-alignment))
              (ekp-pixel-justify text pixel))
          (error text))))))

;;; Faces

(defun etaf-html--face-list (face)
  "Return FACE as a list of face specifications."
  (cond
   ((null face) nil)
   ;; An anonymous face spec such as (:underline t) is itself a list,
   ;; but must be treated as one element of the face list.
   ((and (listp face) (keywordp (car face))) (list face))
   ((listp face) face)
   (t (list face))))

(defun etaf-html--merge-faces (parent child)
  "Merge CHILD faces into PARENT faces, dropping duplicates."
  (seq-uniq (append (etaf-html--face-list parent)
                    (etaf-html--face-list child))))

(defun etaf-html--tag-face (tag attrs)
  "Return the face specification contributed by TAG with ATTRS."
  (pcase tag
    ((or 'b 'strong) '(etaf-html-strong))
    ((or 'i 'em 'cite 'dfn 'var) '(etaf-html-italic))
    ((or 'u 'ins) '(etaf-html-underline))
    ((or 's 'strike 'del) '(etaf-html-strike-through))
    ('mark '(etaf-html-mark))
    ('small '((:height 0.8)))
    ('big '((:height 1.2)))
    ((or 'code 'kbd 'samp 'tt) '(etaf-html-code))
    ((or 'sub 'sup) '((:height 0.8)))
    ('font (when-let* ((color (alist-get 'color attrs)))
             (list (list :foreground color))))
    (_ nil)))

(defun etaf-html--propertize (string face)
  "Return STRING propertized with FACE, when non-nil."
  (if face
      (propertize string 'face face)
    string))

(defun etaf-html--add-text-properties (string props)
  "Return a copy of STRING with text PROPS added.
Existing properties, including faces, are preserved."
  (let ((result (copy-sequence string)))
    (add-text-properties 0 (length result) props result)
    result))

;;; Target IDs

(defvar etaf-html--pending-target-id nil
  "HTML `id' waiting for the first text of an element.")

(defun etaf-html--attach-pending-target-id (string)
  "Attach `etaf-html--pending-target-id' to STRING, then clear it.
Strings that contain only whitespace do not consume the pending ID.
Return STRING unchanged when no ID is pending."
  (if (and etaf-html--pending-target-id
           (not (string-empty-p (string-trim string))))
      (let ((id (prog1 etaf-html--pending-target-id
                  (setq etaf-html--pending-target-id nil))))
        (etaf-html--add-text-properties string (list 'shr-target-id id)))
    string))

(defconst etaf-html--target-id-marker "\u200b"
  "Zero-width character used to anchor an ID on an empty element.")

(defun etaf-html--add-target-id (result id)
  "Attach `shr-target-id' text property ID to RESULT.
RESULT is a string.  Empty strings receive a zero-width marker, since
an empty string cannot carry text properties."
  (if (not id)
      result
    (if (string-empty-p result)
        (propertize etaf-html--target-id-marker 'shr-target-id id)
      (etaf-html--add-text-properties result (list 'shr-target-id id)))))

;;; Inline rendering

(defun etaf-html--link-keymap (url)
  "Return a keymap that opens URL with `etaf-html-browse-url'."
  (let ((map (make-sparse-keymap))
        (open (lambda () (interactive) (funcall etaf-html-browse-url url))))
    (dolist (key (list (kbd "RET") [mouse-1] [mouse-2]))
      (define-key map key open))
    map))

(defun etaf-html--render-inline-nodes (nodes &optional face)
  "Render NODES as inline text, applying FACE to text nodes."
  (mapconcat (lambda (node) (etaf-html--render-inline node face)) nodes ""))

(defun etaf-html--render-inline-string (nodes &optional face)
  "Render NODES as a single collapsed inline string.
FACE is applied to text nodes."
  (etaf-html--collapse-whitespace
   (etaf-html--render-inline-nodes nodes face)))

(defun etaf-html--render-inline-image (attrs face)
  "Render an `<img>' with ATTRS as inline text, applying FACE."
  (let ((alt (alist-get 'alt attrs))
        (title (alist-get 'title attrs))
        (src (alist-get 'src attrs)))
    (let ((string (etaf-html--propertize
                   (format "[image: %s]" (or alt title src "unknown"))
                   face)))
      (if src
          (etaf-html--add-text-properties
           string (list 'help-echo (or title alt src)
                        'mouse-face 'highlight
                        'shr-url src
                        'keymap (etaf-html--link-keymap src)))
        string))))

(defun etaf-html--render-inline-anchor (attrs children face)
  "Render an `<a>' with ATTRS and CHILDREN as inline text.
Nested text inherits FACE; when a href is present, a link face,
tooltip and activation keymap are added."
  (let* ((href (alist-get 'href attrs))
         (title (alist-get 'title attrs))
         (child-face (if href
                         (etaf-html--merge-faces face '(etaf-html-link))
                       face))
         (text (etaf-html--render-inline-nodes children child-face)))
    (etaf-html--add-target-id
     (if href
         (etaf-html--add-text-properties
          text (list 'help-echo (or title href)
                     'mouse-face 'highlight
                     'shr-url href
                     'keymap (etaf-html--link-keymap href)))
       text)
     (alist-get 'id attrs))))

(defun etaf-html--render-inline-control (tag attrs children face)
  "Render form control TAG with ATTRS and CHILDREN as inline text.
FACE is applied to the resulting placeholder."
  (pcase tag
    ('input
     (let ((type (etaf-html--input-type attrs)))
       (pcase type
         ((or "hidden" "image") "")
         ((or "checkbox" "radio")
          (let ((label (or (alist-get 'aria-label attrs)
                           (alist-get 'name attrs))))
            (etaf-html--propertize
             (concat (if (etaf-html--attr-p attrs 'checked) "☑" "☐")
                     (when label (concat " " label)))
             face)))
         ((or "submit" "button" "reset")
          (etaf-html--propertize
           (format "[%s]" (or (alist-get 'value attrs) "Submit"))
           (etaf-html--merge-faces face '(etaf-html-button))))
         (_
          (let* ((value (alist-get 'value attrs))
                 (placeholder (alist-get 'placeholder attrs))
                 (text (or (and value (not (string-empty-p value)) value)
                           placeholder
                           "----------"))
                 (text-face (if (and placeholder
                                     (or (null value)
                                         (string-empty-p value)))
                                '(etaf-html-placeholder)
                              '(etaf-html-field))))
            (etaf-html--propertize
             text (etaf-html--merge-faces face text-face)))))))
    ('button
     (etaf-html--propertize
      (format "[%s]" (etaf-html--render-inline-string children))
      (etaf-html--merge-faces face '(etaf-html-button))))
    ('select
     (let* ((options (seq-filter (lambda (child)
                                   (eq (car-safe child) 'option))
                                 children))
            (option (or (seq-find
                         (lambda (child)
                           (etaf-html--attr-p (cadr child) 'selected))
                         options)
                        (car options)))
            (label (if option
                       (etaf-html--render-inline-string (cddr option))
                     "")))
       (etaf-html--propertize
        (format "[%s ▾]" label)
        (etaf-html--merge-faces face '(etaf-html-field)))))
    ('textarea
     (etaf-html--propertize
      (etaf-html--raw-text children)
      (etaf-html--merge-faces face '(etaf-html-field))))))

(defun etaf-html--render-inline-media (tag attrs face)
  "Render media element TAG with ATTRS as inline text, applying FACE."
  (let* ((src (or (alist-get 'src attrs)
                  (alist-get 'data attrs)))
         (title (or (alist-get 'title attrs)
                    (alist-get 'alt attrs)
                    src))
         (text (etaf-html--propertize
                (format "[%s%s]" tag (if title (format ": %s" title) ""))
                face)))
    (if src
        (etaf-html--add-text-properties
         text (list 'help-echo title
                    'mouse-face 'highlight
                    'shr-url src
                    'keymap (etaf-html--link-keymap src)))
      text)))

(defun etaf-html--render-inline (node &optional face)
  "Render NODE as propertized inline text, layering FACE beneath markup faces."
  (cond
   ((stringp node)
    (etaf-html--attach-pending-target-id
     (etaf-html--propertize (etaf-html--normalize-text node) face)))
   ((not (consp node)) "")
   (t
    (let* ((tag (car node))
           (attrs (cadr node))
           (children (cddr node))
           (child-face (etaf-html--merge-faces
                        face (etaf-html--tag-face tag attrs))))
      (pcase tag
        ('br "\n")
        ((or 'wbr 'comment) "")
        ((or 'audio 'video 'iframe 'embed 'object)
         (etaf-html--render-inline-media tag attrs child-face))
        ('img (etaf-html--render-inline-image attrs child-face))
        ('a (etaf-html--render-inline-anchor attrs children face))
        ((or 'input 'button 'select 'textarea)
         (etaf-html--render-inline-control tag attrs children child-face))
        ('q (concat "“"
                    (etaf-html--render-inline-nodes children child-face)
                    "”"))
        ((pred (lambda (tag) (memq tag etaf-html--ignored-tags))) "")
        (_
         (let ((result (etaf-html--render-inline-nodes children child-face))
               (title (alist-get 'title attrs)))
           (if (and title (memq tag '(abbr dfn time)))
               (setq result (etaf-html--add-text-properties
                             result (list 'help-echo title))))
           (etaf-html--add-target-id result (alist-get 'id attrs)))))))))

;;; ETAF view helpers

(defun etaf-html--text-view (string &optional props)
  "Return a `text' Host showing STRING with PROPS."
  (etaf-node 'text props (list string)))

(defun etaf-html--paragraph (string &optional props)
  "Return a block containing STRING as one paragraph.
PROPS are added to the surrounding `box'."
  (etaf-node 'box props (list (etaf-html--text-view string))))

(defun etaf-html--block-separator ()
  "Return a blank block with `etaf-html-block-spacing' lines."
  (etaf-node 'box
             (list :height (list 'lh etaf-html-block-spacing))
             nil))

(defun etaf-html--space-blocks (nodes)
  "Return NODES with blank blocks inserted between adjacent elements.
The number of blank lines comes from `etaf-html-block-spacing'."
  (if (or (<= etaf-html-block-spacing 0)
          (< (length nodes) 2))
      nodes
    (let (result)
      (dolist (node nodes)
        (when result
          (push (etaf-html--block-separator) result))
        (push node result))
      (nreverse result))))

(defun etaf-html--compose-block (nodes &optional props)
  "Compose NODES into a single block View.
A single node is returned as-is unless PROPS is non-nil.  Nil
entries are ignored.  Blank lines between NODES are controlled by
`etaf-html-block-spacing'."
  (setq nodes (delq nil nodes))
  (cond
   ((null nodes) nil)
   ((and (null props) (= 1 (length nodes))) (car nodes))
   (t (etaf-node 'column props (etaf-html--space-blocks nodes)))))

(defun etaf-html--flex-content (nodes)
  "Return NODES in a flexible content box suitable for a `row'."
  (etaf-node 'box (list :flex-grow 1
                        :flex-shrink 1
                        :flex-basis '(px 0))
             (list (or (etaf-html--compose-block nodes)
                       (etaf-html--text-view "")))))

;;; Block rendering

(defun etaf-html--inline-node-p (node)
  "Return non-nil when NODE belongs to inline text flow."
  (or (stringp node)
      (and (consp node)
           (memq (car node) etaf-html--inline-or-ignored-tags))))

(defun etaf-html--sole-anchor (children)
  "Return the single non-blank anchor node in CHILDREN, if there is one.
Standalone anchors are rendered as buttons rather than as inline text."
  (let ((nodes (seq-remove (lambda (child)
                             (and (stringp child)
                                  (string-empty-p (string-trim child))))
                           children)))
    (when (and (= 1 (length nodes))
               (eq (car-safe (car nodes)) 'a))
      (car nodes))))

(defun etaf-html--button-view (label &optional url help)
  "Return a button View showing LABEL.
When URL is non-nil, pressing the button opens it with
`etaf-html-browse-url'.  HELP becomes the button's help echo."
  (let ((label (copy-sequence label)))
    ;; Put the button face last so faces from nested markup keep priority.
    (add-face-text-property 0 (length label) 'etaf-html-button t label)
    (when url
      (add-text-properties 0 (length label)
                           (list 'shr-url url)
                           label))
    (etaf-node
     'box
     (append
      (list :role 'button
            :tab-index 0
            :border (or etaf-html-table-border-color "#888888")
            :padding '((lh 0) (px 2))
            :bgcolor "#F0F0F0")
      (when help (list :help-echo help))
      (when url
        (list :on-press (lambda () (funcall etaf-html-browse-url url)))))
     (list (etaf-html--text-view label)))))

(defun etaf-html--translate-anchor (attrs children &optional face)
  "Translate an `<a>' with ATTRS and CHILDREN into a block View.
FACE is the inherited face for its label."
  (let* ((href (alist-get 'href attrs))
         (title (alist-get 'title attrs))
         (label (etaf-html--render-inline-string children face))
         (label (if (string-empty-p label) (or href "link") label)))
    (if href
        (etaf-html--button-view label href (or title href))
      (etaf-html--paragraph label))))

(defun etaf-html--translate-block-children (children &optional face)
  "Translate CHILDREN into a list of block-level Views.
Consecutive inline nodes are merged into one paragraph.  FACE is
inherited by the inline text."
  (if-let* ((anchor (etaf-html--sole-anchor children)))
      (let ((node (etaf-html--translate-anchor (cadr anchor)
                                               (cddr anchor)
                                               face)))
        (when node (list node)))
    (let ((result nil)
          (inline "")
          (break-p nil))
      (cl-labels
          ((flush ()
             (let ((text (etaf-html--collapse-whitespace inline)))
               (cond
                ((not (string-empty-p text))
                 (push (etaf-html--paragraph
                        (etaf-html--justify-text text))
                       result))
                (break-p
                 (push (etaf-html--text-view "\n") result))))
             (setq inline "" break-p nil)))
        (dolist (child children)
          (if (etaf-html--inline-node-p child)
              (progn
                (when (eq (car-safe child) 'br)
                  (setq break-p t))
                (setq inline (concat inline
                                     (etaf-html--render-inline child face))))
            (flush)
            (let ((node (etaf-html--translate-node child face)))
              (when node (push node result)))))
        (flush))
      (nreverse result))))

(defun etaf-html--translate-container (children &optional face)
  "Translate CHILDREN as a block container, inheriting FACE."
  (etaf-html--compose-block
   (etaf-html--translate-block-children children face)))

(defun etaf-html--translate-paragraph (children &optional face)
  "Translate inline CHILDREN into one paragraph, inheriting FACE."
  (let ((text (etaf-html--render-inline-string children face)))
    (unless (string-empty-p text)
      (etaf-html--paragraph (etaf-html--justify-text text)))))

(defun etaf-html--translate-heading (level children &optional face)
  "Translate heading CHILDREN of LEVEL into a paragraph.
FACE is merged with the heading face."
  (let ((heading-face (intern (format "etaf-html-heading-%d" level))))
    (etaf-html--translate-paragraph
     children (etaf-html--merge-faces face (list heading-face)))))

(defun etaf-html--translate-list-item (item marker face)
  "Translate list ITEM with MARKER, inheriting FACE."
  (let* ((marker-text (concat marker " "))
         (etaf-html--available-width
          (and etaf-html--available-width
               (max 1 (- etaf-html--available-width
                         (string-width marker-text)))))
         (content (etaf-html--translate-block-children (cddr item) face)))
    (etaf-node
     'row nil
     (list (etaf-html--text-view
            (etaf-html--propertize marker-text
                                   (etaf-html--merge-faces
                                    face '(etaf-html-muted))))
           (etaf-html--flex-content content)))))

(defun etaf-html--translate-list (children ordered start face)
  "Translate list CHILDREN into a `column' of rows.
ORDERED selects numbered markers; START is the first number.
FACE is inherited by item content."
  (let* ((items (seq-filter (lambda (child) (eq (car-safe child) 'li))
                            children))
         (number (or start 1))
         (rows
          (mapcar
           (lambda (item)
             (let ((marker (if ordered
                               (prog1 (format "%d." number)
                                 (setq number (1+ number)))
                             "•")))
               (etaf-html--translate-list-item item marker face)))
           items)))
    (when rows
      (etaf-node 'column nil rows))))

(defun etaf-html--translate-dl (children face)
  "Translate definition list CHILDREN, inheriting FACE."
  (let (nodes)
    (dolist (child children)
      (pcase (car-safe child)
        ('dt
         (push (etaf-html--paragraph
                (etaf-html--render-inline-string
                 (cddr child)
                 (etaf-html--merge-faces face '(etaf-html-strong))))
               nodes))
        ('dd
         (let ((etaf-html--available-width
                (and etaf-html--available-width
                     (max 1 (- etaf-html--available-width 2))))
               (content (etaf-html--translate-block-children
                         (cddr child)
                         (etaf-html--merge-faces face '(etaf-html-muted)))))
           (push (etaf-node 'row nil
                            (list (etaf-html--text-view "  ")
                                  (etaf-html--flex-content content)))
                 nodes)))))
    (etaf-html--compose-block (nreverse nodes))))

(defun etaf-html--table-rows (children)
  "Collect all `<tr>' nodes from table CHILDREN."
  (seq-mapcat
   (lambda (child)
     (pcase (car-safe child)
       ('tr (list child))
       ((or 'thead 'tbody 'tfoot) (etaf-html--table-rows (cddr child)))
       (_ nil)))
   children))

(defun etaf-html--table-cells (row)
  "Return the `<th>' and `<td>' cells of ROW."
  (seq-filter (lambda (child) (memq (car-safe child) '(th td)))
              (cddr row)))

(defun etaf-html--table-cell-content (cell &optional face)
  "Return table CELL contents as one string, inheriting FACE."
  (let ((children (cddr cell)))
    (if (cl-every #'etaf-html--inline-node-p children)
        (etaf-html--render-inline-string children face)
      (etaf-html--collapse-whitespace
       (etaf-html--raw-text children)))))

(defun etaf-html--translate-table (children &optional face)
  "Translate table CHILDREN into a `grid' View.
FACE is inherited by the table cells."
  (let* ((caption (seq-find (lambda (child) (eq (car-safe child) 'caption))
                            children))
         (rows (seq-filter (lambda (row) (etaf-html--table-cells row))
                           (etaf-html--table-rows children))))
    (if (null rows)
        (etaf-html--compose-block nil)
      (let* ((header-cells (etaf-html--table-cells (car rows)))
             (header-p (and header-cells
                            (cl-every (lambda (cell) (eq (car cell) 'th))
                                      header-cells)))
             (ncols (cl-loop for row in rows
                             maximize (length (etaf-html--table-cells row))))
             (cell-nodes
              (mapcan
               (lambda (row)
                 (let ((cells (etaf-html--table-cells row)))
                   (append
                    (cl-loop for cell in cells
                             collect
                             (etaf-html--text-view
                              (etaf-html--table-cell-content
                               cell
                               (if (and header-p (eq row (car rows)))
                                   (etaf-html--merge-faces
                                    face '(etaf-html-table-header))
                                 face))))
                    ;; Pad short rows so the grid stays rectangular.
                    (cl-loop repeat (- ncols (length cells))
                             collect (etaf-html--text-view "")))))
               rows))
             (grid
              (etaf-node
               'grid
               (append
                (list :grid-template-columns (make-list ncols 'auto)
                      :column-gap '(px 8)
                      :row-gap '(lh 0)
                      ;; A vertical border needs a line of its own;
                      ;; without a border, keep the table compact.
                      :padding (if etaf-html-table-border-color
                                   '((lh 1) (px 4))
                                 '((lh 0) (px 4))))
                (when etaf-html-table-border-color
                  (list :border etaf-html-table-border-color)))
               cell-nodes)))
        (if caption
            (etaf-html--compose-block
             (list (etaf-html--paragraph
                    (etaf-html--render-inline-string
                     (cddr caption)
                     (etaf-html--merge-faces face '(etaf-html-muted))))
                   grid))
          grid)))))

(defun etaf-html--language-from-class (class)
  "Extract a language name from CLASS, e.g. \"language-python\"."
  (when (stringp class)
    (when (string-match
           "\\(?:^\\|\\s-\\)\\(?:language\\|lang\\)-\\([[:alnum:]_+#.-]+\\)"
           class)
      (match-string 1 class))))

(defun etaf-html--pre-language (attrs children)
  "Determine the language of a `<pre>' with ATTRS and CHILDREN."
  (or (etaf-html--language-from-class (alist-get 'class attrs))
      (seq-some
       (lambda (child)
         (when (eq (car-safe child) 'code)
           (let ((code-attrs (cadr child)))
             (or (etaf-html--language-from-class
                  (alist-get 'class code-attrs))
                 (alist-get 'data-lang code-attrs)))))
       children)
      (alist-get 'lang attrs)))

(defun etaf-html--translate-pre (attrs children face)
  "Translate a `<pre>' with ATTRS and CHILDREN, inheriting FACE.
The language is detected and exposed as a help echo."
  (let* ((code (etaf-html--raw-text children))
         ;; Browsers drop a single newline directly after <pre>.
         (code (if (string-prefix-p "\n" code) (substring code 1) code))
         (language (etaf-html--pre-language attrs children))
         (text (etaf-html--propertize
                code
                (etaf-html--merge-faces face '(etaf-html-code))))
         (text (if language
                   (etaf-html--add-text-properties
                    text (list 'help-echo language))
                 text)))
    (when (or (not (string-empty-p code)) language)
      (etaf-node 'box
                 (append
                  (list :padding '((lh 0) (px 4))
                        :wrap-mode 'char)
                  (when etaf-html-pre-background
                    (list :bgcolor etaf-html-pre-background)))
                 (list (etaf-html--text-view text))))))

(defun etaf-html--translate-blockquote (children face)
  "Translate blockquote CHILDREN, inheriting FACE."
  (let ((etaf-html--available-width
         (and etaf-html--available-width
              (max 1 (- etaf-html--available-width 2))))
        (content (etaf-html--translate-block-children
                  children
                  (etaf-html--merge-faces face '(etaf-html-muted)))))
    (etaf-node 'row nil
               (list (etaf-html--text-view
                      (etaf-html--propertize "│ "(list 'etaf-html-muted)))
                     (etaf-html--flex-content content)))))

(defun etaf-html--translate-input (attrs)
  "Translate an `<input>' with ATTRS into a form View."
  (let* ((type (etaf-html--input-type attrs))
         (value (alist-get 'value attrs))
         (placeholder (alist-get 'placeholder attrs))
         (size (or (etaf-html--attr-number attrs 'size) 30)))
    (pcase type
      ((or "hidden" "image") nil)
      ((or "checkbox" "radio")
       (etaf-html--paragraph
        (etaf-html--render-inline-control 'input attrs nil nil)))
      ((or "submit" "reset" "button")
       (etaf-html--button-view (or value "Submit")))
      ("password"
       (etaf-html--field-view (or value "") (min size 32) placeholder))
      (_
       (etaf-html--field-view (or value "") size placeholder)))))

(defun etaf-html--field-view (value size &optional placeholder)
  "Return a form field View showing VALUE.
SIZE sets its minimum character width; PLACEHOLDER is shown when
VALUE is empty."
  (let* ((empty (string-empty-p value))
         (text (if (and empty placeholder) placeholder value))
         (face (if (and empty placeholder)
                   '(etaf-html-placeholder)
                 '(etaf-html-field))))
    (when (string-empty-p text) (setq text "----------" face '(etaf-html-placeholder)))
    (etaf-node 'box
               (list :border (or etaf-html-table-border-color "#888888")
                     :padding '((lh 0) (px 2))
                     :min-width (list 'ch (max 4 size)))
               (list (etaf-html--text-view
                      (etaf-html--propertize text face))))))

(defun etaf-html--translate-select (children &optional face)
  "Translate a `<select>' with CHILDREN, inheriting FACE."
  (let* ((options (seq-filter
                   (lambda (child) (eq (car-safe child) 'option))
                   (seq-mapcat
                    (lambda (child)
                      (if (eq (car-safe child) 'optgroup)
                          (cddr child)
                        (list child)))
                    children)))
         (option (or (seq-find
                      (lambda (child)
                        (etaf-html--attr-p (cadr child) 'selected))
                      options)
                     (car options)))
         (label (if option
                    (etaf-html--render-inline-string (cddr option) face)
                  "")))
    (etaf-html--paragraph
     (etaf-html--propertize (format "[%s ▾]" label)
                            (etaf-html--merge-faces face '(etaf-html-field))))))

(defun etaf-html--translate-textarea (children face)
  "Translate a `<textarea>' with CHILDREN, inheriting FACE."
  (etaf-node 'box
             (list :border (or etaf-html-table-border-color "#888888")
                   :padding '((lh 0) (px 2))
                   :wrap-mode 'char)
             (list (etaf-html--text-view
                    (etaf-html--propertize
                     (etaf-html--raw-text children)
                     (etaf-html--merge-faces face '(etaf-html-field)))))))

(defun etaf-html--translate-details (attrs children face)
  "Translate `<details>' with ATTRS and CHILDREN, inheriting FACE."
  (let* ((summary (seq-find (lambda (child) (eq (car-safe child) 'summary))
                            children))
         (body (seq-remove (lambda (child) (eq (car-safe child) 'summary))
                           children))
         (title (if summary
                    (etaf-html--render-inline-string (cddr summary) face)
                  "Details"))
         (body-view (etaf-html--compose-block
                     (etaf-html--translate-block-children body face))))
    (etaf-node 'etaf-html-details
               (list :title title
                     :body body-view
                     :initially-expanded
                     (etaf-html--attr-p attrs 'open))
               nil)))

(defun etaf-html--translate-media (tag attrs &optional face)
  "Translate media element TAG with ATTRS into a block View.
FACE is inherited by the label."
  (let* ((src (or (alist-get 'src attrs)
                  (alist-get 'data attrs)))
         (title (or (alist-get 'title attrs)
                    (alist-get 'alt attrs)))
         (label (format "[%s%s]" tag
                        (if title (format ": %s" title) ""))))
    (if src
        (etaf-html--button-view label src title)
      (etaf-html--paragraph
       (etaf-html--propertize label
                              (etaf-html--merge-faces face '(etaf-html-muted)))))))

;;; Details component

(etaf-define-component etaf-html-details
    (&key title body initially-expanded)
  "Collapsible body used for an HTML <details> element."
  :bindings
  ((open (etaf-ref (and initially-expanded t))))
  :view
  (column
   (box :role 'button
        :tab-index 0
        :on-press (lambda () (etaf-update-value open (lambda (value) (not value))))
     (text (expr (concat (if (etaf-value open) "▾ " "▸ ")
                         (or title "Details")))))
   (expr (when (etaf-value open) body))))

;;; HTML to ETAF translation

(defun etaf-html--translate-node (node &optional face)
  "Translate block-level parsed HTML NODE to an ETAF View or nil.
FACE is inherited by the node's text."
  (let ((tag (car-safe node)))
    (unless (or (null tag)
                (stringp node)
                (memq tag etaf-html--ignored-tags))
      (etaf-html--translate-element tag (cadr node) (cddr node) face))))

(defun etaf-html--translate-element (tag attrs children &optional face)
  "Translate HTML element with TAG, ATTRS and CHILDREN to an ETAF View.
FACE is the inherited face."
  (let ((etaf-html--pending-target-id
         (or (alist-get 'id attrs) etaf-html--pending-target-id)))
    (etaf-html--translate-element-1 tag attrs children face)))

(defun etaf-html--translate-element-1 (tag attrs children face)
  "Translate HTML element TAG with ATTRS and CHILDREN, inheriting FACE."
  (cond
   ;; Document structure and generic block containers
   ((memq tag '(html body top div section article main header footer nav
                     aside address figure center hgroup search
                     form fieldset dialog))
    (etaf-html--translate-container children face))

   ;; Paragraphs and headings
   ((eq tag 'p)
    (etaf-html--translate-paragraph children face))
   ((memq tag '(h1 h2 h3 h4 h5 h6 h7 h8))
    (let ((level (string-to-number (substring (symbol-name tag) 1))))
      (etaf-html--translate-heading level children face)))

   ;; Line and block separators
   ((eq tag 'hr)
    (etaf-html--paragraph
     (etaf-html--propertize
      (make-string (etaf-html--effective-width) ?─)
      (etaf-html--merge-faces face '(etaf-html-muted)))))

   ;; Quoted and preformatted blocks
   ((eq tag 'blockquote)
    (etaf-html--translate-blockquote children face))
   ((eq tag 'pre)
    (etaf-html--translate-pre attrs children face))

   ;; Lists
   ((memq tag '(ul menu))
    (etaf-html--translate-list children nil nil face))
   ((eq tag 'ol)
    (etaf-html--translate-list
     children t (etaf-html--attr-number attrs 'start) face))
   ((eq tag 'li)
    (etaf-html--compose-block
     (etaf-html--translate-block-children children face)))
   ((eq tag 'dl)
    (etaf-html--translate-dl children face))
   ((eq tag 'dt)
    (etaf-html--paragraph
     (etaf-html--render-inline-string
      children (etaf-html--merge-faces face '(etaf-html-strong)))))
   ((eq tag 'dd)
    (let ((content (etaf-html--translate-block-children
                    children
                    (etaf-html--merge-faces face '(etaf-html-muted)))))
      (etaf-node 'row nil
                 (list (etaf-html--text-view "  ")
                       (etaf-html--flex-content content)))))

   ;; Tables
   ((eq tag 'table)
    (etaf-html--translate-table children face))
   ((memq tag '(thead tbody tfoot tr th td))
    (etaf-html--translate-container children face))
   ((eq tag 'caption)
    (etaf-html--paragraph
     (etaf-html--render-inline-string
      children (etaf-html--merge-faces face '(etaf-html-muted)))))

   ;; Links and media
   ((eq tag 'a)
    (etaf-html--translate-anchor attrs children face))
   ((eq tag 'img)
    (let* ((src (alist-get 'src attrs))
           (alt (or (alist-get 'alt attrs)
                    (alist-get 'title attrs)))
           (label (format "[image: %s]" (or alt src "unknown"))))
      (if src
          (etaf-html--button-view label src alt)
        (etaf-html--paragraph
         (etaf-html--propertize
          label (etaf-html--merge-faces face '(etaf-html-muted)))))))
   ((memq tag '(audio video iframe embed object))
    (etaf-html--translate-media tag attrs face))

   ;; Forms
   ((eq tag 'legend)
    (etaf-html--paragraph
     (etaf-html--render-inline-string
      children (etaf-html--merge-faces face '(etaf-html-strong)))))
   ((eq tag 'input)
    (etaf-html--translate-input attrs))
   ((eq tag 'textarea)
    (etaf-html--translate-textarea children face))
   ((eq tag 'select)
    (etaf-html--translate-select children face))
   ((eq tag 'button)
    (etaf-html--button-view
     (etaf-html--render-inline-string children face)))
   ((eq tag 'output)
    (etaf-html--translate-paragraph children face))
   ((memq tag '(progress meter))
    (etaf-html--paragraph
     (format "%s %s" tag (or (alist-get 'value attrs) ""))))

   ;; Disclosure and captions
   ((eq tag 'details)
    (etaf-html--translate-details attrs children face))
   ((eq tag 'summary)
    (etaf-html--paragraph
     (etaf-html--render-inline-string
      children (etaf-html--merge-faces face '(etaf-html-strong)))))
   ((eq tag 'figcaption)
    (etaf-html--paragraph
     (etaf-html--render-inline-string
      children (etaf-html--merge-faces face '(etaf-html-muted)))))

   ;; Unknown elements - treat as a block container
   (t (etaf-html--translate-container children face))))

;;; Main API

(defun etaf-html (html)
  "Parse HTML string and return an ETAF View.
HTML is a string of HTML markup.  The returned View is suitable for
`etaf-mount'."
  (let* ((etaf-html--available-width etaf-html-max-width)
         (node (etaf-html--translate-node
                (etaf-html--parse-html html))))
    (etaf-node 'column
               (append
                (list :wrap-mode 'word)
                (when (and etaf-html-max-width
                           (> etaf-html-max-width 0))
                  (list :width (list 'ch etaf-html-max-width))))
               (list (or node (etaf-node 'column nil nil))))))

(defun etaf-html--font-attributes (font)
  "Return FONT as a plist of face attributes.
FONT is a font family name, a font spec or font object, or a plist
of face attributes.  In the plist, `:size' is accepted in points and
converted to the absolute `:height' that faces use."
  (cond
   ((null font) nil)
   ((stringp font) (list :family font))
   ((fontp font) (list :font font))
   ((listp font)
    (cl-loop for (key value) on font by #'cddr
             append (if (eq key :size)
                        (list :height (round (* value 10)))
                      (list key value))))
   (t (error "Invalid font specification: %S" font))))

(defmacro etaf-html-with-default-font (font &rest body)
  "Execute BODY with the `default' face's font set to FONT.
FONT is a font family name (a string), a font spec, or a plist of
face attributes accepted by `set-face-attribute', for example
\(:family \"Noto Serif CJK SC\" :height 140).  `:size' is accepted
in the plist as a point size and converted to `:height'.

The original attributes are restored when BODY finishes or signals.
`after-setting-font-hook' is run on both changes, so glyph-metric
caches (ETAF, Ebox, ...) are invalidated and text is laid out with the
font that is actually in effect."
  (declare (indent 1) (debug (form body)))
  (let ((attrs (make-symbol "attrs"))
        (saved (make-symbol "saved")))
    `(let* ((,attrs (etaf-html--font-attributes ,font))
            (,saved
             (cl-loop for (key _value) on ,attrs by #'cddr
                      collect (cons key (face-attribute 'default key)))))
       (unwind-protect
           (progn
             (apply #'set-face-attribute 'default nil ,attrs)
             (run-hooks 'after-setting-font-hook)
             ,@body)
         (dolist (entry ,saved)
           (set-face-attribute 'default nil (car entry) (cdr entry)))
         (run-hooks 'after-setting-font-hook)))))

(defvar-local etaf-html--font-remap nil
  "Cookie for this buffer's `etaf-html-font' face remapping.")

(defun etaf-html--set-buffer-font (buffer font)
  "Display BUFFER's text with FONT.
FONT has the same forms as `etaf-html-font'.  It is installed as a
buffer-local remapping of the `default' face rather than as a `face'
text property, so the font survives ETAF re-renders.  A nil FONT
removes a previous remapping."
  (with-current-buffer buffer
    (when etaf-html--font-remap
      (face-remap-remove-relative etaf-html--font-remap)
      (setq etaf-html--font-remap nil))
    (when font
      (setq etaf-html--font-remap
            (face-remap-add-relative
             'default (etaf-html--font-attributes font))))))

;;;###autoload
(defun etaf-html-mount (&optional html)
  "Render HTML string in `etaf-html-buffer-name' and return the buffer.
When HTML is nil, use the contents of the current buffer.
When `etaf-html-font' is non-nil, use it for measuring and displaying
the rendered text.  `etaf-html-mount-options' is passed to `etaf-mount'."
  (interactive)
  (unless html
    (setq html (buffer-string)))
  (let* ((buffer (get-buffer-create etaf-html-buffer-name))
         (mount (lambda ()
                  (etaf-mount
                   buffer
                   (with-current-buffer buffer (etaf-html html))
                   etaf-html-mount-options))))
    (etaf-html--set-buffer-font buffer etaf-html-font)
    (if etaf-html-font
        (etaf-html-with-default-font etaf-html-font (funcall mount))
      (funcall mount))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(provide 'etaf-html)
;;; etaf-html.el ends here
