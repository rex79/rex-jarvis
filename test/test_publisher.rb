require "minitest/autorun"
require "tmpdir"
ENV["JARVIS_BRAIN"] = Dir.mktmpdir("brain")
require_relative "../lib/publisher"

class PublisherTest < Minitest::Test
  def site_dir
    dir = Dir.mktmpdir("site")
    %w[index.html 2026-10-13.html 2026-10-12.html robots.txt].each { |f| File.write(File.join(dir, f), "x") }
    File.write(File.join(dir, "strano nome.html"), "x") # nome non ammesso: ignorato
    dir
  end

  def publish(url: "ftp://ftp.example.com/www/jarvis", user: "utente", password: "s3gr3to", runner: nil, **opts)
    calls = []
    recorder = ->(args, config) { calls << [args, config]; (runner || ->(*) { ["", "", true] }).call(args, config) }
    result = Publisher.publish(site_dir, url: url, user: user, password: password, runner: recorder, **opts)
    [result, calls]
  end

  def test_uploads_every_valid_file_with_index_last
    result, calls = publish
    targets = calls.map { |args, _| args[args.index("-T") + 2] }
    assert_equal %w[2026-10-12.html 2026-10-13.html robots.txt index.html], targets.map { |t| File.basename(t) }
    assert_equal "ftp://ftp.example.com/www/jarvis/index.html", targets.last
    assert_match(/Pubblicati 4 file/, result)
  end

  def test_credentials_go_through_stdin_not_arguments
    _, calls = publish
    args, config = calls.first
    refute args.join(" ").include?("s3gr3to")
    refute args.join(" ").include?("utente")
    assert_equal %(user = "utente:s3gr3to"\n), config
    assert_includes args, "-K"
  end

  def test_plain_ftp_requires_tls_unless_explicitly_allowed
    _, calls = publish
    assert_includes calls.first[0], "--ssl-reqd"
    _, calls = publish(allow_plain: true)
    refute_includes calls.first[0], "--ssl-reqd"
  end

  def test_ftps_and_sftp_do_not_add_ssl_flag
    %w[ftps://h.example.com/a sftp://h.example.com/a].each do |url|
      _, calls = publish(url: url)
      refute_includes calls.first[0], "--ssl-reqd"
    end
  end

  def test_config_escapes_quotes_and_backslashes
    assert_equal %(user = "u:pa\\"ss\\\\w"\n), Publisher.curl_config("u", 'pa"ss\\w')
  end

  def test_rejects_bad_configuration
    assert_raises(Publisher::Error) { publish(user: "") }
    assert_raises(Publisher::Error) { publish(password: nil) }
    assert_raises(Publisher::Error) { publish(url: "http://example.com/") }
    assert_raises(Publisher::Error) { publish(url: "ftp://utente:pw@example.com/") }
    assert_raises(Publisher::Error) { publish(password: "a\nb") }
  end

  def test_failure_is_reported_without_leaking_secrets
    failing = ->(_args, _config) { ["", "curl: (67) Access denied for utente with s3gr3to", false] }
    error = assert_raises(Publisher::Error) { publish(runner: failing) }
    assert_includes error.message, "Access denied"
    refute_includes error.message, "s3gr3to"
    refute_includes error.message, "utente"
  end

  def test_empty_site_dir_raises
    Dir.mktmpdir do |dir|
      assert_raises(Publisher::Error) { Publisher.publish(dir, url: "ftps://h/a", user: "u", password: "p", runner: ->(*) { ["", "", true] }) }
    end
  end
end
