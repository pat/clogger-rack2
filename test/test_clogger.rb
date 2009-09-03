# -*- encoding: binary -*-
$stderr.sync = $stdout.sync = true
require "test/unit"
require "date"
require "stringio"

require "rack"

require "clogger"
class TestClogger < Test::Unit::TestCase
  include Clogger::Format

  def setup
    @req = {
      "REQUEST_METHOD" => "GET",
      "HTTP_VERSION" => "HTTP/1.0",
      "HTTP_USER_AGENT" => 'echo and socat \o/',
      "PATH_INFO" => "/hello",
      "QUERY_STRING" => "goodbye=true",
      "rack.errors" => $stderr,
      "rack.input" => File.open('/dev/null', 'rb'),
      "REMOTE_ADDR" => 'home',
    }
  end

  def test_init_basic
    Clogger.new(lambda { |env| [ 0, {}, [] ] })
  end

  def test_init_noargs
    assert_raise(ArgumentError) { Clogger.new }
  end

  def test_init_stderr
    cl = Clogger.new(lambda { |env| [ 0, {}, [] ] }, :logger => $stderr)
    assert_kind_of(Integer, cl.fileno)
    assert_equal $stderr.fileno, cl.fileno
  end

  def test_init_stringio
    cl = Clogger.new(lambda { |env| [ 0, {}, [] ] }, :logger => StringIO.new)
    assert_nil cl.fileno
  end

  def test_write_stringio
    start = DateTime.now - 1
    str = StringIO.new
    cl = Clogger.new(lambda { |env| [ "302 Found", {}, [] ] }, :logger => str)
    status, headers, body = cl.call(@req)
    assert_equal("302 Found", status)
    assert_equal({}, headers)
    body.each { |part| assert false }
    str = str.string
    r = %r{\Ahome - - \[[^\]]+\] "GET /hello\?goodbye=true HTTP/1.0" 302 -\n\z}
    assert_match r, str
    %r{\[([^\]]+)\]} =~ str
    tmp = nil
    assert_nothing_raised {
      tmp = DateTime.strptime($1, "%d/%b/%Y:%H:%M:%S %z")
    }
    assert tmp >= start
    assert tmp <= DateTime.now
  end

  def test_clen_stringio
    start = DateTime.now - 1
    str = StringIO.new
    app = lambda { |env| [ 301, {'Content-Length' => '5'}, ['abcde'] ] }
    format = Common.dup
    assert format.gsub!(/response_length/, 'sent_http_content_length')
    cl = Clogger.new(app, :logger => str, :format => format)
    status, headers, body = cl.call(@req)
    assert_equal(301, status)
    assert_equal({'Content-Length' => '5'}, headers)
    body.each { |part| assert_equal('abcde', part) }
    str = str.string
    r = %r{\Ahome - - \[[^\]]+\] "GET /hello\?goodbye=true HTTP/1.0" 301 5\n\z}
    assert_match r, str
    %r{\[([^\]]+)\]} =~ str
    tmp = nil
    assert_nothing_raised {
      tmp = DateTime.strptime($1, "%d/%b/%Y:%H:%M:%S %z")
    }
    assert tmp >= start
    assert tmp <= DateTime.now
  end

  def test_compile_ambiguous
    cl = Clogger.new(nil, :logger => $stderr)
    ary = nil
    cl.instance_eval {
      ary = compile_format(
        '$remote_addr $$$$pid' \
        "\n")
    }
    expect = [
      [ Clogger::OP_REQUEST, "REMOTE_ADDR" ],
      [ Clogger::OP_LITERAL, " " ],
      [ Clogger::OP_LITERAL, "$$$" ],
      [ Clogger::OP_SPECIAL, Clogger::SPECIAL_VARS[:pid] ],
      [ Clogger::OP_LITERAL, "\n" ],
      ]
    assert_equal expect, ary
  end

  def test_compile_auto_newline
    cl = Clogger.new(nil, :logger => $stderr)
    ary = nil
    cl.instance_eval { ary = compile_format('$remote_addr $request') }
    expect = [
      [ Clogger::OP_REQUEST, "REMOTE_ADDR" ],
      [ Clogger::OP_LITERAL, " " ],
      [ Clogger::OP_SPECIAL, Clogger::SPECIAL_VARS[:request] ],
      [ Clogger::OP_LITERAL, "\n" ],
      ]
    assert_equal expect, ary
  end

  def test_big_log
    str = StringIO.new
    fmt = '$remote_addr $pid $remote_user [$time_local] ' \
          '"$request" $status $body_bytes_sent "$http_referer" ' \
         '"$http_user_agent" "$http_cookie" $request_time $http_host'
    app = lambda { |env| [ 302, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => fmt)
    cookie = "foo=bar#{'f' * 256}".freeze
    req = {
      'HTTP_HOST' => 'example.com:12345',
      'HTTP_COOKIE' => cookie,
    }
    req = @req.merge(req)
    cl.call(req).last.each { |part| part }
    str = str.string
    assert(str.size > 128)
    assert_match %r["echo and socat \\o/" "#{cookie}" \d+\.\d{3}], str
    assert_match %r["#{cookie}" \d+\.\d{3} example\.com:12345\n\z], str
  end

  def test_compile
    cl = Clogger.new(nil, :logger => $stderr)
    ary = nil
    cl.instance_eval {
      ary = compile_format(
        '$remote_addr - $remote_user [$time_local] ' \
        '"$request" $status $body_bytes_sent "$http_referer" ' \
        '"$http_user_agent" "$http_cookie" $request_time ' \
        '$env{rack.url_scheme}' \
        "\n")
    }
    expect = [
      [ Clogger::OP_REQUEST, "REMOTE_ADDR" ],
      [ Clogger::OP_LITERAL, " - " ],
      [ Clogger::OP_REQUEST, "REMOTE_USER" ],
      [ Clogger::OP_LITERAL, " [" ],
      [ Clogger::OP_TIME_LOCAL, '%d/%b/%Y:%H:%M:%S %z' ],
      [ Clogger::OP_LITERAL, "] \"" ],
      [ Clogger::OP_SPECIAL, Clogger::SPECIAL_VARS[:request] ],
      [ Clogger::OP_LITERAL, "\" "],
      [ Clogger::OP_SPECIAL, Clogger::SPECIAL_VARS[:status] ],
      [ Clogger::OP_LITERAL, " "],
      [ Clogger::OP_SPECIAL, Clogger::SPECIAL_VARS[:body_bytes_sent] ],
      [ Clogger::OP_LITERAL, " \"" ],
      [ Clogger::OP_REQUEST, "HTTP_REFERER" ],
      [ Clogger::OP_LITERAL, "\" \"" ],
      [ Clogger::OP_REQUEST, "HTTP_USER_AGENT" ],
      [ Clogger::OP_LITERAL, "\" \"" ],
      [ Clogger::OP_REQUEST, "HTTP_COOKIE" ],
      [ Clogger::OP_LITERAL, "\" " ],
      [ Clogger::OP_REQUEST_TIME, '%d.%03d', 1000 ],
      [ Clogger::OP_LITERAL, " " ],
      [ Clogger::OP_REQUEST, "rack.url_scheme" ],
      [ Clogger::OP_LITERAL, "\n" ],
    ]
    assert_equal expect, ary
  end

  def test_eval
    current = Thread.current.to_s
    str = StringIO.new
    app = lambda { |env| [ 302, {}, [] ] }
    cl = Clogger.new(app,
                    :logger => str,
                    :format => "-$e{Thread.current}-\n")
    status, headers, body = cl.call(@req)
    assert_equal "-#{current}-\n", str.string
  end

  def test_pid
    str = StringIO.new
    app = lambda { |env| [ 302, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => "[$pid]\n")
    status, headers, body = cl.call(@req)
    assert_equal "[#$$]\n", str.string
  end

  def test_rack_xff
    str = StringIO.new
    app = lambda { |env| [ 302, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => "$ip")
    req = @req.merge("HTTP_X_FORWARDED_FOR" => '192.168.1.1')
    status, headers, body = cl.call(req)
    assert_equal "192.168.1.1\n", str.string
    str.rewind
    str.truncate(0)
    status, headers, body = cl.call(@req)
    assert_equal "home\n", str.string
    str.rewind
    str.truncate(0)
  end

  def test_rack_1_0
    start = DateTime.now - 1
    str = StringIO.new
    app = lambda { |env| [ 200, {'Content-Length'=>'0'}, %w(a b c)] }
    cl = Clogger.new(app, :logger => str, :format => Rack_1_0)
    status, headers, body = cl.call(@req)
    tmp = []
    body.each { |s| tmp << s }
    assert_equal %w(a b c), tmp
    str = str.string
    assert_match %r[" 200 3 \d+\.\d{4}\n\z], str
    tmp = nil
    %r{\[(\d+/\w+/\d+ \d+:\d+:\d+)\]} =~ str
    assert $1
    assert_nothing_raised { tmp = DateTime.strptime($1, "%d/%b/%Y %H:%M:%S") }
    assert tmp >= start
    assert tmp <= DateTime.now
  end

  def test_msec
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$msec')
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\.\d{3}\n\z), str.string
  end

  def test_usec
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$usec')
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\.\d{6}\n\z), str.string
  end

  def test_time_0
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$time{0}')
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\n\z), str.string
  end

  def test_time_1
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$time{1}')
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\.\d\n\z), str.string
  end

  def test_request_length
    str = StringIO.new
    input = StringIO.new('.....')
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$request_length')
    status, header, bodies = cl.call(@req.merge('rack.input' => input))
    assert_equal "5\n", str.string
  end

  def test_response_length_0
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$response_length')
    status, header, bodies = cl.call(@req)
    bodies.each { |part| part }
    assert_equal "-\n", str.string
  end

  def test_combined
    start = DateTime.now - 1
    str = StringIO.new
    app = lambda { |env| [ 200, {'Content-Length'=>'3'}, %w(a b c)] }
    cl = Clogger.new(app, :logger => str, :format => Combined)
    status, headers, body = cl.call(@req)
    tmp = []
    body.each { |s| tmp << s }
    assert_equal %w(a b c), tmp
    str = str.string
    assert_match %r[" 200 3 "-" "echo and socat \\o/"\n\z], str
    tmp = nil
    %r{\[(\d+/\w+/\d+:\d+:\d+:\d+ .+)\]} =~ str
    assert $1
    assert_nothing_raised {
      tmp = DateTime.strptime($1, "%d/%b/%Y:%H:%M:%S %z")
    }
    assert tmp >= start
    assert tmp <= DateTime.now
  end

  def test_rack_errors_fallback
    err = StringIO.new
    app = lambda { |env| [ 200, {'Content-Length'=>'3'}, %w(a b c)] }
    cl = Clogger.new(app, :format => '$pid')
    req = @req.merge('rack.errors' => err)
    status, headers, body = cl.call(req)
    assert_equal "#$$\n", err.string
  end

  def test_body_close
    s_body = StringIO.new(%w(a b c).join("\n"))
    app = lambda { |env| [ 200, {'Content-Length'=>'5'}, s_body] }
    cl = Clogger.new(app, :logger => [], :format => '$pid')
    status, headers, body = cl.call(@req)
    assert ! s_body.closed?
    assert_nothing_raised { body.close }
    assert s_body.closed?
  end

  def test_escape
    str = StringIO.new
    app = lambda { |env| [ 200, {'Content-Length'=>'5'}, [] ] }
    cl = Clogger.new(app,
      :logger => str,
      :format => '$http_user_agent "$request"')
    bad = {
      'HTTP_USER_AGENT' => '"asdf"',
      'QUERY_STRING' => 'sdf=bar"',
      'PATH_INFO' => '/"<>"',
    }
    status, headers, body = cl.call(@req.merge(bad))
    expect = '\x22asdf\x22 "GET /\x22<>\x22?sdf=bar\x22 HTTP/1.0"' << "\n"
    assert_equal expect, str.string
  end

  # rack allows repeated headers with "\n":
  # { 'Set-Cookie' => "a\nb" } =>
  #   Set-Cookie: a
  #   Set-Cookie: b
  def test_escape_header_newlines
    str = StringIO.new
    app = lambda { |env| [302, { 'Set-Cookie' => "a\nb" }, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$sent_http_set_cookie')
    cl.call(@req)
    assert_equal "a\\x0Ab\n", str.string
  end

  def test_request_uri_fallback
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$request_uri')
    status, headers, body = cl.call(@req)
    assert_equal "/hello?goodbye=true\n", str.string
  end

  def test_request_uri_set
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$request_uri')
    status, headers, body = cl.call(@req.merge("REQUEST_URI" => '/zzz'))
    assert_equal "/zzz\n", str.string
  end

  def test_cookies
    str = StringIO.new
    app = lambda { |env|
      req = Rack::Request.new(env).cookies
      [ 302, {}, [] ]
    }
    cl = Clogger.new(app,
        :format => '$cookie_foo $cookie_quux',
        :logger => str)
    req = @req.merge('HTTP_COOKIE' => "foo=bar;quux=h&m")
    status, headers, body = cl.call(req)
    assert_equal "bar h&m\n", str.string
  end

  def test_bogus_app_response
    str = StringIO.new
    app = lambda { |env| 302 }
    cl = Clogger.new(app, :logger => str)
    assert_raise(TypeError) { cl.call(@req) }
    str = str.string
    e = Regexp.quote " \"GET /hello?goodbye=true HTTP/1.0\" 500 -"
    assert_match %r{#{e}$}m, str
  end

  def test_broken_header_response
    str = StringIO.new
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => '$sent_http_set_cookie')
    assert_raise(TypeError) { cl.call(@req) }
  end

  def test_http_09_request
    str = StringIO.new
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => '$request')
    req = @req.dup
    req.delete 'HTTP_VERSION'
    cl.call(req)
    assert_equal "GET /hello?goodbye=true\n", str.string
  end

  def test_request_method_only
    str = StringIO.new
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => '$request_method')
    cl.call(@req)
    assert_equal "GET\n", str.string
  end

  def test_content_length_null
    str = StringIO.new
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => '$content_length')
    cl.call(@req)
    assert_equal "-\n", str.string
  end

  def test_content_length_set
    str = StringIO.new
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => '$content_length')
    cl.call(@req.merge('CONTENT_LENGTH' => '5'))
    assert_equal "5\n", str.string
  end

end
