require "json"
require_relative "config"
require_relative "ollama"
require_relative "tools/filesystem"
require_relative "tools/notes"

class Agent
  SYSTEM_PROMPT = <<~PROMPT
    Sei Jarvis, un assistente personale locale. Rispondi in italiano, in modo conciso.

    Hai accesso al "second brain" dell'utente: una cartella di note Markdown.
    - search_notes(query): cerca per significato nelle note. Usalo PRIMA di rispondere
      a domande che riguardano l'utente, i suoi appunti o i suoi progetti.
    - list_files(directory): elenca i file della cartella note.
    - read_file(file_path): legge un file della cartella note.
    - save_note(title, text): salva una nuova nota.
    - current_time(): data e ora attuali.

    Non inventare mai il contenuto delle note. Se non trovi nulla, dillo.
    Quando usi una nota, cita il nome del file.
  PROMPT

  def initialize(main_model = Config::MAIN_MODEL)
    @ollama = Ollama.new(model: main_model)
    @messages = [{ role: "system", content: SYSTEM_PROMPT }]
    @tools = [
      tool("search_notes", "Cerca per significato nelle note personali",
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

  def ask(question)
    @messages << { role: "user", content: question }

    Config::MAX_TURNS.times do
      message = @ollama.chat(@messages, tools: @tools)["message"]
      @messages << message

      calls = message["tool_calls"]
      return message["content"] if calls.nil? || calls.empty?

      calls.each { |call| @messages << run_tool(call) }
    end

    "Troppi passaggi di ricerca senza una risposta. Prova a riformulare la domanda."
  end

  private

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
    puts "🔧 #{name}(#{args.to_json})"

    result =
      begin
        case name
        when "search_notes" then Notes.search(args.fetch("query"))
        when "list_files"   then Filesystem.list_files(args.fetch("directory", "."))
        when "read_file"    then Filesystem.read_file(args.fetch("file_path"))
        when "save_note"    then Notes.save(args.fetch("title"), args.fetch("text"))
        when "current_time" then Time.now.strftime("%A %d/%m/%Y %H:%M")
        else "Errore: tool sconosciuto #{name}"
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
