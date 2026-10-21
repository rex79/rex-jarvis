require "socket"
require "json"
require "securerandom"
require_relative "status"
require_relative "../tools/music"

# Server HTTP minimo per la dashboard, solo libreria standard. Anche se ascolta solo su
# 127.0.0.1, una pagina web qualsiasi aperta nel browser potrebbe provare a mandargli
# comandi: per questo
#   - accetta solo Host localhost/127.0.0.1 sulla sua porta (difesa dal DNS rebinding);
#   - le API richiedono un token casuale generato a ogni avvio e inserito nella pagina;
#   - le POST con un Origin diverso dal suo vengono rifiutate;
#   - la Content Security Policy permette solo risorse servite da lui stesso.
class HudServer
  ASSETS = File.expand_path("../../hud", __dir__)
  TYPES = { ".html" => "text/html; charset=utf-8", ".css" => "text/css; charset=utf-8",
            ".js" => "text/javascript; charset=utf-8" }.freeze
  CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
  MAX_BODY = 16_384

  Response = Struct.new(:status, :type, :body)

  attr_reader :token, :port

  def initialize(port: 7777, dispatcher: nil, status: HudStatus.new, music: Music, token: SecureRandom.hex(24))
    @port = port
    @dispatcher = dispatcher
    @status = status
    @music = music
    @token = token
    @lock = Mutex.new # l'agente tiene una conversazione: un comando alla volta
  end

  def start
    $stdout.sync = true
    server = TCPServer.new("127.0.0.1", @port)
    puts "🤖 Jarvis HUD su http://localhost:#{@port} (solo questo computer). Ctrl+C per fermarlo."
    loop do
      Thread.new(server.accept) { |client| serve(client) }
    end
  end

  def serve(client)
    method, path, headers, body = read_request(client)
    respond(client, method ? route(method, path, headers, body) : Response.new(400, "text/plain", "richiesta non valida"))
  rescue StandardError => e
    respond(client, Response.new(500, "text/plain", "errore: #{e.message[0, 200]}"))
  ensure
    client.close
  end

  # Logica pura (testabile senza socket): metodo, percorso, header in minuscolo, corpo.
  def route(method, path, headers, body)
    return Response.new(403, "text/plain", "host non consentito") unless allowed_host?(headers["host"])

    path = path.to_s.split("?").first
    case [method, path]
    when ["GET", "/"] then page
    when ["GET", "/app.css"], ["GET", "/app.js"] then asset(path)
    when ["GET", "/api/status"] then api(headers) { @status.snapshot }
    when ["POST", "/api/ask"] then api(headers, post: true) { ask(parse(body)["text"]) }
    when ["POST", "/api/music"] then api(headers, post: true) { music(parse(body)) }
    else Response.new(404, "text/plain", "non trovato")
    end
  end

  private

  def allowed_host?(host)
    ["localhost:#{@port}", "127.0.0.1:#{@port}"].include?(host.to_s.downcase)
  end

  def allowed_origin?(origin)
    origin.nil? || ["http://localhost:#{@port}", "http://127.0.0.1:#{@port}"].include?(origin.downcase)
  end

  def api(headers, post: false)
    return Response.new(403, "application/json", '{"error":"token mancante o errato"}') unless valid_token?(headers["x-jarvis-token"])
    return Response.new(403, "application/json", '{"error":"origine non consentita"}') if post && !allowed_origin?(headers["origin"])

    Response.new(200, "application/json", JSON.generate(yield))
  rescue ArgumentError, Music::Error => e
    Response.new(422, "application/json", JSON.generate(error: e.message))
  end

  def valid_token?(given)
    !given.to_s.empty? && given.bytesize == @token.bytesize &&
      given.bytes.zip(@token.bytes).sum { |a, b| a ^ b }.zero? # confronto a tempo costante
  end

  def parse(body)
    data = JSON.parse(body.to_s)
    raise ArgumentError, "corpo JSON non valido" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise ArgumentError, "corpo JSON non valido"
  end

  def ask(text)
    text = text.to_s.strip
    raise ArgumentError, "comando vuoto" if text.empty?
    raise ArgumentError, "comando troppo lungo" if text.length > 2000

    reply = @lock.synchronize { @dispatcher.handle(text) }
    { label: reply.label, text: reply.text.to_s }
  end

  def music(data)
    action = data["action"].to_s
    raise ArgumentError, "azione non consentita" unless %w[play pause next previous].include?(action)

    { result: @music.control(action), now: @music.now_playing }
  end

  def page
    html = File.read(File.join(ASSETS, "index.html"), encoding: "UTF-8").sub("{{TOKEN}}", @token)
    Response.new(200, TYPES[".html"], html)
  end

  def asset(path)
    file = File.join(ASSETS, File.basename(path))
    Response.new(200, TYPES[File.extname(file)], File.read(file, encoding: "UTF-8"))
  end

  def read_request(client)
    line = client.gets&.chomp
    return [] unless line && (m = line.match(%r{\A(GET|POST) (\S+) HTTP/1\.[01]\z}))

    headers = {}
    100.times do
      header = client.gets&.chomp
      break if header.nil? || header.empty?

      key, value = header.split(":", 2)
      headers[key.strip.downcase] = value.to_s.strip if value
    end
    length = headers["content-length"].to_i
    raise "corpo troppo grande" if length > MAX_BODY

    [m[1], m[2], headers, length.positive? ? client.read(length) : ""]
  end

  def respond(client, response)
    body = response.body.to_s.b
    reason = { 200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
               422 => "Unprocessable Entity", 500 => "Internal Server Error" }[response.status]
    client.write "HTTP/1.1 #{response.status} #{reason}\r\n" \
                 "Content-Type: #{response.type}\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n" \
                 "Referrer-Policy: no-referrer\r\nContent-Security-Policy: #{CSP}\r\nConnection: close\r\n\r\n"
    client.write body
  end
end
