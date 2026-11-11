require "date"
require "json"
require "fileutils"
require_relative "../../lib/config"
require_relative "../../lib/modules"

# Cosa c'è in congelatore, frigo e dispensa, e cosa cucinarci.
#   - L'elenco sta in ~/brain/casa/dispensa.md: una nota come le altre (indicizzata, modificabile a mano).
#   - Aggiungere, togliere ed elencare si fa con regole fisse, senza modello: immediato e sempre uguale.
#   - Solo le idee per i pasti usano un modello online (OpenRouter): gli arrivano l'elenco degli
#     alimenti e la frase dell'utente, nient'altro.
module Dispensa
  PLACES = {
    "congelatore" => { label: "Congelatore", where: "nel congelatore", from: "dal congelatore", empty: "Il congelatore è vuoto.",
                       words: %w[congelatore freezer frizer surgelatore] },
    "frigo" => { label: "Frigo", where: "in frigo", from: "dal frigo", empty: "Il frigo è vuoto.", words: %w[frigorifero frigo] },
    "dispensa" => { label: "Dispensa", where: "in dispensa", from: "dalla dispensa", empty: "La dispensa è vuota.", words: %w[dispensa credenza] }
  }.freeze

  Item = Struct.new(:name, :since)

  # Parole che non distinguono un alimento da un altro: articoli, numeri, unità di misura.
  STOP = %w[il lo la i gli le l un una uno di del della dei degli delle dello dell d e ed da in con
            due tre quattro cinque sei sette otto nove dieci mezzo mezza po paio
            confezione confezioni pacco pacchi pacchetto pacchetti busta buste vaschetta vaschette porzione porzioni
            kg chilo chili grammi etto etti litro litri bottiglia bottiglie scatola scatole fetta fette pezzo pezzi].freeze

  # "2 confezioni di Piselli" e "i piselli" sono lo stesso alimento: contano le parole vere, senza la
  # vocale finale (pizza/pizze, pisello/piselli).
  def self.key(name)
    name.to_s.downcase.tr("'’", "  ").scan(/[\p{L}\p{N}]+/).reject { |w| STOP.include?(w) || w.match?(/\A\d+\z/) }
        .map { |w| w.length > 3 ? w[0..-2] : w }.uniq.sort
  end

  def self.sentence(names)
    names.size <= 1 ? names.first.to_s : "#{names[0..-2].join(', ')} e #{names.last}"
  end

  # L'elenco su disco. Formato della nota:
  #   ## Congelatore
  #   - piselli (dal 2026-11-11)
  class Store
    LINE = /\A[-*]\s+(.+?)(?:\s+\(dal (\d{4}-\d{2}-\d{2})\))?\s*\z/

    attr_reader :path

    def initialize(path = File.join(Config::BRAIN_DIR, "casa", "dispensa.md"))
      @path = path
    end

    def all
      items = PLACES.keys.to_h { |place| [place, []] }
      return items unless File.file?(@path)

      place = nil
      File.read(@path, encoding: "UTF-8").scrub.each_line do |line|
        if (heading = line[/\A##\s+(.+?)\s*\z/, 1])
          place = PLACES.keys.find { |id| PLACES[id][:label].casecmp?(heading) }
        elsif place && (m = line.match(LINE))
          items[place] << Item.new(m[1].strip, m[2])
        end
      end
      items
    end

    # Aggiunge gli alimenti; uno già presente viene aggiornato (nome e data) invece di raddoppiare.
    def add(place, names, today: Date.today)
      change do |items|
        names.each do |name|
          items[place].reject! { |item| Dispensa.key(item.name) == Dispensa.key(name) }
          items[place] << Item.new(name, today.iso8601)
        end
        names
      end
    end

    # Toglie gli alimenti che corrispondono alla richiesta (in un posto, o ovunque se place è nil).
    # Restituisce [tolti come [posto, nome], richieste non trovate].
    def remove(place, queries)
      change do |items|
        removed = []
        missing = []
        queries.each do |query|
          wanted = Dispensa.key(query)
          found = false
          (place ? [place] : PLACES.keys).each do |id|
            hits = items[id].select { |item| !wanted.empty? && (wanted - Dispensa.key(item.name)).empty? }
            hits.each { |item| removed << [id, item.name] }
            items[id] -= hits
            found ||= hits.any?
          end
          missing << query unless found
        end
        [removed, missing]
      end
    end

    private

    # Lettura, modifica e scrittura sotto un lock: dashboard, voce e terminale possono sovrapporsi.
    def change
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        items = all
        result = yield items
        File.write("#{@path}.tmp", render(items))
        File.rename("#{@path}.tmp", @path)
        result
      end
    end

    def render(items)
      lines = ["# Dispensa", "", "Alimenti in casa, tenuti da Jarvis (modulo dispensa). Puoi correggere le righe a mano.", ""]
      PLACES.each do |id, place|
        lines << "## #{place[:label]}"
        items[id].each { |item| lines << "- #{item.name}#{item.since ? " (dal #{item.since})" : ''}" }
        lines << ""
      end
      lines.join("\n")
    end
  end

  # Capisce i comandi detti o scritti. Restituisce un'azione oppure nil se la frase non lo riguarda.
  module Commands
    PLACE = /\b(?:(?:al|nel|in|dal|del|sul|il|a)\s+)?(#{PLACES.values.flat_map { |p| p[:words] }.join('|')})\b/
    ADD = /\A(?:aggiungi|aggiungere|metti|mettere|inserisci|segna|registra|ho messo|ho aggiunto|ho comprato|abbiamo messo|abbiamo comprato)\b/
    REMOVE = /\A(?:togli|togliere|rimuovi|elimina|cancella|leva|ho finito|ho mangiato|ho usato|ho consumato|ho tolto|abbiamo finito|abbiamo mangiato)\b/
    LIST = /\b(?:(?:cosa|cos|che) (?:ho|c è|ci sta|abbiamo|è rimasto|rimane|resta)|elenc\w*|lista|mostra\w*|leggi\w*)\b/
    EVERYWHERE = /\b(?:in casa|da mangiare)\b/
    COOK = /\b(?:cucin\w*|mangi\w*|pranz\w*|cena|cenare|ceno|ceniamo|ricett\w*|prepar\w*|piatt\w*)\b/
    ASK = /\b(?:cosa|cos|idee|idea|consigli\w*|sugger\w*|propon\w*|ricett\w*|che (?:posso|potrei|possiamo|cosa))\b/
    FILLER = /\b(?:agli alimenti|tra gli alimenti|alla lista|all elenco|anche|per favore|grazie|jarvis)\b/
    ARTICLE = /\A(?:(?:il|lo|la|i|gli|le|l|dei|degli|delle|del|della|dello|dell|di|d)\s+)+/

    Action = Struct.new(:kind, :place, :items, :list_first, keyword_init: true)

    def self.parse(text)
      clean = normalize(text)
      place = place_of(clean)
      if clean.match?(ADD)
        place && Action.new(kind: :add, place: place, items: items(clean.sub(ADD, "")))
      elsif clean.match?(REMOVE)
        Action.new(kind: :remove, place: place, items: items(clean.sub(REMOVE, "")))
      elsif clean.match?(COOK) && clean.match?(ASK)
        Action.new(kind: :cook, place: place, list_first: clean.match?(LIST))
      elsif clean.match?(LIST) && (place || clean.match?(EVERYWHERE))
        Action.new(kind: :list, place: place)
      end
    end

    def self.normalize(text)
      text.to_s.downcase.tr("'’", "  ").gsub(/[^\p{L}\p{N}\s,;]/, " ").sub(/\A\s*jarvis\s*[,;]?\s*/, "").squeeze(" ").strip
    end

    def self.place_of(clean)
      word = clean[PLACE, 1]
      word && PLACES.keys.find { |id| PLACES[id][:words].include?(word) }
    end

    # "due confezioni di piselli e il pane" → ["due confezioni di piselli", "pane"]
    def self.items(rest)
      rest.gsub(PLACE, " ").gsub(FILLER, " ").split(/\s*(?:[,;]|\be\b|\bed\b|\bpiù\b)\s*/)
          .map { |item| item.squeeze(" ").strip.sub(ARTICLE, "").strip[0, 60] }
          .reject { |item| Dispensa.key(item).empty? }.uniq.first(15)
    end
  end

  class Module < Modules::Base
    COOK_PROMPT = <<~PROMPT.freeze
      Sei Jarvis e aiuti l'utente a decidere cosa cucinare con quello che ha in casa. Rispondi in
      italiano con un testo breve che verrà letto ad alta voce: frasi semplici, niente elenchi puntati,
      niente simboli, niente Markdown. Proponi due o tre piatti che si possono preparare soprattutto con
      gli alimenti indicati; per ognuno di' quali alimenti usa e in una frase come si prepara. Se un
      alimento è nel congelatore ricorda di scongelarlo. Puoi dare per scontate le basi comuni (olio,
      sale, spezie, pasta, riso, cipolla, aglio), ma non inventare altri alimenti che l'utente non ha
      nominato: se manca qualcosa di importante, dillo. Non salutare e non ripetere l'elenco degli
      alimenti: vai subito ai piatti.
    PROMPT

    def initialize(store: Store.new, llm: nil, clock: -> { Date.today })
      @store = store
      @llm = llm
      @clock = clock
    end

    def handle(text)
      action = Commands.parse(text) or return nil

      case action.kind
      when :add then add(action.place, action.items)
      when :remove then remove(action.place, action.items, strict: !action.place.nil?)
      when :list then list(action.place)
      when :cook then cook(text, action.list_first ? action.place || :all : nil)
      end
    end

    def add(place, names)
      return "Cosa aggiungo #{PLACES[place][:where]}?" if names.empty?

      @store.add(place, names, today: @clock.call)
      "Aggiunto #{PLACES[place][:where]}: #{Dispensa.sentence(names)}."
    end

    # Senza un posto preciso ("ho finito il latte") risponde solo se trova l'alimento: altrimenti la
    # frase non riguarda la dispensa e passa all'agente.
    def remove(place, queries, strict: true)
      return (strict ? "Cosa tolgo?" : nil) if queries.empty?

      removed, missing = @store.remove(place, queries)
      return nil if removed.empty? && !strict

      parts = removed.group_by(&:first).map { |id, rows| "Tolto #{PLACES[id][:from]}: #{Dispensa.sentence(rows.map(&:last))}." }
      parts << "Non trovo #{Dispensa.sentence(missing)}#{place ? " #{PLACES[place][:where]}" : ''}." unless missing.empty?
      parts.join(" ")
    end

    def list(place = nil)
      items = @store.all
      (place ? [place] : PLACES.keys).map do |id|
        names = items[id].map(&:name)
        names.empty? ? PLACES[id][:empty] : "#{PLACES[id][:where].capitalize} hai: #{Dispensa.sentence(names)}."
      end.join(" ")
    end

    def cook(request, list_first = nil)
      intro = list_first && list(list_first == :all ? nil : list_first)
      messages = [{ role: "system", content: COOK_PROMPT },
                  { role: "user", content: "Alimenti in casa:\n#{inventory}\n\nRichiesta: #{request.to_s.strip[0, 500]}" }]
      ideas = llm.chat(messages, options: { temperature: 0.6, num_predict: 500 })["message"]["content"].to_s
      ideas = ideas.gsub(/[*_#`]/, "").gsub(/^\s*[-•]\s+/, "").gsub(/\n{3,}/, "\n\n").strip # i modelli amano il Markdown: qui si legge ad alta voce
      [intro, ideas].compact.join("\n\n")
    rescue StandardError => e
      [intro || list, "Non riesco a chiedere idee al modello online (#{e.message[0, 120]})."].join("\n\n")
    end

    def tools
      places = { type: "string", enum: PLACES.keys, description: "Dove si trova l'alimento" }
      foods = { type: "array", items: { type: "string" }, description: "Gli alimenti, uno per voce, con l'eventuale quantità" }
      [
        Modules.tool("dispensa_aggiungi", "Segna alimenti in congelatore, frigo o dispensa", { posto: places, alimenti: foods }, %w[posto alimenti]),
        Modules.tool("dispensa_togli", "Toglie dall'elenco alimenti finiti o consumati", { posto: places, alimenti: foods }, ["alimenti"]),
        Modules.tool("dispensa_elenco", "Elenca gli alimenti in casa (in un posto, o tutti)", { posto: places }, []),
        Modules.tool("idee_pasto", "Propone cosa cucinare per pranzo o cena con gli alimenti in casa",
                     { richiesta: { type: "string", description: "La richiesta con le parole dell'utente" } }, ["richiesta"])
      ]
    end

    def prompt
      "- dispensa_aggiungi, dispensa_togli, dispensa_elenco: gli alimenti in congelatore, frigo e dispensa. " \
        "Per domande su cosa cucinare o mangiare usa idee_pasto e riporta la sua risposta così com'è."
    end

    def call_tool(name, args)
      place = args["posto"] && place!(args["posto"])
      foods = Array(args["alimenti"]).map { |food| food.to_s.strip[0, 60] }.reject { |food| Dispensa.key(food).empty? }.first(15)
      case name
      when "dispensa_aggiungi" then add(place || raise(ArgumentError, "manca il posto"), foods)
      when "dispensa_togli" then remove(place, foods)
      when "dispensa_elenco" then list(place)
      when "idee_pasto" then cook(args.fetch("richiesta"))
      else raise ArgumentError, "strumento sconosciuto: #{name}"
      end
    end

    # API della dashboard: POST aggiungi {posto, testo} e POST togli {posto, nome}.
    def api(method, path, body, _headers)
      raise ArgumentError, "richiesta non prevista" unless method == "POST"

      data = JSON.parse(body.to_s)
      raise ArgumentError, "corpo JSON non valido" unless data.is_a?(Hash)

      place = place!(data["posto"])
      case path
      when "aggiungi" then { text: add(place, Commands.items(Commands.normalize(data["testo"]))) }
      when "togli"
        @store.remove(place, [data["nome"].to_s])
        { text: "Tolto." }
      else raise ArgumentError, "richiesta non prevista"
      end.merge(status)
    rescue JSON::ParserError
      raise ArgumentError, "corpo JSON non valido"
    end

    def status
      items = @store.all
      { places: PLACES.map { |id, place| { id: id, label: place[:label], items: items[id].map { |item| { name: item.name, since: item.since } } } } }
    end

    private

    def place!(value)
      PLACES.key?(value.to_s) ? value.to_s : raise(ArgumentError, "posto sconosciuto: usa #{PLACES.keys.join(', ')}")
    end

    def inventory
      items = @store.all
      PLACES.map { |id, place| "#{place[:label]}: #{items[id].empty? ? 'niente' : items[id].map(&:name).join(', ')}" }.join("\n")
    end

    # Il modello per le idee: JARVIS_DISPENSA_MODEL, altrimenti quello del digest se è già su OpenRouter.
    def llm
      @llm ||= begin
        require_relative "../../lib/openrouter"
        model = ENV["JARVIS_DISPENSA_MODEL"] || (Config::DIGEST_PROVIDER == "openrouter" ? Config::DIGEST_MODEL : nil)
        raise ArgumentError, "imposta JARVIS_DISPENSA_MODEL (un modello di OpenRouter)" if model.to_s.empty?

        OpenRouter.new(model: model)
      end
    end
  end
end

Modules.register("dispensa") { Dispensa::Module.new }
