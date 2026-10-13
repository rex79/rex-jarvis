require "open3"
require "uri"
require_relative "config"

# Carica il sito generato (Config::SITE_DIR) su uno spazio web via FTPS/SFTP usando curl.
# Variabili (di solito in ~/.jarvis_env):
#   JARVIS_FTP_URL       es. ftps://ftp.example.com/public_html/jarvis/   (ftp:// | ftps:// | sftp://)
#   JARVIS_FTP_USER, JARVIS_FTP_PASSWORD
#   JARVIS_FTP_ALLOW_PLAIN=1   consente FTP senza TLS (password in chiaro: sconsigliato)
# Le credenziali passano a curl da stdin (non compaiono nella lista dei processi) e vengono
# oscurate da ogni messaggio d'errore.
module Publisher
  Error = Class.new(StandardError)

  SCHEMES = %w[ftp ftps sftp].freeze

  def self.configured?
    !ENV["JARVIS_FTP_URL"].to_s.empty?
  end

  def self.publish(dir = Config::SITE_DIR, url: ENV["JARVIS_FTP_URL"], user: ENV["JARVIS_FTP_USER"],
                   password: ENV["JARVIS_FTP_PASSWORD"], allow_plain: ENV["JARVIS_FTP_ALLOW_PLAIN"] == "1",
                   runner: method(:run_curl))
    uri = validate(url, user, password, allow_plain)
    base = url.end_with?("/") ? url : "#{url}/"
    names = Dir.children(dir).sort.select { |f| f.match?(/\A[\w.-]+\z/) && File.file?(File.join(dir, f)) }
    raise Error, "Niente da pubblicare in #{dir}: esegui prima `ruby jarvis.rb --site`" if names.empty?

    names = names.partition { |f| f != "index.html" }.flatten # index per ultimo: mai un link a una pagina mancante
    names.each do |name|
      args = curl_args(File.join(dir, name), "#{base}#{name}", tls: uri.scheme == "ftp" && !allow_plain)
      out, err, ok = runner.call(args, curl_config(user, password))
      raise Error, "upload di #{name} fallito: #{redact(err.to_s.strip.empty? ? out : err, user, password)}" unless ok
    end

    "Pubblicati #{names.size} file su #{uri.scheme}://#{uri.host}#{uri.path}"
  end

  def self.validate(url, user, password, allow_plain)
    raise Error, "JARVIS_FTP_USER e JARVIS_FTP_PASSWORD non impostate" if user.to_s.empty? || password.to_s.empty?
    raise Error, "Le credenziali non possono contenere a-capo" if "#{user}#{password}".match?(/[\r\n]/)

    uri = URI.parse(url.to_s)
    raise Error, "JARVIS_FTP_URL deve iniziare con ftps://, sftp:// o ftp://" unless SCHEMES.include?(uri.scheme) && uri.host
    raise Error, "Metti le credenziali in JARVIS_FTP_USER/PASSWORD, non nell'URL" if uri.userinfo

    uri
  rescue URI::InvalidURIError
    raise Error, "JARVIS_FTP_URL non valido"
  end

  # Su ftp:// pretende TLS esplicito (--ssl-reqd) salvo consenso esplicito al contrario.
  def self.curl_args(file, target, tls:)
    args = %w[curl --silent --show-error --fail --connect-timeout 15 --max-time 120 --ftp-create-dirs]
    args << "--ssl-reqd" if tls
    args + ["-T", file, target, "-K", "-"]
  end

  def self.curl_config(user, password)
    escaped = "#{user}:#{password}".gsub("\\", "\\\\\\\\").gsub('"', '\\"')
    %(user = "#{escaped}"\n)
  end

  def self.redact(text, *secrets)
    secrets.reject { |s| s.to_s.empty? }.reduce(text.to_s) { |t, s| t.gsub(s, "***") }
  end

  def self.run_curl(args, config)
    out, err, status = Open3.capture3(*args, stdin_data: config)
    [out, err, status.success?]
  rescue Errno::ENOENT
    raise Error, "curl non trovato: installalo con `sudo apt install curl`"
  end
end
