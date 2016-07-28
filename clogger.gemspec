ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }
require 'olddoc'
extend Olddoc::Gemspec
name, summary, title = readme_metadata

Gem::Specification.new do |s|
  s.name = %q{clogger}
  s.version = ENV["VERSION"].dup
  s.homepage = Olddoc.config['rdoc_url']
  s.authors = ["cloggers"]
  s.description = readme_description
  s.email = %q{clogger@bogomips.org}
  s.extra_rdoc_files = extra_rdoc_files(manifest)
  s.files = manifest
  s.summary = summary
  s.test_files = %w(test/test_clogger.rb test/test_clogger_to_path.rb)

  # HeaderHash wasn't case-insensitive in old versions
  s.add_dependency(%q<rack>, ['>= 1.0', '< 3.0'])
  s.extensions = %w(ext/clogger_ext/extconf.rb)

  s.licenses = %w(LGPL-2.1+)
end
