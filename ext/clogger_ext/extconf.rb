begin
  require 'mkmf'
  $CPPFLAGS += " -D_BSD_SOURCE=1 "

  # XXX let me know if this works for you...
  if ! defined?(RUBY_VERSION) || RUBY_VERSION !~ /\A1\.[89]\./
    raise "Invalid RUBY_VERSION for C extension"
  end

  have_header('ruby.h') or raise "ruby.h header not found!"

  if have_header('fcntl.h')
    have_macro('F_GETFL', %w(fcntl.h))
    have_macro('O_NONBLOCK', %w(unistd.h fcntl.h))
  end

  $CPPFLAGS += '-D_POSIX_C_SOURCE=200112L'
  unless have_macro('CLOCK_MONOTONIC', 'time.h')
    have_func('CLOCK_MONOTONIC', 'time.h')
  end
  have_type('clockid_t', 'time.h')
  have_func('clock_gettime', 'time.h')
  have_func('localtime_r', 'time.h') or raise "localtime_r needed"
  have_func('gmtime_r', 'time.h') or raise "gmtime_r needed"
  have_struct_member('struct tm', 'tm_gmtoff', 'time.h')
  have_func('rb_str_set_len', 'ruby.h')
  have_func('rb_thread_blocking_region', 'ruby.h')
  have_func('rb_thread_io_blocking_region', 'ruby.h')
  create_makefile('clogger_ext')
rescue Object => err
  warn "E: #{err.inspect}"
  warn "Skipping C extension, pure Ruby version will be used instead"

  # generate a dummy Makefile to fool rubygems installer
  targets = %w(all static clean distclean realclean
               install install-so install-rb install-rb-default
               pre-install-rb pre-install-rb-default
               site-install site-install-so site-install-rb)
  File.open(File.dirname(__FILE__) << "/Makefile", "wb") do |fp|
    fp.puts targets.join(' ') << ":"
    fp.puts "\techo >&2 extension disabled"
  end
end
