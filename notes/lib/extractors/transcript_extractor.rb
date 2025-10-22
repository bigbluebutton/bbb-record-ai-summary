# Audio transcript extractor
# Uses whisper.cpp to transcribe meeting audio with speaker diarization

module NotesExtractors
  class TranscriptExtractor
    def self.extract(raw_archive_dir, target_dir, logger, events_doc = nil)
      # Set up paths
      script_dir = File.expand_path('../../..', __dir__)  # Project root
      transcribe_script = "#{script_dir}/transcribe.sh"

      # Check if transcribe.sh exists
      unless File.exist?(transcribe_script)
        raise "Transcription script not found: #{transcribe_script}"
      end

      # Try per-speaker transcription if events_doc provided
      if events_doc
        audio_tracks = extract_audio_track_mappings(events_doc, logger)

        # If we have per-speaker audio tracks, use new method
        unless audio_tracks.empty?
          logger.info("Using per-speaker transcription (#{audio_tracks.size} tracks)")

          # Find recording start time for relative timestamps
          recording_start = extract_recording_start_time(events_doc, logger)
          unless recording_start
            logger.error("Could not find recording start event")
            return nil
          end

          # Transcribe each speaker's audio tracks
          words = transcribe_per_speaker_tracks(raw_archive_dir, target_dir, audio_tracks,
                                                transcribe_script, logger)

          if words.empty?
            logger.warn("No words extracted from per-speaker transcription")
          else
            # Merge and format transcript with relative timestamps
            diarized = merge_and_format_transcript(words, recording_start, logger)

            # Save diarized transcript
            diarized_file = "#{target_dir}/transcript_diarized.txt"
            File.write(diarized_file, diarized)
            logger.info("Saved diarized transcript: #{diarized_file}")

            # Also create a plain text version (just the text without timestamps/speakers)
            plain_text = words.map { |w| w[:text] }.join('')
            transcript_file = "#{target_dir}/transcript.txt"
            File.write(transcript_file, plain_text)

            return { plain: plain_text, diarized: diarized }
          end
        end
      end

      # Fall back to legacy single-file transcription
      logger.info("Falling back to legacy single-file transcription")

      # Find audio files (supports multiple formats)
      audio_patterns = %w[*.opus *.mp3 *.wav *.ogg *.m4a *.flac *.webm]
      audio_files = audio_patterns.flat_map { |pattern| Dir.glob("#{raw_archive_dir}/audio/#{pattern}") }

      return nil if audio_files.empty?

      logger.info("Found #{audio_files.length} audio file(s)")

      # Use the first/main audio file
      audio_file = audio_files.first
      logger.info("Transcribing: #{File.basename(audio_file)}")

      transcript_file = "#{target_dir}/transcript.txt"
      transcript_json = "#{target_dir}/transcript.json"

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

      # If events_doc provided, generate diarized transcript (legacy method)
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

    # Transcribe per-speaker audio tracks and return word-level entries
    # Returns array of: { abs_timestamp:, abs_end_timestamp:, user_id:, name:, text: }
    def self.transcribe_per_speaker_tracks(raw_archive_dir, target_dir, audio_tracks, transcribe_script, logger)
      all_words = []

      audio_tracks.each do |basename, track_info|
        audio_file = "#{raw_archive_dir}/audio/#{basename}"

        unless File.exist?(audio_file)
          logger.warn("Audio file not found: #{audio_file}")
          next
        end

        logger.info("Transcribing #{basename} (#{track_info[:name]})...")

        # Generate unique JSON output filename
        json_file = "#{target_dir}/#{basename}.json"

        # Run transcription with full JSON output
        success = system(transcribe_script, audio_file, json_file, '--json-full')

        unless success && File.exist?(json_file)
          logger.warn("Failed to transcribe #{basename}, skipping")
          next
        end

        # Parse JSON and extract words with absolute timestamps
        begin
          json_data = JSON.parse(File.read(json_file))
          transcription = json_data['transcription'] || []

          transcription.each do |segment|
            next unless segment['tokens']

            segment['tokens'].each do |token|
              # Skip special tokens (begin/end markers)
              next if token['text'].start_with?('[_')

              # Parse timestamp from "HH:MM:SS,mmm" format to milliseconds
              from_ms = parse_timestamp(token['timestamps']['from'])
              to_ms = parse_timestamp(token['timestamps']['to'])

              # Convert to absolute timestamp by adding track's start time
              abs_from = track_info[:timestamp_utc] + from_ms
              abs_to = track_info[:timestamp_utc] + to_ms

              all_words << {
                abs_timestamp: abs_from,
                abs_end_timestamp: abs_to,
                user_id: track_info[:user_id],
                name: track_info[:name],
                text: token['text']
              }
            end
          end

          logger.info("Extracted #{all_words.size - (all_words.size - segment['tokens']&.size || 0)} words from #{basename}")
        rescue JSON::ParserError => e
          logger.error("Failed to parse JSON for #{basename}: #{e.message}")
        rescue => e
          logger.error("Error processing #{basename}: #{e.message}")
        end
      end

      all_words.sort_by! { |w| w[:abs_timestamp] }
      logger.info("Total words extracted: #{all_words.size}")
      all_words
    end

    # Parse timestamp string "HH:MM:SS,mmm" to milliseconds
    def self.parse_timestamp(ts_string)
      return 0 if ts_string.nil? || ts_string.empty?

      # Format: "00:00:05,380"
      parts = ts_string.split(/[:,]/)
      return 0 if parts.size < 4

      hours = parts[0].to_i
      minutes = parts[1].to_i
      seconds = parts[2].to_i
      millis = parts[3].to_i

      (hours * 3600 + minutes * 60 + seconds) * 1000 + millis
    end

    # Format timestamp from milliseconds to "HH:MM:SS.mmm"
    def self.format_timestamp(ms)
      total_seconds = ms / 1000
      millis = ms % 1000

      hours = total_seconds / 3600
      minutes = (total_seconds % 3600) / 60
      seconds = total_seconds % 60

      format("%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    end

    # Merge word entries and format as speaker-attributed transcript
    # recording_start is in milliseconds (UTC timestamp)
    def self.merge_and_format_transcript(words, recording_start, logger)
      return "" if words.empty?

      lines = []
      current_speaker_id = nil
      current_speaker_name = nil
      current_text = []
      segment_start = nil
      segment_end = nil

      words.each do |word|
        # If speaker changed, output previous segment
        if current_speaker_id != word[:user_id] && !current_text.empty?
          # Convert absolute timestamps to relative (from recording start)
          relative_start = segment_start - recording_start
          relative_end = segment_end - recording_start

          timestamp_range = "#{format_timestamp(relative_start)} --> #{format_timestamp(relative_end)}"
          lines << "#{timestamp_range}: #{current_speaker_name}"
          lines << current_text.join('')
          lines << ""  # Blank line between segments

          current_text = []
        end

        # Start new segment or continue current
        if current_speaker_id != word[:user_id]
          current_speaker_id = word[:user_id]
          current_speaker_name = word[:name]
          segment_start = word[:abs_timestamp]
        end

        segment_end = word[:abs_end_timestamp]
        current_text << word[:text]
      end

      # Output final segment
      unless current_text.empty?
        # Convert absolute timestamps to relative (from recording start)
        relative_start = segment_start - recording_start
        relative_end = segment_end - recording_start

        timestamp_range = "#{format_timestamp(relative_start)} --> #{format_timestamp(relative_end)}"
        lines << "#{timestamp_range}: #{current_speaker_name}"
        lines << current_text.join('')
      end

      logger.info("Generated #{lines.size} transcript lines")
      lines.join("\n")
    end

    # Extract recording start time from RecordStatusEvent with status=true
    # Returns timestampUTC in milliseconds, or nil if not found
    def self.extract_recording_start_time(events_doc, logger)
      # Find RecordStatusEvent with status=true
      recording_event = events_doc.xpath("//event[@eventname='RecordStatusEvent']").find do |event|
        event.xpath('status').text.strip == 'true'
      end

      if recording_event
        timestamp = recording_event.xpath('timestampUTC').text.to_i
        logger.info("Recording started at timestamp: #{timestamp}")
        timestamp
      else
        logger.warn("No RecordStatusEvent with status=true found")
        nil
      end
    end

    # Extract per-speaker audio track mappings from events.xml
    # Returns hash: { basename => { user_id:, name:, timestamp_utc: } }
    def self.extract_audio_track_mappings(events_doc, logger)
      # First, build userId -> name mapping from ParticipantJoinEvent
      user_names = {}
      events_doc.xpath("//event[@eventname='ParticipantJoinEvent']").each do |event|
        user_id = event.xpath('userId').text.strip
        name = event.xpath('name').text.strip
        user_names[user_id] = name unless user_id.empty? || name.empty?
      end

      logger.info("Found #{user_names.size} participants")

      # Extract audio track info from AudioTrackPublishedEvent
      audio_tracks = {}
      events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").each do |event|
        user_id = event.xpath('userId').text.strip
        filename = event.xpath('filename').text.strip
        timestamp_utc = event.xpath('timestampUTC').text.to_i

        next if user_id.empty? || filename.empty?

        basename = File.basename(filename)
        audio_tracks[basename] = {
          user_id: user_id,
          name: user_names[user_id] || "Unknown (#{user_id})",
          timestamp_utc: timestamp_utc
        }
      end

      logger.info("Found #{audio_tracks.size} audio track events")
      audio_tracks
    end
  end
end
