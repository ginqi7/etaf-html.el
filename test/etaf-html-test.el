;;; etaf-html-test.el --- Tests for etaf-html  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Qiqi Jin

;; Author: Qiqi Jin <ginqi7@gmail.com>
;; Keywords:

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

;; Tests for the HTML to ETAF translation.  Most tests render into a
;; temporary buffer and inspect the text (and its properties) written by
;; ETAF, so that they check what the user actually sees.

;;; Code:

(require 'buttercup)
(require 'etaf-html)

(defun etaf-html-test--trim-lines (string)
  "Remove trailing whitespace from every line of STRING.
ETAF pads the last line of a block, so rendered text is compared
without that padding."
  (mapconcat (lambda (line)
               (replace-regexp-in-string "[ \t]+\\'" "" line))
             (split-string string "\n") "\n"))

(defun etaf-html-test--render (html)
  "Render HTML into a buffer and return its text without properties."
  (let ((etaf-html-use-ekp nil))
    (with-current-buffer (etaf-html-mount html)
      (etaf-html-test--trim-lines
       (substring-no-properties (buffer-string))))))

(defun etaf-html-test--inline (html)
  "Render HTML as inline text and return it with its text properties."
  (let ((etaf-html-use-ekp nil))
    (etaf-html--render-inline-string
     (cddr (etaf-html--parse-html html)))))

(defmacro etaf-html-test--with-rendered (html &rest body)
  "Render HTML and evaluate BODY in the rendered buffer."
  (declare (indent 1) (debug t))
  `(let ((etaf-html-use-ekp nil))
     (with-current-buffer (etaf-html-mount ,html)
       ,@body)))

(describe "etaf-html"
  (it "loads successfully"
    (expect (featurep 'etaf-html) :to-be-truthy))

  (it "renders a paragraph"
    (expect (etaf-html-test--render "<p>hello</p>") :to-equal "hello"))

  (it "renders several paragraphs on separate lines"
    (expect (etaf-html-test--render "<p>hello</p><p>world</p>")
            :to-equal "hello\nworld"))

  (it "renders HTML read from the current buffer"
    (with-temp-buffer
      (insert "<p>from buffer</p>")
      (expect (with-current-buffer (etaf-html-mount)
                (etaf-html-test--trim-lines
                 (substring-no-properties (buffer-string))))
              :to-equal "from buffer"))))

;;; Inline formatting

(describe "etaf-html inline formatting"
  (it "renders <em> and <i> with the italic face"
    (dolist (tag '("em" "i"))
      (let ((text (etaf-html-test--inline (format "<%s>x</%s>" tag tag))))
        (expect (substring-no-properties text) :to-equal "x")
        (expect (get-text-property 0 'face text)
                :to-equal '(etaf-html-italic)))))

  (it "renders <u> and <ins> with an underline face"
    (dolist (tag '("u" "ins"))
      (expect (get-text-property
               0 'face (etaf-html-test--inline (format "<%s>x</%s>" tag tag)))
              :to-equal '(etaf-html-underline))))

  (it "renders <s>, <strike> and <del> with a strike-through face"
    (dolist (tag '("s" "strike" "del"))
      (expect (get-text-property
               0 'face (etaf-html-test--inline (format "<%s>x</%s>" tag tag)))
              :to-equal '(etaf-html-strike-through))))

  (it "renders <mark>, <small> and <big>"
    (expect (get-text-property 0 'face (etaf-html-test--inline "<mark>x</mark>"))
            :to-equal '(etaf-html-mark))
    (expect (get-text-property 0 'face (etaf-html-test--inline "<small>x</small>"))
            :to-equal '((:height 0.8)))
    (expect (get-text-property 0 'face (etaf-html-test--inline "<big>x</big>"))
            :to-equal '((:height 1.2))))

  (it "renders <code>, <kbd>, <samp> and <tt> with the code face"
    (dolist (tag '("code" "kbd" "samp" "tt"))
      (expect (get-text-property
               0 'face (etaf-html-test--inline (format "<%s>x</%s>" tag tag)))
              :to-equal '(etaf-html-code))))

  (it "composes nested faces"
    (let ((text (etaf-html-test--inline "<b>bold <i>both</i></b>")))
      (expect (substring-no-properties text) :to-equal "bold both")
      (expect (get-text-property 0 'face text) :to-equal '(etaf-html-strong))
      (expect (get-text-property 5 'face text)
              :to-equal '(etaf-html-strong etaf-html-italic))))

  (it "renders <q> with quotation marks"
    (expect (substring-no-properties
             (etaf-html-test--inline "<q>quoted</q>"))
            :to-equal "“quoted”"))

  (it "adds a tooltip from the <abbr> title attribute"
    (let ((text (etaf-html-test--inline
                 "<abbr title=\"HyperText Markup Language\">HTML</abbr>")))
      (expect (substring-no-properties text) :to-equal "HTML")
      (expect (get-text-property 0 'help-echo text)
              :to-equal "HyperText Markup Language")))

  (it "renders <sub> and <sup> as smaller text"
    (dolist (tag '("sub" "sup"))
      (let ((text (etaf-html-test--inline
                   (format "H<%s>2</%s>O" tag tag))))
        (expect (substring-no-properties text) :to-equal "H2O")
        (expect (get-text-property 1 'face text) :to-equal '((:height 0.8))))))

  (it "collapses whitespace without dropping inline markup"
    (let ((text (etaf-html-test--inline "a<b> b </b>c   d")))
      (expect (substring-no-properties text) :to-equal "a b c d")
      (expect (get-text-property 2 'face text) :to-equal '(etaf-html-strong))))

  (it "turns <br> into a newline"
    (expect (substring-no-properties (etaf-html-test--inline "a<br>b"))
            :to-equal "a\nb"))

  (it "decodes HTML entities"
    (expect (substring-no-properties
             (etaf-html-test--inline "&amp; &lt; &gt; &#65;"))
            :to-equal "& < > A")))

;;; Headings

(describe "etaf-html headings"
  (it "renders h1 through h6 with the matching heading face"
    (dolist (level (number-sequence 1 6))
      (etaf-html-test--with-rendered
          (format "<h%d>Head</h%d>" level level)
        (let ((text (buffer-string)))
          (expect (substring-no-properties text) :to-equal "Head ")
          (expect (get-text-property 0 'face text)
                  :to-equal
                  (list (intern (format "etaf-html-heading-%d" level))))))))

  (it "keeps inline formatting inside a heading"
    (etaf-html-test--with-rendered "<h2>A <code>b</code></h2>"
      (let ((text (buffer-string)))
        (expect (substring-no-properties text) :to-equal "A b ")
        (expect (get-text-property 2 'face text)
                 :to-equal '(etaf-html-heading-2 etaf-html-code))))))

;;; Block containers

(describe "etaf-html block containers"
  (it "treats <section>, <article>, <main> and friends as containers"
    (dolist (tag '("section" "article" "main" "header" "footer" "nav" "aside"))
      (expect (etaf-html-test--render
               (format "<%s><p>a</p><p>b</p></%s>" tag tag))
              :to-equal "a\nb")))

  (it "treats unknown tags as containers"
    (expect (etaf-html-test--render "<unknown>hello</unknown>")
            :to-equal "hello"))

  (it "ignores comments and <script>/<style> content"
    (expect (etaf-html-test--render "<!-- a comment --><p>hello</p>")
            :to-equal "hello")
    (expect (etaf-html-test--render
             "<script>bad()</script><style>.a{}</style><p>ok</p>")
            :to-equal "ok"))

  (it "ignores document metadata"
    (expect (etaf-html-test--render
             "<head><title>T</title><meta charset=\"utf-8\"></head><p>x</p>")
            :to-equal "x"))

  (it "renders a complete document"
    (expect (etaf-html-test--render
             "<!doctype html><html><head><title>T</title></head><body><h1>Hi</h1><p>Body</p></body></html>")
            :to-equal "Hi\nBody"))

  (it "wraps text inside a generic container to `etaf-html-max-width'"
    (let* ((etaf-html-max-width 20)
           (text (mapconcat (lambda (_) "this is a long english sentence")
                            (number-sequence 1 10) " "))
           (lines (split-string
                   (etaf-html-test--render (format "<div><span>%s</span></div>" text))
                   "\n")))
      (expect (> (length lines) 1) :to-be-truthy)
      (dolist (line lines)
        (expect (<= (length line) etaf-html-max-width) :to-be-truthy))))

  (it "keeps the source anchor of an element with an id"
    (etaf-html-test--with-rendered "<p id=\"anchor\">hello</p>"
      (expect (get-text-property (point-min) 'shr-target-id)
              :to-equal "anchor"))))

;;; Lists

(describe "etaf-html lists"
  (it "renders an unordered list"
    (expect (etaf-html-test--render "<ul><li>one</li><li>two</li></ul>")
            :to-equal "• one\n• two"))

  (it "renders an ordered list"
    (expect (etaf-html-test--render "<ol><li>a</li><li>b</li></ol>")
            :to-equal "1. a\n2. b"))

  (it "honours the start attribute of an ordered list"
    (expect (etaf-html-test--render "<ol start=\"3\"><li>a</li><li>b</li></ol>")
            :to-equal "3. a\n4. b"))

  (it "indents nested lists"
    (expect (etaf-html-test--render
             "<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>")
            :to-equal "• one\n• two\n • nested"))

  (it "renders a definition list"
    (expect (etaf-html-test--render "<dl><dt>Term</dt><dd>Definition</dd></dl>")
            :to-equal "Term\n  Definition"))

  (it "renders inline formatting inside a list item"
    (expect (get-text-property
             2 'face (etaf-html-test--inline "<ul><li>a <b>b</b></li></ul>"))
            :to-equal '(etaf-html-strong))))

;;; Tables

(describe "etaf-html tables"
  (it "renders the cells of a table"
    (let ((rendered (etaf-html-test--render
                     "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>")))
      (dolist (cell '("A" "B" "1" "2"))
        (expect (string-match-p (regexp-quote cell) rendered) :to-be-truthy))))

  (it "renders header cells with the table header face"
    (etaf-html-test--with-rendered
        "<table><tr><th>A</th></tr><tr><td>1</td></tr></table>"
      (let* ((text (buffer-string))
             (position (string-match "A" text)))
        (expect (memq 'etaf-html-table-header
                      (etaf-html--face-list
                       (get-text-property position 'face text)))
                :to-be-truthy))))

  (it "supports thead/tbody and caption"
    (let ((rendered (etaf-html-test--render
                     "<table><caption>Cap</caption><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>")))
      (expect (string-match-p "^Cap$" rendered) :to-be-truthy)
      (expect (string-match-p "A" rendered) :to-be-truthy)
      (expect (string-match-p "1" rendered) :to-be-truthy)))

  (it "keeps inline formatting in table cells"
    (etaf-html-test--with-rendered "<table><tr><td><b>x</b></td></tr></table>"
      (let* ((text (buffer-string))
             (position (string-match "x" text)))
        (expect (memq 'etaf-html-strong
                      (etaf-html--face-list
                       (get-text-property position 'face text)))
                :to-be-truthy)))))

;;; Preformatted text

(describe "etaf-html preformatted text"
  (it "renders <pre> content"
    (expect (string-trim (etaf-html-test--render "<pre>code here</pre>"))
            :to-equal "code here"))

  (it "drops the first newline after <pre>"
    (expect (mapconcat #'string-trim
                       (split-string
                        (etaf-html-test--render "<pre>\nline1\nline2</pre>")
                        "\n")
                       "\n")
            :to-equal "line1\nline2"))

  (it "detects the language from a code element class"
    (expect (etaf-html--pre-language
             nil '((code ((class . "language-python")) "print(1)")))
            :to-equal "python"))

  (it "detects the language from the pre class"
    (expect (etaf-html--pre-language
             '((class . "lang-rust")) '("fn main() {}"))
            :to-equal "rust"))

  (it "renders a highlighted code block"
    (expect (string-trim
             (etaf-html-test--render
              "<pre><code class=\"language-emacs-lisp\">(+ 1 2)</code></pre>"))
            :to-equal "(+ 1 2)")))

;;; Quotes

(describe "etaf-html blockquote"
  (it "marks and mutes quoted content"
    (expect (etaf-html-test--render "<blockquote>quoted <b>text</b></blockquote>")
            :to-equal "│ quoted text")))

;;; Links and media

(describe "etaf-html links"
  (it "renders inline links as propertized text"
    (let* ((text (etaf-html-test--inline
                  "visit <a href=\"http://x.com\" title=\"X\">X</a> now"))
           (position (string-match "X" text)))
      (expect (substring-no-properties text) :to-equal "visit X now")
      (expect (get-text-property position 'face text) :to-equal '(etaf-html-link))
      (expect (get-text-property position 'help-echo text) :to-equal "X")
      (expect (get-text-property position 'keymap text) :to-be-truthy)))

  (it "renders an anchor without href as plain text"
    (expect (substring-no-properties (etaf-html-test--inline "a <a>plain</a> b"))
            :to-equal "a plain b"))

  (it "renders a standalone anchor as a button"
    (expect (etaf-html-test--render "<a href=\"http://qiqijin.com\">Qiqi</a>")
            :to-equal "│ Qiqi  │")))

(describe "etaf-html media"
  (it "renders an image with its alt text"
    (expect (etaf-html-test--render "<img src=\"a.png\" alt=\"A\">")
            :to-equal "│ [image: A]  │"))

  (it "renders an image inline inside a paragraph"
    (expect (etaf-html-test--render
             "<p>hello <img src=\"a.png\" alt=\"A\"> world</p>")
            :to-equal "hello [image: A] world"))

  (it "renders an image without src as text"
    (expect (etaf-html-test--render "<img alt=\"A\">")
            :to-equal "[image: A]"))

  (it "renders media elements as labelled buttons"
    (expect (etaf-html-test--render "<iframe src=\"http://x\" title=\"Frame\"></iframe>")
            :to-equal "│ [iframe: Frame]  │")))

;;; Forms

(describe "etaf-html form elements"
  (it "renders a text input with its value"
    (expect (etaf-html-test--render "<input type=\"text\" value=\"v\">")
            :to-equal "│ v  │"))

  (it "shows the placeholder of an empty input"
    (etaf-html-test--with-rendered
        "<input type=\"text\" placeholder=\"p\">"
      (let* ((text (buffer-string))
             (position (string-match "p" text)))
        (expect (memq 'etaf-html-placeholder
                      (etaf-html--face-list
                       (get-text-property position 'face text)))
                :to-be-truthy))))

  (it "renders a checked checkbox"
    (expect (etaf-html-test--render "<input type=\"checkbox\" checked name=\"n\">")
            :to-equal "☑ n"))

  (it "renders a submit input as a button"
    (expect (etaf-html-test--render "<input type=\"submit\" value=\"Send\">")
            :to-equal "│ Send  │"))

  (it "renders a hidden input as nothing"
    (expect (etaf-html-test--render "<input type=\"hidden\" value=\"x\">")
            :to-equal ""))

  (it "renders a textarea as a field"
    (expect (etaf-html-test--render "<textarea>hello</textarea>")
            :to-equal "│ hello  │"))

  (it "renders a select with its selected option"
    (expect (etaf-html-test--render
             "<select><option value=\"a\">A</option><option value=\"b\" selected>B</option></select>")
            :to-equal "[B ▾]"))

  (it "renders a button with its label"
    (expect (etaf-html-test--render "<button>Go</button>")
            :to-equal "│ Go  │"))

  (it "renders progress and meter values"
    (expect (etaf-html-test--render "<progress value=\"0.5\"></progress>")
            :to-equal "progress 0.5")))

;;; Disclosure

(describe "etaf-html details"
  (it "renders <details> as a collapsible section"
    (expect (etaf-html-test--render
             "<details><summary>More</summary><p>hidden</p></details>")
            :to-equal "▸ More"))

  (it "starts expanded when the open attribute is present"
    (expect (etaf-html-test--render
             "<details open><summary>More</summary><p>shown</p></details>")
            :to-equal "▾ More\nshown")))

;;; Miscellaneous blocks

(describe "etaf-html block elements"
  (it "renders <hr> as a rule"
    (expect (etaf-html-test--render "<hr>")
            :to-equal (make-string etaf-html-max-width ?─)))

  (it "renders <figure> with a caption"
    (expect (etaf-html-test--render
             "<figure><img src=\"a.png\" alt=\"A\"><figcaption>cap</figcaption></figure>")
            :to-equal "│ [image: A]  │\ncap"))

  (it "renders <dialog> as a container"
    (expect (etaf-html-test--render "<dialog><p>hello</p></dialog>")
            :to-equal "hello")))

;;; Mounting

(describe "etaf-html-mount"
  (it "renders into `etaf-html-buffer-name'"
    (unwind-protect
        (progn
          (etaf-html-mount "<p>mounted</p>")
          (with-current-buffer etaf-html-buffer-name
            (expect (etaf-html-test--trim-lines
                     (substring-no-properties (buffer-string)))
                    :to-equal "mounted")))
      (when (get-buffer etaf-html-buffer-name)
        (kill-buffer etaf-html-buffer-name))))

  (it "applies `etaf-html-font' to the rendered page"
    (let ((etaf-html-font "TestFont"))
      (unwind-protect
          (progn
            (etaf-html-mount "<p>mounted <code>code</code></p>")
            (with-current-buffer etaf-html-buffer-name
              (expect (assq 'default face-remapping-alist)
                      :to-equal '(default (:family "TestFont") default))))
        (when (get-buffer etaf-html-buffer-name)
          (kill-buffer etaf-html-buffer-name)))))

  (it "applies family and size from an `etaf-html-font' plist"
    (let ((etaf-html-font '(:family "TestFont" :size 16)))
      (unwind-protect
          (progn
            (etaf-html-mount "<p>mounted</p>")
            (with-current-buffer etaf-html-buffer-name
              (expect (assq 'default face-remapping-alist)
                      :to-equal
                      '(default (:family "TestFont" :height 160) default))))
        (when (get-buffer etaf-html-buffer-name)
          (kill-buffer etaf-html-buffer-name))))))

;;; With-default-font

(describe "etaf-html-with-default-font"
  (it "sets the default face family for the dynamic extent of BODY"
    (let (inside)
      (etaf-html-with-default-font "TestFont"
        (setq inside (face-attribute 'default :family)))
      (expect inside :to-equal "TestFont")
      (expect (face-attribute 'default :family) :not :to-equal "TestFont")))

  (it "restores the default face when BODY signals"
    (let ((original (face-attribute 'default :family)))
      (ignore-errors
        (etaf-html-with-default-font "TestFont"
          (error "boom")))
      (expect (face-attribute 'default :family) :to-equal original)))

  (it "accepts a plist of face attributes"
    (etaf-html-with-default-font '(:family "TestFont" :weight bold)
      (expect (face-attribute 'default :family) :to-equal "TestFont")
      (expect (face-attribute 'default :weight) :to-equal 'bold)))

  (it "converts :size to an absolute :height"
    (etaf-html-with-default-font '(:family "TestFont" :size 16)
      (expect (face-attribute 'default :height) :to-equal 160))))

(describe "etaf-html--font-attributes"
  (it "accepts a family name"
    (expect (etaf-html--font-attributes "TestFont")
            :to-equal '(:family "TestFont")))

  (it "converts :size in a plist to :height"
    (expect (etaf-html--font-attributes '(:family "TestFont" :size 12.5 :weight bold))
            :to-equal '(:family "TestFont" :height 125 :weight bold)))

  (it "keeps an absolute or relative :height as is"
    (expect (etaf-html--font-attributes '(:height 1.2))
            :to-equal '(:height 1.2))))

(provide 'etaf-html-test)
;;; etaf-html-test.el ends here
