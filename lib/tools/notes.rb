require "json"
require "time"
require_relative "../config"
require_relative "../ollama"
require_relative "filesystem"

# Ricerca semantica e salvataggio note in una cartella radice (le note di un contesto),
# con il proprio indice. Gli embedding usano sempre Ollama locale. I metodi di classe usano
# la cartella personale (Config::BRAIN_DIR), come prima.
class Notes
  CHUNK_CHARS = 800

  attr_reader :root

  def initialize(root = Config::BRAIN_DIR)
    @root = File.expand_path(root)
    @fs = Filesystem.new(@root)
  end

  def self.default
    new(Config::BRAIN_DIR)
  end

  def self.search(query, top_k = 4) = default.search(query, top_k)
  def self.save(title, text) = default.save(title, text)
  def self.build_index = default.build_index

  def index_file
    File.join(@root, ".jarvis_index.json")
  end

  def search(query, top_k = 4)
    index = load_index
    return "Nessuna nota indicizzata. Esegui: ruby jarvis.rb --index" if index.empty?

    q = Ollama.embed(["search_query: #{query}"]).first
    ranked = index.map { |c| c.merge("score" => self.class.cosine(q, c["vector"])) }
                  .sort_by { |c| -c["score"] }
                  .first(top_k.to_i.clamp(1, 8))

    ranked.map { |c| { file: c["file"], score: c["score"].round(3), text: c["text"] } }
  end

  def save(title, text)
    slug = title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
    raise "Titolo non valido" if slug.empty?

    path = @fs.safe_path("#{slug}.md")
    File.write(path, "# #{title}\n\n#{text}\n", mode: "a")
    "Nota salvata in #{File.basename(path)} (esegui --index per renderla ricercabile)"
  end

  # Re-indicizza solo i file modificati dall'ultima volta.
  def build_index
    old = load_index.group_by { |c| c["file"] }
    files = Dir.glob(File.join(@root, "**", "*.md")).sort
    chunks = []

    files.each do |path|
      rel = path.delete_prefix(@root + File::SEPARATOR)
      mtime = File.mtime(path).to_i

      cached = old[rel]
      if cached && cached.first["mtime"] == mtime
        chunks.concat(cached)
        next
      end

      pieces = self.class.split(File.read(path, encoding: "UTF-8").scrub)
      next if pieces.empty?

      vectors = Ollama.embed(pieces.map { |p| "search_document: #{p}" })
      pieces.zip(vectors).each do |text, vec|
        chunks << { "file" => rel, "mtime" => mtime, "text" => text, "vector" => vec }
      end
      puts "indicizzato: #{rel} (#{pieces.size} frammenti)"
    end

    File.write(index_file, JSON.generate(chunks))
    "Indice pronto: #{chunks.size} frammenti da #{files.size} file"
  end

  def load_index
    return [] unless File.exist?(index_file)

    JSON.parse(File.read(index_file, encoding: "UTF-8"))
  rescue JSON::ParserError
    []
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
