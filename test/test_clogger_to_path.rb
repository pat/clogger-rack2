# -*- encoding: binary -*-
$stderr.sync = $stdout.sync = true
require "test/unit"
require "date"
require "stringio"
require "rack"
require "clogger"

class MyBody < Struct.new(:to_path, :closed)
  def each(&block)
    raise RuntimeError, "each should never get called"
  end

  def close
    self.closed = true
  end
end

class TestCloggerToPath < Test::Unit::TestCase

  def setup
    @req = {
      "REQUEST_METHOD" => "GET",
      "HTTP_VERSION" => "HTTP/1.0",
      "HTTP_USER_AGENT" => 'echo and socat \o/',
      "PATH_INFO" => "/",
      "QUERY_STRING" => "",
      "rack.errors" => $stderr,
      "rack.input" => File.open('/dev/null', 'rb'),
      "REMOTE_ADDR" => '127.0.0.1',
    }
  end

  def check_body(body)
    assert body.respond_to?(:to_path)
    assert body.respond_to?("to_path")

    assert ! body.respond_to?(:to_Path)
    assert ! body.respond_to?("to_Path")
  end

  def test_wraps_to_path
    logger = StringIO.new
    tmp = Tempfile.new('')
    b = nil
    app = Rack::Builder.new do
      tmp.syswrite(' ' * 365)
      h = {
        'Content-Length' => '0',
        'Content-Type' => 'text/plain',
      }
      use Clogger,
        :logger => logger,
        :reentrant => true,
        :format => '$body_bytes_sent $status'
      run lambda { |env| [ 200, h, b = MyBody.new(tmp.path) ] }
    end.to_app

    status, headers, body = app.call(@req)
    assert_instance_of(Clogger, body)
    check_body(body)
    assert logger.string.empty?
    assert_equal tmp.path, body.to_path
    body.close
    assert b.closed, "close passed through"
    assert_equal "365 200\n", logger.string
  end

  def test_wraps_to_path_dev_fd
    logger = StringIO.new
    tmp = Tempfile.new('')
    b = nil
    app = Rack::Builder.new do
      tmp.syswrite(' ' * 365)
      h = {
        'Content-Length' => '0',
        'Content-Type' => 'text/plain',
      }
      use Clogger,
        :logger => logger,
        :reentrant => true,
        :format => '$body_bytes_sent $status'
      run lambda { |env| [ 200, h, b = MyBody.new("/dev/fd/#{tmp.fileno}") ] }
    end.to_app

    status, headers, body = app.call(@req)
    assert_instance_of(Clogger, body)
    check_body(body)
    assert logger.string.empty?
    assert_equal "/dev/fd/#{tmp.fileno}", body.to_path
    body.close
    assert b.closed
    assert_equal "365 200\n", logger.string
  end

  def test_wraps_to_path_to_io
    logger = StringIO.new
    tmp = Tempfile.new('')
    def tmp.to_io
      @to_io_called = super
    end
    def tmp.to_path
      path
    end
    app = Rack::Builder.new do
      tmp.syswrite(' ' * 365)
      tmp.sysseek(0)
      h = {
        'Content-Length' => '0',
        'Content-Type' => 'text/plain',
      }
      use Clogger,
        :logger => logger,
        :reentrant => true,
        :format => '$body_bytes_sent $status'
      run lambda { |env| [ 200, h, tmp ] }
    end.to_app

    status, headers, body = app.call(@req)
    assert_instance_of(Clogger, body)
    check_body(body)

    assert_equal tmp.path, body.to_path
    assert_nothing_raised { body.to_io }
    assert_kind_of IO, tmp.instance_variable_get(:@to_io_called)
    assert logger.string.empty?
    assert ! tmp.closed?
    body.close
    assert tmp.closed?
    assert_equal "365 200\n", logger.string
  end

  def test_does_not_wrap_to_path
    logger = StringIO.new
    app = Rack::Builder.new do
      h = {
        'Content-Length' => '3',
        'Content-Type' => 'text/plain',
      }
      use Clogger,
        :logger => logger,
        :reentrant => true,
        :format => '$body_bytes_sent $status'
      run lambda { |env| [ 200, h, [ "hi\n" ] ] }
    end.to_app
    status, headers, body = app.call(@req)
    assert_instance_of(Clogger, body)
    assert ! body.respond_to?(:to_path)
    assert ! body.respond_to?("to_path")
    assert logger.string.empty?
    body.close
    assert ! logger.string.empty?
  end

end
