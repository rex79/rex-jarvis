require_relative "agent"
require_relative "router"
require_relative "intents"

# Riceve un comando (scritto o, in futuro, trascritto dalla voce) e lo esegue:
#   1. comandi musicali semplici → subito, senza modello (contesto personale);
#   2. altrimenti il router sceglie il contesto e risponde l'agente di quel contesto.
class Dispatcher
  Reply = Struct.new(:label, :text)

  def initialize(forced: nil, agent_factory: ->(context) { Agent.new(context) }, music: Music)
    @forced = forced && Contexts.fetch(forced).id
    @agent_factory = agent_factory
    @music = music
    @agents = {}
  end

  def handle(text)
    # Un comando con parole di lavoro non è mai un comando musicale rapido.
    if @forced != :work && Router.hits(text, Router::WORK_WORDS).zero? && (intent = Intents.music(text))
      action, app = intent
      return Reply.new("personale · comando rapido", @music.control(action, nil, app: app))
    end

    route = @forced ? Router::Route.new(@forced, text, "scelto") : Router.route(text)
    agent = @agents[route.context] ||= @agent_factory.call(Contexts.fetch(route.context))
    Reply.new("#{agent.context.label} · #{route.reason}", agent.ask(route.text))
  end
end
