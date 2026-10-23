require "json"
require "fileutils"
require_relative "config"
require_relative "ollama"
require_relative "privacy"
require_relative "contexts"
require_relative "tools/filesystem"
require_relative "tools/notes"
require_relative "tools/music"
require_relative "tools/copilot"

# Agente con strumenti, legato a un contesto (lavoro o personale): vede solo le note del suo
# contesto e solo i suoi strumenti. Nel contesto di lavoro tutto deve restare sul computer.
class Agent
  NOTES_HELP = <<~TEXT.freeze
    Hai accesso alle note di questo contesto: una cartella di file Markdown.
    - search_notes(query): cerca per significato nelle note. Usalo PRIMA di rispondere
      a domande che riguardano l'utente, i suoi appunti o i suoi progetti.
    - list_files(directory): elenca i file della cartella note.
    - read_file(file_path): legge un file della cartella note.
    - save_note(title, text): salva una nuova nota.
    - current_time(): data e ora attuali.
    Non inventare mai il contenuto delle note. Se non trovi nulla, dillo.
    Quando usi una nota, cita il nome del file.
  TEXT

  PROMPTS = {
    work: <<~PROMPT,
      Sei Jarvis, l'assistente dell'utente, nel contesto LAVORO. Rispondi in italiano, in modo conciso.
      Lavori solo con strumenti e modelli che girano su questo computer: i dati di lavoro non devono
      uscire da qui, con un'unica eccezione: ask_copilot, l'agente aziendale nel tenant Microsoft
      dell'azienda. Per briefing, progetti, riunioni, Jira e calendario usa ask_copilot. Non hai accesso alle note personali né alla musica: se l'utente chiede cose
      personali, digli di usare il prefisso "personale:".
      #{NOTES_HELP}
    PROMPT
    personal: <<~PROMPT
      Sei Jarvis, l'assistente dell'utente, nel contesto PERSONALE. Rispondi in italiano, in modo conciso.
      Non hai accesso alle note di lavoro: se l'utente chiede cose di lavoro, digli di usare il
      prefisso "lavoro:".
      #{NOTES_HELP}
      - music_control(action, query, app): controlla la musica. play avvia o RIPRENDE da dove era
        (riprendi, continua, fai ripartire): usalo senza query e senza chiedere cosa riprodurre.
        pause, next, previous; playlist con il nome in query, song con il titolo in query.
        Non dire mai di aver fatto un'azione sulla musica senza aver chiamato lo strumento. Indica app (Spotify o Music)
        solo se l'utente la nomina: altrimenti si usa la sua app preferita, #{Config::MUSIC_APP}.
    PROMPT
  }.freeze

  attr_reader :context

  def initialize(context = Contexts.personal, llm: nil)
    @context = context
    # Anche gli embedding delle note passano da OLLAMA_URL: con local_only deve essere locale.
    Privacy.assert_local!(Config::OLLAMA_URL, "Il contesto #{context.label}") if context.local_only
    FileUtils.mkdir_p(context.root)

    @llm = llm || Ollama.new(model: context.model)
    @fs = Filesystem.new(context.root)
    @notes = Notes.new(context.root)
    @tools = note_tools
    @tools << music_tool if context.id == :personal
    @tools << copilot_tool if context.id == :work && Copilot.configured?
    @messages = [{ role: "system", content: PROMPTS.fetch(context.id) }]
  end

  def tool_names
    @tools.map { |t| t.dig(:function, :name) }
  end

  def ask(question)
    @messages << { role: "user", content: question }

    Config::MAX_TURNS.times do
      message = @llm.chat(@messages, tools: @tools)["message"]
      @messages << message

      calls = message["tool_calls"]
      return message["content"] if calls.nil? || calls.empty?

      calls.each { |call| @messages << run_tool(call) }
    end

    "Troppi passaggi di ricerca senza una risposta. Prova a riformulare la domanda."
  end

  private

  def note_tools
    [
      tool("search_notes", "Cerca per significato nelle note",
           { query: { type: "string", description: "Cosa cercare" } }, ["query"]),
      tool("list_files", "Elenca i file in una directory della cartella note",
           { directory: { type: "string", description: "Directory, '.' per la radice" } }, ["directory"]),
      tool("read_file", "Legge un file della cartella note",
           { file_path: { type: "string", description: "Percorso del file" } }, ["file_path"]),
      tool("save_note", "Salva una nuova nota Markdown",
           { title: { type: "string" }, text: { type: "string" } }, %w[title text]),
      tool("current_time", "Restituisce data e ora attuali", {}, [])
    ]
  end

  def copilot_tool
    tool("ask_copilot", "Inoltra una richiesta all'agente aziendale Copilot (PM Assistant): briefing, stato dei " \
                        "progetti, riunioni, Jira, calendario, documenti aziendali, salvataggio di briefing e knowledge",
         { request: { type: "string", description: "La richiesta, in italiano, con le parole dell'utente" } }, ["request"])
  end

  def music_tool
    tool("music_control", "Controlla la musica sul Mac",
         { action: { type: "string", enum: Music::ACTIONS, description: "Cosa fare" },
           query: { type: "string", description: "Nome della playlist o titolo del brano" },
           app: { type: "string", enum: Music::APPS, description: "Solo se l'utente nomina l'app" } }, ["action"])
  end

  def tool(name, description, properties, required)
    {
      type: "function",
      function: {
        name: name,
        description: description,
        parameters: { type: "object", properties: properties, required: required }
      }
    }
  end

  def run_tool(call)
    name = call.dig("function", "name")
    args = call.dig("function", "arguments") || {}
    args = JSON.parse(args) if args.is_a?(String)
    puts "🔧 #{name}(#{args.to_json})"

    result =
      begin
        # Un modello può "inventarsi" uno strumento di un altro contesto: si eseguono solo i propri.
        raise "strumento non disponibile nel contesto #{@context.label}: #{name}" unless tool_names.include?(name)

        case name
        when "search_notes"  then @notes.search(args.fetch("query"))
        when "list_files"    then @fs.list_files(args.fetch("directory", "."))
        when "read_file"     then @fs.read_file(args.fetch("file_path"))
        when "save_note"     then @notes.save(args.fetch("title"), args.fetch("text"))
        when "current_time"  then Time.now.strftime("%A %d/%m/%Y %H:%M")
        when "music_control" then Music.control(args.fetch("action"), args["query"], app: args["app"])
        when "ask_copilot"
          answer = Copilot.ask(args.fetch("request"))[:text]
          Copilot.save_copy(args.fetch("request"), answer)
          answer
        end
      rescue StandardError => e
        # L'errore torna al modello, che può correggersi, invece di far crollare Jarvis.
        "Errore: #{e.message}"
      end

    text = result.is_a?(String) ? result : JSON.generate(result)
    text = text[0, Config::MAX_TOOL_OUTPUT] + "\n[...troncato]" if text.length > Config::MAX_TOOL_OUTPUT

    { role: "tool", tool_name: name, content: text }
  end
end
