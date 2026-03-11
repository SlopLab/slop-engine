#!/usr/bin/env ruby

require "securerandom"
require "webrick"

port = Integer(ENV.fetch("PORT", "4567"))
host = ENV.fetch("HOST", "slop-engine.de")
registered_clients = {}

server = WEBrick::HTTPServer.new(
  Port: port,
  BindAddress: host,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

server.mount_proc "/register" do |request, response|
  unless request.request_method == "POST"
    response.status = 405
    response["Content-Type"] = "text/plain"
    response.body = "error=method_not_allowed\n"
    next
  end

  client_id = request.query["client_id"]
  if client_id.nil? || client_id.empty?
    response.status = 400
    response["Content-Type"] = "text/plain"
    response.body = "error=missing_client_id\n"
    next
  end

  token = SecureRandom.hex(16)
  registered_clients[token] = {
    client_id: client_id,
    issued_at: Time.now.utc
  }

  response.status = 200
  response["Content-Type"] = "text/plain"
  response.body = <<~BODY
    status=registered
    client_id=#{client_id}
    token=#{token}
  BODY
end

server.mount_proc "/data" do |request, response|
  auth_header = request["Authorization"]
  token = auth_header&.match(/\ABearer\s+([A-Za-z0-9]+)\z/)&.captures&.first
  client = token && registered_clients[token]

  unless client
    response.status = 401
    response["Content-Type"] = "text/plain"
    response.body = "error=invalid_token\n"
    next
  end

  response.status = 200
  response["Content-Type"] = "text/plain"
  response.body = "SLOPINATOR\n"
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "Listening on http://#{host}:#{port}"
puts "POST /register with client_id=<value> to obtain a token"
puts "GET /data with Authorization: Bearer <token> to access protected data"
server.start
