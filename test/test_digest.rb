require "minitest/autorun"
require "tmpdir"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/daily_digest"

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

  def test_summarize_falls_back_when_llm_fails
    llm = Object.new
    def llm.chat(*, **) = raise("Ollama spento")
    it = item("T", "https://a.com/1", text: "testo originale")
    assert_equal "testo originale", Builder.new(llm: llm).summarize(it)
  end
end
