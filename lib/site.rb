require "cgi"
require "fileutils"
require_relative "config"

# Genera un sito statico (HTML + CSS/JS inline, nessuna risorsa esterna) dai digest in
# ~/brain/digest/*.md. Titoli e testi arrivano da internet: tutto viene escapato e i link
# sono accettati solo se http(s).
module Site
  Entry = Struct.new(:title, :source, :url, :summary, :why, keyword_init: true) do
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
      body = rest.map(&:strip).reject { |l| l.empty? || l.start_with?("Fonte:") }
      why_line = body.find { |l| l.start_with?("Perché ti interessa:") }

      Entry.new(
        title: title.to_s.strip,
        source: text[/^Fonte: (.+?) ·/, 1].to_s,
        url: text[%r{\[link\]\((https?://[^)\s]+)\)}, 1],
        summary: (body - [why_line]).join(" "),
        why: why_line&.sub("Perché ti interessa:", "")&.strip
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
    "Sito generato: #{days.size} #{days.size == 1 ? 'giorno' : 'giorni'} in #{out_dir}"
  end

  def self.h(text)
    CGI.escapeHTML(text.to_s)
  end

  def self.page(day, days)
    cards = day ? day.entries.each_with_index.map { |entry, i| card(entry, i + 1) }.join : ""
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
        <div class="tools">
          <input id="q" type="search" placeholder="Cerca nel digest…" aria-label="Cerca">
          <label><input id="low" type="checkbox"> mostra anche i poco rilevanti</label>
        </div>
      </header>
      <main id="list">#{cards}#{empty}</main>
      <p id="none" hidden>Nessun risultato.</p>
      <script>#{JS}</script>
      </body>
      </html>
    HTML
  end

  def self.card(entry, number)
    link = entry.url ? %(<a href="#{h(entry.url)}" rel="noopener noreferrer" target="_blank">Apri la fonte ↗</a>) : ""
    why = entry.why ? %(<p class="why"><strong>Perché ti interessa:</strong> #{h(entry.why)}</p>) : ""

    <<~HTML
      <article class="card#{' low' if entry.low?}">
        <div class="meta"><span class="n">#{number}</span><span class="src">#{h(entry.source)}</span></div>
        <h2>#{h(entry.title)}</h2>
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
    header,main,#none{max-width:720px;margin:0 auto}
    header{padding:28px 0 8px}
    h1{font-size:1.5rem;margin:0 0 12px;letter-spacing:-.01em}
    .archive{display:flex;gap:8px;overflow-x:auto;padding-bottom:6px;margin-bottom:12px}
    .archive a{white-space:nowrap;font-size:.85rem;padding:4px 10px;border:1px solid var(--line);border-radius:999px;color:var(--muted);text-decoration:none}
    .archive a[aria-current]{background:var(--accent);border-color:var(--accent);color:#fff}
    .tools{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin-bottom:16px}
    #q{flex:1 1 220px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--fg);font:inherit}
    label{font-size:.85rem;color:var(--muted)}
    .card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:0 0 14px}
    .card.low{opacity:.6}
    .meta{display:flex;gap:10px;align-items:center;font-size:.8rem;color:var(--muted);margin-bottom:4px}
    .n{background:var(--line);border-radius:6px;padding:0 7px;font-weight:600}
    h2{font-size:1.05rem;line-height:1.35;margin:0 0 8px;overflow-wrap:anywhere}
    .card p{margin:0 0 8px}
    .why{font-size:.92rem;color:var(--muted)}
    .card a{color:var(--accent);font-size:.9rem;text-decoration:none}
    .card a:hover{text-decoration:underline}
    .empty,#none{color:var(--muted);text-align:center;padding:32px 0}
  CSS

  # Filtra le card per testo e nasconde per default quelle "poco rilevanti".
  JS = <<~JS.freeze
    const q=document.getElementById('q'),low=document.getElementById('low'),none=document.getElementById('none');
    const cards=[...document.querySelectorAll('.card')];
    function apply(){const t=q.value.trim().toLowerCase();let shown=0;
      cards.forEach(c=>{const ok=(low.checked||!c.classList.contains('low'))&&c.textContent.toLowerCase().includes(t);
        c.hidden=!ok;if(ok)shown++;});
      none.hidden=shown>0||!cards.length;}
    q.addEventListener('input',apply);low.addEventListener('change',apply);apply();
  JS
end
