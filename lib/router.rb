require_relative "config"
require_relative "privacy"
require_relative "ollama"

# Decide il contesto di un comando. Nell'ordine:
#   1. prefisso esplicito ("lavoro: …", "personale: …"), che viene tolto dal testo;
#   2. parole chiave: basta un segnale di lavoro perché il comando resti nel contesto di lavoro;
#   3. un modello LOCALE (il testo può contenere dati di lavoro);
#   4. nel dubbio, lavoro: è la scelta prudente, perché lì nulla esce dal computer.
module Router
  Route = Struct.new(:context, :text, :reason)

  PREFIXES = { "lavoro" => :work, "work" => :work, "personale" => :personal, "personal" => :personal }.freeze

  WORK_WORDS = %w[briefing riunion meeting progett client jira copilot knowledge uat steering scadenz
                  stakeholder report rischi blocker decision follow-up agenda].freeze
  PERSONAL_WORDS = %w[musica canzon brano playlist spotify riproduci metti suona pausa volume
                      album artista].freeze

  CLASSIFY_PROMPT = <<~PROMPT.freeze
    Classifica la richiesta dell'utente in uno di due contesti e rispondi con una sola parola:
    - lavoro: attività professionali (progetti, riunioni, clienti, colleghi, documenti di lavoro, briefing);
    - personale: tutto il resto (musica, interessi personali, note private, notizie sull'AI).
    Se non sei sicuro rispondi lavoro.
  PROMPT

  def self.route(text, llm: nil)
    stripped = text.to_s.strip
    if (m = stripped.match(/\A(lavoro|work|personale|personal)\s*[:,]\s*/i))
      return Route.new(PREFIXES[m[1].downcase], m.post_match, "prefisso")
    end

    return Route.new(:work, stripped, "parole chiave") if hits(stripped, WORK_WORDS).positive?
    return Route.new(:personal, stripped, "parole chiave") if hits(stripped, PERSONAL_WORDS).positive?

    Route.new(classify(stripped, llm), stripped, "modello locale")
  end

  def self.hits(text, words)
    words.count { |w| text.match?(/\b#{Regexp.escape(w)}/i) }
  end

  def self.classify(text, llm)
    llm ||= begin
      Privacy.assert_local!(Config::OLLAMA_URL, "Il router")
      Ollama.new(model: Config::ROUTER_MODEL)
    end
    messages = [{ role: "system", content: CLASSIFY_PROMPT }, { role: "user", content: text }]
    answer = llm.chat(messages, options: { temperature: 0, num_predict: 5 })["message"]["content"].to_s
    answer.downcase.include?("personale") ? :personal : :work
  rescue Privacy::Error
    raise
  rescue StandardError
    :work # modello irraggiungibile o risposta strana: si resta nel contesto prudente
  end
end
