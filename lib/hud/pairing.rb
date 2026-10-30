require "json"
require "fileutils"
require "openssl"
require "securerandom"
require "time"

# Accesso alla dashboard dalla rete di casa. Sul Mac mini `--hud-pair` genera un codice monouso;
# il tablet lo scambia con un token suo, che tiene nel browser e manda a ogni chiamata. Nel file
# (permessi 600) restano solo le impronte: leggerlo non basta per entrare. Il file è condiviso tra
# il comando e il server, che sono processi diversi: ogni operazione lo rilegge sotto lock.
class HudPairing
  CODE_TTL = 10 * 60
  MAX_ATTEMPTS = 5 # poi il codice non vale più
  ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".chars.freeze # niente caratteri che si confondono

  def initialize(file: File.expand_path("~/.jarvis/hud_pairing.json"))
    @file = file
  end

  def start(now: Time.now)
    code = Array.new(8) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join
    update do |data|
      data["pending"] = { "digest" => digest(code), "expires_at" => (now + CODE_TTL).iso8601, "attempts" => 0 }
    end
    code
  end

  # Restituisce il token del dispositivo; il codice vale una volta sola.
  def redeem(code, now: Time.now)
    update do |data|
      pending = data["pending"]
      raise ArgumentError, "nessun codice valido: generane uno con --hud-pair" unless pending && Time.parse(pending["expires_at"]) > now

      unless same?(digest(code.to_s.strip.upcase), pending["digest"])
        pending["attempts"] += 1
        data.delete("pending") if pending["attempts"] >= MAX_ATTEMPTS
        next :wrong
      end

      token = SecureRandom.hex(32)
      data.delete("pending")
      data["devices"] = Array(data["devices"]) << { "digest" => digest(token), "paired_at" => now.iso8601 }
      token
    end.tap { |result| raise ArgumentError, "codice errato" if result == :wrong }
  end

  def valid?(token)
    return false if token.to_s.empty?

    given = digest(token)
    Array(read["devices"]).any? { |device| same?(given, device["digest"]) }
  end

  # Tablet perso o da sostituire: tutti i dispositivi dovranno rifare l'abbinamento.
  def revoke_all
    update do |data|
      count = Array(data["devices"]).size
      data.clear
      count
    end
  end

  private

  def digest(text) = OpenSSL::Digest::SHA256.hexdigest(text.to_s)

  def same?(a, b) = a.bytesize == b.to_s.bytesize && OpenSSL.fixed_length_secure_compare(a, b.to_s)

  def read
    File.file?(@file) ? JSON.parse(File.read(@file, encoding: "UTF-8")) : {}
  end

  def update
    FileUtils.mkdir_p(File.dirname(@file))
    File.open("#{@file}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      data = read
      begin
        yield data
      ensure
        File.write(@file, JSON.generate(data), perm: 0o600)
        File.chmod(0o600, @file)
      end
    end
  end
end
