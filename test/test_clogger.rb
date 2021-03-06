# -*- encoding: binary -*-
$stderr.sync = $stdout.sync = true
require "test/unit"
require "time"
require "date"
require "stringio"
require "tempfile"

require "rack"

require "clogger"

# used to test subclasses
class FooString < String
end

class TestClogger < Test::Unit::TestCase
  include Clogger::Format

  def setup
    @tz = ENV["TZ"]
    @nginx_fmt = "%d/%b/%Y:%H:%M:%S %z"
    @req = {
      "REQUEST_METHOD" => "GET",
      "HTTP_VERSION" => "HTTP/1.0",
      "HTTP_USER_AGENT" => 'echo and socat \o/',
      "PATH_INFO" => "/hello",
      "QUERY_STRING" => "goodbye=true",
      "rack.errors" => $stderr,
      "rack.input" => File.open('/dev/null', 'rb'),
      "rack.url_scheme" => "http",
      "REMOTE_ADDR" => 'home',
    }
  end

  def teardown
    ENV["TZ"] = @tz
  end

  def test_init_basic
    Clogger.new(lambda { |env| [ 0, {}, [] ] })
  end

  def test_init_noargs
    assert_raise(ArgumentError) { Clogger.new }
  end

  def test_clogger_sym_format
    app = lambda { |env| [ 0, {}, [] ] }
    tmp = Clogger.new app, :format => :Rack_1_0, :logger => $stderr
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
    body.close
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
      'REMOTE_USER' => 'foo_user',
    }
    req = @req.merge(req)
    body = cl.call(req).last
    body.each { |part| part }
    body.close
    str = str.string
    assert(str.size > 128)
    assert_equal 'foo_user', str.split(' ')[2]
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
      [ Clogger::OP_SPECIAL, Clogger::SPECIAL_VARS[:time_local] ],
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

    str = StringIO.new
    cl = Clogger.new(app, :logger => str, :format => "$ip")
    status, headers, body = cl.call(@req)
    assert_equal "home\n", str.string
  end

  def test_rack_1_0
    start = DateTime.now - 1
    str = StringIO.new
    app = lambda { |env| [ 200, {'Content-Length'=>'0'}, %w(a b c)] }
    cl = Clogger.new(app, :logger => str, :format => Rack_1_0)
    status, headers, body = cl.call(@req)
    tmp = []
    body.each { |s| tmp << s }
    body.close
    assert_equal %w(a b c), tmp
    str = str.string
    assert_match %r[" 200 3 \d+\.\d{4}\n\z], str
    tmp = nil
    %r{\[(\d+/\w+/\d+ \d+:\d+:\d+)\]} =~ str
    assert $1
    assert_nothing_raised { tmp = DateTime.strptime($1, "%d/%b/%Y %H:%M:%S") }
    assert tmp >= start
    # This test is not time-zone friendly.
    # assert tmp <= DateTime.now
  end

  def test_msec
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$msec')
    a = Time.now.to_f - 0.001
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\.\d{3}\n\z), str.string
    b = Time.now.to_f + 0.001
    logged = str.string.to_f
    assert logged >= a, "#{logged} >= #{a}"
    assert logged <= b, "#{logged} <= #{b}"
  end

  def test_usec
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$usec')
    a = Time.now.to_f - 0.000001
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\.\d{6}\n\z), str.string
    b = Time.now.to_f + 0.000001
    logged = str.string.to_f
    assert logged >= a, "#{logged} >= #{a}"
    assert logged <= b, "#{logged} <= #{b}"
  end

  def test_time_0
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$time{0}')
    a = Time.now.to_f - 1
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\n\z), str.string
    b = Time.now.to_f + 1
    logged = str.string.to_f
    assert logged >= a, "#{logged} >= #{a}"
    assert logged <= b, "#{logged} <= #{b}"
  end

  def test_time_1
    str = StringIO.new
    app = lambda { |env| [ 200, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => '$time{1}')
    a = Time.now.to_f - 0.5
    status, header, bodies = cl.call(@req)
    assert_match %r(\A\d+\.\d\n\z), str.string
    b = Time.now.to_f + 0.5
    logged = str.string.to_f
    assert logged >= a, "#{logged} >= #{a}"
    assert logged <= b, "#{logged} <= #{b}"
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
    bodies.close
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
    body.close
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

  def test_escape_crazy_delete
    str = StringIO.new
    app = lambda { |env| [302, {}, [] ] }
    cl = Clogger.new(app, :logger => str, :format => "$http_cookie")
    @req["HTTP_COOKIE"] = "a\x7f\xff"
    cl.call(@req)
    assert_equal "a\\x7F\\xFF\n", str.string
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
    req = @req.merge('HTTP_COOKIE' => "foo=bar;quux=h%7F&m")
    status, headers, body = cl.call(req)
    assert_equal "bar h\\x7F&m\n", str.string
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
    assert_nothing_raised { cl.call(@req) }
  end

  def test_subclass_hash
    str = StringIO.new
    req = Rack::Utils::HeaderHash.new(@req)
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => Rack_1_0)
    assert_nothing_raised { cl.call(req).last.each {}.close }
    assert str.size > 0
  end

  def test_subclassed_string_req
    str = StringIO.new
    req = {}
    @req.each { |key,value|
      req[FooString.new(key)] = value.kind_of?(String) ?
                                FooString.new(value) : value
    }
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => Rack_1_0)
    assert_nothing_raised { cl.call(req).last.each {}.close }
    assert str.size > 0
  end

  def test_subclassed_string_in_body
    str = StringIO.new
    body = "hello"
    r = nil
    app = lambda { |env| [302, [ %w(a) ], [FooString.new(body)]] }
    cl = Clogger.new(app, :logger => str, :format => '$body_bytes_sent')
    assert_nothing_raised { cl.call(@req).last.each { |x| r = x }.close }
    assert str.size > 0
    assert_equal body.size.to_s << "\n", str.string
    assert_equal r, body
    assert r.object_id != body.object_id
  end

  # Rack::BodyProxy does this thing with method_missing
  # This test fails under MRI 1.9.1 and 1.9.2, but works under 1.9.3
  def test_each_with_external_block
    foo = Object.new
    foo.instance_variable_set(:@body, ["BodyProxy"])
    def foo.method_missing(*args, &block)
      @body.__send__(*args, &block)
    end
    app = lambda { |env| [302, [], foo] }
    str = StringIO.new
    cl = Clogger.new(app, :logger => str, :format => '$body_bytes_sent')
    r = nil
    assert_nothing_raised { r = cl.call(@req) }
    body = []
    r[2].each { |x| body << x }
    r[2].close
    assert_equal %w(BodyProxy), body
    assert_equal "9\n", str.string
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

  def test_http_content_type_fallback
    str = StringIO.new
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => str, :format => '$http_content_type')
    cl.call(@req.merge('CONTENT_TYPE' => 'text/plain'))
    assert_equal "text/plain\n", str.string
  end

  def test_clogger_synced
    io = StringIO.new
    logger = Struct.new(:sync, :io).new(false, io)
    assert ! logger.sync
    def logger.<<(str)
      io << str
    end
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => logger)
    assert logger.sync
  end

  def test_clogger_unsyncable
    logger = ''
    assert ! logger.respond_to?('sync=')
    app = lambda { |env| [302, [ %w(a) ], []] }
    assert_nothing_raised { Clogger.new(app, :logger => logger) }
  end

  def test_clogger_no_ORS
    s = ''
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => s, :format => "$request", :ORS => "")
    cl.call(@req)
    assert_equal "GET /hello?goodbye=true HTTP/1.0", s
  end

  def test_clogger_weird_ORS
    s = ''
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => s, :format => "<$request", :ORS => ">")
    cl.call(@req)
    assert_equal "<GET /hello?goodbye=true HTTP/1.0>", s
  end

  def test_clogger_body_not_closeable
    s = ''
    app = lambda { |env| [302, [ %w(a) ], []] }
    cl = Clogger.new(app, :logger => s)
    status, headers, body = cl.call(@req)
    assert_nil body.close
  end

  def test_clogger_response_frozen
    response = [ 200, { "AAAA" => "AAAA"}.freeze, [].freeze ].freeze
    s = StringIO.new("")
    app = Rack::Builder.new do
      use Clogger, :logger => s, :format => "$request_time $http_host"
      run lambda { |env| response }
    end
    assert_nothing_raised do
      3.times do
        resp = app.call(@req)
        assert ! resp.frozen?
        resp.last.each { |x| }
      end
    end
  end

  def test_clogger_body_close_return_value
    s = ''
    body = []
    def body.close
      :foo
    end
    app = lambda { |env| [302, [ %w(a) ], body ] }
    cl = Clogger.new(app, :logger => s)
    status, headers, body = cl.call(@req)
    assert_equal :foo, body.close
  end

  def test_clogger_auto_reentrant_true
    s = ''
    body = []
    app = lambda { |env| [302, [ %w(a) ], body ] }
    cl = Clogger.new(app, :logger => s, :format => "$request_time")
    @req['rack.multithread'] = true
    status, headers, body = cl.call(@req)
    assert cl.reentrant?
  end

  def test_clogger_auto_reentrant_false
    s = ''
    body = []
    app = lambda { |env| [302, [ %w(a) ], body ] }
    cl = Clogger.new(app, :logger => s, :format => "$request_time")
    @req['rack.multithread'] = false
    status, headers, body = cl.call(@req)
    assert ! cl.reentrant?
  end

  def test_clogger_auto_reentrant_forced_true
    s = ''
    body = []
    app = lambda { |env| [302, [ %w(a) ], body ] }
    o = { :logger => s, :format => "$request_time", :reentrant => true }
    cl = Clogger.new(app, o)
    @req['rack.multithread'] = false
    status, headers, body = cl.call(@req)
    assert cl.reentrant?
  end

  def test_clogger_auto_reentrant_forced_false
    s = ''
    body = []
    app = lambda { |env| [302, [ %w(a) ], body ] }
    o = { :logger => s, :format => "$request_time", :reentrant => false }
    cl = Clogger.new(app, o)
    @req['rack.multithread'] = true
    status, headers, body = cl.call(@req)
    assert ! cl.reentrant?
  end

  def test_invalid_status
    s = []
    body = []
    app = lambda { |env| [ env["force.status"], [ %w(a b) ], body ] }
    o = { :logger => s, :format => "$status" }
    cl = Clogger.new(app, o)
    status, headers, body = cl.call(@req.merge("force.status" => -1))
    assert_equal -1, status
    assert_equal "-\n", s.last
    status, headers, body = cl.call(@req.merge("force.status" => 1000))
    assert_equal 1000, status
    assert_equal "-\n", s.last
    u64_max = 0xffffffffffffffff
    status, headers, body = cl.call(@req.merge("force.status" => u64_max))
    assert_equal u64_max, status
    assert_equal "-\n", s.last
  end

  # so we don't  care about the portability of this test
  # if it doesn't leak on Linux, it won't leak anywhere else
  # unless your C compiler or platform is otherwise broken
  LINUX_PROC_PID_STATUS = "/proc/self/status"
  def test_memory_leak
    app = lambda { |env| [ 0, {}, [] ] }
    clogger = Clogger.new(app, :logger => $stderr)
    match_rss = /^VmRSS:\s+(\d+)/
    if File.read(LINUX_PROC_PID_STATUS) =~ match_rss
      before = $1.to_i
      1000000.times { clogger.dup }
      File.read(LINUX_PROC_PID_STATUS) =~ match_rss
      after = $1.to_i
      diff = after - before
      assert(diff < 10000, "memory grew more than 10M: #{diff}")
    end
  end if RUBY_PLATFORM =~ /linux/ && File.readable?(LINUX_PROC_PID_STATUS)

  def test_path_open_file
    tmp = Tempfile.new('test_clogger')
    app = lambda { |env| [ 200, {}, [] ] }
    app = Clogger.new(app, :format => '$status', :path => tmp.path)
    assert_kind_of Integer, app.fileno
    assert app.fileno != tmp.fileno
    status, headers, body = app.call(@req)
    assert_equal "200\n", tmp.read
  end

  def test_path_logger_conflict
    tmp = Tempfile.new('test_clogger')
    app = lambda { |env| [ 200, {}, [] ] }
    assert_raises(ArgumentError) {
      Clogger.new(app, :logger=> $stderr, :path => tmp.path)
    }
  end

  def test_request_time
    s = []
    app = lambda { |env| sleep(0.1) ; [302, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$request_time")
    status, headers, body = cl.call(@req)
    assert_nothing_raised { body.each { |x| } ; body.close }
    assert s[-1].to_f >= 0.100
    assert s[-1].to_f <= 0.110
  end

  def test_insanely_long_time_format
    s = []
    app = lambda { |env| [200, [], [] ] }
    fmt = '%Y' * 100
    expect = Time.now.utc.strftime(fmt) << "\n"
    assert_equal 100 * 4 + 1, expect.size
    cl = Clogger.new(app, :logger => s, :format => "$time_utc{#{fmt}}")
    status, headers, body = cl.call(@req)
    assert_equal expect, s[0]
  end

  def test_time_utc
    s = []
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$time_utc")
    status, headers, body = cl.call(@req)
    assert %r!\A\d+/\w+/\d{4}:\d\d:\d\d:\d\d \+0000\n\z! =~ s[0], s.inspect
  end

  def test_time_iso8601
    s = []
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$time_iso8601")
    status, headers, body = cl.call(@req)
    t = Time.parse(s[0])
    assert_equal t.iso8601, s[0].strip
  end

  def test_time_iso8601_pst8pdt
    ENV["TZ"] = "PST8PDT"
    s = []
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$time_iso8601")
    status, headers, body = cl.call(@req)
    t = Time.parse(s[0])
    assert_equal t.iso8601, s[0].strip
  end

  def test_time_iso8601_utc
    ENV["TZ"] = "UTC"
    s = []
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$time_iso8601")
    status, headers, body = cl.call(@req)
    t = Time.parse(s[0])
    assert_equal t.iso8601, s[0].strip
  end

  def test_time_local
    s = []
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$time_local")
    status, headers, body = cl.call(@req)
    t = DateTime.strptime(s[0].strip, @nginx_fmt)
    assert_equal t.strftime(@nginx_fmt), s[0].strip
  end

  def test_time_local_pst8pdt
    orig = ENV["TZ"]
    ENV["TZ"] = "PST8PDT"
    s = []
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$time_local")
    status, headers, body = cl.call(@req)
    t = DateTime.strptime(s[0].strip, @nginx_fmt)
    assert_equal t.strftime(@nginx_fmt), s[0].strip
  end

  def test_time_local_utc
    ENV["TZ"] = "UTC"
    s = []
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => "$time_local")
    status, headers, body = cl.call(@req)
    t = DateTime.strptime(s[0].strip, @nginx_fmt)
    assert_equal t.strftime(@nginx_fmt), s[0].strip
  end

  def test_method_missing
    s = []
    body = []
    def body.foo_bar(foo)
      [ foo.to_s ]
    end
    def body.noargs
      :hello
    end
    def body.omg(&block)
      yield :PONIES
    end
    app = lambda { |env| [200, [], body ] }
    cl = Clogger.new(app, :logger => s, :format => '$body_bytes_sent')
    status, headers, body = cl.call(@req)
    assert_nothing_raised do
      body.each { |x| s << x }
      body.close
    end
    assert_equal "0\n", s[0], s.inspect
    assert_kind_of Clogger, body
    assert_equal %w(1), body.foo_bar(1)
    assert_equal :hello, body.noargs
    body.omg { |x| s << x }
    assert_equal :PONIES, s[1]
    assert_equal 2, s.size
  end

  def test_full_uri
    s = []
    format = '"$request_method ' \
             '$env{rack.url_scheme}://$http_host$request_uri $http_version"'
    app = lambda { |env| [200, [], [] ] }
    cl = Clogger.new(app, :logger => s, :format => format)
    @req["HTTP_HOST"] = "example.com"
    status, headers, body = cl.call(@req)
    expect = "\"GET http://example.com/hello?goodbye=true HTTP/1.0\"\n"
    assert_equal [ expect ], s
  end

  def test_lint_error_wrapper
    require 'rack/lobster'
    @req["SERVER_NAME"] = "FOO"
    @req["SERVER_PORT"] = "666"
    @req["rack.version"] = [1,1]
    @req["rack.multithread"] = true
    @req["rack.multiprocess"] = true
    @req["rack.run_once"] = false
    app = Rack::ContentLength.new(Rack::ContentType.new(Rack::Lobster.new))
    cl = Clogger.new(app, :format => :Combined)
    @req["rack.errors"] = err = StringIO.new
    status, headers, body = r = Rack::Lint.new(cl).call(@req)
    body.each { |x| assert_kind_of String, x.to_str }
    body.close # might raise here
    assert_match(%r{GET /hello}, err.string)
  end
end
