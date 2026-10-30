require "time"
require_relative "../trading_remote"

# Dashboard sul Mac mini: l'analisi gira qui, senza SSH. Stessa interfaccia di TradingRemote;
# ciò che manca (modello, ambiente Python) arriva come errore leggibile nel riquadro.
module TradingLocal
  def self.configured? = true
  def self.run = Trading.remote("run")
  def self.latest = nil
end

# Analisi lanciata dalla dashboard: gira in un thread (dura minuti) e la dashboard ne legge lo
# stato a ogni aggiornamento. Una sola alla volta; il risultato arriva in ~/brain/trading.
class TradingJob
  def initialize(remote: TradingRemote)
    @remote = remote
    @lock = Mutex.new
    @state = { running: false }
  end

  def state = @lock.synchronize { @state.merge(configured: @remote.configured?) }

  def start
    @lock.synchronize do
      raise ArgumentError, "analisi già in corso" if @state[:running]
      raise ArgumentError, "Mac mini non configurato: imposta JARVIS_TRADING_SSH e la chiave SSH" unless @remote.configured?

      @state = { running: true, started_at: Time.now.iso8601 }
    end
    @thread = Thread.new { work { @remote.run } }
    state
  end

  # All'avvio della dashboard copia l'ultima analisi del Mac mini (es. quella del cron).
  def sync_later
    return unless @remote.configured?

    Thread.new do
      @remote.latest
    rescue StandardError => e
      warn "⚠️  analisi titoli: #{e.message}"
    end
  end

  def wait = @thread&.join

  private

  def work
    yield
    finish(nil)
  rescue StandardError => e
    finish(e.message[0, 300])
  end

  def finish(error)
    @lock.synchronize do
      @state = { running: false, started_at: @state[:started_at], finished_at: Time.now.iso8601, error: error }
    end
  end
end
