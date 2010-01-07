all:: test
RUBY = ruby
RAKE = rake
GIT_URL = git://git.bogomips.org/clogger.git

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

test-ext: ext/clogger_ext/clogger.$(DLEXT)
	$(RUBY) -Iext/clogger_ext:lib test/test_clogger.rb

test-pure:
	CLOGGER_PURE=t $(RUBY) -Ilib test/test_clogger.rb

test: test-ext test-pure

pkg_extra := GIT-VERSION-FILE NEWS ChangeLog
manifest: $(pkg_extra)
	$(RM) .manifest
	$(MAKE) .manifest

.manifest:
	(git ls-files && \
         for i in $@ $(pkg_extra); \
	 do echo $$i; done) | LC_ALL=C sort > $@+
	cmp $@+ $@ || mv $@+ $@
	$(RM) $@+

NEWS: GIT-VERSION-FILE
	$(RAKE) -s news_rdoc > $@+
	mv $@+ $@

SINCE = 0.0.7
ChangeLog: log_range = $(shell test -n "$(SINCE)" && echo v$(SINCE)..)
ChangeLog: GIT-VERSION-FILE
	@echo "ChangeLog from $(GIT_URL) ($(SINCE)..$(GIT_VERSION))" > $@+
	@echo >> $@+
	git log $(log_range) | sed -e 's/^/    /' >> $@+
	mv $@+ $@

news_atom := http://clogger.rubyforge.org/NEWS.atom.xml
cgit_atom := http://git.bogomips.org/cgit/clogger.git/atom/?h=master
atom = <link rel="alternate" title="Atom feed" href="$(1)" \
             type="application/atom+xml"/>

doc: .document NEWS ChangeLog
	rdoc -Na -t "$(shell sed -ne '1s/^= //p' README)"
	install -m644 COPYING doc/COPYING
	install -m644 $(shell grep '^[A-Z]' .document)  doc/
	$(RUBY) -i -p -e \
	  '$$_.gsub!("</title>",%q{\&$(call atom,$(cgit_atom))})' \
	  doc/ChangeLog.html
	$(RUBY) -i -p -e \
	  '$$_.gsub!("</title>",%q{\&$(call atom,$(news_atom))})' \
	  doc/NEWS.html doc/README.html
	$(RAKE) -s news_atom > doc/NEWS.atom.xml
	cd doc && ln README.html tmp && mv tmp index.html

# publishes docs to http://clogger.rubyforge.org/
# this preserves timestamps as best as possible to help HTTP caches out
# git set-file-times is here: http://git-scm.org/gitwiki/ExampleScripts
publish_doc:
	git set-file-times
	$(RM) -r doc
	$(MAKE) doc
	rsync -av --delete doc/ rubyforge.org:/var/www/gforge-projects/clogger/
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
	$(RAKE) -s release_changes > $@+
	$(VISUAL) $@+ && test -s $@+ && mv $@+ $@
$(release_notes):
	GIT_URL=$(GIT_URL) $(RUBY) -s release_notes > $@+
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
	tar c `cat .manifest` | (cd $(distdir) && tar x)
	cd pkg && tar c $(basename $(@F)) | gzip -9 > $(@F)+
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
