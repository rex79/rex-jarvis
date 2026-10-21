require "open3"
require_relative "../config"

# Controllo della musica su macOS via AppleScript (app Musica o Spotify).
# Il testo cercato passa come argomento a osascript, mai dentro lo script: niente iniezioni.
module Music
  class Error < StandardError; end

  APPS = %w[Music Spotify].freeze
  BASIC = {
    "play" => "play", "pause" => "pause", "next" => "next track", "previous" => "previous track"
  }.freeze
  SEARCH = {
    "playlist" => 'on run argv
  tell application "Music" to play playlist (item 1 of argv)
end run',
    "song" => 'on run argv
  tell application "Music" to play (first track of library playlist 1 whose name contains (item 1 of argv))
end run'
  }.freeze
  ACTIONS = (BASIC.keys + SEARCH.keys).freeze

  def self.control(action, query = nil, app: Config::MUSIC_APP, runner: method(:osascript))
    action = action.to_s.downcase
    raise Error, "azione non valida: #{action} (#{ACTIONS.join(', ')})" unless ACTIONS.include?(action)
    raise Error, "app musicale non supportata: #{app} (#{APPS.join(' o ')})" unless APPS.include?(app)

    if BASIC.key?(action)
      runner.call(%(tell application "#{app}" to #{BASIC[action]}), [])
      return "Musica: #{action} (#{app})"
    end

    raise Error, "con Spotify posso solo play, pausa, avanti e indietro" if app == "Spotify"
    raise Error, "dimmi cosa cercare" if query.to_s.strip.empty?

    runner.call(SEARCH[action], [query.to_s.strip])
    "Musica: riproduco #{action} \"#{query.to_s.strip}\""
  end

  def self.osascript(script, args)
    raise Error, "il controllo della musica funziona solo su macOS" unless RUBY_PLATFORM.include?("darwin")

    _out, err, status = Open3.capture3("osascript", "-e", script, *args)
    raise Error, "AppleScript: #{err.strip}" unless status.success?
  end
end
