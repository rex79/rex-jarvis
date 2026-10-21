require_relative "../config"

# Accesso al filesystem limitato a una cartella radice (le note di un contesto).
# I metodi di classe usano la cartella personale (Config::BRAIN_DIR), come prima.
class Filesystem
  MAX_READ_BYTES = 100_000

  attr_reader :root

  def initialize(root = Config::BRAIN_DIR)
    @root = File.expand_path(root)
  end

  def self.default
    new(Config::BRAIN_DIR)
  end

  def self.safe_path(path) = default.safe_path(path)
  def self.list_files(directory = ".") = default.list_files(directory)
  def self.read_file(file_path) = default.read_file(file_path)

  def safe_path(path)
    raise "Cartella note non trovata: #{@root}" unless Dir.exist?(@root)

    full = File.expand_path(path, @root)
    root = File.realpath(@root)
    real =
      if File.exist?(full)
        File.realpath(full)
      else
        parent = File.dirname(full)
        File.exist?(parent) ? File.join(File.realpath(parent), File.basename(full)) : full
      end
    unless real == root || real.start_with?(root + File::SEPARATOR)
      raise "Accesso negato: #{path} è fuori da #{@root}"
    end
    real
  end

  def list_files(directory = ".")
    path = safe_path(directory)
    raise "Directory non trovata: #{directory}" unless Dir.exist?(path)

    Dir.children(path).reject { |f| f.start_with?(".") }.sort
  end

  def read_file(file_path)
    path = safe_path(file_path)
    raise "File non trovato: #{file_path}" unless File.file?(path)

    File.read(path, MAX_READ_BYTES, encoding: "UTF-8").scrub
  end
end
