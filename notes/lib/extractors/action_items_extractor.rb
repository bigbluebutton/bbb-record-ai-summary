# Action items extractor
# Uses LLM to extract action items from meeting summary and transcript

require_relative '../llm_client'

module NotesExtractors
  class ActionItemsExtractor
    def self.extract(summary, transcript, target_dir, logger)
      # Build input for LLM
      sections = []
      sections << "MEETING SUMMARY:\n#{summary}" if summary && !summary.empty?
      sections << "TRANSCRIPT:\n#{transcript}" if transcript && !transcript.empty?
      combined_text = sections.join("\n\n")

      # Return empty array if no content
      return [] if combined_text.empty?

      logger.info("Extracting action items from #{combined_text.length} characters")

      # Load LLM configuration
      script_dir = File.expand_path('../../..', __dir__)  # Project root
      config_path = "#{script_dir}/config/llm.yml"

      unless File.exist?(config_path)
        logger.warn("LLM config not found at #{config_path}, skipping action items extraction")
        return []
      end

      # Create LLM client
      begin
        llm_client = LLMClient::Base.create(config_path)
      rescue StandardError => e
        logger.warn("Failed to initialize LLM client for action items: #{e.message}")
        return []
      end

      # Custom prompt for action item extraction
      prompt = <<~PROMPT
        Analyze the following meeting content to extract action items.

        For each action item, identify:
        - Owner: Person responsible (use "Team" if unclear or multiple people)
        - Task: Clear, concise description of what needs to be done
        - Status: Use "ok" for clear/actionable items, "warn" for items needing attention or follow-up

        Return ONLY a JSON array in this exact format:
        [
          {"owner": "Person Name", "label": "Task description", "status": "ok"},
          {"owner": "Another Person", "label": "Another task", "status": "warn"}
        ]

        If no action items are found, return an empty array: []

        Do not include any other text, explanations, or markdown - just the JSON array.

        #{combined_text}
      PROMPT

      # Generate action items
      logger.info("Generating action items using LLM...")
      begin
        response = llm_client.summarize(prompt)

        # Return empty array if disabled or empty response
        return [] if response.nil? || response.strip.empty?

        # Parse JSON response
        # Extract JSON array from response (handle markdown code blocks)
        json_text = response.strip
        json_text = json_text.gsub(/^```json?\s*\n/, '').gsub(/\n```$/, '')  # Remove markdown code blocks
        json_text = json_text.strip

        action_items_raw = JSON.parse(json_text)

        # Convert to symbol keys for consistency with template
        action_items = action_items_raw.map do |item|
          {
            owner: item['owner'] || 'Team',
            label: item['label'] || item['task'] || 'Unknown task',
            status: (item['status'] == 'ok' ? :ok : (item['status'] == 'warn' ? :warn : :pending))
          }
        end

        # Save to file
        if action_items && !action_items.empty?
          action_items_file = "#{target_dir}/action_items.json"
          File.write(action_items_file, JSON.pretty_generate(action_items_raw))
          logger.info("Extracted #{action_items.length} action items, saved to action_items.json")
        else
          logger.info("No action items identified")
        end

        action_items
      rescue JSON::ParserError => e
        logger.warn("Failed to parse action items JSON: #{e.message}")
        logger.warn("LLM response was: #{response[0...200]}...")
        []
      rescue StandardError => e
        logger.warn("Action items extraction failed: #{e.message}")
        []
      end
    rescue StandardError => e
      logger.error("Action items extraction error: #{e.message}")
      []
    end
  end
end
