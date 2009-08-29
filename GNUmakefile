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
	$(RM) -f $@+

.PHONY: test doc Manifest.txt
