#!/usr/bin/env ruby
require_relative "lib/agent"
require_relative "lib/router"

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

# Ogni comando va al contesto giusto (lavoro o personale); --context lo forza.
forced = arg_value("--context")
agents = {}
handle = lambda do |text|
  route = forced ? Router::Route.new(Contexts.fetch(forced).id, text, "scelto") : Router.route(text)
  agent = agents[route.context] ||= Agent.new(Contexts.fetch(route.context))
  puts "[#{agent.context.label} · #{route.reason}]"
  agent.ask(route.text)
end

begin
  if (question = arg_value("--ask"))
    puts handle.call(question)
    exit
  end
rescue Privacy::Error, ArgumentError => e
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
    puts "\nJarvis: #{handle.call(question)}\n\n"
  rescue Privacy::Error => e
    abort "❌ #{e.message}"
  rescue StandardError => e
    puts "\n⚠️  #{e.message}\n\n"
  end
end
