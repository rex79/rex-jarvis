# Carica le variabili da ~/.jarvis_env (o da JARVIS_ENV_FILE) senza dipendenze.
# Formato: una riga CHIAVE=VALORE, opzionale `export`, commenti con #, valori anche tra apici.
# Le variabili già presenti nell'ambiente hanno la precedenza sul file.
# I valori non vengono mai stampati.
module EnvFile
  def self.load(path = ENV["JARVIS_ENV_FILE"] || File.expand_path("~/.jarvis_env"))
    return unless File.file?(path)

    if File.stat(path).mode & 0o077 != 0
      warn "⚠️  #{path} è leggibile da altri utenti: esegui `chmod 600 #{path}`"
    end

    parse(File.read(path)).each { |key, value| ENV[key] ||= value }
  end

  def self.parse(text)
    text.each_line.with_object({}) do |line, vars|
      line = line.strip.sub(/\Aexport\s+/, "")
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next if value.nil? || key !~ /\A[A-Za-z_][A-Za-z0-9_]*\z/

      value = value.strip
      value = value[1..-2] if value.match?(/\A(["']).*\1\z/m)
      vars[key] = value
    end
  end
end
