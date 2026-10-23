require_relative "../tools/copilot"

# Conversazione con l'agente Copilot condivisa da dispatcher e strumento ask_copilot.
# Dopo una risposta resta "agganciata" per STICKY secondi: i messaggi di lavoro successivi
# ("inseriscile nei to-do") vanno all'agente nella stessa conversazione, che ne ha il contesto.
class CopilotSession
  STICKY = 15 * 60

  attr_reader :conversation_id, :last_at

  def initialize(copilot: Copilot, clock: -> { Time.now })
    @copilot = copilot
    @clock = clock
  end

  def configured? = @copilot.configured?

  def active?
    !@conversation_id.nil? && !@last_at.nil? && @clock.call - @last_at < STICKY
  end

  def ask(text, progress: nil)
    reset unless active? # dopo il silenzio si riparte da una conversazione nuova
    reply = @copilot.ask(text, conversation_id: @conversation_id, progress: progress)
    @conversation_id = reply[:conversation_id]
    @last_at = @clock.call
    @copilot.save_copy(text, reply[:text])
    reply[:text]
  end

  def reset
    @conversation_id = nil
    @last_at = nil
  end
end
