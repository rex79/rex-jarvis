require "minitest/autorun"
require "tmpdir"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/daily_digest"
require_relative "../lib/env_file"

class DigestTest < Minitest::Test
  include DailyDigest

  RSS = <<~XML
    <rss><channel>
      <item><title><![CDATA[Ollama &amp; llama.cpp: nuova versione]]></title>
        <link>https://example.com/a/</link>
        <description>&lt;p&gt;Supporto &lt;b&gt;GGUF&lt;/b&gt;&lt;/p&gt;</description>
        <pubDate>Mon, 12 Oct 2026 08:00:00 GMT</pubDate></item>
    </channel></rss>
  XML

  ATOM = <<~XML
    <feed><entry><title>Post Reddit</title>
      <link href="https://reddit.com/r/x/1" />
      <updated>2026-10-12T09:00:00+00:00</updated>
      <content type="html">&lt;div&gt;testo&lt;/div&gt;</content></entry></feed>
  XML

  def item(title, url, source: "S", published: Time.now, text: "", **extra)
    Item.new(title: title, url: url, source: source, published: published, text: text, **extra)
  end

  def test_parse_rss_strips_cdata_and_html
    it = FeedParser.parse(RSS, "Blog").first
    assert_equal "Ollama & llama.cpp: nuova versione", it.title
    assert_equal "https://example.com/a/", it.url
    assert_equal "Supporto GGUF", it.text
    assert_equal 2026, it.published.year
  end

  def test_parse_atom_uses_href
    it = FeedParser.parse(ATOM, "Reddit", ranked: true).first
    assert_equal "https://reddit.com/r/x/1", it.url
    assert_equal "testo", it.text
    assert it.ranked
  end

  def test_parse_garbage_returns_empty
    assert_empty FeedParser.parse("<html>non è un feed</html>", "X")
  end

  def test_deduplicates_by_url_and_title
    items = [item("Uno", "https://www.a.com/x/"), item("Altro", "https://a.com/x"), item("UNO!", "https://b.com/y")]
    assert_equal 1, Ranker.deduplicate(items).size
  end

  def test_select_filters_old_and_penalizes_promo
    ranking = { "keywords" => { "ollama" => 3 }, "avoid" => ["webinar"] }
    items = [
      item("Ollama update", "https://a.com/1", published: Time.now),
      item("Ollama vecchio", "https://a.com/2", published: Time.now - 10 * 86_400),
      item("Ollama webinar gratis", "https://a.com/3", published: Time.now)
    ]
    result = Ranker.select(items, ranking, n: 5, hours: 48)
    assert_equal ["Ollama update"], result.map(&:title).first(1)
    refute_includes result.map(&:title), "Ollama vecchio"
  end

  def test_select_caps_items_per_source
    items = (1..6).map { |i| item("Titolo #{i} unico", "https://a.com/#{i}", source: "Solo") }
    ranking = { "keywords" => { "titolo" => 3 } }
    assert_equal Ranker::MAX_PER_SOURCE, Ranker.select(items, ranking, n: 10, hours: 48).size
  end

  def test_select_drops_items_below_min_score
    assert_empty Ranker.select([item("Niente di rilevante", "https://a.com/1")], { "min_score" => 2 }, n: 5, hours: 48)
  end

  def test_render_and_sanitize
    builder = Builder.new(llm: nil)
    out = builder.send(:sanitize, "Vai su http://evil.example/x ora")
    refute_includes out, "evil.example"

    it = item("Titolo", "https://a.com/1", source: "Fonte")
    md = builder.render([it], ["Riassunto."], Time.new(2026, 10, 13), model: "test")
    assert_includes md, "# AI Daily — 13 ottobre 2026"
    assert_includes md, "[link](https://a.com/1)"
  end

  def test_openrouter_requires_key_and_model
    assert_raises(OpenRouter::AuthError) { OpenRouter.new(model: "a/b", api_key: "") }
    assert_raises(ArgumentError) { OpenRouter.new(model: nil, api_key: "k") }
  end

  def test_openrouter_chat_maps_options_and_response
    client = OpenRouter.new(model: "a/b", api_key: "sk-secret")
    sent = nil
    client.define_singleton_method(:post) do |payload|
      sent = payload
      { "choices" => [{ "message" => { "content" => "ciao" } }] }
    end

    out = client.chat([{ role: "user", content: "x" }], options: { num_predict: 160, temperature: 0.2 })
    assert_equal "ciao", out["message"]["content"]
    assert_equal({ "model" => "a/b", "max_tokens" => 160, "temperature" => 0.2 }, sent.reject { |k, _| k == "messages" })
  end

  def test_openrouter_empty_response_raises_without_leaking_key
    client = OpenRouter.new(model: "a/b", api_key: "sk-secret")
    client.define_singleton_method(:post) { |_| { "error" => { "message" => "modello non disponibile" } } }
    error = assert_raises(RuntimeError) { client.chat([]) }
    refute_includes error.message, "sk-secret"
  end

  def test_auth_error_stops_digest_instead_of_falling_back
    llm = Object.new
    def llm.chat(*, **) = raise(OpenRouter::AuthError, "chiave non valida")
    assert_raises(OpenRouter::AuthError) { Builder.new(llm: llm).summarize(item("T", "https://a.com/1")) }
  end

  def test_summarize_falls_back_when_llm_fails
    llm = Object.new
    def llm.chat(*, **) = raise("Ollama spento")
    it = item("T", "https://a.com/1", text: "testo originale")
    assert_equal "testo originale", Builder.new(llm: llm).summarize(it)
  end
end

class EnvFileTest < Minitest::Test
  def test_parse_handles_export_quotes_comments_and_junk
    vars = EnvFile.parse(<<~ENV)
      # commento
      export A=uno
      B="due con spazi"
      C='tre'
      D=quattro=cinque
      riga senza uguale
      1BAD=x
    ENV
    assert_equal({ "A" => "uno", "B" => "due con spazi", "C" => "tre", "D" => "quattro=cinque" }, vars)
  end

  def test_load_does_not_override_existing_env_and_warns_on_loose_permissions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "env")
      File.write(path, "TEST_JARVIS_X=dal_file\nTEST_JARVIS_Y=dal_file\n")
      File.chmod(0o644, path)
      ENV["TEST_JARVIS_X"] = "da_ambiente"

      _out, err = capture_io { EnvFile.load(path) }

      assert_equal "da_ambiente", ENV["TEST_JARVIS_X"]
      assert_equal "dal_file", ENV["TEST_JARVIS_Y"]
      assert_includes err, "chmod 600"
      refute_includes err, "dal_file" # i valori non vengono mai stampati
    end
  ensure
    ENV.delete("TEST_JARVIS_X")
    ENV.delete("TEST_JARVIS_Y")
  end

  def test_load_ignores_missing_file
    assert_nil EnvFile.load("/percorso/che/non/esiste")
  end
end
