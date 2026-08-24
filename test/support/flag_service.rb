# frozen_string_literal: true

require "socket"

# A real, programmable HTTP/1.1 server for contract tests. Mock-free on
# purpose: 304-handling, header echo, and timeout behavior must exercise the
# real Net::HTTP (design doc §9).
class FlagService
  Request = Struct.new(:method, :path, :headers)

  attr_reader :requests
  attr_accessor :delay

  def initialize
    @requests = []
    @delay = nil
    @responder = ->(_req) { [404, {}, nil] }
    @mutex = Mutex.new
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
    self
  end

  def url = "http://127.0.0.1:#{@port}/flags/test/production"

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
    socket.write "Content-Length: #{body ? body.bytesize : 0}\r\n\r\n"
    socket.write(body) if body
  end
end
