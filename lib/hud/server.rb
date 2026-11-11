require "socket"
require "json"
require "securerandom"
require_relative "status"
require_relative "pairing"
require_relative "tls"
require_relative "../modules"
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
# Con JARVIS_HUD_TLS risponde in HTTPS (vedi HudTls): al tablet serve per usare il microfono.
# I moduli accesi (lib/modules.rb) aggiungono i loro file e le loro API sotto /modules e /api/modules.
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
                 bind: "127.0.0.1", hosts: %w[localhost 127.0.0.1], pairing: nil, modules: Modules.none, tls: nil)
    @port = port
    @modules = modules
    @tls = tls
    @bind = bind
    @hosts = hosts.map(&:downcase)
    @pairing = pairing
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
      pairing: HudPairing.new, status: HudStatus.new(personal: true) }
      .then { |options| Config::HUD_TLS ? options.merge(tls: HudTls.new(hosts: options[:hosts])) : options }
  end

  def start
    $stdout.sync = true
    server = TCPServer.new(@bind, @port)
    server = @tls.wrap(server) if @tls
    where = @pairing ? "rete di casa, solo dispositivi abbinati" : "solo questo computer"
    puts "🤖 Jarvis HUD su #{scheme}://#{@pairing ? @hosts.last : 'localhost'}:#{@port} (#{where}). Ctrl+C per fermarlo."
    puts "   moduli: #{@modules.names.join(', ')}" unless @modules.empty?
    @modules.start
    loop do
      Thread.new(server.accept) { |client| @tls ? serve_tls(client) : serve(client) }
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

  # Con HTTPS la stretta di mano avviene qui, nel thread del client: uno che non si fida ancora del
  # certificato, o che parla HTTP alla porta HTTPS, viene chiuso senza disturbare gli altri.
  def serve_tls(client)
    serve(@tls.handshake(client))
  rescue OpenSSL::SSL::SSLError, SystemCallError
    nil
  end

  # Logica pura (testabile senza socket): metodo, percorso, header in minuscolo, corpo.
  def route(method, path, headers, body)
    return Response.new(403, "text/plain", "host non consentito") unless allowed_host?(headers["host"])

    path = path.to_s.split("?").first
    case [method, path]
    when ["GET", "/"] then page
    when ["GET", "/app.css"], ["GET", "/app.js"] then asset(path)
    when ["POST", "/api/pair"] then @pairing ? pair(headers, body) : Response.new(404, "text/plain", "non trovato")
    when ["GET", "/api/status"] then api(headers) { @status.snapshot.merge(copilot_active: copilot_active?, modules: @modules.status) }
    when ["POST", "/api/ask"] then api(headers, post: true) { ask(parse(body)["text"]) }
    when ["POST", "/api/music"] then api(headers, post: true) { music(parse(body)) }
    else module_route(method, path, headers, body) || Response.new(404, "text/plain", "non trovato")
    end
  end

  private

  def scheme = @tls ? "https" : "http"

  # /modules/<nome>/hud.js|hud.css (file del modulo) e /api/modules/<nome>/<azione> (le sue API, con token).
  def module_route(method, path, headers, body)
    if method == "GET" && (m = path.match(%r{\A/modules/([a-z0-9_]+)/(hud\.(?:js|css))\z})) && (file = @modules.asset(m[1], m[2]))
      return Response.new(200, TYPES[File.extname(file)], File.read(file, encoding: "UTF-8"))
    end

    m = path.match(%r{\A/api/modules/([a-z0-9_]+)(?:/([a-z0-9_]+))?\z}) or return nil
    mod = @modules[m[1]] or return nil
    api(headers, post: method == "POST") { mod.api(method, m[2].to_s, body, headers) }
  end

  def allowed_host?(host)
    @hosts.map { |h| "#{h}:#{@port}" }.include?(host.to_s.downcase)
  end

  def allowed_origin?(origin)
    origin.nil? || @hosts.map { |h| "#{scheme}://#{h}:#{@port}" }.include?(origin.downcase)
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
    styles = @modules.assets("hud.css").map { |name| %(<link rel="stylesheet" href="/modules/#{name}/hud.css">\n) }.join
    scripts = @modules.assets("hud.js").map { |name| %(<script src="/modules/#{name}/hud.js"></script>\n) }.join
    html = html.sub("</head>") { "#{styles}</head>" }.sub("</body>") { "#{scripts}</body>" }
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
    raise "corpo troppo grande" if length > max_body(m[2])

    [m[1], m[2], headers, length.positive? ? client.read(length) : ""]
  end

  # Le API di un modulo possono accettare corpi più grandi (es. l'audio della voce).
  def max_body(path)
    name = path.to_s[%r{\A/api/modules/([a-z0-9_]+)}, 1]
    (name && @modules[name]&.max_body) || MAX_BODY
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
