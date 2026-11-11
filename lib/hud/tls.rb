require "openssl"
require "fileutils"
require "ipaddr"

# HTTPS per la dashboard sulla rete di casa. I browser concedono il microfono solo alle pagine
# sicure, quindi per la voce dal tablet serve un certificato: il Mac mini se ne genera uno suo
# (autofirmato, 5 anni) per i nomi e gli indirizzi con cui viene aperto, e lo tiene in ~/.jarvis.
# Sul tablet va accettato una volta ("Avanzate → Procedi"), oppure installato come certificato fidato.
# Se cambiano gli indirizzi del Mac mini il certificato viene rigenerato.
class HudTls
  YEARS = 5

  attr_reader :cert_file

  def initialize(hosts:, dir: File.expand_path("~/.jarvis"))
    @hosts = hosts.uniq
    @cert_file = File.join(dir, "hud_cert.pem")
    @key_file = File.join(dir, "hud_key.pem")
  end

  def wrap(tcp_server)
    server = OpenSSL::SSL::SSLServer.new(tcp_server, context)
    server.start_immediately = false # la stretta di mano si fa nel thread del client, non nel ciclo di accept
    server
  end

  def handshake(client)
    client.accept
    client
  rescue StandardError
    client.close
    raise
  end

  def context
    cert, key = load || generate
    OpenSSL::SSL::SSLContext.new.tap do |ctx|
      ctx.cert = cert
      ctx.key = key
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
    end
  end

  # Impronta da confrontare con quella mostrata dal browser prima di fidarsi.
  def fingerprint
    cert, = load || generate
    OpenSSL::Digest::SHA256.hexdigest(cert.to_der).upcase.scan(/../).join(":")
  end

  private

  def names = @hosts.map { |h| ip?(h) ? "IP:#{h}" : "DNS:#{h}" }.sort

  def ip?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::Error
    false
  end

  # Il certificato salvato vale se non è scaduto e copre tutti i nomi di oggi.
  def load
    return nil unless File.file?(@cert_file) && File.file?(@key_file)

    cert = OpenSSL::X509::Certificate.new(File.read(@cert_file))
    key = OpenSSL::PKey.read(File.read(@key_file))
    san = cert.extensions.find { |e| e.oid == "subjectAltName" }&.value.to_s.gsub("IP Address:", "IP:").split(/,\s*/)
    return nil if cert.not_after < Time.now + 86_400 || !(names - san).empty?

    [cert, key]
  rescue OpenSSL::OpenSSLError
    nil
  end

  def generate
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(127)
    cert.subject = cert.issuer = OpenSSL::X509::Name.new([["CN", "Jarvis HUD (#{@hosts.find { |h| !ip?(h) && h != 'localhost' } || 'localhost'})"]])
    cert.public_key = key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + YEARS * 365 * 86_400
    factory = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    # CA:TRUE permette di installarlo sul tablet come certificato fidato.
    cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(factory.create_extension("keyUsage", "digitalSignature,keyCertSign", true))
    cert.add_extension(factory.create_extension("extendedKeyUsage", "serverAuth"))
    cert.add_extension(factory.create_extension("subjectAltName", names.join(",")))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))

    FileUtils.mkdir_p(File.dirname(@cert_file))
    File.write(@key_file, key.to_pem, perm: 0o600)
    File.write(@cert_file, cert.to_pem)
    [cert, key]
  end
end
