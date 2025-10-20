# Audio transcript extractor
# Uses whisper.cpp to transcribe meeting audio with speaker diarization

module NotesExtractors
  class TranscriptExtractor
    def self.extract(raw_archive_dir, target_dir, logger, events_doc = nil)
      # Find audio files (supports multiple formats)
      audio_patterns = %w[*.opus *.mp3 *.wav *.ogg *.m4a *.flac]
      audio_files = audio_patterns.flat_map { |pattern| Dir.glob("#{raw_archive_dir}/audio/#{pattern}") }

      return nil if audio_files.empty?

      logger.info("Found #{audio_files.length} audio file(s)")

      # Use the first/main audio file
      audio_file = audio_files.first
      logger.info("Transcribing: #{File.basename(audio_file)}")

      # Set up paths
      script_dir = File.expand_path('../../..', __dir__)  # Project root
      transcribe_script = "#{script_dir}/transcribe.sh"
      transcript_file = "#{target_dir}/transcript.txt"
      transcript_json = "#{target_dir}/transcript.json"

      # Check if transcribe.sh exists
      unless File.exist?(transcribe_script)
        raise "Transcription script not found: #{transcribe_script}"
      end

      # Run transcription (plain text for backward compatibility)
      success = system(transcribe_script, audio_file, transcript_file)

      unless success
        raise "Transcription failed with exit code #{$?.exitstatus}"
      end

      # Read plain transcript
      unless File.exist?(transcript_file)
        raise "Transcript file not created: #{transcript_file}"
      end

      transcript = File.read(transcript_file).strip

      if transcript.empty?
        logger.warn("Transcription produced empty output")
        return nil
      end

      logger.info("Transcribed #{transcript.length} characters")

      # If events_doc provided, generate diarized transcript
      if events_doc
        diarized = generate_diarized_transcript(raw_archive_dir, target_dir, logger,
                                                 events_doc, transcribe_script, audio_file,
                                                 transcript_json)

        return { plain: transcript, diarized: diarized } if diarized
      end

      # Return plain text if diarization not available
      transcript
    end

    private

    def self.generate_diarized_transcript(raw_archive_dir, target_dir, logger,
                                          events_doc, transcribe_script, audio_file,
                                          transcript_json)
      logger.info("Generating diarized transcript...")

      # Extract participant mapping (userId => name)
      participant_map = extract_participant_mapping(events_doc, logger)

      if participant_map.empty?
        logger.warn("No participants found for diarization")
        return nil
      end

      # Extract talking timeline
      talking_timeline = extract_talking_timeline(events_doc, logger)

      if talking_timeline.empty?
        logger.warn("No talking events found for diarization")
        return nil
      end

      # Find recording start timestamp
      recording_start = extract_recording_start(events_doc, logger)

      unless recording_start
        logger.warn("No recording start event found")
        return nil
      end

      # Run whisper with JSON output
      logger.info("Running whisper with JSON output for diarization...")
      success = system(transcribe_script, audio_file, transcript_json, '--json')

      unless success || File.exist?(transcript_json)
        logger.warn("JSON transcription failed, skipping diarization")
        return nil
      end

      # Parse JSON and build diarized transcript
      begin
        json_data = JSON.parse(File.read(transcript_json))
        segments = json_data['transcription'] || []

        diarized_lines = []
        segments.each do |segment|
          # Get segment time range in milliseconds
          # whisper.cpp JSON format uses timestamps in milliseconds
          segment_start_ms = recording_start + segment['offsets']['from']
          segment_end_ms = recording_start + segment['offsets']['to']

          # Use midpoint of segment for better speaker matching
          segment_mid_ms = (segment_start_ms + segment_end_ms) / 2

          # Find speaker at midpoint of this segment
          speaker_id = find_speaker_at_time(segment_mid_ms, talking_timeline)
          speaker_name = participant_map[speaker_id] || "Unknown Speaker"

          # Format as "[Speaker]: text"
          text = segment['text'].strip
          diarized_lines << "[#{speaker_name}]: #{text}" unless text.empty?
        end

        logger.info("Diarized transcript: #{diarized_lines.length} segments")
        diarized_lines.join("\n")

      rescue JSON::ParserError => e
        logger.error("Failed to parse JSON transcript: #{e.message}")
        nil
      rescue => e
        logger.error("Diarization failed: #{e.message}")
        nil
      end
    end

    def self.extract_participant_mapping(events_doc, logger)
      mapping = {}

      # Extract from ParticipantJoinedEvent (voice events have userId and callername)
      events_doc.xpath("//event[@eventname='ParticipantJoinedEvent']").each do |event|
        participant_id = event.xpath('participant').text.strip
        caller_name = event.xpath('callername').text.strip

        mapping[participant_id] = caller_name unless participant_id.empty? || caller_name.empty?
      end

      logger.info("Extracted #{mapping.size} participant mappings")
      mapping
    end

    def self.extract_talking_timeline(events_doc, logger)
      timeline = []
      current_speakers = {}  # Track current talking state for each participant

      events_doc.xpath("//event[@eventname='ParticipantTalkingEvent']").each do |event|
        participant_id = event.xpath('participant').text.strip
        talking = event.xpath('talking').text.strip == 'true'
        timestamp = event['timestamp'].to_i

        if talking
          # Speaker started talking
          current_speakers[participant_id] = timestamp
        else
          # Speaker stopped talking
          if current_speakers[participant_id]
            timeline << {
              speaker: participant_id,
              start: current_speakers[participant_id],
              end: timestamp
            }
            current_speakers.delete(participant_id)
          end
        end
      end

      logger.info("Extracted #{timeline.size} speaking segments")
      timeline
    end

    def self.extract_recording_start(events_doc, logger)
      recording_event = events_doc.xpath("//event[@eventname='StartRecordingEvent']").first

      if recording_event
        timestamp = recording_event.xpath('recordingTimestamp').text.to_i
        logger.info("Recording started at timestamp: #{timestamp}")
        timestamp
      else
        nil
      end
    end

    def self.find_speaker_at_time(timestamp, talking_timeline)
      # First, try to find exact match (timestamp within speaking segment)
      exact_match = talking_timeline.find do |s|
        s[:start] <= timestamp && timestamp <= s[:end]
      end

      return exact_match[:speaker] if exact_match

      # If no exact match, find the closest speaking segment
      # Add tolerance window of 5 seconds to account for latency
      tolerance_ms = 5000

      closest = talking_timeline.min_by do |s|
        # Calculate distance from timestamp to this speaking segment
        if timestamp < s[:start]
          s[:start] - timestamp
        elsif timestamp > s[:end]
          timestamp - s[:end]
        else
          0  # timestamp is within segment (shouldn't happen, we checked above)
        end
      end

      # Only return if within tolerance
      if closest
        distance = if timestamp < closest[:start]
                    closest[:start] - timestamp
                  elsif timestamp > closest[:end]
                    timestamp - closest[:end]
                  else
                    0
                  end

        return closest[:speaker] if distance <= tolerance_ms
      end

      nil  # No match found within tolerance
    end
  end
end
