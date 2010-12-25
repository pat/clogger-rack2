begin
  require 'rake/extensiontask'
  Rake::ExtensionTask.new('clogger_ext')
rescue LoadError
  warn "rake-compiler not available, cross compiling disabled"
end

desc "read news article from STDIN and post to rubyforge"
task :publish_news do
  require 'rubyforge'
  IO.select([STDIN], nil, nil, 1) or abort "E: news must be read from stdin"
  msg = STDIN.readlines
  subject = msg.shift
  blank = msg.shift
  blank == "\n" or abort "no newline after subject!"
  subject.strip!
  body = msg.join("").strip!

  rf = RubyForge.new.configure
  rf.login
  rf.post_news('clogger', subject, body)
end

cgit_url = "http://git.bogomips.org/cgit/clogger.git"
git_url = 'git://git.bogomips.org/clogger.git'

desc "post to RAA"
task :raa_update do
  require 'rubygems'
  require 'net/http'
  require 'net/netrc'
  rc = Net::Netrc.locate('clogger-raa') or abort "~/.netrc not found"
  password = rc.password

  s = Gem::Specification.load('clogger.gemspec')
  desc = [ s.description.strip ]
  desc << ""
  desc << "* #{s.email}"
  desc << "* #{git_url}"
  desc << "* #{cgit_url}"
  desc = desc.join("\n")
  uri = URI.parse('http://raa.ruby-lang.org/regist.rhtml')
  form = {
    :name => s.name,
    :short_description => s.summary,
    :version => s.version.to_s,
    :status => 'experimental',
    :owner => s.authors.first,
    :email => s.email,
    :category_major => 'Library',
    :category_minor => 'Rack',
    :url => s.homepage,
    :download => 'http://rubyforge.org/frs/?group_id=8896',
    :license => 'LGPL',
    :description_style => 'Plain',
    :description => desc,
    :pass => password,
    :submit => 'Update',
  }
  res = Net::HTTP.post_form(uri, form)
  p res
  puts res.body
end
