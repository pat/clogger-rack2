all:: test
ruby = ruby
rake = rake

-include local.mk

ifeq ($(DLEXT),) # "so" for Linux
  DLEXT := $(shell $(ruby) -rrbconfig -e 'puts Config::CONFIG["DLEXT"]')
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
	CLOGGER_PURE=t $(ruby) -Ilib test/test_clogger.rb

test: test-ext test-pure

History:
	$(rake) -s history > $@+
	mv $@+ $@

.manifest: History
	(git ls-files; for i in $^ $@; do echo $$i; done) | LC_ALL=C sort > $@+
	mv $@+ $@

VERSION := $(shell git describe 2>/dev/null | sed 's/^v//')

ifneq ($(VERSION),)
v := /^v$(VERSION)$$/
vPREV := $(shell git tag -l 2>/dev/null | sed -n -e '$(v)!h' -e '$(v){x;p;q}')
release_notes := release_notes-$(VERSION)
release_changes := release_changes-$(VERSION)
release-notes: $(release_notes)
release-changes: $(release_changes)
$(release_changes): verify
	git diff --stat $(vPREV) v$(VERSION) > $@+
	echo >> $@+
	git log $(vPREV)..v$(VERSION) >> $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@
$(release_notes): pkggem = pkg/clogger-$(VERSION).gem
$(release_notes): verify package
	gem spec $(pkggem) description | sed -ne '/\w/p' > $@+
	echo >> $@+
	gem spec $(pkggem) homepage | sed -ne 's/^--- /* /p' >> $@+
	gem spec $(pkggem) email | sed -ne 's/^--- /* /p' >> $@+
	echo '* git://git.bogomips.org/clogger.git' >> $@+
	echo >> $@+
	echo Changes: >> $@+
	echo >> $@+
	git cat-file tag v$(VERSION) | awk 'p>1{print $$0}/^$$/{++p}' >> $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@
verify:
	@test -n "$(VERSION)" || { echo >&2 VERSION= not defined; exit 1; }
	git rev-parse --verify refs/tags/v$(VERSION)^{}
	@test -n "$(VISUAL)" || { echo >&2 VISUAL= not defined; exit 1; }
	git diff-index --quiet HEAD^0
	test `git rev-parse --verify HEAD^0` = \
	     `git rev-parse --verify refs/tags/v$(VERSION)^{}`

pkg/clogger-$(VERSION).gem: .manifest History clogger.gemspec
	gem build clogger.gemspec
	mkdir -p pkg
	mv $(@F) $@

pkg/clogger-$(VERSION).tgz: HEAD = v$(VERSION)
pkg/clogger-$(VERSION).tgz: .manifest History
	$(RM) -r $(basename $@)
	git archive --format=tar --prefix=$(basename $@)/ $(HEAD) | tar xv
	install -m644 $^ $(basename $@)
	cd pkg && tar cv $(basename $(@F)) | gzip -9 > $(@F)+
	mv $@+ $@

package: pkg/clogger-$(VERSION).gem pkg/clogger-$(VERSION).tgz

# not using Hoe's release system since we release 2 gems but only one tgz
release: package $(release_notes) $(release_changes)
	rubyforge add_release -f -n $(release_notes) -a $(release_changes) \
	  clogger clogger $(VERSION) pkg/clogger-$(VERSION).gem
	rubyforge add_file \
	  clogger clogger $(VERSION) pkg/clogger-$(VERSION).tgz
endif

doc: .document History
	rdoc -Na -t "$(shell sed -ne '1s/^= //p' README)"
	install -m644 COPYING doc/COPYING
	cd doc && ln README.html tmp.html && mv tmp.html index.html

# publishes docs to http://clogger.rubyforge.org/
# this preserves timestamps as best as possible to help HTTP caches out
# git set-file-times can is here: http://git-scm.org/gitwiki/ExampleScripts
publish_doc:
	git set-file-times
	$(RM) -r doc
	$(MAKE) doc
	rsync -av --delete doc/ rubyforge.org:/var/www/gforge-projects/clogger/
	git ls-files | xargs touch

.PHONY: test doc .manifest release History
