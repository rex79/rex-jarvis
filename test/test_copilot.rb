require "minitest/autorun"
require "stringio"
require "minitest/mock"
require "tmpdir"
require "json"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("personal")
ENV["JARVIS_WORK_DIR"] = Dir.mktmpdir("work")
require_relative "../lib/dispatcher"

class CopilotToolTest < Minitest::Test
  def configured
    Copilot.stub(:configured?, true) { yield }
  end

  def test_ask_sends_text_and_conversation_as_json
    received = nil
    runner = ->(command, input, _progress) { received = [command, JSON.parse(input)]; { "text" => "Briefing pronto", "conversation_id" => "c1" } }
    reply = configured { Copilot.ask("dammi il briefing", conversation_id: "c0", runner: runner) }
    assert_equal ["ask", { "text" => "dammi il briefing", "conversation_id" => "c0" }], received
    assert_equal({ text: "Briefing pronto", conversation_id: "c1" }, reply)
  end

  def test_not_configured_is_a_clear_error
    Copilot.stub(:configured?, false) do
      error = assert_raises(Copilot::Error) { Copilot.ask("x", runner: ->(*) { flunk "non deve chiamare il ponte" }) }
      assert_equal "CONFIG", error.code
    end
  end

  def test_save_copy_writes_a_work_note
    Dir.mktmpdir do |dir|
      path = Copilot.save_copy("Dammi il daily briefing!", "Tre rischi aperti.", dir: dir, now: Time.new(2026, 10, 23, 9, 5))
      assert_equal "2026-10-23-0905-dammi-il-daily-briefing.md", File.basename(path)
      assert_includes File.read(path, encoding: "UTF-8"), "Tre rischi aperti."
    end
  end

  def test_progress_lines_from_the_bridge_reach_the_callback
    seen = []
    Open3.stub(:popen3, ->(*_, &block) {
      out = StringIO.new(%({"text": "ok", "conversation_id": "c"}\n))
      err = StringIO.new("PROGRESS 5\nlog del client\nPROGRESS 65\n")
      thread = Struct.new(:pid) { def join(*) = sleep(0.05) && self }.new(0)
      block.call(StringIO.new, out, err, thread)
    }) do
      Copilot.run("ask", "{}", ->(s) { seen << s })
    end
    assert_equal [5, 65], seen
  end

  def test_bridge_errors_become_copilot_errors_with_code
    Open3.stub(:popen3, ->(*_, &block) {
      stdin = StringIO.new
      out = StringIO.new(%({"error": "accesso Microsoft necessario", "code": "LOGIN_REQUIRED"}\n))
      thread = Struct.new(:pid) { def join(*) = self }.new(0)
      block.call(stdin, out, StringIO.new, thread)
    }) do
      error = assert_raises(Copilot::Error) { Copilot.run("ask", "{}", nil) }
      assert_equal "LOGIN_REQUIRED", error.code
    end
  end
end

class CopilotDispatchTest < Minitest::Test
  class FakeCopilot
    attr_reader :asked, :saved

    def initialize(configured: true)
      @configured = configured
      @asked = []
      @saved = []
    end

    def configured? = @configured

    def ask(text, conversation_id: nil, progress: nil)
      progress&.call(42)
      @asked << [text, conversation_id]
      { text: "risposta #{@asked.size}", conversation_id: "conv-1" }
    end

    def save_copy(question, answer) = @saved << [question, answer]
  end

  def dispatcher(copilot)
    built = []
    factory = ->(c) { built << c.id; Agent.new(c, llm: Class.new { def chat(*, **) = { "message" => { "content" => "dal modello" } } }.new) }
    [Dispatcher.new(agent_factory: factory, music: nil, copilot: copilot), built]
  end

  def test_briefing_goes_verbatim_to_copilot_without_the_local_model
    copilot = FakeCopilot.new
    d, built = dispatcher(copilot)
    request = "Jarvis dammi il daily briefing e salvamelo nella cartella, creami le note e salvami la knowledge"
    reply = d.handle(request)
    sent = "Dammi il daily briefing e salvamelo nella cartella, creami le note e salvami la knowledge"
    assert_equal [[sent, nil]], copilot.asked
    assert_empty built, "nessun modello locale coinvolto"
    assert_equal "lavoro · Copilot", reply.label
    assert_equal [[sent, "risposta 1"]], copilot.saved
  end

  def test_the_conversation_continues_within_the_session
    copilot = FakeCopilot.new
    d, = dispatcher(copilot)
    d.handle("dammi il briefing")
    d.handle("lavoro: chiedi a copilot i rischi del progetto Shopify")
    assert_equal [["Dammi il briefing", nil], ["I rischi del progetto Shopify", "conv-1"]], copilot.asked
  end

  def test_progress_is_forwarded_while_copilot_works
    copilot = FakeCopilot.new
    d, = dispatcher(copilot)
    seen = []
    d.progress = ->(s) { seen << s }
    d.handle("dammi il briefing")
    assert_equal [42], seen
  end

  def test_personal_requests_never_reach_copilot
    copilot = FakeCopilot.new
    d, = dispatcher(copilot)
    d.handle("personale: com'è andato il mio agente di musica?")
    assert_empty copilot.asked
  end

  def test_without_configuration_the_local_agent_answers
    copilot = FakeCopilot.new(configured: false)
    d, built = dispatcher(copilot)
    assert_equal "dal modello", d.handle("dammi il briefing").text
    assert_equal [:work], built
    assert_empty copilot.asked
  end

  def test_ask_copilot_tool_only_in_the_work_context
    Copilot.stub(:configured?, true) do
      llm = Class.new { def chat(*, **) = { "message" => { "content" => "ok" } } }.new
      assert_includes Agent.new(Contexts.work, llm: llm).tool_names, "ask_copilot"
      refute_includes Agent.new(Contexts.personal, llm: llm).tool_names, "ask_copilot"
    end
  end
end

class CopilotRequestTest < Minitest::Test
  def test_words_addressed_to_jarvis_are_removed
    {
      "chiedi a Copilot quali competenze hai" => "Quali competenze hai",
      "Jarvis, chiedi a Copilot di prepararmi il meeting delle 15" => "Prepararmi il meeting delle 15",
      "Copilot: stato del progetto Shopify" => "Stato del progetto Shopify",
      "chiedi all'agente se ci sono rischi su UAT" => "Ci sono rischi su UAT",
      "Jarvis dammi il daily briefing e salvamelo" => "Dammi il daily briefing e salvamelo",
      "dammi il briefing di copilot" => "Dammi il briefing di copilot"
    }.each { |said, sent| assert_equal sent, Intents.copilot_request(said), said }
  end

  def test_dispatcher_forwards_the_cleaned_request
    copilot = CopilotDispatchTest::FakeCopilot.new
    d = Dispatcher.new(music: nil, copilot: copilot)
    d.handle("lavoro: chiedi a Copilot quali strumenti hai")
    assert_equal [["Quali strumenti hai", nil]], copilot.asked
  end
end


class BridgeTimeoutTest < Minitest::Test
  def test_python_bridge_inactivity_timeout
    skip "manca .venv (bin/setup-copilot)" unless File.executable?(Copilot::PYTHON)
    out, status = Open3.capture2e(Copilot::PYTHON, "-I", File.expand_path("test_bridge.py", __dir__))
    assert status.success?, out
  end
end
