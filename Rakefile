begin
  require 'rake/extensiontask'
  Rake::ExtensionTask.new('clogger_ext')
rescue LoadError
  warn "rake-compiler not available, cross compiling disabled"
end

desc 'prints RDoc-formatted history'
task :history do
  tags = `git tag -l`.split(/\n/).grep(/^v/).reverse
  timefmt = '%Y-%m-%d %H:%M UTC'
  tags.each do |tag|
    header, subject, body = `git cat-file tag #{tag}`.split(/\n\n/, 3)
    tagger = header.split(/\n/).grep(/^tagger /).first.split(/\s/)
    time = Time.at(tagger[-2].to_i).utc
    puts "=== #{tag.sub(/^v/, '')} / #{time.strftime(timefmt)}"
    puts ""
    puts body
    puts ""
  end
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
