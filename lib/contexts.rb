require_relative "config"

# Due contesti separati: ognuno ha le sue note, il suo modello e i suoi strumenti.
#   work:     note in JARVIS_WORK_DIR, solo modelli locali (local_only), nessuno strumento online.
#   personal: note in JARVIS_BRAIN (le stesse del digest), strumenti personali come la musica.
Context = Struct.new(:id, :label, :root, :model, :local_only, keyword_init: true)

module Contexts
  def self.work
    Context.new(id: :work, label: "lavoro", root: Config::WORK_DIR, model: Config::WORK_MODEL, local_only: true)
  end

  def self.personal
    Context.new(id: :personal, label: "personale", root: Config::BRAIN_DIR, model: Config::MAIN_MODEL, local_only: false)
  end

  def self.fetch(id)
    case id.to_s
    when "work", "lavoro" then work
    when "personal", "personale" then personal
    else raise ArgumentError, "contesto sconosciuto: #{id} (usa work o personal)"
    end
  end
end
