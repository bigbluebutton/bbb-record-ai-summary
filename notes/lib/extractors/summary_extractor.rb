# Meeting summary extractor
# Generates AI summary of notes and transcript using LLM

require_relative '../llm_client'

module NotesExtractors
  class SummaryExtractor
    def self.extract(notes_content, transcript, target_dir, logger)
      # Build structured prompt with clear section labels
      sections = []
      sections << "SHARED NOTES:\n#{notes_content}" if notes_content && !notes_content.empty?
      sections << "AUDIO TRANSCRIPT:\n#{transcript}" if transcript && !transcript.empty?
      combined_text = sections.join("\n\n")

      return nil if combined_text.empty?

      logger.info("Preparing to generate summary for #{combined_text.length} characters")

      # Load LLM configuration
      script_dir = File.expand_path('../../..', __dir__)  # Project root
      config_path = "#{script_dir}/config/llm.yml"

      unless File.exist?(config_path)
        logger.warn("LLM config not found at #{config_path}, skipping summarization")
        return nil
      end

      # Create LLM client
      begin
        llm_client = LLMClient::Base.create(config_path)
      rescue StandardError => e
        raise "Failed to initialize LLM client: #{e.message}"
      end

      # Generate summary
      logger.info("Generating summary using LLM...")
      summary = llm_client.summarize(combined_text)

      # Return nil if disabled or empty response
      return nil if summary.nil? || summary.strip.empty?

      # Save summary to file
      summary_file = "#{target_dir}/summary.txt"
      File.write(summary_file, summary.strip)

      logger.info("Generated summary: #{summary.length} characters, saved to summary.txt")
      summary.strip
    rescue StandardError => e
      raise "Summary generation failed: #{e.message}"
    end
  end
end
