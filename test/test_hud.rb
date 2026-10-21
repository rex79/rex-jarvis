require "minitest/autorun"
require "tmpdir"
require "json"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("personal")
ENV["JARVIS_WORK_DIR"] = Dir.mktmpdir("work")
require_relative "../lib/hud/server"
require_relative "../lib/dispatcher"

class HudServerTest < Minitest::Test
  TOKEN = "t" * 48

  class FakeDispatcher
    attr_reader :texts

    def initialize = @texts = []

    def handle(text)
      @texts << text
      Dispatcher::Reply.new("personale · test", "risposta a #{text}")
    end
  end

  class FakeMusic
    attr_reader :actions

    def initialize = @actions = []

    def control(action, *_, **_)
      @actions << action
      "Musica: #{action}"
    end

    def now_playing = { app: "Spotify", state: "in pausa" }
  end

  class FakeStatus
    def snapshot = { host: "test", privacy: { local: true } }
  end

  def setup
    @dispatcher = FakeDispatcher.new
    @music = FakeMusic.new
    @server = HudServer.new(port: 7777, dispatcher: @dispatcher, status: FakeStatus.new, music: @music, token: TOKEN)
  end

  def headers(extra = {})
    { "host" => "localhost:7777", "x-jarvis-token" => TOKEN, "origin" => "http://localhost:7777" }.merge(extra)
  end

  def test_page_contains_the_token_and_strict_csp_assets
    r = @server.route("GET", "/", { "host" => "127.0.0.1:7777" }, "")
    assert_equal 200, r.status
    assert_includes r.body, %(content="#{TOKEN}")
    refute_includes r.body, "{{TOKEN}}"
    refute_match(/<script>(?!<\/script>)/, r.body, "niente script inline")
    assert_equal 200, @server.route("GET", "/app.js", headers, "").status
    assert_equal 200, @server.route("GET", "/app.css", headers, "").status
  end

  def test_foreign_host_is_rejected_even_with_token_dns_rebinding
    %w[evil.example:7777 localhost:8080 192.168.1.5:7777].each do |host|
      assert_equal 403, @server.route("GET", "/api/status", headers("host" => host), "").status, host
      assert_equal 403, @server.route("GET", "/", headers("host" => host), "").status, host
    end
  end

  def test_api_requires_the_exact_token
    assert_equal 403, @server.route("GET", "/api/status", headers("x-jarvis-token" => nil), "").status
    assert_equal 403, @server.route("GET", "/api/status", headers("x-jarvis-token" => "sbagliato"), "").status
    assert_equal 403, @server.route("GET", "/api/status", headers("x-jarvis-token" => TOKEN.sub(/.\z/, "x")), "").status
    assert_equal 200, @server.route("GET", "/api/status", headers, "").status
  end

  def test_post_from_another_origin_is_rejected
    r = @server.route("POST", "/api/ask", headers("origin" => "https://evil.example"), '{"text":"pausa"}')
    assert_equal 403, r.status
    assert_empty @dispatcher.texts
  end

  def test_ask_goes_through_the_dispatcher
    r = @server.route("POST", "/api/ask", headers, JSON.generate(text: "  riprendi la musica  "))
    assert_equal 200, r.status
    assert_equal ["riprendi la musica"], @dispatcher.texts
    assert_equal "personale · test", JSON.parse(r.body)["label"]
  end

  def test_bad_requests_get_clear_errors
    assert_equal 422, @server.route("POST", "/api/ask", headers, '{"text":"   "}').status
    assert_equal 422, @server.route("POST", "/api/ask", headers, "non json").status
    assert_equal 422, @server.route("POST", "/api/ask", headers, JSON.generate(text: "a" * 2001)).status
    assert_equal 404, @server.route("GET", "/../lib/config.rb", headers, "").status
  end

  def test_music_endpoint_allows_only_basic_actions
    assert_equal 200, @server.route("POST", "/api/music", headers, '{"action":"pause"}').status
    assert_equal 422, @server.route("POST", "/api/music", headers, '{"action":"playlist"}').status
    assert_equal ["pause"], @music.actions
  end
end

class MusicNowPlayingTest < Minitest::Test
  def test_parses_state_track_and_artist
    np = Music.now_playing(app: "spotify", runner: ->(_, argv) { "playing\nBleed It Out\nLinkin Park" if argv == ["Spotify"] })
    assert_equal({ app: "Spotify", state: "in riproduzione", track: "Bleed It Out", artist: "Linkin Park" }, np)
    assert_equal "chiusa", Music.now_playing(app: "Music", runner: ->(*) { "closed" })[:state]
  end

  def test_app_name_is_passed_as_argument_not_in_the_script
    script = nil
    Music.now_playing(app: "Spotify", runner: ->(s, _) { script = s; "stopped" })
    refute_includes script, "Spotify"
  end
end

class HudStatusTest < Minitest::Test
  def test_a_failing_panel_does_not_break_the_others
    music = Object.new
    def music.now_playing = raise(Music::Error, "permesso negato")
    snap = HudStatus.new(music: music, ollama_url: "http://127.0.0.1:1").snapshot
    assert_equal({ error: "permesso negato" }, snap[:music])
    assert_equal false, snap[:ollama][:online]
    assert snap[:privacy][:local]
    assert_kind_of Integer, snap[:system][:ram_gb]
  end

  def test_privacy_flag_reflects_a_remote_ollama
    refute HudStatus.new(ollama_url: "http://192.168.1.10:11434").privacy[:local]
  end

  def test_digest_panel_reads_the_latest_digest
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "2026-10-20.md"), "# Vecchio\n\n## 1. Vecchia\nFonte: X · [link](https://a.com/1)\n\nTesto.\n")
      File.write(File.join(dir, "2026-10-21.md"), "# Nuovo\n\n## 1. Nuova notizia\nFonte: Anthropic · [link](https://a.com/2)\nCategoria: Ufficiali\n\nTesto.\n")
      digest = HudStatus.new(digest_dir: dir).digest
      assert_equal "2026-10-21", digest[:date]
      assert_equal [{ title: "Nuova notizia", source: "Anthropic", category: "Ufficiali", url: "https://a.com/2" }], digest[:items]
    end
  end
end
