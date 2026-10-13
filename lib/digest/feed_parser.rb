require "cgi"
require "time"

module DailyDigest
  Item = Struct.new(:title, :url, :source, :published, :text, :position, :ranked, :stars, :score, :boost, :cap, :window, :category, keyword_init: true)

  # Parser RSS/Atom minimale, solo libreria standard (niente gem rexml).
  module FeedParser
    def self.parse(xml, source, ranked: false)
      xml = xml.to_s.dup.force_encoding("UTF-8").scrub
      blocks = xml.scan(%r{<(?:item|entry)[\s>].*?</(?:item|entry)>}m)

      blocks.each_with_index.map do |block, i|
        Item.new(
          title: clean(tag(block, "title")),
          url: link(block),
          source: source,
          published: time(tag(block, "published") || tag(block, "updated") || tag(block, "pubDate") || tag(block, "dc:date")),
          text: clean(tag(block, "summary") || tag(block, "description") || tag(block, "content")),
          position: i,
          ranked: ranked
        )
      end.reject { |it| it.title.empty? || it.url.to_s.empty? }
    end

    def self.tag(block, name)
      block[%r{<#{Regexp.escape(name)}(?:\s[^>]*)?>(.*?)</#{Regexp.escape(name)}>}m, 1]
    end

    def self.link(block)
      text = clean(tag(block, "link"))
      return text unless text.empty?

      block[/<link[^>]*href=["']([^"']+)["']/, 1]&.then { |u| CGI.unescapeHTML(u) }
    end

    def self.time(value)
      value && Time.parse(clean(value))
    rescue ArgumentError
      nil
    end

    # Rimuove CDATA, tag HTML ed entità: il testo dei feed è non attendibile.
    def self.clean(value)
      return "" if value.nil?

      text = value.gsub(/<!\[CDATA\[|\]\]>/, "")
      text = CGI.unescapeHTML(text)
      text = text.gsub(/<[^>]*>/, " ")
      CGI.unescapeHTML(text).gsub(/\s+/, " ").strip
    end
  end
end
