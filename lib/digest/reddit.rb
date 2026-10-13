require "net/http"
require "json"
require "uri"
require_relative "feed_parser"

module DailyDigest
  # Client Reddit con OAuth "client credentials": legge solo contenuti pubblici, quindi
  # servono id e secret di un'app di tipo "script" ma NON la password dell'utente.
  # Token solo in memoria: non viene scritto su disco né stampato.
  class RedditClient
    class AuthError < StandardError; end

    TOKEN_URI = URI("https://www.reddit.com/api/v1/access_token")
    API_HOST  = "https://oauth.reddit.com".freeze

    def self.configured?
      !ENV["REDDIT_CLIENT_ID"].to_s.empty? && !ENV["REDDIT_CLIENT_SECRET"].to_s.empty?
    end

    def initialize(id: ENV["REDDIT_CLIENT_ID"], secret: ENV["REDDIT_CLIENT_SECRET"],
                   user_agent: ENV.fetch("REDDIT_USER_AGENT", "jarvis-digest/0.1"))
      @id = id
      @secret = secret
      @user_agent = user_agent
    end

    def top(subreddit, period: "day", limit: 25)
      raise ArgumentError, "nome subreddit non valido: #{subreddit}" unless subreddit.to_s.match?(/\A\w+\z/)

      uri = URI("#{API_HOST}/r/#{subreddit}/top?t=#{period}&limit=#{limit}&raw_json=1")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      request["User-Agent"] = @user_agent

      posts = JSON.parse(fetch(uri, request)).dig("data", "children").map { |child| child["data"] }
      posts.reject { |p| p["stickied"] || p["over_18"] }.each_with_index.map do |p, i|
        Item.new(
          title: p["title"].to_s.strip,
          url: "https://www.reddit.com#{p['permalink']}",
          source: "r/#{subreddit}",
          published: Time.at(p["created_utc"].to_f),
          text: p["selftext"].to_s.gsub(/\s+/, " ").strip,
          position: i,
          ranked: true
        )
      end
    end

    private

    def access_token
      @access_token ||= begin
        request = Net::HTTP::Post.new(TOKEN_URI)
        request["Authorization"] = "Basic #{["#{@id}:#{@secret}"].pack("m0")}"
        request["User-Agent"] = @user_agent
        request.set_form_data("grant_type" => "client_credentials")

        token = JSON.parse(fetch(TOKEN_URI, request))["access_token"]
        raise "Reddit OAuth: risposta senza token (controlla id e secret)" if token.to_s.empty?

        token
      end
    end

    # Restituisce il body o solleva un errore che non contiene mai credenziali.
    def fetch(uri, request)
      status, body = send_request(uri, request)
      return body if status.between?(200, 299)
      raise AuthError, "Reddit OAuth: credenziali non valide (HTTP #{status})" if [401, 403].include?(status)

      raise "Reddit HTTP #{status}"
    end

    def send_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20
      response = http.request(request)
      [response.code.to_i, response.body.to_s]
    end
  end
end
