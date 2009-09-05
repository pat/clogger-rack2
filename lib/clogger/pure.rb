# -*- encoding: binary -*-
# :stopdoc:

require 'rack'

# Not at all optimized for performance, this was written based on
# the original C extension code so it's not very Ruby-ish...
class Clogger

  def initialize(app, opts = {})
    @app = app
    @logger = opts[:logger]
    (@logger.sync = true) rescue nil
    @fmt_ops = compile_format(opts[:format] || Format::Common, opts)
    @wrap_body = need_wrap_body?(@fmt_ops)
    @reentrant = nil
    @body_bytes_sent = 0
  end

  def call(env)
    @start = Time.now
    resp = @app.call(env)
    unless resp.instance_of?(Array) && resp.size == 3
      log(env, 500, {})
      raise TypeError, "app response not a 3 element Array: #{resp.inspect}"
    end
    status, headers, body = resp
    headers = Rack::Utils::HeaderHash.new(headers)
    if wrap_body?
      @reentrant = env['rack.multithread']
      @env, @status, @headers, @body = env, status, headers, body
      return [ status, headers, reentrant? ? self.dup : self ]
    end
    log(env, status, headers)
    [ status, headers, body ]
  end

  def each
    @body_bytes_sent = 0
    @body.each do |part|
      @body_bytes_sent += part.size
      yield part
    end
    ensure
      log(@env, @status, @headers)
  end

  def close
    @body.close
  end

  def reentrant?
    @reentrant
  end

  def wrap_body?
    @wrap_body
  end

  def fileno
    @logger.fileno rescue nil
  end

private

  def byte_xs(s)
    s = s.dup
    s.force_encoding(Encoding::BINARY) if defined?(Encoding::BINARY)
    s.gsub!(/(['"\x00-\x1f])/) { |x| "\\x#{$1.unpack('H2').first.upcase}" }
    s
  end

  SPECIAL_RMAP = SPECIAL_VARS.inject([]) { |ary, (k,v)| ary[v] = k; ary }

  def request_uri(env)
    ru = env['REQUEST_URI'] and return byte_xs(ru)
    qs = env['QUERY_STRING']
    qs.empty? or qs = "?#{byte_xs(qs)}"
    "#{byte_xs(env['PATH_INFO'])}#{qs}"
  end

  def special_var(special_nr, env, status, headers)
    case SPECIAL_RMAP[special_nr]
    when :body_bytes_sent
      @body_bytes_sent.to_s
    when :status
      status = status.to_i
      status >= 100 && status <= 999 ? ('%03d' % status) : '-'
    when :request
      version = env['HTTP_VERSION'] and version = " #{byte_xs(version)}"
      qs = env['QUERY_STRING']
      qs.empty? or qs = "?#{byte_xs(qs)}"
      "#{env['REQUEST_METHOD']} " \
        "#{request_uri(env)}#{version}"
    when :request_uri
      request_uri(env)
    when :request_length
      env['rack.input'].size.to_s
    when :response_length
      @body_bytes_sent == 0 ? '-' : @body_bytes_sent.to_s
    when :ip
      xff = env['HTTP_X_FORWARDED_FOR'] and return byte_xs(xff)
      env['REMOTE_ADDR'] || '-'
    when :pid
      $$.to_s
    else
      raise "EDOOFUS #{special_nr}"
    end
  end

  def time_format(sec, usec, format, div)
    format % [ sec, usec / div ]
  end

  def log(env, status, headers)
    (@logger || env['rack.errors']) << @fmt_ops.map { |op|
      case op[0]
      when OP_LITERAL; op[1]
      when OP_REQUEST; byte_xs(env[op[1]] || "-")
      when OP_RESPONSE; byte_xs(headers[op[1]] || "-")
      when OP_SPECIAL; special_var(op[1], env, status, headers)
      when OP_EVAL; eval(op[1]).to_s rescue "-"
      when OP_TIME_LOCAL; Time.now.strftime(op[1])
      when OP_TIME_UTC; Time.now.utc.strftime(op[1])
      when OP_REQUEST_TIME
        t = Time.now - @start
        time_format(t.to_i, (t - t.to_i) * 1000000, op[1], op[2])
      when OP_TIME
        t = Time.now
        time_format(t.sec, t.usec, op[1], op[2])
      when OP_COOKIE
        (env['rack.request.cookie_hash'][op[1]] rescue "-") || "-"
      else
        raise "EDOOFUS #{op.inspect}"
      end
    }.join('')
  end

end
