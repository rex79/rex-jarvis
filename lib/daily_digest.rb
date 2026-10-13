require "yaml"
require_relative "config"
require_relative "digest/collector"
require_relative "digest/ranker"
require_relative "digest/builder"
require_relative "digest/seen"
require_relative "tools/notes"
require_relative "site"
require_relative "publisher"

module DailyDigest
  # dry_run: raccoglie e classifica, stampa la lista, non usa Ollama né scrive file.
  def self.run(dry_run: false, now: Time.now)
    config = YAML.load_file(Config::SOURCES_FILE)
    # Configurazione sbagliata (chiave/modello mancanti) = errore subito, prima di raccogliere.
    builder = dry_run ? nil : Builder.new

    items = Collector.collect(config["sources"])
    puts "Raccolti #{items.size} contenuti da #{items.map(&:source).uniq.size} fonti"

    seen = Seen.new(now: now)
    top = Ranker.select(items, config["ranking"], n: Config::DIGEST_ITEMS, hours: Config::DIGEST_HOURS, now: now, seen: seen)
    return puts("Nessun contenuto rilevante.") if top.empty?

    if dry_run
      top.each { |it| puts format("%5.1f  %-16s %s\n       %s", it.score, it.source, it.title, it.url) }
      return
    end

    summaries = top.each_with_index.map do |item, i|
      puts "Riassumo #{i + 1}/#{top.size}: #{item.title[0, 60]}"
      builder.summarize(item)
    end

    path = builder.write(builder.render(top, summaries, now), now)
    puts "Digest scritto in #{path}"

    seen.add(top) # solo dopo aver scritto il file: un'esecuzione fallita non brucia le voci
    seen.save

    begin
      puts Site.build
    rescue StandardError => e
      warn "⚠️  sito non aggiornato (il digest è comunque salvato): #{e.message}"
    end

    begin
      puts Publisher.publish if Publisher.configured?
    rescue Publisher::Error => e
      warn "⚠️  pubblicazione fallita (il digest è comunque salvato): #{e.message}"
    end

    begin
      puts Notes.build_index # rende il digest ricercabile da search_notes
    rescue StandardError => e
      warn "⚠️  indicizzazione fallita (il digest è comunque salvato): #{e.message}"
    end
  rescue OpenRouter::AuthError, ArgumentError => e
    abort "❌ #{e.message}"
  end
end
