require "json"
require "fileutils"
require_relative "../config"
require_relative "ranker"

module DailyDigest
  # Ricorda i contenuti già pubblicati per non ripeterli nei digest dei giorni dopo.
  # File: ~/brain/digest/.visti.json  ({ chiave => "AAAA-MM-GG" }), voci più vecchie di 30 giorni scartate.
  class Seen
    RETENTION_DAYS = 30

    def initialize(path = File.join(Config::BRAIN_DIR, "digest", ".visti.json"), now: Time.now)
      @path = path
      @today = now.strftime("%Y-%m-%d")
      @cutoff = (now - RETENTION_DAYS * 86_400).strftime("%Y-%m-%d")
      @entries = load
    end

    # Le voci registrate oggi non contano: rilanciare il digest nello stesso giorno
    # deve dare lo stesso risultato, non sovrascrivere il file con voci diverse.
    def include?(item)
      Ranker.keys(item).any? { |key| (date = @entries[key]) && date < @today }
    end

    def add(items)
      items.each { |item| Ranker.keys(item).each { |key| @entries[key] ||= @today } }
    end

    def save
      @entries.reject! { |_, date| date < @cutoff }
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp"
      File.write(tmp, JSON.generate(@entries))
      File.rename(tmp, @path) # scrittura atomica: un crash non lascia un file a metà
    end

    private

    def load
      return {} unless File.exist?(@path)

      data = JSON.parse(File.read(@path, encoding: "UTF-8"))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      warn "⚠️  #{@path} è danneggiato: riparto da una memoria vuota"
      {}
    end
  end
end
