require_relative "config"

# Moduli opzionali: ogni funzione "di casa" vive in modules/<nome>/ con il suo codice, i suoi dati,
# il suo pezzo di dashboard e i suoi test, e si accende elencandola in JARVIS_MODULES
# (es. JARVIS_MODULES=dispensa,voce in ~/.jarvis_env). Il nucleo non sa cosa fanno: chiede soltanto
#   - handle(text): un comando riconosciuto con regole fisse, senza modello → testo, oppure nil;
#   - tools / call_tool / prompt: strumenti in più per l'agente personale;
#   - api(method, path, body, headers): le sue API sotto /api/modules/<nome>/…;
#   - status: cosa mostrare nella dashboard (dentro /api/status → modules.<nome>);
#   - max_body: quanto può pesare una richiesta alle sue API;
#   - start: cosa preparare quando parte la dashboard (es. caricare un modello).
# I file in modules/<nome>/hud/ (hud.js, hud.css) vengono caricati dalla dashboard.
# I moduli valgono solo nel contesto personale: quello di lavoro non li vede.
module Modules
  DIR = File.expand_path("../modules", __dir__)
  NAME = /\A[a-z][a-z0-9_]{0,30}\z/

  class Base
    def handle(_text) = nil
    def tools = []
    def call_tool(_name, _args) = raise(ArgumentError, "strumento sconosciuto")
    def prompt = nil
    def api(_method, _path, _body, _headers) = raise(ArgumentError, "richiesta non prevista")
    def status = nil
    def max_body = nil
    def start = nil
  end

  # I moduli accesi, nell'ordine di JARVIS_MODULES.
  class Set
    attr_reader :names

    def initialize(modules = {})
      @modules = modules
      @names = modules.keys
    end

    def [](name) = @modules[name.to_s]
    def empty? = @modules.empty?

    # Il primo modulo che riconosce il comando risponde: [nome, testo] oppure nil.
    def handle(text)
      @modules.each do |name, mod|
        reply = mod.handle(text)
        return [name, reply] if reply
      end
      nil
    end

    def start = @modules.each_value(&:start)
    def tools = @modules.values.flat_map(&:tools)
    def prompt = @modules.values.filter_map(&:prompt).join("\n")

    def call_tool(name, args)
      owner = @modules.values.find { |mod| mod.tools.any? { |t| t.dig(:function, :name) == name } }
      raise ArgumentError, "strumento sconosciuto: #{name}" unless owner

      owner.call_tool(name, args)
    end

    def status
      @modules.to_h do |name, mod|
        [name, begin
          mod.status
        rescue StandardError => e
          { error: e.message[0, 160] }
        end]
      end
    end

    # File della dashboard di un modulo (solo hud.js e hud.css), oppure nil.
    def asset(name, file)
      return nil unless @modules.key?(name) && %w[hud.js hud.css].include?(file)

      path = File.join(DIR, name, "hud", file)
      File.file?(path) ? path : nil
    end

    def assets(file) = @names.select { |name| asset(name, file) }
  end

  def self.none = Set.new

  def self.load(names = Config::MODULES)
    Set.new(names.uniq.to_h do |name|
      raise ArgumentError, "nome di modulo non valido in JARVIS_MODULES: #{name}" unless name.match?(NAME)

      file = File.join(DIR, name, "#{name}.rb")
      raise ArgumentError, "modulo sconosciuto in JARVIS_MODULES: #{name} (manca modules/#{name}/#{name}.rb)" unless File.file?(file)

      require file
      [name, registry.fetch(name).call]
    end)
  end

  def self.registry = (@registry ||= {})

  # Chiamato dal file del modulo: Modules.register("dispensa") { Dispensa::Module.new }
  def self.register(name, &factory) = registry[name] = factory

  # Definizione di uno strumento nel formato dell'agente.
  def self.tool(name, description, properties, required)
    { type: "function",
      function: { name: name, description: description,
                  parameters: { type: "object", properties: properties, required: required } } }
  end
end
