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

  def self.control(action, query = nil, app: nil, runner: method(:osascript))
    app = normalize_app(app) || Config::MUSIC_APP
    action = action.to_s.downcase
    raise Error, "azione non valida: #{action} (#{ACTIONS.join(', ')})" unless ACTIONS.include?(action)
    raise Error, "app musicale non supportata: #{app} (#{APPS.join(' o ')})" unless APPS.include?(app)

    if BASIC.key?(action)
      # Solo "play" avvia l'app; pausa/avanti/indietro su un'app chiusa non devono aprirla.
      script = %(tell application "#{app}" to #{BASIC[action]})
      script = %(if application "#{app}" is running then #{script}) unless action == "play"
      runner.call(script, [])
      return "Musica: #{action} (#{app})"
    end

    # Cercare playlist o brani su Spotify richiede la sua Web API (OAuth): non ancora supportato.
    raise Error, "con Spotify posso solo play, pausa, avanti e indietro" if app == "Spotify"
    raise Error, "dimmi cosa cercare" if query.to_s.strip.empty?

    runner.call(SEARCH[action], [query.to_s.strip])
    "Musica: riproduco #{action} \"#{query.to_s.strip}\""
  end

  # Accetta i nomi detti a voce ("spotify", "apple music", "musica"); nil = preferenza configurata.
  def self.normalize_app(app)
    case app.to_s.strip.downcase
    when "" then nil
    when "spotify" then "Spotify"
    when "music", "apple music", "musica", "itunes" then "Music"
    else app.to_s
    end
  end

  NOW_PLAYING = <<~SCRIPT.freeze
    on run argv
      set appName to item 1 of argv
      if application appName is not running then return "closed"
      using terms from application "Music"
        tell application appName
          if player state is stopped then return "stopped"
          return (player state as text) & linefeed & (name of current track) & linefeed & (artist of current track)
        end tell
      end using terms from
    end run
  SCRIPT

  # Cosa sta suonando, senza mai aprire l'app: { app:, state:, track:, artist: }.
  def self.now_playing(app: nil, runner: method(:osascript))
    app = normalize_app(app) || Config::MUSIC_APP
    raise Error, "app musicale non supportata: #{app}" unless APPS.include?(app)

    state, track, artist = runner.call(NOW_PLAYING, [app]).to_s.split("\n").map(&:strip)
    { app: app, state: { "closed" => "chiusa", "playing" => "in riproduzione", "paused" => "in pausa",
                         "stopped" => "ferma" }.fetch(state.to_s, state.to_s), track: track, artist: artist }
  end

  def self.osascript(script, args)
    raise Error, "il controllo della musica funziona solo su macOS" unless RUBY_PLATFORM.include?("darwin")

    out, err, status = Open3.capture3("osascript", "-e", script, *args)
    raise Error, "AppleScript: #{err.strip}" unless status.success?

    out.strip
  end
end
