require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/daily_digest"
require_relative "../lib/env_file"
require_relative "../lib/site"

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

class FeedOptionsTest < Minitest::Test
  RELEASES = <<~XML
    <feed>
      <entry><title>v0.40.4</title><link rel="alternate" href="https://github.com/o/o/releases/tag/v0.40.4-rc1"/><updated>2026-10-13T05:00:00Z</updated><content>rc</content></entry>
      <entry><title>v0.40.3</title><link rel="alternate" href="https://github.com/o/o/releases/tag/v0.40.3"/><updated>2026-10-12T05:00:00Z</updated><content>stabile</content></entry>
    </feed>
  XML

  def test_feed_applies_prefix_boost_and_excludes_prereleases
    source = { "name" => "Rel", "url" => "x", "title_prefix" => "Ollama ", "boost" => 3, "exclude_url" => "-(rc|alpha|beta)" }
    DailyDigest::Collector.stub(:get, RELEASES) do
      items = DailyDigest::Collector.feed(source)
      assert_equal ["Ollama v0.40.3"], items.map(&:title)
      assert_equal 3, items.first.boost
    end
  end

  def test_boost_lets_official_source_pass_min_score
    item = DailyDigest::Item.new(title: "Ollama v0.40.3", url: "https://a.com/r", source: "Rel", published: Time.now, text: "", boost: 3)
    assert_equal 1, DailyDigest::Ranker.select([item], { "min_score" => 2 }, n: 5, hours: 48).size
  end
end

