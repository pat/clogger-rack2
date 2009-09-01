all:: test
ruby = ruby

-include local.mk

ifeq ($(DLEXT),) # "so" for Linux
  DLEXT := $(shell $(ruby) -rrbconfig -e 'puts Config::CONFIG["DLEXT"]')
endif

ifeq ($(RUBY_VERSION),)
  RUBY_VERSION := $(shell $(ruby) -e 'puts RUBY_VERSION')
endif

ext/clogger_ext/Makefile: ext/clogger_ext/clogger.c ext/clogger_ext/extconf.rb
	cd ext/clogger_ext && $(ruby) extconf.rb

ext/clogger_ext/clogger.$(DLEXT): ext/clogger_ext/Makefile
	$(MAKE) -C ext/clogger_ext

clean:
	-$(MAKE) -C ext/clogger_ext clean
	$(RM) ext/clogger_ext/Makefile lib/clogger_ext.$(DLEXT)

test-ext: ext/clogger_ext/clogger.$(DLEXT)
	$(ruby) -Iext/clogger_ext:lib test/test_clogger.rb

test-pure:
	$(ruby) -Ilib test/test_clogger.rb

test: test-ext test-pure

Manifest.txt:
	git ls-files > $@+
	cmp $@+ $@ || mv $@+ $@
	$(RM) $@+

VERSION := $(shell git describe 2>/dev/null | sed 's/^v//')

ifneq ($(VERSION),)
v := /^v$(VERSION)$$/
vPREV := $(shell git tag -l 2>/dev/null | sed -n -e '$(v)!h' -e '$(v){x;p;q}')
release_notes := release_notes-$(VERSION).txt
release_changes := release_changes-$(VERSION).txt
$(release_changes): verify
	git diff --stat $(vPREV) v$(VERSION) > $@+
	echo >> $@+
	git log $(vPREV)..v$(VERSION) >> $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@
$(release_notes): verify package
	gem spec pkg/clogger-$(VERSION).gem description | sed -ne '/\w/p' > $@+
	echo >> $@+
	git cat-file tag v$(VERSION) | awk 'p>1{print $$0}/^$$/{++p}' >> $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@
verify:
	@test -n "$(VERSION)" || { echo >&2 VERSION= not defined; exit 1; }
	git rev-parse --verify refs/tags/v$(VERSION)^{}
	@test -n "$(VISUAL)" || { echo >&2 VISUAL= not defined; exit 1; }

package: verify
	git diff-index --quiet HEAD^0
	test `git rev-parse --verify HEAD^0` = \
	     `git rev-parse --verify refs/tags/v$(VERSION)^{}`
	$(RM) -r pkg
	unset CLOGGER_EXT; rake package VERSION=$(VERSION)
	CLOGGER_EXT=1 rake package VERSION=$(VERSION)

# not using Hoe's release system since we release 2 gems but only one tgz
release: package Manifest.txt $(release_notes) $(release_changes)
	rubyforge add_release -f -n $(release_notes) -a $(release_changes) \
	  clogger clogger $(VERSION) pkg/clogger-$(VERSION).gem
	rubyforge add_file \
	  clogger clogger $(VERSION) pkg/clogger-$(VERSION).tgz
	rubyforge add_release -f -n $(release_notes) -a $(release_changes) \
	  clogger clogger_ext $(VERSION) pkg/clogger_ext-$(VERSION).gem
	rake post_news
endif

.PHONY: test doc Manifest.txt release
