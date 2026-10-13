require "uri"
require_relative "feed_parser"

module DailyDigest
  # Filtra, deduplica e ordina senza LLM: sul tuo hardware ogni token costa.
  module Ranker
    MAX_PER_SOURCE = 3

    def self.select(items, ranking, n:, hours:, now: Time.now)
      cutoff = now - hours * 3600
      fresh = items.select { |it| it.published.nil? || it.published >= cutoff }

      deduplicate(fresh)
        .each { |it| it.score = score(it, ranking) }
        .reject { |it| it.score < ranking.fetch("min_score", 2) }
        .sort_by { |it| -it.score }
        .then { |sorted| cap_per_source(sorted) }
        .first(n)
    end

    def self.score(item, ranking)
      text = "#{item.title} #{item.text}".downcase
      total = 0.0

      ranking.fetch("keywords", {}).each { |word, weight| total += weight if text.include?(word.to_s.downcase) }
      total += 3.0 * (1 - [item.position.to_i, 25].min / 25.0) if item.ranked
      total += Math.log10(item.stars + 1) if item.stars
      total -= 5 if ranking.fetch("avoid", []).any? { |word| text.include?(word.downcase) }
      total
    end

    # Stesso link o stesso titolo normalizzato = stesso contenuto; si tiene il primo.
    def self.deduplicate(items)
      seen = {}
      items.each_with_object([]) do |it, kept|
        keys = [url_key(it.url), "t:#{title_key(it.title)}"]
        next if keys.any? { |k| seen[k] }

        keys.each { |k| seen[k] = true }
        kept << it
      end
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
      sorted.select { |it| (counts[it.source] += 1) <= MAX_PER_SOURCE }
    end
  end
end
