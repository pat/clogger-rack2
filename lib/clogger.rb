# -*- encoding: binary -*-
class Clogger
  VERSION = '0.0.2'

  OP_LITERAL = 0
  OP_REQUEST = 1
  OP_RESPONSE = 2
  OP_SPECIAL = 3
  OP_EVAL = 4
  OP_TIME_LOCAL = 5
  OP_TIME_UTC = 6
  OP_REQUEST_TIME = 7
  OP_TIME = 8
  OP_COOKIE = 9

  # support nginx variables that are less customizable than our own
  ALIASES = {
    '$request_time' => '$request_time{3}',
    '$time_local' => '$time_local{%d/%b/%Y:%H:%M:%S %z}',
    '$msec' => '$time{3}',
    '$usec' => '$time{6}',
  }

  SPECIAL_VARS = {
    :body_bytes_sent => 0,
    :status => 1,
    :request => 2, # REQUEST_METHOD PATH_INFO?QUERY_STRING HTTP_VERSION
    :request_length => 3, # env['rack.input'].size
    :response_length => 4, # like body_bytes_sent, except "-" instead of "0"
    :ip => 5, # HTTP_X_FORWARDED_FOR || REMOTE_ADDR || -
    :pid => 6, # getpid()
    :request_uri => 7
  }

private

  CGI_ENV = Regexp.new('\A\$(' <<
      %w(remote_addr remote_ident remote_user
         path_info query_string script_name
         server_name server_port).join('|') << ')\z').freeze

  SCAN = /([^$]*)(\$+(?:env\{\w+(?:\.[\w\.]+)?\}|
                        e\{[^\}]+\}|
                        (?:request_)?time\{\d+\}|
                        time_(?:utc|local)\{[^\}]+\}|
                        \w*))?([^$]*)/x

  def compile_format(str)
    rv = []
    str.scan(SCAN).each do |pre,tok,post|
      rv << [ OP_LITERAL, pre ] if pre && pre != ""

      unless tok.nil?
        if tok.sub!(/\A(\$+)\$/, '$')
          rv << [ OP_LITERAL, $1.dup ]
        end

        compat = ALIASES[tok] and tok = compat

        case tok
        when /\A(\$*)\z/
          rv << [ OP_LITERAL, $1.dup ]
        when /\A\$env\{(\w+(?:\.[\w\.]+))\}\z/
          rv << [ OP_REQUEST, $1.freeze ]
        when /\A\$e\{([^\}]+)\}\z/
          rv << [ OP_EVAL, $1.dup ]
        when /\A\$cookie_(\w+)\z/
          rv << [ OP_COOKIE, $1.dup.freeze ]
        when CGI_ENV, /\A\$(http_\w+)\z/
          rv << [ OP_REQUEST, $1.upcase.freeze ]
        when /\A\$sent_http_(\w+)\z/
          rv << [ OP_RESPONSE, $1.downcase.tr('_','-').freeze ]
        when /\A\$time_local\{([^\}]+)\}\z/
          rv << [ OP_TIME_LOCAL, $1.dup ]
        when /\A\$time_utc\{([^\}]+)\}\z/
          rv << [ OP_TIME_UTC, $1.dup ]
        when /\A\$time\{(\d+)\}\z/
          rv << [ OP_TIME, *usec_conv_pair(tok, $1.to_i) ]
        when /\A\$request_time\{(\d+)\}\z/
          rv << [ OP_REQUEST_TIME, *usec_conv_pair(tok, $1.to_i) ]
        else
          tok_sym = tok[1..-1].to_sym
          if special_code = SPECIAL_VARS[tok_sym]
            rv << [ OP_SPECIAL, special_code ]
          else
            raise ArgumentError, "unable to make sense of token: #{tok}"
          end
        end
      end

      rv << [ OP_LITERAL, post ] if post && post != ""
    end

    # auto-append a newline
    last = rv.last or return rv
    op = last.first
    if (op == OP_LITERAL && /\n\z/ !~ last.last) || op != OP_LITERAL
      rv << [ OP_LITERAL, "\n" ]
    end

    rv
  end

  def usec_conv_pair(tok, prec)
    if prec == 0
      [ "%d", 1 ] # stupid...
    elsif prec > 6
      raise ArgumentError, "#{tok}: too high precision: #{prec} (max=6)"
    else
      [ "%d.%0#{prec}d", 10 ** (6 - prec) ]
    end
  end

  def need_response_headers?(fmt_ops)
    fmt_ops.any? { |op| OP_RESPONSE == op[0] }
  end

  def need_wrap_body?(fmt_ops)
    fmt_ops.any? do |op|
      (OP_REQUEST_TIME == op[0]) || (OP_SPECIAL == op[0] &&
        (SPECIAL_VARS[:body_bytes_sent] == op[1] ||
         SPECIAL_VARS[:response_length] == op[1]))
    end
  end

end

require 'clogger/format'

begin
  require 'clogger_ext'
rescue LoadError
  require 'clogger/pure'
end
