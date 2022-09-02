EMACS ?= emacs
BATCH := $(EMACS) $(EFLAGS) -batch -q -no-site-file -L .

all: disaster.elc

README.md: make-readme-markdown.el
	emacs --script $< <disaster.el >$@ 2>/dev/null
make-readme-markdown.el:
	curl -s -o $@ https://raw.githubusercontent.com/mgalgs/make-readme-markdown/master/make-readme-markdown.el
.INTERMEDIATE: make-readme-markdown.el

clean:
	$(RM) *.elc

%.elc: %.el
	$(BATCH) --eval '(byte-compile-file "$<")'

.PHONY: clean README.md
