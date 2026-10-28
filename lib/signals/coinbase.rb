require "net/http"
require "json"
require "uri"
require "time"
require "date"

module Signals
  class Error < StandardError; end

  Candle = Struct.new(:time, :open, :high, :low, :close, :volume, keyword_init: true) do
    def date = time.utc.to_date
  end

  # Candele giornaliere dall'API pubblica di Coinbase Exchange: nessuna chiave e nessun dato
  # dell'utente, solo prezzi. Al massimo 300 candele per richiesta, quindi si va a blocchi.
  # La candela del giorno in corso non è chiusa e viene scartata: i segnali usano solo chiusure.
  class Coinbase
    URL = "https://api.exchange.coinbase.com/products/%s/candles"
    DAY = 86_400
    PER_REQUEST = 300
    PRODUCT = /\A[A-Z0-9]{2,10}-[A-Z]{3,5}\z/

    # http: riceve un URI e restituisce il corpo della risposta (sostituibile nei test).
    def initialize(http: method(:get), pause: 0.25)
      @http = http
      @pause = pause
    end

    def candles(product, days:, now: Time.now)
      raise Error, "coppia non valida: #{product.inspect} (es. BTC-EUR)" unless product.to_s.match?(PRODUCT)

      today = Time.at(now.to_i / DAY * DAY).utc # mezzanotte UTC: inizio della candela non ancora chiusa
      by_time = {}
      finish = today
      while by_time.size < days
        start = finish - PER_REQUEST * DAY
        rows = fetch(product, start, finish)
        break if rows.empty? # prima della quotazione non ci sono dati

        rows.each { |row| by_time[row[0]] = row }
        finish = start
        sleep @pause if @pause.positive?
      end

      by_time.values
             .map { |t, low, high, open, close, volume| Candle.new(time: Time.at(t).utc, open: open.to_f, high: high.to_f, low: low.to_f, close: close.to_f, volume: volume.to_f) }
             .reject { |c| c.time >= today }
             .sort_by(&:time)
             .last(days)
    end

    private

    def fetch(product, start, finish)
      query = URI.encode_www_form(granularity: DAY, start: start.iso8601, end: finish.iso8601)
      data = JSON.parse(@http.call(URI("#{format(URL, product)}?#{query}")))
      raise Error, "Coinbase: #{data['message'] || 'risposta inattesa'} (#{product})" unless data.is_a?(Array)

      data
    rescue JSON::ParserError
      raise Error, "Coinbase ha risposto con dati non validi (#{product})"
    end

    def get(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30
      response = http.get(uri.request_uri, "User-Agent" => "jarvis-signals", "Accept" => "application/json")
      return response.body if response.is_a?(Net::HTTPSuccess)

      message = (JSON.parse(response.body)["message"] rescue nil) || response.body.to_s[0, 120]
      raise Error, "Coinbase HTTP #{response.code}: #{message}"
    end
  end
end
