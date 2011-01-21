all::
RSYNC_DEST := rubyforge.org:/var/www/gforge-projects/clogger/
rfproject := clogger
rfpackage := clogger
include pkg.mk
test-ext:
	CLOGGER_PURE= $(MAKE) test-unit
test-pure:
	CLOGGER_PURE=1 $(MAKE) test-unit

test: test-ext test-pure

.PHONY: test-ext test-pure
ifneq ($(VERSION),)
release::
	$(RAKE) publish_news VERSION=$(VERSION)
	$(RAKE) raa_update VERSION=$(VERSION)
endif
