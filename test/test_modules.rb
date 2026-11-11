require "minitest/autorun"
require "tmpdir"
require "json"
require "net/http"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("personal")
ENV["JARVIS_WORK_DIR"] = Dir.mktmpdir("work")
require_relative "../lib/modules"
require_relative "../lib/dispatcher"
require_relative "../lib/hud/server"

# Modulo finto: riconosce "ping", offre uno strumento e un'API.
class EchoModule < Modules::Base
  def handle(text) = text.match?(/\Aping\b/i) ? "pong" : nil
  def tools = [Modules.tool("echo_tool", "Ripete", { testo: { type: "string" } }, ["testo"])]
  def call_tool(_name, args) = "eco: #{args['testo']}"
  def prompt = "- echo_tool: ripete."
  def status = { ok: true }
  def max_body = 100_000

  def api(method, path, body, _headers)
    raise ArgumentError, "richiesta non prevista" unless method == "POST" && path == "size"

    { bytes: body.bytesize }
  end
end

class ModulesTest < Minitest::Test
  def set = Modules::Set.new("echo" => EchoModule.new)

  def test_unknown_or_malformed_names_are_refused
    assert_raises(ArgumentError) { Modules.load(["nonesiste"]) }
    assert_raises(ArgumentError) { Modules.load(["../lib/agent"]) }
    assert Modules.load([]).empty?
  end

  def test_real_modules_load_by_name
    modules = Modules.load(%w[dispensa])
    assert_equal %w[dispensa], modules.names
    assert_includes modules.tools.map { |t| t.dig(:function, :name) }, "dispensa_aggiungi"
  end

  def test_only_hud_files_are_served
    modules = Modules.load(%w[dispensa])
    assert modules.asset("dispensa", "hud.js")
    assert_nil modules.asset("dispensa", "dispensa.rb")
    assert_nil modules.asset("altro", "hud.js")
  end

  def test_a_failing_status_does_not_break_the_others
    broken = Class.new(Modules::Base) { def status = raise("rotto") }.new
    status = Modules::Set.new("a" => broken, "echo" => EchoModule.new).status
    assert_equal({ error: "rotto" }, status["a"])
    assert_equal({ ok: true }, status["echo"])
  end
end

class DispatcherModulesTest < Minitest::Test
  class FakeAgent
    attr_reader :context, :asked

    def initialize(context) = (@context = context; @asked = [])

    def ask(text)
      @asked << text
      "agente"
    end
  end

  def dispatcher(forced: nil)
    @agents = {}
    Dispatcher.new(forced: forced, modules: Modules::Set.new("echo" => EchoModule.new),
                   agent_factory: ->(context) { @agents[context.id] = FakeAgent.new(context) })
  end

  def test_module_commands_answer_without_any_model
    reply = dispatcher(forced: "personal").handle("ping")
    assert_equal "personale · echo", reply.label
    assert_equal "pong", reply.text
    assert_empty @agents
    assert_equal "pong", dispatcher.handle("personale: ping").text
  end

  def test_work_never_reaches_a_module
    assert_equal "agente", dispatcher(forced: "work").handle("ping").text
    assert_equal "agente", dispatcher.handle("lavoro: ping").text
    assert_equal "agente", dispatcher.handle("ping sul progetto del cliente").text
    assert_equal [:work], @agents.keys
  end

  def test_personal_agent_gets_module_tools_and_work_agent_does_not
    modules = Modules::Set.new("echo" => EchoModule.new)
    llm = Object.new
    def llm.chat(*, **) = { "message" => { "role" => "assistant", "content" => "ok" } }
    assert_includes Agent.new(Contexts.personal, llm: llm, modules: modules).tool_names, "echo_tool"
    refute_includes Agent.new(Contexts.work, llm: llm, modules: modules).tool_names, "echo_tool"
  end

  def test_agent_runs_a_module_tool
    replies = [{ "role" => "assistant", "tool_calls" => [{ "function" => { "name" => "echo_tool", "arguments" => { "testo" => "ciao" } } }] },
               { "role" => "assistant", "content" => "fatto" }]
    seen = []
    llm = Object.new
    llm.define_singleton_method(:chat) { |messages, **| seen << messages.last; { "message" => replies.shift } }
    agent = Agent.new(Contexts.personal, llm: llm, modules: Modules::Set.new("echo" => EchoModule.new))
    capture_io { assert_equal "fatto", agent.ask("ripeti ciao") }
    assert_equal "eco: ciao", seen.last[:content]
  end
end

