require 'hoe'
$LOAD_PATH << 'lib'
require 'clogger'
begin
  require 'rake/extensiontask'
  Rake::ExtensionTask.new('clogger_ext')
rescue LoadError
  warn "rake-compiler not available, cross compiling disabled"
end

common = lambda do |hoe|
  title = hoe.paragraphs_of("README.txt", 0).first.sub(/^= /, '')
  hoe.version = Clogger::VERSION
  hoe.summary = title.split(/\s*-\s*/, 2).last
  hoe.description = hoe.paragraphs_of("README.txt", 3)
  hoe.rubyforge_name = 'clogger'
  hoe.author = 'Eric Wong'
  hoe.email = 'clogger@librelist.com'
  hoe.spec_extras.merge!('rdoc_options' => [ "--title", title ])
  hoe.remote_rdoc_dir = ''
end

if ENV['CLOGGER_EXT']
  Hoe.spec('clogger_ext') do
    common.call(self)
    self.spec_extras.merge!(:extensions => Dir.glob('ext/*/extconf.rb'))
  end
else
  Hoe.spec('clogger') { common.call(self) }
end
