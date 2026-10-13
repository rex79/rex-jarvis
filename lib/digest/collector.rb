require "net/http"
require "json"
require "uri"
require "time"
require_relative "feed_parser"
require_relative "reddit"

module DailyDigest
  module Collector
    UA = "jarvis-digest/0.1 (personal local assistant)".freeze

    def self.collect(sources)
      sources.flat_map do |source|
        case source["type"]
        when "feed"   then feed(source)
        when "reddit" then reddit(source)
        when "github" then github(source)
        else []
        end
      rescue StandardError => e
        warn "⚠️  #{source['name']}: #{e.message}"
        []
      end
    end

    # Opzioni per fonte: ranked, title_prefix (es. "Ollama " per dare contesto a "v0.40.4"),
    # boost (punti extra: fonti ufficiali), exclude_url / exclude_title (regex: pre-release,
    # annunci di eventi), max_items (tetto di voci di questa fonte in un digest).
    def self.feed(source)
      decorate(FeedParser.parse(get(source["url"]), source["name"], ranked: source["ranked"] == true), source)
    end

    # `hours`: finestra di freschezza della fonte (default globale 48h). Le fonti che pubblicano
    # di rado (blog, newsletter) ne hanno una più lunga: la memoria dei link visti evita i doppioni.
    def self.decorate(items, source)
      items = items.reject { |it| it.url.match?(Regexp.new(source["exclude_url"])) } if source["exclude_url"]
      items = items.reject { |it| it.title.match?(Regexp.new(source["exclude_title"], Regexp::IGNORECASE)) } if source["exclude_title"]
      items.each do |it|
        it.title = "#{source['title_prefix']}#{it.title}" if source["title_prefix"]
        it.boost = source["boost"]
        it.cap = source["max_items"]
        it.window = source["hours"]
        it.category = source["category"]
      end
    end

    # API ufficiale con OAuth se ci sono le credenziali; altrimenti (o se l'API fallisce)
    # il feed RSS pubblico, che Reddit però limita spesso con errori 429.
    def self.reddit(source)
      if RedditClient.configured? && !@reddit_auth_failed
        begin
          return decorate((@reddit_client ||= RedditClient.new).top(source["subreddit"]), source)
        rescue RedditClient::AuthError => e
          @reddit_auth_failed = true # inutile riprovare per gli altri subreddit
          warn "⚠️  #{e.message}: uso i feed RSS"
        rescue StandardError => e
          warn "⚠️  #{source['name']}: API Reddit non riuscita (#{e.message}), uso il feed RSS"
        end
      elsif !RedditClient.configured? && !@reddit_warned
        @reddit_warned = true
        warn "⚠️  REDDIT_CLIENT_ID/REDDIT_CLIENT_SECRET non impostate: uso i feed RSS di Reddit (spesso limitati)"
      end

      feed(source.merge("url" => "https://www.reddit.com/r/#{source['subreddit']}/top/.rss?t=day", "ranked" => true))
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
            stars: repo["stargazers_count"],
            category: source["category"]
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
