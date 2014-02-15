all::
RSYNC_DEST := clogger.bogomips.org:/srv/clogger/
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
endif
