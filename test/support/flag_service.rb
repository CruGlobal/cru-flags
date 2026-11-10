# frozen_string_literal: true

require "socket"

# A real, programmable HTTP/1.1 server for contract tests. Mock-free on
# purpose: 304-handling, header echo, and timeout behavior must exercise the
# real Net::HTTP (design doc §9).
class FlagService
  Request = Struct.new(:method, :path, :headers)

  attr_reader :requests
  attr_accessor :delay

  def initialize(host: "127.0.0.1")
    @host = host
    @requests = []
    @delay = nil
    @responder = ->(_req) { [404, {}, nil] }
    @mutex = Mutex.new
  end

  def start
    @server = TCPServer.new(@host, 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
    self
  end

  def url = "http://#{url_host}:#{@port}/flags/test/production"

  # An IPv6 literal has to be bracketed inside a URL's authority, which is
  # exactly the shape that makes URI#host (brackets kept) the wrong thing to
  # hand to Net::HTTP.
  def url_host = @host.include?(":") ? "[#{@host}]" : @host

  def respond_with(status:, body: nil, headers: {})
    @mutex.synchronize { @responder = ->(_req) { [status, headers, body] } }
  end

  def respond(&block)
    @mutex.synchronize { @responder = block }
  end

  def stop
    @server&.close
    @thread&.join(2)
  end

  private

  def accept_loop
    loop do
      begin
        socket = @server.accept
      rescue IOError, Errno::EBADF
        break # listener closed by #stop
      end
      handle(socket)
    rescue
      next # one bad connection must not stop the server
    end
  end

  def handle(socket)
    request_line = socket.gets or return
    method, path, = request_line.split(" ", 3)
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip if value
    end
    request = Request.new(method:, path:, headers:)
    responder = @mutex.synchronize { @responder }
    @requests << request
    sleep(@delay) if @delay
    status, response_headers, body = responder.call(request)
    write_response(socket, status, response_headers, body)
  ensure
    socket&.close
  end

  def write_response(socket, status, headers, body)
    socket.write "HTTP/1.1 #{status} X\r\n"
    headers.each { |k, v| socket.write "#{k}: #{v}\r\n" }
    socket.write "Connection: close\r\n"
    if body.respond_to?(:call)
      # Streaming body: the responder supplies its own Content-Length header
      # and writes the payload incrementally, so a test can observe how much
      # of it the client actually consumed before hanging up.
      socket.write "\r\n"
      body.call(socket)
    else
      socket.write "Content-Length: #{body ? body.bytesize : 0}\r\n\r\n"
      socket.write(body) if body
    end
  end
end