class HudModulesTest < Minitest::Test
  TOKEN = "t" * 48

  def setup
    @modules = Modules::Set.new("echo" => EchoModule.new, "dispensa" => Modules.load(%w[dispensa])["dispensa"])
    @server = HudServer.new(port: 7777, token: TOKEN, modules: @modules,
                            status: Struct.new(:x) { def snapshot = { host: "test" } }.new(nil))
  end

  def headers(extra = {})
    { "host" => "localhost:7777", "x-jarvis-token" => TOKEN, "origin" => "http://localhost:7777" }.merge(extra)
  end

  def test_page_loads_module_files_and_status_includes_modules
    page = @server.route("GET", "/", headers, "").body
    assert_includes page, %(<script src="/modules/dispensa/hud.js"></script>)
    assert_includes page, %(<link rel="stylesheet" href="/modules/dispensa/hud.css">)
    refute_includes page, "/modules/echo/" # nessun file hud: niente tag
    assert_equal 200, @server.route("GET", "/modules/dispensa/hud.js", headers, "").status
    assert_equal 404, @server.route("GET", "/modules/dispensa/dispensa.rb", headers, "").status
    assert_equal 404, @server.route("GET", "/modules/voce/hud.js", headers, "").status # modulo non acceso
    assert_equal({ "ok" => true }, JSON.parse(@server.route("GET", "/api/status", headers, "").body)["modules"]["echo"])
  end

  def test_module_api_needs_token_and_origin
    assert_equal 403, @server.route("POST", "/api/modules/echo/size", headers("x-jarvis-token" => "x"), "abc").status
    assert_equal 403, @server.route("POST", "/api/modules/echo/size", headers("origin" => "https://evil.example"), "abc").status
    assert_equal({ "bytes" => 3 }, JSON.parse(@server.route("POST", "/api/modules/echo/size", headers, "abc").body))
    assert_equal 422, @server.route("POST", "/api/modules/echo/altro", headers, "abc").status
    assert_equal 404, @server.route("POST", "/api/modules/spento/size", headers, "abc").status
  end

  def test_only_module_apis_accept_larger_bodies
    assert_equal 100_000, @server.send(:max_body, "/api/modules/echo/size")
    assert_equal HudServer::MAX_BODY, @server.send(:max_body, "/api/ask")
    assert_equal HudServer::MAX_BODY, @server.send(:max_body, "/api/modules/spento/size")
  end
end

class HudTlsTest < Minitest::Test
  def test_certificate_covers_the_hosts_and_is_reused_until_they_change
    Dir.mktmpdir do |dir|
      tls = HudTls.new(hosts: %w[localhost mac-mini 192.168.2.26], dir: dir)
      first = tls.fingerprint
      assert_equal 0o600, File.stat(File.join(dir, "hud_key.pem")).mode & 0o777
      cert = OpenSSL::X509::Certificate.new(File.read(tls.cert_file))
      san = cert.extensions.find { |e| e.oid == "subjectAltName" }.value
      assert_includes san, "DNS:mac-mini"
      assert_includes san, "IP Address:192.168.2.26"
      assert_equal first, HudTls.new(hosts: %w[localhost mac-mini 192.168.2.26], dir: dir).fingerprint
      refute_equal first, HudTls.new(hosts: %w[localhost mac-mini 192.168.2.99], dir: dir).fingerprint
    end
  end

  def test_dashboard_answers_over_https_and_checks_the_https_origin
    Dir.mktmpdir do |dir|
      tls = HudTls.new(hosts: %w[localhost 127.0.0.1], dir: dir)
      tcp = TCPServer.new("127.0.0.1", 0)
      port = tcp.addr[1]
      server = HudServer.new(port: port, token: "t" * 48, tls: tls, status: Struct.new(:x) { def snapshot = { host: "test" } }.new(nil))
      ssl = tls.wrap(tcp)
      thread = Thread.new { 2.times { server.send(:serve_tls, ssl.accept) } }
      plain = TCPSocket.new("127.0.0.1", port) # un client che parla HTTP non deve fermare il server
      plain.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
      plain.close
      http = Net::HTTP.new("localhost", port)
      http.use_ssl = true
      http.ca_file = tls.cert_file
      assert_equal "200", http.get("/").code
      thread.join(5)
      ok = { "host" => "localhost:#{port}", "x-jarvis-token" => "t" * 48 }
      assert_equal 200, server.route("POST", "/api/music", ok.merge("origin" => "https://localhost:#{port}"), "{}").status.then { |s| s == 422 ? 200 : s }
      assert_equal 403, server.route("POST", "/api/music", ok.merge("origin" => "http://localhost:#{port}"), "{}").status
    ensure
      tcp&.close
    end
  end
end
