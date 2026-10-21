require "cgi"
require "json"
require "fileutils"
require_relative "config"

# Genera un sito statico (HTML + CSS/JS inline, nessuna risorsa esterna) dai digest in
# ~/brain/digest/*.md. Titoli e testi arrivano da internet: tutto viene escapato e i link
# sono accettati solo se http(s).
module Site
  Entry = Struct.new(:title, :source, :url, :summary, :why, :category, keyword_init: true) do
    def low?
      why.to_s.downcase.start_with?("poco")
    end
  end
  Day = Struct.new(:date, :heading, :entries, keyword_init: true)

  DATE_FILE = /\A\d{4}-\d{2}-\d{2}\z/

  def self.parse(markdown, date)
    entries = markdown.split(/^## \d+\. /).drop(1).map do |block|
      title, *rest = block.lines
      text = rest.join
      body = rest.map(&:strip).reject { |l| l.empty? || l.start_with?("Fonte:", "Categoria:") }.join(" ")
      # Il modello a volte scrive il "Perché ti interessa" sulla stessa riga del riassunto.
      summary, why = body.split("Perché ti interessa:", 2).map(&:strip)

      Entry.new(
        title: title.to_s.strip,
        source: text[/^Fonte: (.+?) ·/, 1].to_s,
        category: text[/^Categoria: (.+)$/, 1]&.strip,
        url: text[%r{\[link\]\((https?://[^)\s]+)\)}, 1],
        summary: summary.to_s,
        why: why.to_s.empty? ? nil : why
      )
    end

    Day.new(date: date, heading: markdown[/^# (.+)$/, 1] || date, entries: entries)
  end

  def self.build(digest_dir = File.join(Config::BRAIN_DIR, "digest"), out_dir = Config::SITE_DIR)
    days = Dir.glob(File.join(digest_dir, "*.md")).sort.reverse.filter_map do |file|
      date = File.basename(file, ".md")
      parse(File.read(file, encoding: "UTF-8").scrub, date) if date.match?(DATE_FILE)
    end

    FileUtils.mkdir_p(out_dir)
    days.each { |day| File.write(File.join(out_dir, "#{day.date}.html"), page(day, days)) }
    File.write(File.join(out_dir, "index.html"), page(days.first, days))
    File.write(File.join(out_dir, "robots.txt"), "User-agent: *\nDisallow: /\n")
    File.write(File.join(out_dir, "digest.json"), JSON.generate(feed(days.first, days)))
    "Sito generato: #{days.size} #{days.size == 1 ? 'giorno' : 'giorni'} in #{out_dir}"
  end

  # Versione leggibile dalle macchine dell'ultimo digest, per la dashboard sul Mac di lavoro.
  def self.feed(day, days)
    {
      version: 1,
      date: day&.date,
      heading: day&.heading,
      dates: days.first(14).map(&:date),
      entries: (day ? day.entries : []).map do |e|
        { title: e.title, source: e.source, category: e.category, url: e.url, summary: e.summary, why: e.why, low: e.low? }
      end
    }
  end

  def self.h(text)
    CGI.escapeHTML(text.to_s)
  end

  def self.page(day, days)
    groups = day ? sections(day) : []
    body = groups.each_with_index.map { |(label, entries), i| section(label, entries, i, groups.size) }.join
    chips = groups.size > 1 ? categories_nav(groups) : ""
    archive = days.map { |d| %(<a href="#{h(d.date)}.html"#{' aria-current="page"' if d.date == day&.date}>#{h(d.date)}</a>) }.join
    heading = day ? h(day.heading) : "AI Daily"
    empty = day ? "" : "<p class=\"empty\">Nessun digest ancora. Esegui <code>ruby jarvis.rb --digest</code>.</p>"

    <<~HTML
      <!doctype html>
      <html lang="it">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="robots" content="noindex, nofollow">
      <title>#{heading}</title>
      <style>#{CSS}</style>
      </head>
      <body>
      <header>
        <h1>#{heading}</h1>
        <nav class="archive" aria-label="Archivio">#{archive}</nav>
        #{chips}
        <div class="tools">
          <input id="q" type="search" placeholder="Cerca nel digest…" aria-label="Cerca">
          <label><input id="low" type="checkbox"> nascondi i poco rilevanti</label>
        </div>
      </header>
      <main id="list">#{body}#{empty}</main>
      <p id="none" hidden>Nessun risultato.</p>
      <script>#{JS}</script>
      </body>
      </html>
    HTML
  end

  # Raggruppa per categoria nell'ordine in cui compaiono nel digest. Digest vecchi, senza
  # categorie, restano un'unica lista senza titoli di sezione.
  def self.sections(day)
    return [[nil, day.entries]] if day.entries.none?(&:category)

    day.entries.group_by { |e| e.category || "Altro" }.to_a
  end

  def self.slug(label, index)
    "cat-#{index}-#{label.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')}"
  end

  def self.categories_nav(groups)
    links = groups.each_with_index.map do |(label, entries), i|
      %(<a href="##{slug(label, i)}">#{h(label)} <span>#{entries.size}</span></a>)
    end
    %(<nav class="cats" aria-label="Sezioni">#{links.join}</nav>)
  end

  def self.section(label, entries, index, total)
    cards = entries.map { |entry| card(entry) }.join
    title = total > 1 || label ? %(<h2 class="cat-title">#{h(label)} <span>#{entries.size}</span></h2>) : ""
    %(<section class="cat" id="#{slug(label, index)}">#{title}<div class="grid">#{cards}</div></section>)
  end

  def self.card(entry)
    link = entry.url ? %(<a href="#{h(entry.url)}" rel="noopener noreferrer" target="_blank">Apri la fonte ↗</a>) : ""
    why = entry.why ? %(<p class="why"><strong>Perché ti interessa:</strong> #{h(entry.why)}</p>) : ""

    <<~HTML
      <article class="card#{' low' if entry.low?}">
        <div class="meta"><span class="src">#{h(entry.source)}</span></div>
        <h3>#{h(entry.title)}</h3>
        <p>#{h(entry.summary)}</p>
        #{why}
        #{link}
      </article>
    HTML
  end

  CSS = <<~CSS.gsub(/\s+/, " ").freeze
    :root{--bg:#fafaf9;--fg:#1c1917;--muted:#78716c;--card:#fff;--line:#e7e5e4;--accent:#c2410c}
    @media(prefers-color-scheme:dark){:root{--bg:#0c0a09;--fg:#f5f5f4;--muted:#a8a29e;--card:#1c1917;--line:#292524;--accent:#fb923c}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;padding:0 16px 48px}
    header,main,#none{max-width:1100px;margin:0 auto}
    header{padding:28px 0 8px}
    h1{font-size:1.5rem;margin:0 0 12px;letter-spacing:-.01em}
    .archive{display:flex;gap:8px;overflow-x:auto;padding-bottom:6px;margin-bottom:12px}
    .archive a{white-space:nowrap;font-size:.85rem;padding:4px 10px;border:1px solid var(--line);border-radius:999px;color:var(--muted);text-decoration:none}
    .archive a[aria-current]{background:var(--accent);border-color:var(--accent);color:#fff}
    .tools{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin-bottom:16px}
    #q{flex:1 1 220px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--fg);font:inherit}
    label{font-size:.85rem;color:var(--muted)}
    .cats{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px}
    .cats a{font-size:.85rem;padding:5px 12px;border-radius:999px;background:var(--card);border:1px solid var(--line);color:var(--fg);text-decoration:none}
    .cats a span,.cat-title span{color:var(--muted);font-weight:400}
    .cat-title{font-size:.8rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);margin:26px 0 10px;scroll-margin-top:12px}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:14px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin:0}
    .card.low{opacity:.6}
    .meta{display:flex;gap:10px;align-items:center;font-size:.8rem;color:var(--muted);margin-bottom:4px}
    .card h3{font-size:1rem;line-height:1.35;margin:0 0 8px;overflow-wrap:anywhere}
    .card p{margin:0 0 8px;font-size:.95rem}
    .why{font-size:.92rem;color:var(--muted)}
    .card a{color:var(--accent);font-size:.9rem;text-decoration:none}
    .card a:hover{text-decoration:underline}
    .empty,#none{color:var(--muted);text-align:center;padding:32px 0}
  CSS

  # Filtra le card per testo e nasconde per default quelle "poco rilevanti".
  JS = <<~JS.freeze
    const q=document.getElementById('q'),low=document.getElementById('low'),none=document.getElementById('none');
    const cards=[...document.querySelectorAll('.card')],sections=[...document.querySelectorAll('section.cat')];
    function apply(){const t=q.value.trim().toLowerCase();let shown=0;
      cards.forEach(c=>{const ok=(!low.checked||!c.classList.contains('low'))&&c.textContent.toLowerCase().includes(t);
        c.hidden=!ok;if(ok)shown++;});
      sections.forEach(s=>{const n=s.querySelectorAll('.card:not([hidden])').length;s.hidden=!n;
        const t=s.querySelector('.cat-title span'),c=document.querySelector('.cats a[href="#'+s.id+'"] span');
        if(t)t.textContent=n;if(c)c.textContent=n;});
      none.hidden=shown>0||!cards.length;}
    q.addEventListener('input',apply);low.addEventListener('change',apply);apply();
  JS
end
