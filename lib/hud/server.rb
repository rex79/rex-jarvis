require "socket"
require "json"
require "securerandom"
require_relative "status"
require_relative "trading_job"
require_relative "pairing"
require_relative "../tools/music"
require_relative "../tools/copilot"

# Server HTTP minimo per la dashboard, solo libreria standard. Anche se ascolta solo su
# 127.0.0.1, una pagina web qualsiasi aperta nel browser potrebbe provare a mandargli
# comandi: per questo
#   - accetta solo Host localhost/127.0.0.1 sulla sua porta (difesa dal DNS rebinding);
#   - le API richiedono un token casuale generato a ogni avvio e inserito nella pagina;
#   - le POST con un Origin diverso dal suo vengono rifiutate;
#   - la Content Security Policy permette solo risorse servite da lui stesso.
# Con --lan (Mac mini, tablet) ascolta sulla rete di casa e resta nel contesto personale: la pagina
# non contiene più il token e ogni dispositivo si abbina con un codice monouso (vedi HudPairing).
class HudServer
  ASSETS = File.expand_path("../../hud", __dir__)
  TYPES = { ".html" => "text/html; charset=utf-8", ".css" => "text/css; charset=utf-8",
            ".js" => "text/javascript; charset=utf-8" }.freeze
  CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
  MAX_BODY = 16_384

  Response = Struct.new(:status, :type, :body)

  attr_reader :token, :port

  def initialize(port: 7777, dispatcher: nil, status: HudStatus.new, music: Music, token: SecureRandom.hex(24),
                 trading: TradingJob.new, bind: "127.0.0.1", hosts: %w[localhost 127.0.0.1], pairing: nil)
    @port = port
    @bind = bind
    @hosts = hosts.map(&:downcase)
    @pairing = pairing
    @trading = trading
    @dispatcher = dispatcher
    @status = status
    @music = music
    @token = token
    @lock = Mutex.new # l'agente tiene una conversazione: un comando alla volta
  end

  # Opzioni per la rete di casa: gli indirizzi privati e il nome di questa macchina sono gli unici
  # Host accettati, più quelli di JARVIS_HUD_HOSTS (es. il nome Tailscale).
  def self.lan_options
    addresses = Socket.ip_address_list.select(&:ipv4_private?).map(&:ip_address)
    name = Socket.gethostname.split(".").first
    { bind: Config::HUD_BIND, hosts: ["localhost", "127.0.0.1", name, "#{name}.local", *addresses, *Config::HUD_HOSTS].uniq,
      pairing: HudPairing.new, trading: TradingJob.new(remote: TradingLocal), status: HudStatus.new(personal: true) }
  end

  def start
    $stdout.sync = true
    server = TCPServer.new(@bind, @port)
    @trading.sync_later
    where = @pairing ? "rete di casa, solo dispositivi abbinati" : "solo questo computer"
    puts "🤖 Jarvis HUD su http://#{@pairing ? @hosts.last : 'localhost'}:#{@port} (#{where}). Ctrl+C per fermarlo."
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
    when ["POST", "/api/pair"] then @pairing ? pair(headers, body) : Response.new(404, "text/plain", "non trovato")
    when ["GET", "/api/status"]
      api(headers) { @status.snapshot.merge(copilot_active: copilot_active?, trading_job: @trading.state) }
    when ["POST", "/api/trading"] then api(headers, post: true) { @trading.start }
    when ["GET", "/api/trading/note"] then api(headers) { Trading.latest_note || { name: nil, text: "" } }
    when ["POST", "/api/ask"] then api(headers, post: true) { ask(parse(body)["text"]) }
    when ["POST", "/api/music"] then api(headers, post: true) { music(parse(body)) }
    else Response.new(404, "text/plain", "non trovato")
    end
  end

  private

  def allowed_host?(host)
    @hosts.map { |h| "#{h}:#{@port}" }.include?(host.to_s.downcase)
  end

  def allowed_origin?(origin)
    origin.nil? || @hosts.map { |h| "http://#{h}:#{@port}" }.include?(origin.downcase)
  end

  # L'unica API senza token: il codice monouso è la prova di accesso, con tentativi limitati.
  def pair(headers, body)
    return Response.new(403, "application/json", '{"error":"origine non consentita"}') unless allowed_origin?(headers["origin"])

    Response.new(200, "application/json", JSON.generate(token: @pairing.redeem(parse(body)["code"])))
  rescue ArgumentError => e
    Response.new(422, "application/json", JSON.generate(error: e.message))
  end

  def api(headers, post: false)
    return Response.new(403, "application/json", '{"error":"token mancante o errato"}') unless valid_token?(headers["x-jarvis-token"])
    return Response.new(403, "application/json", '{"error":"origine non consentita"}') if post && !allowed_origin?(headers["origin"])

    Response.new(200, "application/json", JSON.generate(yield))
  rescue ArgumentError, Music::Error, Copilot::Error => e
    Response.new(422, "application/json", JSON.generate(error: e.message))
  end

  def copilot_active?
    @dispatcher.respond_to?(:session) && @dispatcher.session.active?
  end

  def valid_token?(given)
    return @pairing.valid?(given) if @pairing

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
    { label: reply.label, text: reply.text.to_s, copilot_active: copilot_active? }
  end

  def music(data)
    action = data["action"].to_s
    raise ArgumentError, "azione non consentita" unless %w[play pause next previous].include?(action)

    { result: @music.control(action), now: @music.now_playing }
  end

  def page
    html = File.read(File.join(ASSETS, "index.html"), encoding: "UTF-8").sub("{{TOKEN}}", @pairing ? "" : @token)
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
