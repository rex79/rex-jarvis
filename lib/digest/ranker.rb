require "uri"
require_relative "feed_parser"

module DailyDigest
  # Filtra, deduplica e ordina senza LLM: sul tuo hardware ogni token costa.
  module Ranker
    MAX_PER_SOURCE = 3
    MAX_KEYWORD_SCORE = 6.0 # tetto: una voce piena di parole chiave non deve schiacciare le fonti primarie

    def self.select(items, ranking, n:, hours:, now: Time.now, seen: nil, categories: nil)
      fresh = items.select { |it| it.published.nil? || it.published >= now - (it.window || hours) * 3600 }
      fresh = fresh.reject { |it| seen&.include?(it) }

      deduplicate(fresh)
        .each { |it| it.score = score(it, ranking) }
        .reject { |it| it.score < ranking.fetch("min_score", 2) }
        .sort_by { |it| -it.score }
        .then { |sorted| cap_per_source(sorted) }
        .then { |sorted| pick(sorted, categories, n) }
    end

    # Con le categorie ogni gruppo ha i suoi posti (`slots`): Reddit non può occupare tutto il
    # digest e le fonti primarie, che pubblicano di rado, hanno un posto garantito. I posti
    # lasciati vuoti passano alle migliori voci rimaste. Ordine finale: per categoria, poi punteggio.
    def self.pick(sorted, categories, n)
      return sorted.first(n) if categories.nil? || categories.empty?

      order = categories.map { |c| c["id"] }
      chosen = categories.flat_map { |c| sorted.select { |it| it.category == c["id"] }.first(c["slots"].to_i) }
      chosen = chosen.sort_by { |it| -it.score }.first(n)
      chosen += (sorted - chosen).first(n - chosen.size) if chosen.size < n
      chosen.sort_by { |it| [order.index(it.category) || order.size, -it.score] }
    end

    def self.score(item, ranking)
      text = "#{item.title} #{item.text}".downcase
      total = 0.0

      keywords = ranking.fetch("keywords", {}).sum { |word, weight| keyword?(text, word.to_s) ? weight : 0 }
      total += [keywords, MAX_KEYWORD_SCORE].min
      total += 3.0 * (1 - [item.position.to_i, 25].min / 25.0) if item.ranked
      total += Math.log10(item.stars + 1) if item.stars
      total += item.boost.to_f
      total -= 5 if ranking.fetch("avoid", []).any? { |word| text.include?(word.downcase) }
      total
    end

    # Parola intera, non sottostringa ("rag" non deve scattare su "storage"). Le parole brevi
    # ammettono il plurale e cifre dopo ("llms", "qwen3"); le lunghe sono un prefisso ("quantiz").
    def self.keyword?(text, word)
      escaped = Regexp.escape(word.downcase)
      pattern = word.length <= 4 ? /\b#{escaped}s?(?![a-z])/i : /\b#{escaped}/i
      text.match?(pattern)
    end

    # Stesso link o stesso titolo normalizzato = stesso contenuto; si tiene il primo.
    def self.deduplicate(items)
      seen = {}
      items.each_with_object([]) do |it, kept|
        keys = keys(it)
        next if keys.any? { |k| seen[k] }

        keys.each { |k| seen[k] = true }
        kept << it
      end
    end

    # Chiavi di identità di un contenuto: link normalizzato e titolo normalizzato.
    def self.keys(item)
      [url_key(item.url), "t:#{title_key(item.title)}"]
    end

    def self.url_key(url)
      uri = URI(url)
      "u:#{uri.host.to_s.sub(/\Awww\./, '').downcase}#{uri.path.to_s.chomp('/')}"
    rescue URI::InvalidURIError
      "u:#{url}"
    end

    def self.title_key(title)
      title.downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def self.cap_per_source(sorted)
      counts = Hash.new(0)
      sorted.select { |it| (counts[it.source] += 1) <= (it.cap || MAX_PER_SOURCE) }
    end
  end
end
