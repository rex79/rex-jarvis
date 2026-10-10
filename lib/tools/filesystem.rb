require_relative "../config"

# Accesso al filesystem limitato a Config::BRAIN_DIR.
class Filesystem
  MAX_READ_BYTES = 100_000

  def self.safe_path(path)
    full = File.expand_path(path, Config::BRAIN_DIR)
    root = File.realpath(Config::BRAIN_DIR)
    real =
      if File.exist?(full)
        File.realpath(full)
      else
        parent = File.dirname(full)
        File.exist?(parent) ? File.join(File.realpath(parent), File.basename(full)) : full
      end
    unless real == root || real.start_with?(root + File::SEPARATOR)
      raise "Accesso negato: #{path} è fuori da #{Config::BRAIN_DIR}"
    end
    real
  end

  def self.list_files(directory = ".")
    path = safe_path(directory)
    raise "Directory non trovata: #{directory}" unless Dir.exist?(path)

    Dir.children(path).reject { |f| f.start_with?(".") }.sort
  end

  def self.read_file(file_path)
    path = safe_path(file_path)
    raise "File non trovato: #{file_path}" unless File.file?(path)

    File.read(path, MAX_READ_BYTES, encoding: "UTF-8").scrub
  end
end
