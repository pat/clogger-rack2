require 'mkmf'

if have_header('fcntl.h')
  have_macro('F_GETFL', %w(fcntl.h))
  have_macro('O_NONBLOCK', %w(unistd.h fcntl.h))
end

have_func('localtime_r', 'time.h') or abort "localtime_r needed"
have_func('gmtime_r', 'time.h') or abort "gmtime_r needed"
have_func('rb_str_set_len', 'ruby.h')
dir_config('clogger_ext')
create_makefile('clogger_ext')
