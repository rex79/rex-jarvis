require "net/http"
require "json"
require "uri"
require "time"
require_relative "feed_parser"

module DailyDigest
  module Collector
    UA = "jarvis-digest/0.1 (personal local assistant)".freeze

    def self.collect(sources)
      sources.flat_map do |source|
        case source["type"]
        when "feed"   then feed(source)
        when "github" then github(source)
        else []
        end
      rescue StandardError => e
        warn "⚠️  #{source['name']}: #{e.message}"
        []
      end
    end

    # Opzioni per fonte: ranked, title_prefix (es. "Ollama " per dare contesto a "v0.40.4"),
    # boost (punti extra: fonti ufficiali), exclude_url (regex, es. pre-release "-rc").
    def self.feed(source)
      items = FeedParser.parse(get(source["url"]), source["name"], ranked: source["ranked"] == true)
      items = items.reject { |it| it.url.match?(Regexp.new(source["exclude_url"])) } if source["exclude_url"]
      items.each do |it|
        it.title = "#{source['title_prefix']}#{it.title}" if source["title_prefix"]
        it.boost = source["boost"]
      end
    end

    def self.github(source)
      since = (Time.now - source.fetch("days", 7) * 86_400).strftime("%Y-%m-%d")

      source["topics"].flat_map do |topic|
        query = URI.encode_www_form_component("topic:#{topic} created:>#{since}")
        url = "https://api.github.com/search/repositories?q=#{query}&sort=stars&order=desc&per_page=10"

        JSON.parse(get(url, "Accept" => "application/vnd.github+json"))["items"].select { |r| r["stargazers_count"] >= source.fetch("min_stars", 0) }.map do |repo|
          Item.new(
            title: repo["full_name"],
            url: repo["html_url"],
            source: source["name"],
            published: Time.parse(repo["created_at"]),
            text: repo["description"].to_s,
            stars: repo["stargazers_count"]
          )
        end
      end
    end

    MIN_GAP = 2.0 # secondi tra due richieste allo stesso host (Reddit limita in fretta)
    @last_hit = {}

    def self.throttle(host)
      wait = MIN_GAP - (Time.now - (@last_hit[host] || Time.at(0)))
      sleep(wait) if wait.positive?
      @last_hit[host] = Time.now
    end

    def self.get(url, headers = {}, limit = 3, retries = 2)
      raise "troppi redirect" if limit.zero?

      uri = URI(url)
      throttle(uri.host)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 20

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = UA
      headers.each { |k, v| request[k] = v }
      # Il token (opzionale, alza i limiti dell'API) viaggia solo verso GitHub.
      request["Authorization"] = "Bearer #{ENV['GITHUB_TOKEN']}" if uri.host == "api.github.com" && ENV["GITHUB_TOKEN"]

      response = http.request(request)
      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection then get(URI.join(url, response["location"]).to_s, headers, limit - 1, retries)
      when Net::HTTPTooManyRequests, Net::HTTPServerError
        raise "HTTP #{response.code}" if retries.zero?

        sleep([response["retry-after"].to_i, 5].max * (3 - retries))
        get(url, headers, limit, retries - 1)
      else raise "HTTP #{response.code}"
      end
    end
  end
end
