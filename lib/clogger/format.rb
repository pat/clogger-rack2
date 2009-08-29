# -*- encoding: binary -*-

class Clogger

  # predefined log formats in wide use
  module Format
    # common log format used by Apache:
    # http://httpd.apache.org/docs/2.2/logs.html
    Common = "$remote_addr - $remote_user [$time_local] " \
             '"$request" $status $response_length'.freeze

    # combined log format used by Apache:
    # http://httpd.apache.org/docs/2.2/logs.html
    Combined = %Q|#{Common} "$http_referer" "$http_user_agent"|.freeze

    # combined log format used by nginx:
    # http://wiki.nginx.org/NginxHttpLogModule
    NginxCombined = Combined.gsub(/response_length/, 'body_bytes_sent').freeze

    # log format used by Rack 1.0
    Rack_1_0 = "$ip - $remote_user [$time_local{%d/%b/%Y %H:%M:%S}] " \
               '"$request" $status $response_length $request_time{4}'.freeze
  end

end
