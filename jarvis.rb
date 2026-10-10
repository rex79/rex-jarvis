#!/usr/bin/env ruby
require_relative "lib/agent"

if ARGV.include?("--index")
  puts Notes.build_index
  exit
end

unless Dir.exist?(Config::BRAIN_DIR)
  abort "Cartella note non trovata: #{Config::BRAIN_DIR} (creala o imposta JARVIS_BRAIN)"
end

agent = Agent.new

puts "🤖 Jarvis online (#{Config::MAIN_MODEL}, note: #{Config::BRAIN_DIR})."
puts "Scrivi 'exit' per uscire."
puts

loop do
  print "Tu > "
  question = gets&.chomp
  break if question.nil? || question.downcase == "exit"
  next if question.strip.empty?

  begin
    puts "\nJarvis: #{agent.ask(question)}\n\n"
  rescue StandardError => e
    puts "\n⚠️  #{e.message}\n\n"
  end
end
