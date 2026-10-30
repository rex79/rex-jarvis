#!/usr/bin/env ruby
require_relative "lib/agent"
require_relative "lib/dispatcher"

def arg_value(flag)
  i = ARGV.index(flag)
  i && utf8(ARGV[i + 1])
end

# Lanciato da cron, da un comando vocale o da un terminale senza locale, Ruby può leggere il
# testo come binario: lo forziamo a UTF-8 (gli accenti italiani sono la norma).
def utf8(text)
  text&.dup&.force_encoding("UTF-8")&.scrub
end

if ARGV.include?("--index")
  [Contexts.personal, Contexts.work].each do |context|
    next unless Dir.exist?(context.root)

    Privacy.assert_local!(Config::OLLAMA_URL, "L'indice del contesto #{context.label}") if context.local_only
    puts "[#{context.label}] #{Notes.new(context.root).build_index}"
  end
  exit
end

if ARGV.include?("--site") || ARGV.include?("--publish")
  require_relative "lib/site"
  puts Site.build
  if ARGV.include?("--publish")
    require_relative "lib/publisher"
    begin
      puts Publisher.publish
    rescue Publisher::Error => e
      abort "❌ #{e.message}"
    end
  end
  exit
end

if ARGV.include?("--digest")
  require_relative "lib/daily_digest"
  DailyDigest.run(dry_run: ARGV.include?("--dry-run"))
  exit
end

if ARGV.include?("--signals")
  require_relative "lib/signals"
  begin
    path, reports = Signals.run
  rescue Signals::Error, ArgumentError => e
    abort "❌ #{e.message}"
  end
  reports.each do |r|
    s = r.signal
    puts r.error ? "#{s.product}: non disponibile (#{r.error})" : "#{s.product}: #{Signals::Strategy::ACTIONS[s.action]}"
  end
  puts "Segnali scritti in #{path}"
  begin
    puts Notes.build_index # rende i segnali ricercabili da search_notes
  rescue StandardError => e
    warn "⚠️  indicizzazione fallita (i segnali sono comunque salvati): #{e.message}"
  end
  exit
end

if ARGV.include?("--trading")
  require_relative "lib/trading"
  begin
    path, reports = Trading.exclusive { Trading.run }
  rescue Trading::Error, ArgumentError => e
    abort "❌ #{e.message}"
  end
  reports.each { |r| puts r.error ? "#{r.ticker}: non disponibile (#{r.error})" : "#{r.ticker}: #{r.decision}" }
  puts "Analisi scritta in #{path}"
  Trading.index_later # l'indice delle note si aggiorna dopo, in background
  puts "Indicizzazione avviata in background (log in ~/.jarvis/index.log)"
  exit
end

# Lanciato dalla chiave SSH della dashboard (command= in authorized_keys): accetta solo "run" e "latest".
if ARGV.include?("--trading-remote")
  require_relative "lib/trading"
  begin
    puts JSON.generate(Trading.remote(ENV["SSH_ORIGINAL_COMMAND"]))
  rescue Trading::Error, ArgumentError => e
    puts JSON.generate(error: e.message)
    exit 1
  rescue StandardError => e # anche gli errori imprevisti arrivano leggibili alla dashboard
    puts JSON.generate(error: "#{e.class}: #{utf8(e.message)[0, 300]}")
    warn e.full_message(highlight: false)
    exit 1
  end
  exit
end

if ARGV.include?("--telegram")
  require_relative "lib/telegram_bot"
  begin
    TelegramBot.new.run
  rescue TelegramBot::Error => e
    abort "❌ #{e.message}"
  rescue Interrupt
    puts "\nBot Telegram fermato."
  end
  exit
end

if ARGV.include?("--copilot-login") || ARGV.include?("--copilot-status")
  require_relative "lib/tools/copilot"
  begin
    if ARGV.include?("--copilot-login")
      puts "Si apre il browser per l'accesso Microsoft aziendale…"
      data = Copilot.login
      puts "✅ Collegato come #{data['account']}"
    else
      data = Copilot.status
      puts data["logged_in"] ? "✅ Collegato come #{data['account']}" : "Non collegato: ruby jarvis.rb --copilot-login"
    end
  rescue Copilot::Error => e
    abort "❌ #{e.message}"
  end
  exit
end

if ARGV.include?("--hud")
  require_relative "lib/hud/server"
  port = Integer(arg_value("--port") || 7777)
  begin
    HudServer.new(port: port, dispatcher: Dispatcher.new(forced: arg_value("--context"))).start
  rescue Interrupt
    puts "\nHUD fermato."
  end
  exit
end

# Ogni comando va al contesto giusto (lavoro o personale); --context lo forza.
dispatcher = nil
handle = lambda do |text|
  dispatcher ||= Dispatcher.new(forced: arg_value("--context")).tap do |d|
    d.progress = lambda do |seconds|
      $stderr.print "\r⏳ Copilot sta lavorando… #{seconds / 60}:#{format('%02d', seconds % 60)}" if $stderr.tty?
    end
  end
  reply = dispatcher.handle(text)
  puts "[#{reply.label}]"
  reply.text
end

begin
  if (question = arg_value("--ask"))
    answer = handle.call(question)
    $stderr.print "\r\e[K" if $stderr.tty?
    puts answer
    exit
  end
rescue Privacy::Error, ArgumentError, Music::Error, Copilot::Error => e
  $stderr.print "\r" if $stderr.tty?
  abort "❌ #{e.message}"
end

puts "🤖 Jarvis online. Contesti: lavoro (#{Config::WORK_MODEL}, #{Config::WORK_DIR}) e personale (#{Config::MAIN_MODEL}, #{Config::BRAIN_DIR})."
puts "Prefissi \"lavoro:\" e \"personale:\" per scegliere il contesto. Scrivi 'exit' per uscire."
puts

loop do
  print "Tu > "
  question = utf8($stdin.gets&.chomp)
  break if question.nil? || question.downcase == "exit"
  next if question.strip.empty?

  begin
    answer = handle.call(question)
    $stderr.print "\r\e[K" if $stderr.tty?
    puts "\nJarvis: #{answer}\n\n"
  rescue Privacy::Error => e
    abort "❌ #{e.message}"
  rescue StandardError => e
    puts "\n⚠️  #{e.message}\n\n"
  end
end
