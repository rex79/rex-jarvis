require "uri"

# Garanzia del contesto di lavoro: i dati non escono dal computer. Ogni modello usato in quel
# contesto (e dal router, che legge anche i comandi di lavoro) deve rispondere su un indirizzo
# locale; altrimenti Jarvis si rifiuta di procedere invece di inviare dati altrove.
module Privacy
  class Error < StandardError; end

  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  def self.local_url?(url)
    host = URI.parse(url.to_s).host.to_s.delete("[]").downcase
    LOCAL_HOSTS.include?(host)
  rescue URI::InvalidURIError
    false
  end

  def self.assert_local!(url, what)
    return if local_url?(url)

    raise Error, "#{what} deve usare un modello locale, ma OLLAMA_URL punta a #{url}: " \
                 "i dati di lavoro non devono uscire dal computer"
  end
end
