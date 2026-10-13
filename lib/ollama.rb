require "net/http"
require "json"
require "uri"
require_relative "config"

class Ollama
  def initialize(model: Config::MAIN_MODEL)
    @model = model
  end

  def chat(messages, tools: [], options: nil)
    payload = {
      "model" => @model,
      "messages" => messages,
      "stream" => false,
      "think" => false,
      "keep_alive" => Config::KEEP_ALIVE
    }
    payload["tools"] = tools unless tools.empty?
    payload["options"] = options if options

    started = Time.now
    result = post("/api/chat", payload)
    puts "[OLLAMA] #{@model} ha risposto in #{(Time.now - started).round(1)}s"
    result
  end

  # Restituisce un array di vettori, uno per ogni testo.
  def self.embed(texts, model: Config::EMBED_MODEL)
    new.post("/api/embed", { "model" => model, "input" => texts, "keep_alive" => Config::KEEP_ALIVE })["embeddings"]
  end

  def post(path, payload)
    uri = URI("#{Config::OLLAMA_URL}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)

    http = Net::HTTP.new(uri.hostname, uri.port)
    http.open_timeout = 10
    http.read_timeout = 300 # CPU lenta: le risposte possono richiedere minuti
    http.write_timeout = 10

    response = http.request(request)
    raise "Ollama error: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end
end
