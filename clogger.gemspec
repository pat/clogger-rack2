ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }
require 'wrongdoc'
extend Wrongdoc::Gemspec
name, summary, title = readme_metadata

Gem::Specification.new do |s|
  s.name = %q{clogger}
  s.version = ENV["VERSION"].dup
  s.homepage = Wrongdoc.config[:rdoc_url]
  s.authors = ["cloggers"]
  s.date = Time.now.utc.strftime('%Y-%m-%d')
  s.description = readme_description
  s.email = %q{clogger@librelist.org}
  s.extra_rdoc_files = extra_rdoc_files(manifest)
  s.files = manifest
  s.rdoc_options = rdoc_options
  s.require_paths = %w(lib ext)
  s.rubyforge_project = %q{clogger}
  s.summary = summary
  s.test_files = %w(test/test_clogger.rb test/test_clogger_to_path.rb)

  # HeaderHash wasn't case-insensitive in old versions
  s.add_dependency(%q<rack>, ["> 0.9"])
  s.add_development_dependency(%q<wrongdoc>, "~> 1.0")
  s.extensions = %w(ext/clogger_ext/extconf.rb)

  # disabled for compatibility with older RubyGems
  # s.license = "LGPLv2.1 LGPLv3"
end
