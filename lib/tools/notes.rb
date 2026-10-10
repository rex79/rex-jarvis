require "json"
require "time"
require_relative "../config"
require_relative "../ollama"
require_relative "filesystem"

# Ricerca semantica e salvataggio note in Config::BRAIN_DIR.
class Notes
  CHUNK_CHARS = 800

  def self.search(query, top_k = 4)
    index = load_index
    return "Nessuna nota indicizzata. Esegui: ruby jarvis.rb --index" if index.empty?

    q = Ollama.embed(["search_query: #{query}"]).first
    ranked = index.map { |c| c.merge("score" => cosine(q, c["vector"])) }
                  .sort_by { |c| -c["score"] }
                  .first(top_k.to_i.clamp(1, 8))

    ranked.map { |c| { file: c["file"], score: c["score"].round(3), text: c["text"] } }
  end

  def self.save(title, text)
    slug = title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
    raise "Titolo non valido" if slug.empty?

    path = Filesystem.safe_path("#{slug}.md")
    File.write(path, "# #{title}\n\n#{text}\n", mode: "a")
    "Nota salvata in #{File.basename(path)} (esegui --index per renderla ricercabile)"
  end

  # Re-indicizza solo i file modificati dall'ultima volta.
  def self.build_index
    old = load_index.group_by { |c| c["file"] }
    files = Dir.glob(File.join(Config::BRAIN_DIR, "**", "*.md")).sort
    chunks = []

    files.each do |path|
      rel = path.delete_prefix(Config::BRAIN_DIR + File::SEPARATOR)
      mtime = File.mtime(path).to_i

      cached = old[rel]
      if cached && cached.first["mtime"] == mtime
        chunks.concat(cached)
        next
      end

      pieces = split(File.read(path, encoding: "UTF-8").scrub)
      next if pieces.empty?

      vectors = Ollama.embed(pieces.map { |p| "search_document: #{p}" })
      pieces.zip(vectors).each do |text, vec|
        chunks << { "file" => rel, "mtime" => mtime, "text" => text, "vector" => vec }
      end
      puts "indicizzato: #{rel} (#{pieces.size} frammenti)"
    end

    File.write(Config::INDEX_FILE, JSON.generate(chunks))
    "Indice pronto: #{chunks.size} frammenti da #{files.size} file"
  end

  def self.split(text)
    paragraphs = text.split(/\n{2,}/).map(&:strip).reject(&:empty?)
    pieces = []
    buffer = +""
    paragraphs.each do |p|
      if buffer.length + p.length > CHUNK_CHARS && !buffer.empty?
        pieces << buffer
        buffer = +""
      end
      buffer << "\n\n" unless buffer.empty?
      buffer << p
    end
    pieces << buffer unless buffer.empty?
    pieces.flat_map { |p| p.length > CHUNK_CHARS * 2 ? p.scan(/.{1,#{CHUNK_CHARS}}/m) : [p] }
  end

  def self.load_index
    return [] unless File.exist?(Config::INDEX_FILE)

    JSON.parse(File.read(Config::INDEX_FILE))
  rescue JSON::ParserError
    []
  end

  def self.cosine(a, b)
    dot = 0.0
    na = 0.0
    nb = 0.0
    a.each_index do |i|
      dot += a[i] * b[i]
      na += a[i]**2
      nb += b[i]**2
    end
    dot / (Math.sqrt(na) * Math.sqrt(nb) + 1e-12)
  end
end
