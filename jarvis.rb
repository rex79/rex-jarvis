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

# Un'opzione scritta male (--hub-pair) non deve aprire la chat in silenzio: si ferma e suggerisce quella giusta.
OPTIONS = %w[--index --site --publish --digest --dry-run --copilot-login --copilot-status --hud-pair --hud-revoke
             --hud --lan --port --context --ask].freeze
WITH_VALUE = %w[--port --context --ask].freeze
unknown = ARGV.each_with_index.select { |arg, i| arg.start_with?("-") && !OPTIONS.include?(arg) && !(i.positive? && WITH_VALUE.include?(ARGV[i - 1])) }.map(&:first)
unless unknown.empty?
  require "did_you_mean"
  hint = DidYouMean::SpellChecker.new(dictionary: OPTIONS).correct(unknown.first).first
  abort "❌ opzione sconosciuta: #{unknown.join(', ')}#{hint ? " (forse volevi #{hint}?)" : ''}\nOpzioni: #{OPTIONS.join(' ')}"
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

if ARGV.include?("--hud-pair") || ARGV.include?("--hud-revoke")
  require_relative "lib/hud/pairing"
  if ARGV.include?("--hud-revoke")
    puts "Abbinamenti rimossi: #{HudPairing.new.revoke_all}. Ogni dispositivo dovrà rifarlo."
  else
    puts "Codice per il tablet: #{HudPairing.new.start} (vale 10 minuti, una volta sola)"
  end
  exit
end

if ARGV.include?("--hud")
  require_relative "lib/hud/server"
  port = Integer(arg_value("--port") || 7777)
  lan = ARGV.include?("--lan") # sulla rete di casa solo il contesto personale, qualunque cosa chieda il comando
  begin
    modules = Modules.load
    HudServer.new(port: port, modules: modules,
                  dispatcher: Dispatcher.new(forced: lan ? "personal" : arg_value("--context"), modules: modules),
                  **(lan ? HudServer.lan_options : {})).start
  rescue ArgumentError => e
    abort "❌ #{e.message}"
  rescue Interrupt
    puts "\nHUD fermato."
  end
  exit
end

# Ogni comando va al contesto giusto (lavoro o personale); --context lo forza.
dispatcher = nil
handle = lambda do |text|
  dispatcher ||= Dispatcher.new(forced: arg_value("--context"), modules: Modules.load).tap do |d|
    d.progress = lambda do |seconds|
      $stderr.print "\r⏳ Copilot sta lavorando… #{seconds / 60}:#{format('%02d', seconds % 60)}" if $stderr.tty?
    end
  end
  reply = dispatcher.handle(text)
  puts "[#{reply.label}]"
  [reply.text, *Array(reply.links).map { |link| "→ #{link[:title]}: #{link[:url]}" }].join("\n")
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
