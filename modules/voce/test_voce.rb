require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "voce"

class VoceTest < Minitest::Test
  class FakeTranscriber
    attr_reader :seen

    def initialize(text) = @text = text
    def ready? = true

    def transcribe(path)
      @seen = [path, File.binread(path)]
      @text
    end
  end

  def test_audio_goes_through_a_private_temp_file_that_is_deleted
    transcriber = FakeTranscriber.new("  Aggiungi al congelatore\n i piselli. ")
    mod = Voce::Module.new(transcriber: transcriber)
    reply = mod.api("POST", "trascrivi", "OPUS".b, { "content-type" => "audio/webm;codecs=opus" })
    assert_equal({ text: "Aggiungi al congelatore i piselli." }, reply)
    assert_equal "OPUS".b, transcriber.seen[1]
    refute File.exist?(transcriber.seen[0])
  end

  def test_only_audio_posts_are_accepted
    mod = Voce::Module.new(transcriber: FakeTranscriber.new("x"))
    assert_raises(ArgumentError) { mod.api("POST", "trascrivi", "x", { "content-type" => "application/json" }) }
    assert_raises(ArgumentError) { mod.api("POST", "trascrivi", "", { "content-type" => "audio/webm" }) }
    assert_raises(ArgumentError) { mod.api("GET", "trascrivi", "x", { "content-type" => "audio/webm" }) }
    assert_raises(ArgumentError) { mod.api("POST", "altro", "x", { "content-type" => "audio/webm" }) }
    assert_equal Voce::MAX_AUDIO, mod.max_body
  end

  def test_whisper_hallucinations_on_silence_are_dropped
    assert_equal "", Voce.clean("Sottotitoli creati dalla comunità Amara.org")
    assert_equal "", Voce.clean(" Grazie per la visione! ")
    assert_equal "Cosa ho in frigo?", Voce.clean("Cosa ho in frigo?")
  end

  # Un finto servizio che parla lo stesso protocollo di transcribe.py.
  def fake_service(body)
    script = File.join(Dir.mktmpdir, "fake.rb")
    File.write(script, "$stdout.sync = true\n#{body}\n")
    Voce::Transcriber.new(command: [RbConfig.ruby, script], log: File.join(Dir.mktmpdir, "voce.log"))
  end

  def test_transcriber_keeps_one_process_and_reports_errors
    service = fake_service(<<~RUBY)
      require "json"
      puts JSON.generate(ready: true)
      n = 0
      $stdin.each_line do |line|
        n += 1
        path = JSON.parse(line)["path"]
        puts JSON.generate(path.include?("rotto") ? { error: "audio illeggibile" } : { text: "frase \#{n} da \#{Process.pid}" })
      end
    RUBY
    first = service.transcribe("/tmp/a")
    assert_match(/\Afrase 1 da \d+\z/, first)
    assert_equal first.sub("frase 1", "frase 2"), service.transcribe("/tmp/b") # stesso processo
    assert_equal "audio illeggibile", assert_raises(Voce::Error) { service.transcribe("/tmp/rotto") }.message
    assert_match(/\Afrase 4/, service.transcribe("/tmp/c"))
  ensure
    service&.stop
  end

  def test_missing_environment_and_startup_errors_are_readable
    missing = Voce::Transcriber.new(command: ["/nonexistent/python"], log: File.join(Dir.mktmpdir, "voce.log"))
    refute missing.ready?
    assert_match(/bin\/setup-voce/, assert_raises(Voce::Error) { missing.transcribe("/tmp/a") }.message)
    broken = fake_service(%(puts '{"error":"faster-whisper non installato: esegui bin/setup-voce"}'))
    assert_match(/non installato/, assert_raises(Voce::Error) { broken.transcribe("/tmp/a") }.message)
    mod = Voce::Module.new(transcriber: broken)
    assert_match(/non installato/, assert_raises(ArgumentError) { mod.api("POST", "trascrivi", "x", { "content-type" => "audio/webm" }) }.message)
  end
end
