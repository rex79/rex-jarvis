require "net/http"
require "json"
require "uri"
require "date"
require_relative "config"
require_relative "trading"
require_relative "signals"

# Bot Telegram di Jarvis (contesto personale, Mac mini). Legge soltanto i report già scritti
# da --trading e --signals: non lancia analisi, non chiama modelli, non esegue comandi.
# Risponde solo agli ID in JARVIS_TELEGRAM_ALLOWED_USERS e solo in chat privata; gli altri
# messaggi vengono ignorati. Il token non compare mai in log o errori.
class TelegramBot
  class Error < StandardError; end

  API = "api.telegram.org"
  POLL = 50 # secondi di long polling
  MAX_MESSAGE = 4000 # Telegram accetta fino a 4096 caratteri

  HELP = <<~TEXT.freeze
    Comandi di Jarvis:
    /trading — le decisioni dell'ultima analisi dei titoli
    /trading NVDA — il dettaglio di un titolo
    /segnali — gli ultimi segnali crypto
  TEXT

  def initialize(token: Config::TELEGRAM_TOKEN, allowed: Config::TELEGRAM_ALLOWED,
                 trading_file: File.join(Trading.dir, "latest.json"),
                 signals_file: File.join(Signals.dir, "latest.json"), http: nil)
    raise Error, "imposta JARVIS_TELEGRAM_TOKEN (il token di @BotFather)" if token.to_s.empty?
    raise Error, "imposta JARVIS_TELEGRAM_ALLOWED_USERS (il tuo ID numerico Telegram)" if allowed.empty?

    @token = token
    @allowed = allowed.map(&:to_s)
    @trading_file = trading_file
    @signals_file = signals_file
    @http = http || method(:call)
  end

  def run
    offset = nil
    puts "🤖 Bot Telegram di Jarvis attivo (#{@allowed.size} utente/i ammesso/i)."
    loop do
      updates = @http.call("getUpdates", { timeout: POLL, offset: offset, allowed_updates: ["message"] })
      updates.each do |update|
        offset = update["update_id"] + 1
        process(update)
      end
    rescue Error, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      warn "⚠️  Telegram: #{e.message}"
      sleep 10
    end
  end

  def process(update)
    message = update["message"] or return
    user = message.dig("from", "id").to_s
    unless message.dig("chat", "type") == "private" && @allowed.include?(user)
      warn "messaggio ignorato da un utente non ammesso (id #{user})"
      return
    end

    reply(message.dig("chat", "id"), answer(message["text"].to_s))
  end

  def answer(text)
    command, arg = text.strip.split(/\s+/, 2)
    case command.to_s.downcase.sub(/@\w+\z/, "")
    when "/trading" then arg ? trading_detail(arg) : trading_overview
    when "/segnali" then signals_overview
    else HELP
    end
  end

  def trading_overview
    data = Trading.latest(@trading_file) or return "Nessuna analisi ancora: sul Mac mini esegui ruby jarvis.rb --trading"

    lines = ["📈 Analisi titoli del #{day(data['date'])}", ""]
    data["tickers"].each do |t|
      lines << (t["error"] ? "#{t['ticker']}: non disponibile" : "#{t['ticker']}: #{t['decision']}")
    end
    lines += ["", "Dettaglio: /trading TICKER", "È ricerca automatica, non un consiglio di investimento."]
    lines.join("\n")
  end

  def trading_detail(ticker)
    data = Trading.latest(@trading_file) or return "Nessuna analisi ancora."
    item = data["tickers"].find { |t| t["ticker"].casecmp?(ticker.strip) }
    return "#{ticker.strip.upcase} non è nell'analisi del #{day(data['date'])}." unless item
    return "#{item['ticker']}: analisi non riuscita (#{item['error']})" if item["error"]

    "#{item['ticker']}: #{item['decision']} (#{day(data['date'])})\n\n#{item['summary']}"
  end

  def signals_overview
    data = Signals.latest(@signals_file) or return "Nessun segnale ancora: sul Mac mini esegui ruby jarvis.rb --signals"

    lines = ["🪙 Segnali crypto", ""]
    data["signals"].each do |s|
      lines << (s["error"] ? "#{s['product']}: non disponibile" : "#{s['product']}: #{s['label']}")
    end
    lines.join("\n")
  end

  def reply(chat_id, text)
    chunks(text).each { |chunk| @http.call("sendMessage", { chat_id: chat_id, text: chunk }) }
  end

  # Divide sui ritorni a capo per restare sotto il limite di Telegram.
  def chunks(text)
    text.each_line.with_object([+""]) do |line, out|
      out << +"" if out.last.size + line.size > MAX_MESSAGE
      out.last << line.slice(0, MAX_MESSAGE)
    end.reject { |c| c.strip.empty? }
  end

  def day(iso)
    Trading.long_date(Date.iso8601(iso.to_s))
  rescue Date::Error
    iso.to_s
  end

  private

  def call(method, params)
    http = Net::HTTP.new(API, 443)
    http.use_ssl = true
    http.read_timeout = POLL + 10
    request = Net::HTTP::Post.new("/bot#{@token}/#{method}", "Content-Type" => "application/json")
    request.body = JSON.generate(params.compact)
    response = http.request(request)
    data = JSON.parse(response.body)
    raise Error, "#{method}: #{data['description'] || response.code}" unless data["ok"]

    data["result"]
  rescue JSON::ParserError
    raise Error, "#{method}: risposta non valida (HTTP #{response&.code})"
  end
end
