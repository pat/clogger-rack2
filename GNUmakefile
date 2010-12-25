all:: test
RUBY = ruby
RAKE = rake
RSYNC = rsync

GIT-VERSION-FILE: .FORCE-GIT-VERSION-FILE
	@./GIT-VERSION-GEN
-include GIT-VERSION-FILE
-include local.mk

ifeq ($(DLEXT),) # "so" for Linux
  DLEXT := $(shell $(RUBY) -rrbconfig -e 'puts Config::CONFIG["DLEXT"]')
endif

ext/clogger_ext/Makefile: ext/clogger_ext/clogger.c ext/clogger_ext/extconf.rb
	cd ext/clogger_ext && $(RUBY) extconf.rb

ext/clogger_ext/clogger.$(DLEXT): ext/clogger_ext/Makefile
	$(MAKE) -C ext/clogger_ext

clean:
	-$(MAKE) -C ext/clogger_ext clean
	$(RM) ext/clogger_ext/Makefile lib/clogger_ext.$(DLEXT)

test_unit := $(wildcard test/test_*.rb)
test-unit: $(test_unit)

ifeq ($(CLOGGER_PURE),)
$(test_unit): mylib := ext/clogger_ext:lib
$(test_unit): ext/clogger_ext/clogger.$(DLEXT)
else
$(test_unit): mylib := lib
endif

$(test_unit):
	$(RUBY) -I $(mylib) $@

test-ext:
	CLOGGER_PURE= $(MAKE) test-unit

test-pure:
	CLOGGER_PURE=1 $(MAKE) test-unit

test: test-ext test-pure

pkg_extra := GIT-VERSION-FILE NEWS ChangeLog LATEST
manifest: $(pkg_extra)
	$(RM) .manifest
	$(MAKE) .manifest

.manifest:
	(git ls-files && \
         for i in $@ $(pkg_extra); \
	 do echo $$i; done) | LC_ALL=C sort > $@+
	cmp $@+ $@ || mv $@+ $@
	$(RM) $@+

ChangeLog: GIT-VERSION-FILE .wrongdoc.yml
	wrongdoc prepare

doc: .document .wrongdoc.yml
	find lib ext -type f -name '*.rbc' -exec rm -f '{}' ';'
	$(RM) -r doc
	wrongdoc all
	install -m644 COPYING doc/COPYING
	install -m644 $(shell grep '^[A-Z]' .document) doc/

# publishes docs to http://clogger.rubyforge.org/
# this preserves timestamps as best as possible to help HTTP caches out
# git set-file-times is here: http://git-scm.org/gitwiki/ExampleScripts
publish_doc:
	-git set-file-times
	$(MAKE) doc
	-find doc/images -type f | \
                TZ=UTC xargs touch -d '1970-01-01 00:00:03' doc/rdoc.css
	$(RSYNC) -av doc/ rubyforge.org:/var/www/gforge-projects/clogger/
	git ls-files | xargs touch

ifneq ($(VERSION),)
rfproject := clogger
rfpackage := clogger
pkggem := pkg/$(rfpackage)-$(VERSION).gem
pkgtgz := pkg/$(rfpackage)-$(VERSION).tgz
release_notes := release_notes-$(VERSION)
release_changes := release_changes-$(VERSION)

release-notes: $(release_notes)
release-changes: $(release_changes)
$(release_changes):
	wrongdoc release_changes > $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@
$(release_notes):
	wrongdoc release_notes > $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@

# ensures we're actually on the tagged $(VERSION), only used for release
verify:
	test x"$(shell umask)" = x0022
	git rev-parse --verify refs/tags/v$(VERSION)^{}
	git diff-index --quiet HEAD^0
	test `git rev-parse --verify HEAD^0` = \
	     `git rev-parse --verify refs/tags/v$(VERSION)^{}`

fix-perms:
	-git ls-tree -r HEAD | awk '/^100644 / {print $$NF}' | xargs chmod 644
	-git ls-tree -r HEAD | awk '/^100755 / {print $$NF}' | xargs chmod 755

gem: $(pkggem)

install-gem: $(pkggem)
	gem install $(CURDIR)/$<

$(pkggem): manifest fix-perms
	gem build $(rfpackage).gemspec
	mkdir -p pkg
	mv $(@F) $@

$(pkgtgz): distdir = $(basename $@)
$(pkgtgz): HEAD = v$(VERSION)
$(pkgtgz): manifest fix-perms
	@test -n "$(distdir)"
	$(RM) -r $(distdir)
	mkdir -p $(distdir)
	tar cf - `cat .manifest` | (cd $(distdir) && tar xf -)
	cd pkg && tar cf - $(basename $(@F)) | gzip -9 > $(@F)+
	mv $@+ $@

package: $(pkgtgz) $(pkggem)

release: verify package $(release_notes) $(release_changes)
	rubyforge add_release -f -n $(release_notes) -a $(release_changes) \
	  $(rfproject) $(rfpackage) $(VERSION) $(pkgtgz)
	gem push $(pkggem)
	rubyforge add_file \
	  $(rfproject) $(rfpackage) $(VERSION) $(pkggem)
else
gem install-gem: GIT-VERSION-FILE
	$(MAKE) $@ VERSION=$(GIT_VERSION)
endif

.PHONY: .FORCE-GIT-VERSION-FILE test doc manifest
.PHONY: test test-ext test-pure $(test_unit)
