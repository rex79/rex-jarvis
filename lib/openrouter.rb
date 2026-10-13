require "net/http"
require "json"
require "uri"
require_relative "config"

# Client minimo per OpenRouter (formato OpenAI chat/completions). Restituisce la stessa
# forma di Ollama#chat ({"message" => {"content" => ...}}) così il Builder non cambia.
# La chiave si legge solo da OPENROUTER_API_KEY e non compare mai in log o errori.
class OpenRouter
  class AuthError < StandardError; end

  attr_reader :model

  def initialize(model: Config::DIGEST_MODEL, api_key: ENV["OPENROUTER_API_KEY"])
    raise AuthError, "OPENROUTER_API_KEY non impostata" if api_key.to_s.empty?
    raise ArgumentError, "Imposta JARVIS_DIGEST_MODEL (es. 'provider/modello', vedi openrouter.ai/models)" if model.to_s.empty?

    @model = model
    @api_key = api_key
  end

  def chat(messages, options: nil, **)
    payload = { "model" => @model, "messages" => messages }
    payload["max_tokens"] = options[:num_predict] if options&.key?(:num_predict)
    payload["temperature"] = options[:temperature] if options&.key?(:temperature)

    started = Time.now
    data = post(payload)
    puts "[OPENROUTER] #{@model} ha risposto in #{(Time.now - started).round(1)}s"

    content = data.dig("choices", 0, "message", "content")
    raise "Risposta OpenRouter senza contenuto: #{data['error'] || data.keys}" if content.nil?

    { "message" => { "role" => "assistant", "content" => content } }
  end

  private

  def post(payload)
    uri = URI(Config::OPENROUTER_URL)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{@api_key}"
    request["X-Title"] = "Jarvis daily digest"
    request.body = JSON.generate(payload)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 120

    response = http.request(request)
    case response
    when Net::HTTPSuccess then JSON.parse(response.body)
    when Net::HTTPUnauthorized, Net::HTTPPaymentRequired, Net::HTTPForbidden
      raise AuthError, "OpenRouter HTTP #{response.code}: chiave non valida o credito esaurito"
    else
      raise "OpenRouter HTTP #{response.code}: #{response.body.to_s[0, 200]}"
    end
  end
end
