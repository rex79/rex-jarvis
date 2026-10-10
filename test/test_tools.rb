require "minitest/autorun"
require "tmpdir"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/tools/filesystem"
require_relative "../lib/tools/notes"

class ToolsTest < Minitest::Test
  def test_blocks_paths_outside_brain
    assert_raises(RuntimeError) { Filesystem.read_file("/etc/passwd") }
    assert_raises(RuntimeError) { Filesystem.read_file("../../etc/passwd") }
  end

  def test_save_and_read_note
    Notes.save("Idea Uno", "testo di prova")
    assert_includes Filesystem.list_files("."), "idea-uno.md"
    assert_includes Filesystem.read_file("idea-uno.md"), "testo di prova"
  end

  def test_cosine
    assert_in_delta 1.0, Notes.cosine([1, 2], [1, 2]), 1e-6
    assert_in_delta 0.0, Notes.cosine([1, 0], [0, 1]), 1e-6
  end

  def test_split_respects_chunk_size
    text = (["parola " * 60] * 6).join("\n\n")
    assert Notes.split(text).all? { |c| c.length <= Notes::CHUNK_CHARS * 2 }
  end
end
