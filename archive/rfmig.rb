#!/usr/bin/env ruby
require 'find'
require 'fileutils'
rfdir = 'rubyforge.org:/var/www/gforge-projects/clogger/'
newbase = 'http://clogger.bogomips.org/'
refresh = '<meta http-equiv="refresh" content="0; url=%s" />'
old = 'rf.old'
new = 'rf.new'
cmd = %W(rsync -av #{rfdir} #{old}/)
unless File.directory?(old)
  system(*cmd) or abort "#{cmd.inspect} failed: #$?"
end

Find.find(old) do |path|
  path =~ /\.html\z/ or next
  data = File.read(path)
  tmp = path.split(%r{/})
  tmp.shift == old or abort "BUG"
  dst = "#{new}/#{tmp.join('/')}"

  tmp[-1] = '' if tmp[-1] == "index.html"
  url = "#{newbase}#{tmp.join('/')}"
  meta = sprintf(refresh, url)
  data.sub!(/(<head[^>]*>)/i, "#$1#{meta}")
  data.sub!(/(<body[^>]*>)/i,
            "#{$1}Redirecting to <a href=\"#{url}\">#{url}</a> ...<br/>")
  FileUtils.mkdir_p(File.dirname(dst))
  File.open(dst, "w") { |fp| fp.write(data) }
end

print "Verify results in #{new}/, then run:\n  "
puts %W(rsync -av #{new}/ #{rfdir}).join(' ')
