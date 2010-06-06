ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }

Gem::Specification.new do |s|
  s.name = %q{clogger}
  s.version = ENV["VERSION"]

  if s.respond_to? :required_rubygems_version=
    s.required_rubygems_version = Gem::Requirement.new(">= 0")
  end
  s.homepage = 'http://clogger.rubyforge.org/'
  s.authors = ["cloggers"]
  s.date = Time.now.utc.strftime('%Y-%m-%d')
  s.description = %q{
Clogger is Rack middleware for logging HTTP requests.  The log format
is customizable so you can specify exactly which fields to log.
}.strip
  s.email = %q{clogger@librelist.com}

  s.extra_rdoc_files = File.readlines('.document').map! do |x|
    x.chomp!
    if File.directory?(x)
      manifest.grep(%r{\A#{x}/})
    elsif File.file?(x)
      x
    else
      nil
    end
  end.flatten.compact

  s.files = manifest
  s.rdoc_options = [ "-Na",
                     "-t", "Clogger - configurable request logging for Rack"
                   ]
  s.require_paths = %w(lib ext)
  s.rubyforge_project = %q{clogger}
  s.summary = %q{configurable request logging for Rack}
  s.test_files = %w(test/test_clogger.rb)

  # HeaderHash wasn't case-insensitive in old versions
  s.add_dependency(%q<rack>, ["> 0.9"])
  s.extensions = %w(ext/clogger_ext/extconf.rb)

  # s.license = "LGPLv2.1+" # disabled for compatibility with older RubyGems
end
