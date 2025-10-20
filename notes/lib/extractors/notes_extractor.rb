# Notes content extractor
# Extracts shared notes content and calculates word count

module NotesExtractors
  class NotesExtractor
    attr_reader :word_count

    def initialize
      @word_count = 0
    end

    def extract(raw_archive_dir, html_to_plain_text_method, logger)
      notes_html_file = "#{raw_archive_dir}/notes/notes.html"

      unless File.exist?(notes_html_file)
        logger.warn("notes.html not found, word count will be 0")
        return nil
      end

      html_content = File.read(notes_html_file)
      text_content = html_to_plain_text_method.call(html_content)

      # Count words
      words = text_content.split(/\s+/)
      @word_count = words.length
      logger.info("Extracted notes: #{@word_count} words")

      text_content.empty? ? nil : text_content
    end
  end
end
