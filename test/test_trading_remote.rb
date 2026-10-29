require "minitest/autorun"
require "tmpdir"
require "json"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
ENV["JARVIS_TRADING_SSH_KEY"] = File.join(Dir.mktmpdir("ssh"), "jarvis_trading").tap { |k| File.write(k, "chiave finta") }
require_relative "../lib/hud/trading_job"
require_relative "../lib/hud/server"

LATEST = { "date" => "2026-10-29", "tickers" => [{ "ticker" => "NVDA", "decision" => "AUMENTA", "summary" => "ok" }] }.freeze

class TradingRemoteTest < Minitest::Test
  def setup
    ENV["JARVIS_TRADING_SSH"] = "rex@192.168.2.26"
    FileUtils.rm_rf(Trading.dir)
  end

  def teardown = ENV.delete("JARVIS_TRADING_SSH")

  def test_host_must_look_like_user_at_host
    assert TradingRemote.configured?
    ["-oProxyCommand=x@y", "rex@", "192.168.2.26", "rex@host;ls"].each do |bad|
      ENV["JARVIS_TRADING_SSH"] = bad
      refute TradingRemote.configured?, bad
    end
    assert_raises(TradingRemote::Error) { TradingRemote.run(runner: ->(_) { flunk "niente ssh" }) }
  end

  def test_run_copies_latest_and_note_locally
    sent = nil
    out = "log qualsiasi\n" + JSON.generate(latest: LATEST, note: { name: "2026-10-29.md", text: "# Analisi" })
    latest = TradingRemote.run(runner: ->(command) { sent = command; out })
    assert_equal "run", sent
    assert_equal "AUMENTA", latest["tickers"][0]["decision"]
    assert_equal LATEST, Trading.latest
    assert_equal "# Analisi", File.read(File.join(Trading.dir, "2026-10-29.md"))
  end

  def test_note_name_cannot_escape_the_folder
    TradingRemote.run(runner: ->(_) { JSON.generate(latest: LATEST, note: { name: "../../evil.md", text: "x" }) })
    assert_equal ["latest.json"], Dir.children(Trading.dir)
  end

  def test_remote_errors_are_reported
    err = assert_raises(TradingRemote::Error) { TradingRemote.run(runner: ->(_) { '{"error":"un\'analisi è già in corso"}' }) }
    assert_match(/già in corso/, err.message)
    assert_raises(TradingRemote::Error) { TradingRemote.latest(runner: ->(_) { "non json" }) }
  end
end

class TradingRemoteCommandTest < Minitest::Test
  def test_only_run_and_latest_are_allowed
    calls = []
    run = -> { calls << :run }
    index = -> { calls << :index }
    assert Trading.remote("run", run: run, index: index).key?(:latest)
    assert_equal %i[run index], calls
    Trading.remote(" latest\n", run: run, index: index)
    assert_equal %i[run index], calls
    ["", "rm -rf ~", "run; ls"].each do |bad|
      assert_raises(Trading::Error) { Trading.remote(bad, run: run, index: index) }
    end
  end

  def test_one_analysis_at_a_time
    lock = File.join(Dir.mktmpdir, "trading.lock")
    Trading.exclusive(lock) do
      assert_raises(Trading::Error) { Trading.exclusive(lock) { flunk "doppia analisi" } }
    end
    assert_equal :ok, Trading.exclusive(lock) { :ok }
  end
end

class TradingJobTest < Minitest::Test
  class FakeRemote
    attr_accessor :configured, :gate, :fail

    def initialize = (@configured = true; @gate = Queue.new)
    def configured? = @configured

    def run
      @gate.pop
      raise TradingRemote::Error, "Mac mini non raggiungibile" if @fail
    end
  end

  def test_runs_once_and_reports_the_outcome
    remote = FakeRemote.new
    job = TradingJob.new(remote: remote)
    assert job.start[:running]
    assert_raises(ArgumentError) { job.start }
    remote.gate << :go
    job.wait
    state = job.state
    refute state[:running]
    assert state[:finished_at]
    assert_nil state[:error]
  end

  def test_errors_and_missing_configuration
    remote = FakeRemote.new
    remote.fail = true
    job = TradingJob.new(remote: remote)
    job.start
    remote.gate << :go
    job.wait
    assert_equal "Mac mini non raggiungibile", job.state[:error]
    remote.configured = false
    assert_raises(ArgumentError) { job.start }
  end

  def test_server_endpoint_needs_token_and_origin
    remote = FakeRemote.new
    job = TradingJob.new(remote: remote)
    server = HudServer.new(port: 7777, token: "t" * 48, trading: job,
                           status: Struct.new(:x) { def snapshot = { host: "test" } }.new(nil))
    ok = { "host" => "localhost:7777", "x-jarvis-token" => "t" * 48, "origin" => "http://localhost:7777" }
    assert_equal 403, server.route("POST", "/api/trading", ok.merge("x-jarvis-token" => "x"), "{}").status
    assert_equal 403, server.route("POST", "/api/trading", ok.merge("origin" => "https://evil.example"), "{}").status
    r = server.route("POST", "/api/trading", ok, "{}")
    assert_equal 200, r.status
    assert JSON.parse(r.body)["running"]
    status = JSON.parse(server.route("GET", "/api/status", ok, "").body)
    assert status["trading_job"]["running"]
    remote.gate << :go
    job.wait
  end

  def test_full_note_endpoint
    server = HudServer.new(port: 7777, token: "t" * 48, trading: TradingJob.new(remote: FakeRemote.new),
                           status: Struct.new(:x) { def snapshot = {} }.new(nil))
    ok = { "host" => "localhost:7777", "x-jarvis-token" => "t" * 48 }
    FileUtils.mkdir_p(Trading.dir)
    File.write(File.join(Trading.dir, "2026-10-28.md"), "# vecchia")
    File.write(File.join(Trading.dir, "2026-10-29.md"), "# Analisi\n\n## NVDA: AUMENTA")
    assert_equal 403, server.route("GET", "/api/trading/note", ok.merge("x-jarvis-token" => "x"), "").status
    note = JSON.parse(server.route("GET", "/api/trading/note", ok, "").body)
    assert_equal "2026-10-29.md", note["name"]
    assert_includes note["text"], "NVDA: AUMENTA"
  end
end
