Gem::Specification.new do |s|
  s.name = %q{clogger}
  s.version = "2.1.0"
  s.homepage = "https://github.com/pat/clogger-rack2"
  s.authors = ["cloggers"]
  s.description = "configurable request logging for Rack"
  s.email = %q{clogger@bogomips.org}
  s.extra_rdoc_files = []
  s.files = [
    "LICENSE",
    "README",
    "ext/clogger_ext/clogger.c",
    "ext/clogger_ext/extconf.rb",
    "ext/clogger_ext/blocking_helpers.h",
    "ext/clogger_ext/broken_system_compat.h",
    "ext/clogger_ext/ruby_1_9_compat.h",
    "lib/clogger.rb",
    "lib/clogger/format.rb",
    "lib/clogger/pure.rb"
  ]
  s.summary = "configurable request logging for Rack"
  s.test_files = %w(test/test_clogger.rb test/test_clogger_to_path.rb)

  # HeaderHash wasn't case-insensitive in old versions
  s.add_dependency(%q<rack>, ['>= 1.0', '< 3.0'])
  s.extensions = %w(ext/clogger_ext/extconf.rb)

  s.licenses = %w(LGPL-2.1+)
end
