= Clogger - configurable request logging for Rack

* http://clogger.rubyforge.org/
* mailto:clogger@librelist.com
* git://rubyforge.org/clogger.git
* http://clogger.rubyforge.org/git?p=clogger.git

== DESCRIPTION

Clogger is Rack middleware for logging HTTP requests.  The log format
is customizable so you can specify exactly which fields to log.

== FEATURES

* pre-defines Apache Common Log Format, Apache Combined Log Format and
  Rack::CommonLogger (as distributed by Rack 1.0) formats.

* highly customizable with easy-to-read nginx-like log formatting variables.

* Untrusted values are escaped (all HTTP headers, request URI components)
  to make life easier for HTTP log parsers. The following bytes are escaped:

    ' (single quote)
    " (double quote)
    all bytes in the range of \x00-\x1f

== SYNOPSIS

Clogger may be loaded as Rack middleware in your config.ru:

  require "clogger"
  use Clogger,
      :format => Clogger::Format::Combined,
      :logger => File.open("/path/to/log", "ab")
  run YourApplication.new

If you're using Rails 2.3.x or later, in your config/environment.rb
somewhere inside the "Rails::Initializer.run do |config|" block:

  config.middleware.use 'Clogger',
      :format => Clogger::Format::Combined,
      :logger => File.open("/path/to/log", "ab")

== VARIABLES

* $http_* - HTTP request headers (e.g. $http_user_agent)
* $sent_http_* - HTTP response headers (e.g. $sent_http_content_length)
* $cookie_* - HTTP request cookie (e.g. $cookie_session_id)
  Rack::Request#cookies must have been used by the underlying application
  to parse the cookies into a hash.
* $request_method - the HTTP request method (e.g. GET, POST, HEAD, ...)
* $path_info - path component requested (e.g. /index.html)
* $query_string - request query string (not including leading "?")
* $request_uri - the URI requested ($path_info?$query_string)
* $request - the first line of the HTTP request
  ($request_method $request_uri $http_version)
* $request_time, $request_time{PRECISION} - time taken for request
  (including response body iteration).  PRECISION defaults to 3
  (milliseconds) if not specified but may be specified 0(seconds) to
  6(microseconds).
* $time_local, $time_local{FORMAT} - current local time, FORMAT defaults to
  "%d/%b/%Y:%H:%M:%S %z" but accepts any strftime(3)-compatible format
* $time_utc, $time_utc{FORMAT} - like $time_local, except with UTC
* $usec - current time in seconds.microseconds since the Epoch
* $msec - current time in seconds.milliseconds since the Epoch
* $body_bytes_sent - bytes in the response body (Apache: %B)
* $response_length - body_bytes_sent, except "-" instead of "0" (Apache: %b)
* $remote_user - HTTP-authenticated user
* $remote_addr - IP of the requesting client socket
* $ip - X-Forwarded-For request header if available, $remote_addr if not
* $pid - process ID of the current process
* $e{Thread.current} - Thread processing the request
* $e{Actor.current} - Actor processing the request (Revactor or Rubinius)

== REQUIREMENTS

* Ruby, Rack

== CONTACT

All feedback (bug reports, user/development dicussion, patches, pull
requests) should go to the mailing list.  Patches should be sent inline
(git format-patch -M + git send-email) so we can reply to them inline.

* mailto:clogger@librelist.com

== INSTALL:

For Rubygems users:

  gem install clogger

If you're using MRI 1.8 or 1.9 and have a build environment, you can also try:

  gem install clogger_ext

A setup.rb file is also included if you do not use Rubygems.

== LICENSE

Copyright (C) 2009 Eric Wong <normalperson@yhbt.net> and contributors.

Clogger is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the
Free Software Foundation, version 3.0.

Clogger is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
License for more details.

You should have received a copy of the GNU Lesser General Public License
along with Clogger; if not, write to the Free Software Foundation, Inc.,
51 Franklin Street, Fifth Floor, Boston, MA 02110-1301