class RedditTest < Minitest::Test
  LISTING = JSON.generate(
    "data" => { "children" => [
      { "data" => { "title" => "Nuovo modello GGUF", "permalink" => "/r/LocalLLaMA/comments/abc/x/", "selftext" => "testo\n\ndel post",
                    "created_utc" => Time.now.to_i - 3600, "stickied" => false, "over_18" => false } },
      { "data" => { "title" => "Regole del subreddit", "permalink" => "/r/LocalLLaMA/comments/def/y/", "selftext" => "",
                    "created_utc" => Time.now.to_i, "stickied" => true, "over_18" => false } }
    ] }
  )

  # Client con rete simulata: registra le richieste e risponde dal copione.
  def client(script)
    c = DailyDigest::RedditClient.new(id: "ID", secret: "SEGRETO", user_agent: "test-agent")
    calls = []
    c.define_singleton_method(:send_request) do |uri, request|
      calls << [uri.to_s, request["Authorization"], request["User-Agent"]]
      script.shift
    end
    [c, calls]
  end

  def test_top_gets_token_then_posts_and_skips_stickied
    c, calls = client([[200, '{"access_token":"TOK"}'], [200, LISTING]])
    items = c.top("LocalLLaMA")

    assert_equal ["Nuovo modello GGUF"], items.map(&:title)
    assert_equal "https://www.reddit.com/r/LocalLLaMA/comments/abc/x/", items.first.url
    assert_equal "testo del post", items.first.text
    assert items.first.ranked
    assert_match(%r{\Ahttps://www\.reddit\.com/api/v1/access_token}, calls[0][0])
    assert_equal "Basic #{['ID:SEGRETO'].pack('m0')}", calls[0][1]
    assert_match(%r{\Ahttps://oauth\.reddit\.com/r/LocalLLaMA/top\?t=day}, calls[1][0])
    assert_equal "Bearer TOK", calls[1][1]
    assert_equal "test-agent", calls[1][2]
  end

  def test_token_is_reused_across_subreddits
    c, calls = client([[200, '{"access_token":"TOK"}'], [200, LISTING], [200, LISTING]])
    c.top("LocalLLaMA")
    c.top("LocalLLM")
    assert_equal 1, calls.count { |u, _| u.include?("access_token") }
  end

  def test_bad_credentials_raise_without_leaking_secret
    c, = client([[401, "unauthorized"]])
    error = assert_raises(DailyDigest::RedditClient::AuthError) { c.top("LocalLLaMA") }
    assert_includes error.message, "credenziali non valide"
    refute_includes error.message, "SEGRETO"
  end

  def test_rejects_invalid_subreddit_name
    c, = client([])
    assert_raises(ArgumentError) { c.top("../../etc") }
  end

  def test_collector_falls_back_to_rss_without_credentials
    ENV.delete("REDDIT_CLIENT_ID")
    ENV.delete("REDDIT_CLIENT_SECRET")
    requested = nil
    rss = '<rss><channel><item><title>Da RSS</title><link>https://reddit.com/1</link></item></channel></rss>'
    DailyDigest::Collector.stub(:get, ->(url, *) { requested = url; rss }) do
      _out, err = capture_io do
        items = DailyDigest::Collector.reddit("name" => "r/X", "subreddit" => "X")
        assert_equal ["Da RSS"], items.map(&:title)
        assert items.first.ranked
      end
      assert_includes requested, "/r/X/top/.rss"
      assert_includes err, "REDDIT_CLIENT_ID"
    end
  end
end

class RedditAuthFailureTest < Minitest::Test
  def test_auth_failure_is_remembered_and_skips_api_for_other_subreddits
    ENV["REDDIT_CLIENT_ID"] = "fake"
    ENV["REDDIT_CLIENT_SECRET"] = "fake"
    attempts = 0
    DailyDigest::RedditClient.stub(:new, -> { Object.new.tap { |o| o.define_singleton_method(:top) { |*| attempts += 1; raise DailyDigest::RedditClient::AuthError, "Reddit OAuth: credenziali non valide (HTTP 401)" } } }) do
      DailyDigest::Collector.stub(:get, '<rss/>') do
        capture_io do
          DailyDigest::Collector.instance_variable_set(:@reddit_client, nil)
          DailyDigest::Collector.instance_variable_set(:@reddit_auth_failed, nil)
          DailyDigest::Collector.reddit("name" => "r/A", "subreddit" => "A")
          DailyDigest::Collector.reddit("name" => "r/B", "subreddit" => "B")
        end
      end
    end
    assert_equal 1, attempts
  ensure
    ENV.delete("REDDIT_CLIENT_ID")
    ENV.delete("REDDIT_CLIENT_SECRET")
    DailyDigest::Collector.instance_variable_set(:@reddit_client, nil)
    DailyDigest::Collector.instance_variable_set(:@reddit_auth_failed, nil)
  end
end

class SeenTest < Minitest::Test
  include DailyDigest

  def item(title, url) = Item.new(title: title, url: url, source: "S", published: Time.now, text: "", boost: 5)

  def seen_at(dir, day) = Seen.new(File.join(dir, "digest", ".visti.json"), now: Time.new(2026, 10, day, 8))

  def test_item_published_yesterday_is_excluded_today
    Dir.mktmpdir do |dir|
      first = seen_at(dir, 13)
      first.add([item("Uno", "https://a.com/1")])
      first.save

      assert seen_at(dir, 14).include?(item("Uno", "https://www.a.com/1/")), "stesso link normalizzato"
      assert seen_at(dir, 14).include?(item("UNO!", "https://b.com/altro")), "stesso titolo normalizzato"
      refute seen_at(dir, 14).include?(item("Due", "https://a.com/2"))
    end
  end

  def test_same_day_rerun_is_not_excluded
    Dir.mktmpdir do |dir|
      first = seen_at(dir, 13)
      first.add([item("Uno", "https://a.com/1")])
      first.save
      refute seen_at(dir, 13).include?(item("Uno", "https://a.com/1"))
    end
  end

  def test_old_entries_are_pruned_on_save
    Dir.mktmpdir do |dir|
      old = Seen.new(File.join(dir, "digest", ".visti.json"), now: Time.new(2026, 8, 1))
      old.add([item("Vecchio", "https://a.com/old")])
      old.save
      later = seen_at(dir, 13)
      later.save
      refute JSON.parse(File.read(File.join(dir, "digest", ".visti.json"))).keys.any? { |k| k.include?("old") }
    end
  end

  def test_corrupt_file_starts_empty_with_warning
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "digest"))
      File.write(File.join(dir, "digest", ".visti.json"), "{non json")
      _out, err = capture_io { refute seen_at(dir, 13).include?(item("Uno", "https://a.com/1")) }
      assert_includes err, "danneggiato"
    end
  end

  def test_select_skips_seen_and_fills_with_others
    Dir.mktmpdir do |dir|
      first = seen_at(dir, 13)
      first.add([item("Vecchia notizia", "https://a.com/1")])
      first.save

      items = [item("Vecchia notizia", "https://a.com/1"), item("Notizia nuova", "https://a.com/2")]
      result = Ranker.select(items, {}, n: 5, hours: 48, seen: seen_at(dir, 14))
      assert_equal ["Notizia nuova"], result.map(&:title)
    end
  end
end

class KeywordAndSourceOptionsTest < Minitest::Test
  def item(title, source: "S", **extra)
    DailyDigest::Item.new(title: title, url: "https://a.com/#{title.hash}", source: source, published: Time.now, text: "", **extra)
  end

  def test_keywords_match_whole_words_not_substrings
    r = DailyDigest::Ranker
    refute r.keyword?("cloud storage and average fragments", "rag")
    assert r.keyword?("a rag pipeline", "rag")
    assert r.keyword?("rag-based search", "rag")
    assert r.keyword?("new llms arrive", "llm")      # plurale
    assert r.keyword?("Qwen3-1.7B released", "qwen") # cifre dopo
    refute r.keyword?("language models", "llm")
    assert r.keyword?("quantization tricks", "quantiz") # parole lunghe: prefisso
    assert r.keyword?("Agentic agents", "agent")
    assert r.keyword?("llama.cpp update", "llama.cpp")
  end

  def test_max_items_overrides_default_cap_per_source
    items = (1..6).map { |i| item("Claude Code release #{i}", source: "CC", boost: 5, cap: 1) } +
            (1..6).map { |i| item("Altra notizia #{i}", source: "X", boost: 5) }
    result = DailyDigest::Ranker.select(items, {}, n: 20, hours: 48)
    assert_equal 1, result.count { |i| i.source == "CC" }
    assert_equal DailyDigest::Ranker::MAX_PER_SOURCE, result.count { |i| i.source == "X" }
  end

  def test_feed_exclude_title_and_max_items
    xml = '<feed><entry><title>[Subscriber Exclusive] NYC Meetups</title><link href="https://a.com/1"/></entry>' \
          '<entry><title>Notizia vera</title><link href="https://a.com/2"/></entry>' \
          '<entry><title>AINews: not much happened today</title><link href="https://a.com/3"/></entry></feed>'
    source = { "name" => "LS", "url" => "x", "exclude_title" => "Subscriber Exclusive|not much happened", "max_items" => 2 }
    DailyDigest::Collector.stub(:get, xml) do
      items = DailyDigest::Collector.feed(source)
      assert_equal ["Notizia vera"], items.map(&:title)
      assert_equal 2, items.first.cap
    end
  end

  def test_shipped_sources_file_is_valid
    config = YAML.load_file(Config::SOURCES_FILE)
    names = config["sources"].map { |s| s["name"] }
    assert_equal names.uniq, names, "nomi di fonte duplicati"
    config["sources"].each do |s|
      assert %w[feed reddit github].include?(s["type"]), "tipo non valido in #{s['name']}"
      Regexp.new(s["exclude_url"]) if s["exclude_url"]
      Regexp.new(s["exclude_title"]) if s["exclude_title"]
      assert_match(%r{\Ahttps://}, s["url"], "#{s['name']} deve usare https") if s["type"] == "feed"
    end
  end
end

class FreshnessWindowTest < Minitest::Test
  def item(title, age_hours, **extra)
    DailyDigest::Item.new(title: title, url: "https://a.com/#{title}", source: title, published: Time.now - age_hours * 3600, text: "", boost: 5, **extra)
  end

  def test_per_source_window_keeps_slow_publishers
    items = [item("Blog lento", 100, window: 168), item("Feed veloce", 100), item("Fresco", 5)]
    titles = DailyDigest::Ranker.select(items, {}, n: 10, hours: 48).map(&:title)
    assert_includes titles, "Blog lento"
    assert_includes titles, "Fresco"
    refute_includes titles, "Feed veloce"
  end

  def test_feed_and_reddit_options_are_applied_by_decorate
    source = { "name" => "R", "title_prefix" => "P ", "boost" => 2, "max_items" => 1, "hours" => 96 }
    items = [DailyDigest::Item.new(title: "T", url: "https://a.com/1", source: "R")]
    out = DailyDigest::Collector.decorate(items, source).first
    assert_equal ["P T", 2, 1, 96], [out.title, out.boost, out.cap, out.window]
  end
end

class KeywordCapTest < Minitest::Test
  def test_keyword_score_is_capped
    ranking = { "keywords" => { "alfa" => 4, "beta" => 4, "gamma" => 4 } }
    item = DailyDigest::Item.new(title: "alfa beta gamma", url: "https://a.com/1", source: "S")
    assert_equal DailyDigest::Ranker::MAX_KEYWORD_SCORE, DailyDigest::Ranker.score(item, ranking)
  end
end

class CategoriesTest < Minitest::Test
  CATEGORIES = [
    { "id" => "ufficiali", "label" => "Ufficiali", "slots" => 2 },
    { "id" => "community", "label" => "Community", "slots" => 2 }
  ].freeze

  def item(title, category, score_boost, source: nil)
    DailyDigest::Item.new(title: title, url: "https://a.com/#{title}", source: source || title, published: Time.now,
                          text: "", boost: score_boost, category: category)
  end

  def test_reddit_cannot_take_every_slot
    reddit = (1..6).map { |i| item("Reddit #{i}", "community", 20 - i, source: "r/#{i}") }
    official = [item("Anthropic news", "ufficiali", 3), item("DeepMind post", "ufficiali", 3)]
    result = DailyDigest::Ranker.select(reddit + official, {}, n: 4, hours: 48, categories: CATEGORIES)

    assert_equal ["Anthropic news", "DeepMind post"], result.select { |i| i.category == "ufficiali" }.map(&:title).sort
    assert_equal 2, result.count { |i| i.category == "community" }
  end

  def test_result_is_ordered_by_category_then_score
    items = [item("C1", "community", 9), item("U1", "ufficiali", 3), item("C2", "community", 8), item("U2", "ufficiali", 5)]
    result = DailyDigest::Ranker.select(items, {}, n: 4, hours: 48, categories: CATEGORIES)
    assert_equal %w[U2 U1 C1 C2], result.map(&:title)
  end

  def test_empty_slots_go_to_best_remaining_items
    items = [item("U1", "ufficiali", 3)] + (1..5).map { |i| item("C#{i}", "community", 10 - i, source: "r/#{i}") }
    result = DailyDigest::Ranker.select(items, {}, n: 4, hours: 48, categories: CATEGORIES)
    assert_equal 4, result.size
    assert_equal 1, result.count { |i| i.category == "ufficiali" }
  end

  def test_total_never_exceeds_n
    items = (1..5).map { |i| item("U#{i}", "ufficiali", 9, source: "u#{i}") } + (1..5).map { |i| item("C#{i}", "community", 9, source: "c#{i}") }
    assert_equal 3, DailyDigest::Ranker.select(items, {}, n: 3, hours: 48, categories: CATEGORIES).size
  end

  def test_without_categories_behaviour_is_unchanged
    items = (1..5).map { |i| item("T#{i}", "x", 10 - i, source: "s#{i}") }
    assert_equal %w[T1 T2 T3], DailyDigest::Ranker.select(items, {}, n: 3, hours: 48).map(&:title)
  end

  def test_render_writes_category_line_and_site_groups_by_it
    builder = DailyDigest::Builder.new(llm: nil)
    items = [item("Post ufficiale", "ufficiali", 1, source: "Anthropic"), item("Thread", "community", 1, source: "r/LocalLLaMA")]
    md = builder.render(items, ["Riassunto A.", "Riassunto B."], Time.new(2026, 10, 14), model: "m",
                        labels: { "ufficiali" => "Ufficiali", "community" => "Community" })
    assert_includes md, "Categoria: Ufficiali"

    day = Site.parse(md, "2026-10-14")
    assert_equal %w[Ufficiali Community], day.entries.map(&:category)
    assert_equal %w[Ufficiali Community], Site.sections(day).map(&:first)
    html = Site.page(day, [day])
    assert_includes html, 'class="cats"'
    assert_includes html, "Community <span>1</span>"
  end

  def test_shipped_config_categories_are_consistent
    config = YAML.load_file(Config::SOURCES_FILE)
    ids = config["categories"].map { |c| c["id"] }
    assert_equal ids.uniq, ids
    assert config["categories"].all? { |c| c["slots"].to_i.positive? && !c["label"].to_s.empty? }
    config["sources"].each { |s| assert_includes ids, s["category"], "#{s['name']}: categoria mancante o sconosciuta" }
  end
end
