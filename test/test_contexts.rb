require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("personal")
ENV["JARVIS_WORK_DIR"] = Dir.mktmpdir("work")
require_relative "../lib/agent"
require_relative "../lib/router"
require_relative "../lib/dispatcher"

# Modello finto: registra i messaggi e risponde secondo un copione.
class FakeLLM
  attr_reader :calls

  def initialize(*replies)
    @replies = replies
    @calls = []
  end

  def chat(messages, **opts)
    @calls << [messages.map(&:dup), opts]
    { "message" => @replies.shift || { "role" => "assistant", "content" => "ok" } }
  end
end

class PrivacyTest < Minitest::Test
  def test_only_loopback_addresses_are_local
    %w[http://localhost:11434 http://127.0.0.1:11434 http://[::1]:11434].each { |u| assert Privacy.local_url?(u), u }
    %w[http://192.168.1.10:11434 https://ollama.example.com http://localhost.evil.com:11434 nonsense].each do |u|
      refute Privacy.local_url?(u), u
    end
  end

  def test_work_agent_refuses_a_remote_model
    Config.stub_const(:OLLAMA_URL, "http://192.168.1.10:11434") do
      error = assert_raises(Privacy::Error) { Agent.new(Contexts.work, llm: FakeLLM.new) }
      assert_includes error.message, "non devono uscire dal computer"
    end
  end

  def test_personal_agent_is_not_bound_by_the_local_only_rule
    Config.stub_const(:OLLAMA_URL, "http://192.168.1.10:11434") do
      assert Agent.new(Contexts.personal, llm: FakeLLM.new)
    end
  end

  def test_router_refuses_to_classify_with_a_remote_model
    Config.stub_const(:OLLAMA_URL, "https://ollama.example.com") do
      assert_raises(Privacy::Error) { Router.route("qualcosa di ambiguo") }
    end
  end
end

class RouterTest < Minitest::Test
  def test_explicit_prefix_wins_and_is_removed
    route = Router.route("Personale: metti il briefing in musica")
    assert_equal [:personal, "metti il briefing in musica", "prefisso"], route.to_a
    assert_equal :work, Router.route("lavoro, cosa ho oggi?").context
  end

  def test_keywords
    assert_equal :work, Router.route("Jarvis dammi il daily briefing e salvalo").context
    assert_equal :personal, Router.route("Jarvis metti la playlist Focus").context
  end

  def test_any_work_signal_keeps_the_command_in_work
    assert_equal :work, Router.route("metti in pausa il progetto").context
  end

  def test_ambiguous_text_asks_the_local_model
    llm = FakeLLM.new({ "content" => "personale" })
    route = Router.route("che tempo fa domani?", llm: llm)
    assert_equal [:personal, "modello locale"], [route.context, route.reason]
    assert_equal 0, llm.calls.first[1][:options][:temperature]
  end

  def test_odd_answers_and_failures_fall_back_to_work
    assert_equal :work, Router.route("che tempo fa?", llm: FakeLLM.new({ "content" => "boh" })).context
    broken = Object.new
    def broken.chat(*, **) = raise("Ollama spento")
    assert_equal :work, Router.route("che tempo fa?", llm: broken).context
  end
end

class SeparationTest < Minitest::Test
  def test_each_context_sees_only_its_own_notes
    Notes.new(Config::WORK_DIR).save("Cliente X", "contratto riservato")
    Notes.new(Config::BRAIN_DIR).save("Ricetta", "brisket")

    assert_includes Filesystem.new(Config::WORK_DIR).list_files, "cliente-x.md"
    refute_includes Filesystem.new(Config::BRAIN_DIR).list_files, "cliente-x.md"
    assert_raises(RuntimeError) { Filesystem.new(Config::BRAIN_DIR).read_file(File.join(Config::WORK_DIR, "cliente-x.md")) }
    assert_raises(RuntimeError) { Filesystem.new(Config::WORK_DIR).read_file(File.join(Config::BRAIN_DIR, "ricetta.md")) }
  end

  def test_each_context_has_its_own_index_file
    refute_equal Notes.new(Config::WORK_DIR).index_file, Notes.new(Config::BRAIN_DIR).index_file
  end

  def test_tool_sets_differ_by_context
    work = Agent.new(Contexts.work, llm: FakeLLM.new)
    personal = Agent.new(Contexts.personal, llm: FakeLLM.new)
    refute_includes work.tool_names, "music_control"
    assert_includes personal.tool_names, "music_control"
  end

  def test_work_agent_will_not_run_a_tool_it_does_not_have
    call = { "function" => { "name" => "music_control", "arguments" => { "action" => "play" } } }
    llm = FakeLLM.new({ "role" => "assistant", "content" => "", "tool_calls" => [call] })
    agent = Agent.new(Contexts.work, llm: llm)
    played = false
    Music.stub(:control, ->(*) { played = true }) { capture_io { agent.ask("metti musica") } }
    refute played
    tool_reply = llm.calls.last[0].find { |m| m[:role] == "tool" }
    assert_includes tool_reply[:content], "non disponibile nel contesto lavoro"
  end

  def test_work_agent_saves_notes_in_the_work_folder
    call = { "function" => { "name" => "save_note", "arguments" => { "title" => "Steering 21 ottobre", "text" => "decisioni" } } }
    agent = Agent.new(Contexts.work, llm: FakeLLM.new({ "role" => "assistant", "content" => "", "tool_calls" => [call] }))
    capture_io { agent.ask("salva la nota dello steering") }
    assert File.exist?(File.join(Config::WORK_DIR, "steering-21-ottobre.md"))
    refute File.exist?(File.join(Config::BRAIN_DIR, "steering-21-ottobre.md"))
  end

  def test_string_tool_arguments_are_parsed
    call = { "function" => { "name" => "current_time", "arguments" => "{}" } }
    agent = Agent.new(Contexts.personal, llm: FakeLLM.new({ "role" => "assistant", "content" => "", "tool_calls" => [call] }))
    out, = capture_io { agent.ask("che ore sono?") }
    assert_includes out, "current_time"
  end
end

class MusicTest < Minitest::Test
  def run_music(*args, app: "Music")
    calls = []
    result = Music.control(*args, app: app, runner: ->(script, argv) { calls << [script, argv] })
    [result, calls]
  end

  def test_basic_actions_do_not_launch_a_closed_app_except_play
    _, calls = run_music("next")
    assert_equal [['if application "Music" is running then tell application "Music" to next track', []]], calls
    _, calls = run_music("pause", app: "Spotify")
    assert_equal 'if application "Spotify" is running then tell application "Spotify" to pause', calls.first[0]
    _, calls = run_music("play", app: "Spotify")
    assert_equal 'tell application "Spotify" to play', calls.first[0]
  end

  def test_app_names_spoken_by_the_user_are_understood
    { "spotify" => "Spotify", "Apple Music" => "Music", "musica" => "Music" }.each do |said, app|
      _, calls = run_music("play", app: said)
      assert_equal %(tell application "#{app}" to play), calls.first[0]
    end
  end

  def test_without_an_app_the_configured_preference_is_used
    calls = []
    Config.stub_const(:MUSIC_APP, "Spotify") do
      Music.control("play", runner: ->(script, _) { calls << script })
    end
    assert_equal ['tell application "Spotify" to play'], calls
  end

  def test_agent_passes_the_app_named_by_the_user
    call = { "function" => { "name" => "music_control", "arguments" => { "action" => "play", "app" => "Spotify" } } }
    agent = Agent.new(Contexts.personal, llm: FakeLLM.new({ "role" => "assistant", "content" => "", "tool_calls" => [call] }))
    received = nil
    Music.stub(:control, ->(action, query, app:) { received = [action, query, app]; "ok" }) { capture_io { agent.ask("metti Spotify") } }
    assert_equal ["play", nil, "Spotify"], received
  end

  def test_search_text_is_passed_as_argument_not_inside_the_script
    hostile = 'Focus" & (do shell script "rm -rf ~") & "'
    _, calls = run_music("playlist", hostile)
    script, argv = calls.first
    refute_includes script, "rm -rf"
    assert_equal [hostile], argv
  end

  def test_rejects_unknown_actions_apps_and_unsupported_combinations
    assert_raises(Music::Error) { run_music("delete") }
    assert_raises(Music::Error) { run_music("play", app: "iTunes\" to quit") }
    assert_raises(Music::Error) { run_music("playlist", "Focus", app: "Spotify") }
    assert_raises(Music::Error) { run_music("song", "  ") }
  end
end

# Minitest non ha stub per le costanti: piccolo aiuto per i test sulla privacy.
module StubConst
  def stub_const(name, value)
    old = const_get(name)
    silence = $VERBOSE
    $VERBOSE = nil
    const_set(name, value)
    yield
  ensure
    const_set(name, old)
    $VERBOSE = silence
  end
end
Config.extend(StubConst)

class IntentsTest < Minitest::Test
  def test_simple_music_commands
    {
      "riprendi la musica" => ["play", nil], "Jarvis, riprendi" => ["play", nil], "fai ripartire la canzone" => ["play", nil],
      "metti la musica" => ["play", nil], "metti in pausa la musica" => ["pause", nil], "pausa" => ["pause", nil],
      "ferma Spotify" => ["pause", "Spotify"], "prossima canzone" => ["next", nil], "brano precedente" => ["previous", nil],
      "riprendi la musica su apple music" => ["play", "Music"], "Jarvis continua" => ["play", nil]
    }.each { |said, expected| assert_equal expected, Intents.music(said), said }
  end

  def test_not_simple_commands
    ["metti la playlist Focus", "metti la musica di Vasco", "continua il report", "che ore sono?",
     "dammi il daily briefing", "salva una nota", "torna indietro alla bozza"].each do |said|
      assert_nil Intents.music(said), said
    end
  end
end

class DispatcherTest < Minitest::Test
  class FakeMusic
    attr_reader :calls

    def initialize = @calls = []

    def control(action, query, app:)
      @calls << [action, query, app]
      "Musica: #{action}"
    end
  end

  def dispatcher(forced: nil)
    music = FakeMusic.new
    built = []
    factory = ->(context) { built << context.id; Agent.new(context, llm: FakeLLM.new({ "role" => "assistant", "content" => "risposta" })) }
    [Dispatcher.new(forced: forced, agent_factory: factory, music: music), music, built]
  end

  def test_resume_runs_play_immediately_without_any_model
    d, music, built = dispatcher
    reply = d.handle("riprendi la musica")
    assert_equal [["play", nil, nil]], music.calls
    assert_empty built
    assert_equal "personale · comando rapido", reply.label
  end

  def test_work_words_disable_the_shortcut
    d, music, built = dispatcher
    d.handle("pausa sul progetto Shopify: dammi lo stato")
    assert_empty music.calls
    assert_equal [:work], built
  end

  def test_forcing_work_never_touches_music
    d, music, = dispatcher(forced: "work")
    d.handle("pausa")
    assert_empty music.calls
  end

  def test_complex_requests_go_to_the_agent
    d, music, built = dispatcher
    reply = d.handle("metti la playlist Focus")
    assert_empty music.calls
    assert_equal [:personal], built
    assert_equal "risposta", reply.text
  end
end
