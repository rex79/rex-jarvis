# Comandi semplici riconosciuti con regole fisse, senza modello: istantanei e sempre uguali
# (i modelli piccoli a volte rispondono "fatto" senza eseguire nulla). Le richieste complesse,
# come una playlist per nome, restano all'agente.
module Intents
  MUSIC_WORDS = /\b(musica|canzon\w*|brano|traccia|spotify|apple music)\b/i
  SPECIFIC = /\b(playlist|album|artista|di|dei|degli|della)\b/i
  FILLER = /\b(jarvis|per favore|grazie|la|il|lo|le|un|una|su|mi|me|ti)\b/i

  MUSIC_ACTIONS = [
    ["pause",    /\b(pausa|ferma\w*|stop\w*|interromp\w*|silenzio)\b/i],
    ["play",     /\b(riprendi|ripart\w*|continua|play|riproduci|rimetti|fai partire|avvia|metti)\b/i],
    ["next",     /\b(prossim\w*|successiv\w*|avanti|salta|skip)\b/i],
    ["previous", /\b(precedente|indietro|torna)\b/i]
  ].freeze

  COPILOT = /\b(copilot|briefing|agente)\b/i
  NEW_CONVERSATION = /\A\s*(?:jarvis\s*[,:]?\s*)?(?:nuova conversazione|ricominciamo|chiudi (?:la )?conversazione)\s*[.!]?\s*\z/i

  def self.new_conversation?(text)
    text.to_s.match?(NEW_CONVERSATION)
  end

  # Richieste da inoltrare così come sono all'agente Copilot (contesto di lavoro): il modello
  # locale non le riformula, l'agente riceve le parole dell'utente.
  def self.copilot?(text)
    text.to_s.match?(COPILOT)
  end

  # Toglie le parole rivolte a Jarvis ("Jarvis, chiedi a Copilot …"): l'agente riceve solo la richiesta.
  # "dammi il daily briefing" resta com'è.
  COPILOT_LEAD = /\A\s*(?:jarvis\s*[,:]?\s*)?(?:(?:chiedi|domanda)\s+(?:a|al|all')\s*)?(?:copilot|agente)\s*[,:]?\s*(?:(?:se|di|che)\s+)?/i

  def self.copilot_request(text)
    stripped = text.to_s.strip.sub(COPILOT_LEAD, "").sub(/\A\s*jarvis\s*[,:]?\s*/i, "")
    stripped.empty? ? text.to_s.strip : stripped[0].upcase + stripped[1..]
  end

  # Restituisce [azione, app] per un comando musicale semplice, altrimenti nil.
  # Vale se il testo nomina la musica, oppure se è solo il verbo ("pausa", "Jarvis, riprendi"):
  # "continua il report" non è un comando musicale.
  def self.music(text)
    clean = text.to_s.downcase.gsub(/[^\p{L}\p{N}\s]/, " ")
    return nil if clean.match?(SPECIFIC)

    bare = clean.gsub(FILLER, " ").split
    return nil unless clean.match?(MUSIC_WORDS) || bare.size == 1

    action = MUSIC_ACTIONS.find { |_, pattern| clean.match?(pattern) }&.first
    return nil unless action

    app = if clean.include?("spotify") then "Spotify"
          elsif clean.include?("apple music") then "Music"
          end
    [action, app]
  end
end
