require "json"
require "net/http"
require "open3"
require "socket"
require "etc"
require_relative "../config"
require_relative "../privacy"
require_relative "../site"
require_relative "../tools/music"
require_relative "digest_feed"

# Fotografia dello stato per la dashboard. Ogni pannello è indipendente: se una parte fallisce
# (Ollama spento, app musicale senza permesso) restituisce un errore leggibile e le altre continuano.
class HudStatus
  def initialize(music: Music, ollama_url: Config::OLLAMA_URL, digest_dir: File.join(Config::BRAIN_DIR, "digest"),
                 feed: DigestFeed.new)
    @feed = feed
    @music = music
    @ollama_url = ollama_url
    @digest_dir = digest_dir
  end

  def snapshot
    {
      host: Socket.gethostname.split(".").first,
      system: safe { system_info },
      privacy: privacy,
      ollama: safe { ollama },
      music: safe { @music.now_playing },
      digest: safe { digest }
    }
  end

  def privacy
    {
      local: Privacy.local_url?(@ollama_url),
      work_model: Config::WORK_MODEL,
      personal_model: Config::MAIN_MODEL,
      work_dir: Config::WORK_DIR,
      personal_dir: Config::BRAIN_DIR
    }
  end

  def system_info
    cores = Etc.respond_to?(:nprocessors) ? Etc.nprocessors : nil
    load = File.exist?("/proc/loadavg") ? File.read("/proc/loadavg").split.first.to_f : sysctl("vm.loadavg")[/[\d.]+/].to_f
    ram = File.exist?("/proc/meminfo") ? File.read("/proc/meminfo")[/MemTotal:\s+(\d+)/, 1].to_i * 1024 : sysctl("hw.memsize").to_i
    {
      load: load.round(2),
      cores: cores,
      load_percent: cores ? [(load / cores * 100).round, 100].min : nil,
      ram_gb: (ram / 1_073_741_824.0).round,
      battery: battery,
      disk_free_gb: disk_free_gb
    }
  end

  def ollama
    uri = URI("#{@ollama_url}/api/ps")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 1
    http.read_timeout = 2
    models = JSON.parse(http.get(uri.path).body).fetch("models", [])
    { online: true, models: models.map { |m| { name: m["name"], gb: (m["size"].to_i / 1_073_741_824.0).round(1) } } }
  rescue StandardError
    { online: false, models: [] }
  end

  # Il digest pubblicato dal Mac mini (JARVIS_DIGEST_URL) se configurato, altrimenti quello locale.
  def digest
    return @feed.latest.merge(origin: "remoto") if @feed.configured?

    file = Dir.glob(File.join(@digest_dir, "*.md")).max
    return { date: nil, items: [], origin: "locale" } unless file

    day = Site.parse(File.read(file, encoding: "UTF-8").scrub, File.basename(file, ".md"))
    items = day.entries.map do |e|
      { title: e.title, source: e.source, category: e.category, url: e.url, summary: e.summary, why: e.why, low: e.low? }
    end
    { date: day.date, items: items, origin: "locale" }
  end

  private

  def safe
    yield
  rescue StandardError => e
    { error: e.message[0, 160] }
  end

  def sysctl(key)
    out, = Open3.capture2("sysctl", "-n", key)
    out
  end

  def battery
    return nil unless RUBY_PLATFORM.include?("darwin")

    out, = Open3.capture2("pmset", "-g", "batt")
    out[/(\d+)%/, 1]&.to_i
  end

  def disk_free_gb
    out, = Open3.capture2("df", "-k", "/")
    (out.lines.last.split[3].to_i / 1_048_576.0).round
  end
end
