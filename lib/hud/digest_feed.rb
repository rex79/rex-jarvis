require "json"
require "net/http"
require "uri"

# Legge il digest pubblicato dal Mac mini (digest.json accanto al sito) per la dashboard.
#   JARVIS_DIGEST_URL       es. https://tuodominio.it/jarvis/  (oppure l'URL diretto di digest.json)
#   JARVIS_DIGEST_USER/PASSWORD  se la cartella è protetta da password (Basic auth): solo su https.
# Scarica al massimo ogni 15 minuti; se il sito non risponde mostra l'ultima copia valida.
# Il contenuto arriva da internet: viene validato e la dashboard lo inserisce solo come testo.
class DigestFeed
  class Error < StandardError; end

  TTL = 15 * 60
  MAX_BYTES = 1_000_000
  MAX_ENTRIES = 30

  def initialize(url: ENV["JARVIS_DIGEST_URL"], user: ENV["JARVIS_DIGEST_USER"], password: ENV["JARVIS_DIGEST_PASSWORD"],
                 fetcher: nil, clock: -> { Time.now })
    @url = url.to_s.strip
    @user = user.to_s
    @password = password.to_s
    @fetcher = fetcher || method(:http_get)
    @clock = clock
    @lock = Mutex.new
  end

  def configured?
    !@url.empty?
  end

  def latest
    @lock.synchronize do
      return @cache.merge(stale: false) if @cache && @clock.call - @fetched_at < TTL
      return @cache.merge(stale: true, error: @error) if @failed_at && @clock.call - @failed_at < 60 && @cache

      begin
        @cache = normalize(JSON.parse(@fetcher.call(uri, @user, @password)))
        @fetched_at = @clock.call
        @failed_at = @error = nil
        @cache.merge(stale: false)
      rescue StandardError => e
        @failed_at = @clock.call
        @error = e.message[0, 160]
        raise Error, @error unless @cache

        @cache.merge(stale: true, error: @error)
      end
    end
  end

  def uri
    u = URI.parse(@url.end_with?(".json") ? @url : "#{@url.chomp('/')}/digest.json")
    raise Error, "JARVIS_DIGEST_URL deve essere http(s)" unless %w[http https].include?(u.scheme) && u.host
    raise Error, "con utente e password serve https (altrimenti viaggiano in chiaro)" if !@user.empty? && u.scheme != "https"

    u
  rescue URI::InvalidURIError
    raise Error, "JARVIS_DIGEST_URL non valido"
  end

  private

  def normalize(data)
    raise Error, "digest.json non valido" unless data.is_a?(Hash) && data["entries"].is_a?(Array)

    entries = data["entries"].first(MAX_ENTRIES).select { |e| e.is_a?(Hash) && e["title"].is_a?(String) }.map do |e|
      url = e["url"].to_s
      {
        title: text(e["title"], 300), source: text(e["source"], 80), category: text(e["category"], 60),
        url: url.match?(%r{\Ahttps?://\S+\z}) ? url[0, 2000] : nil,
        summary: text(e["summary"], 1200), why: text(e["why"], 400), low: e["low"] == true
      }
    end
    { date: text(data["date"], 10), items: entries }
  end

  def text(value, max)
    value.is_a?(String) ? value.strip[0, max] : nil
  end

  def http_get(uri, user, password, redirects = 2)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 8
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "jarvis-hud/0.1"
    request.basic_auth(user, password) unless user.empty?

    response = http.request(request)
    case response
    when Net::HTTPSuccess
      body = response.body.to_s
      raise Error, "digest.json troppo grande" if body.bytesize > MAX_BYTES

      body.force_encoding("UTF-8").scrub
    when Net::HTTPRedirection
      target = URI.join(uri, response["location"])
      # Le credenziali seguono un redirect solo sullo stesso host e in https.
      raise Error, "redirect verso un altro host rifiutato" if target.host != uri.host || (!user.empty? && target.scheme != "https")
      raise Error, "troppi redirect" if redirects.zero?

      http_get(target, user, password, redirects - 1)
    when Net::HTTPUnauthorized then raise Error, "accesso negato: controlla JARVIS_DIGEST_USER/PASSWORD"
    else raise Error, "HTTP #{response.code}"
    end
  end
end
