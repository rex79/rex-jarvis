require_relative "agent"
require_relative "router"
require_relative "intents"
require_relative "tools/copilot"
require_relative "copilot/session"

# Riceve un comando (scritto o, in futuro, trascritto dalla voce) e lo esegue:
#   1. comandi musicali semplici → subito, senza modello (contesto personale);
#   2. altrimenti il router sceglie il contesto e risponde l'agente di quel contesto.
class Dispatcher
  Reply = Struct.new(:label, :text)

  attr_accessor :progress # chiamato con i secondi trascorsi mentre Copilot lavora

  attr_reader :session

  def initialize(forced: nil, agent_factory: nil, music: Music, copilot: Copilot, session: nil)
    @forced = forced && Contexts.fetch(forced).id
    @session = session || CopilotSession.new(copilot: copilot)
    @agent_factory = agent_factory || ->(context) { Agent.new(context, copilot_session: @session) }
    @music = music
    @agents = {}
  end

  def handle(text)
    if Intents.new_conversation?(text)
      @session.reset
      return Reply.new("lavoro · Copilot", "Conversazione con Copilot chiusa: la prossima richiesta ne apre una nuova.")
    end

    # Un comando con parole di lavoro non è mai un comando musicale rapido.
    if @forced != :work && Router.hits(text, Router::WORK_WORDS).zero? && (intent = Intents.music(text))
      @session.reset
      action, app = intent
      return Reply.new("personale · comando rapido", @music.control(action, nil, app: app))
    end

    route = route_for(text)

    # All'agente aziendale: richieste esplicite, oppure il seguito di una conversazione ancora aperta
    # ("inseriscile nei to-do" dopo il briefing), che solo lui può capire.
    if route.context == :work && @session.configured? && (Intents.copilot?(route.text) || @session.active?)
      request = Intents.copilot_request(route.text)
      label = @session.active? ? "lavoro · Copilot (seguito)" : "lavoro · Copilot"
      return Reply.new(label, @session.ask(request, progress: @progress))
    end

    @session.reset if route.context == :personal

    agent = @agents[route.context] ||= @agent_factory.call(Contexts.fetch(route.context))
    Reply.new("#{agent.context.label} · #{route.reason}", agent.ask(route.text))
  end

  private

  # Con una conversazione Copilot aperta, i messaggi senza prefisso né parole personali restano
  # nel contesto di lavoro senza chiedere al modello locale.
  def route_for(text)
    return Router::Route.new(@forced, text, "scelto") if @forced

    route_text = text.to_s.strip
    explicit = route_text.match?(/\A(lavoro|work|personale|personal)\s*[:,]/i)
    if @session.active? && !explicit && Router.hits(route_text, Router::PERSONAL_WORDS).zero?
      return Router::Route.new(:work, route_text, "conversazione Copilot")
    end

    Router.route(text)
  end
end
