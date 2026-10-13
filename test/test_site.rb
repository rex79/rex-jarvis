require "minitest/autorun"
require "tmpdir"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/site"

class SiteTest < Minitest::Test
  DIGEST = <<~MD
    # AI Daily — 13 ottobre 2026

    > 3 segnalazioni selezionate e riassunte via openrouter con un-modello. I post Reddit sono segnalazioni da verificare.

    ## 1. Benchmarked Strata against llama.cpp
    Fonte: r/LocalLLM · [link](https://www.reddit.com/r/LocalLLM/comments/1x46wxm/x/)

    Strata 0.1.39 supera llama.cpp in velocità.

    Perché ti interessa: poco, generico.

    ## 2. 4B model, 6 GB laptop GPU
    Fonte: r/LocalLLM · [link](https://www.reddit.com/r/LocalLLM/comments/1x44lnn/y/)

    VLS è un'app locale per LLM che supporta modelli GGUF.
    Perché ti interessa: Potrebbe essere utile per testare modelli locali.

    ## 3. <script>alert(1)</script> & "virgolette"
    Fonte: <img src=x onerror=alert(2)> · [link](javascript:alert(3))

    Testo con <b>html</b>.
    Perché ti interessa: boh.
  MD

  def test_parse_extracts_entries
    day = Site.parse(DIGEST, "2026-10-13")
    assert_equal "AI Daily — 13 ottobre 2026", day.heading
    assert_equal 3, day.entries.size

    first = day.entries[0]
    assert_equal "Benchmarked Strata against llama.cpp", first.title
    assert_equal "r/LocalLLM", first.source
    assert_equal "https://www.reddit.com/r/LocalLLM/comments/1x46wxm/x/", first.url
    assert_equal "Strata 0.1.39 supera llama.cpp in velocità.", first.summary
    assert first.low?
    refute day.entries[1].low?
  end

  def test_javascript_links_are_dropped
    assert_nil Site.parse(DIGEST, "2026-10-13").entries[2].url
  end

  def test_page_escapes_hostile_text
    html = Site.page(Site.parse(DIGEST, "2026-10-13"), [])
    refute_includes html, "<script>alert(1)"
    refute_includes html, "<img src=x"
    refute_includes html, "javascript:"
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;virgolette&quot;"
  end

  def test_build_writes_index_and_day_pages_and_ignores_other_files
    Dir.mktmpdir do |dir|
      digest = File.join(dir, "digest")
      out = File.join(dir, "site")
      FileUtils.mkdir_p(digest)
      File.write(File.join(digest, "2026-10-13.md"), DIGEST)
      File.write(File.join(digest, "2026-10-12.md"), DIGEST.sub("13 ottobre", "12 ottobre"))
      File.write(File.join(digest, "note.md"), "# non è un digest")

      assert_match(/2 giorni/, Site.build(digest, out))
      assert_equal %w[2026-10-12.html 2026-10-13.html index.html robots.txt], Dir.children(out).sort
      index = File.read(File.join(out, "index.html"), encoding: "UTF-8")
      assert_includes index, "13 ottobre 2026"
      assert_includes index, 'href="2026-10-12.html"'
      assert_includes index, 'aria-current="page"'
    end
  end

  def test_pages_ask_search_engines_not_to_index
    html = Site.page(Site.parse(DIGEST, "2026-10-13"), [])
    assert_includes html, '<meta name="robots" content="noindex, nofollow">'
  end

  def test_build_without_digests_shows_empty_state
    Dir.mktmpdir do |dir|
      Site.build(File.join(dir, "vuoto"), File.join(dir, "site"))
      assert_includes File.read(File.join(dir, "site", "index.html"), encoding: "UTF-8"), "Nessun digest ancora"
    end
  end
end

class SiteSectionsTest < Minitest::Test
  MD = <<~MD
    # AI Daily — 14 ottobre 2026

    ## 1. Rilascio ufficiale
    Fonte: Ollama blog · [link](https://ollama.com/blog/x)
    Categoria: Ufficiali

    Riassunto uno.
    Perché ti interessa: molto.

    ## 2. Discussione
    Fonte: r/LocalLLaMA · [link](https://reddit.com/r/x/1)
    Categoria: Community

    Riassunto due.
    Perché ti interessa: poco, generico.

    ## 3. Altro ufficiale
    Fonte: Anthropic · [link](https://anthropic.com/news/y)
    Categoria: Ufficiali

    Riassunto tre.
    Perché ti interessa: boh.
  MD

  def test_entries_are_grouped_in_order_of_first_appearance
    day = Site.parse(MD, "2026-10-14")
    sections = Site.sections(day)
    assert_equal %w[Ufficiali Community], sections.map(&:first)
    assert_equal [2, 1], sections.map { |_, entries| entries.size }
  end

  def test_page_has_section_headings_nav_and_no_numbers
    html = Site.page(Site.parse(MD, "2026-10-14"), [])
    assert_includes html, '<h2 class="cat-title">Ufficiali <span>2</span></h2>'
    assert_includes html, '<nav class="cats"'
    assert_includes html, 'href="#cat-0-ufficiali"'
    refute_includes html, 'class="n"'
  end

  def test_old_digest_without_categories_stays_a_flat_list
    html = Site.page(Site.parse(SiteTest::DIGEST, "2026-10-13"), [])
    refute_includes html, 'class="cat-title"'
    refute_includes html, '<nav class="cats"'
  end

  def test_category_labels_are_escaped
    md = MD.sub("Categoria: Community", "Categoria: <img src=x onerror=alert(1)>")
    html = Site.page(Site.parse(md, "2026-10-14"), [])
    refute_includes html, "<img src=x"
  end
end

class SiteLowRelevanceTest < Minitest::Test
  INLINE = <<~MD
    # AI Daily — 14 ottobre 2026

    ## 1. Ollama v0.40.3
    Fonte: Ollama releases · [link](https://github.com/ollama/ollama/releases/tag/v0.40.3)
    Categoria: Ufficiali

    Rimuove i warning e pausa gli aggiornamenti in background. Perché ti interessa: ottimizza i modelli locali.

    ## 2. Annuncio generico
    Fonte: Anthropic · [link](https://anthropic.com/news/x)
    Categoria: Ufficiali

    Riassunto. Perché ti interessa: poco, generico.
  MD

  def test_why_is_recognised_mid_line
    first, second = Site.parse(INLINE, "2026-10-14").entries
    assert_equal "Rimuove i warning e pausa gli aggiornamenti in background.", first.summary
    assert_equal "ottimizza i modelli locali.", first.why
    refute first.low?
    assert second.low?
  end

  def test_everything_is_visible_by_default_and_toggle_hides_low_ones
    html = Site.page(Site.parse(INLINE, "2026-10-14"), [])
    assert_includes html, "nascondi i poco rilevanti"
    refute_match(/id="low"[^>]*checked/, html)
    assert_includes html, "!low.checked||!c.classList.contains('low')"
    assert_includes html, "textContent=n" # i contatori seguono le card visibili
  end

  def test_summary_without_why_keeps_everything_as_summary
    md = INLINE.sub("Perché ti interessa: poco, generico.", "")
    entry = Site.parse(md, "2026-10-14").entries.last
    assert_nil entry.why
    assert_equal "Riassunto.", entry.summary
  end
end
