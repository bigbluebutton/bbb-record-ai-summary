# Audio transcript extractor
# Uses whisper.cpp to transcribe meeting audio with speaker diarization

module NotesExtractors
  class TranscriptExtractor
    # Minimum average token confidence to keep a segment (0.0-1.0)
    MIN_SEGMENT_CONFIDENCE = 0.4
    # Minimum meaningful words a track must produce to be included
    MIN_TRACK_WORDS = 3
    # Maximum characters in a single VTT cue text before splitting at sentence boundaries
    MAX_CUE_CHARS = 200
    # Maximum duration (ms) for a single VTT cue before splitting
    MAX_CUE_DURATION_MS = 15_000

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

        # If we have per-speaker audio tracks, use segment-level method
        unless audio_tracks.empty?
          logger.info("Using per-speaker transcription (#{audio_tracks.size} tracks)")

          # Find recording start time for relative timestamps
          recording_start = extract_recording_start_time(events_doc, logger)
          unless recording_start
            logger.error("Could not find recording start event")
            return nil
          end

          # Transcribe each speaker's audio tracks (segment-level)
          segments = transcribe_per_speaker_tracks(raw_archive_dir, target_dir, audio_tracks,
                                                    transcribe_script, logger)

          if segments.empty?
            logger.warn("No segments extracted from per-speaker transcription")
          else
            # Merge and format transcript with relative timestamps
            diarized = merge_and_format_transcript(segments, recording_start, logger)

            # Save diarized transcript in WebVTT format
            diarized_file = "#{target_dir}/transcript_diarized.vtt"
            File.write(diarized_file, diarized)
            logger.info("Saved diarized transcript (WebVTT): #{diarized_file}")

            # Create plain text version with speaker labels
            plain_text = generate_plain_text(segments, recording_start)
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

    # Transcribe per-speaker audio tracks and return segment-level entries
    # Returns array of: { abs_start:, abs_end:, user_id:, name:, text:, confidence: }
    def self.transcribe_per_speaker_tracks(raw_archive_dir, target_dir, audio_tracks, transcribe_script, logger)
      all_segments = []

      audio_tracks.each do |basename, track_info|
        # [Improvement 1] Skip screen share audio tracks - they contain tab/presentation audio, not speech
        if basename.start_with?('screen_share_audio')
          logger.info("Skipping screen share audio track: #{basename}")
          next
        end

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

        # [Improvement 2] Extract at segment level (not token level)
        begin
          json_data = JSON.parse(File.read(json_file))
          transcription = json_data['transcription'] || []

          track_segments = []

          transcription.each do |segment|
            next unless segment['tokens']

            # Skip entire segment if it's just noise description
            segment_text = segment['text'].to_s.strip
            next if segment_text.empty?
            next if is_noise_segment?(segment_text)

            # [Improvement 3] Calculate average confidence from non-special tokens
            real_tokens = segment['tokens'].reject { |t| is_special_token?(t['text'].to_s) }
            next if real_tokens.empty?

            avg_confidence = real_tokens.sum { |t| t['p'].to_f } / real_tokens.size

            if avg_confidence < MIN_SEGMENT_CONFIDENCE
              logger.info("Skipping low-confidence segment (#{format('%.2f', avg_confidence)}): #{segment_text[0..60]}")
              next
            end

            from_ms = segment['offsets']['from']
            to_ms = segment['offsets']['to']

            track_segments << {
              abs_start: track_info[:timestamp_utc] + from_ms,
              abs_end: track_info[:timestamp_utc] + to_ms,
              user_id: track_info[:user_id],
              name: track_info[:name],
              text: segment_text,
              confidence: avg_confidence
            }
          end

          # [Improvement 4] Skip tracks that produce too few meaningful words
          total_words = track_segments.sum { |s| s[:text].split.size }
          if total_words < MIN_TRACK_WORDS
            logger.info("Skipping track #{basename}: only #{total_words} words (min: #{MIN_TRACK_WORDS})")
            next
          end

          logger.info("Extracted #{track_segments.size} segments (#{total_words} words) from #{basename}")
          all_segments.concat(track_segments)
        rescue JSON::ParserError => e
          logger.error("Failed to parse JSON for #{basename}: #{e.message}")
        rescue => e
          logger.error("Error processing #{basename}: #{e.message}")
        end
      end

      all_segments.sort_by! { |s| s[:abs_start] }
      logger.info("Total segments extracted: #{all_segments.size}")
      all_segments
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
      ms = [ms, 0].max  # Clamp to non-negative
      total_seconds = ms / 1000
      millis = ms % 1000

      hours = total_seconds / 3600
      minutes = (total_seconds % 3600) / 60
      seconds = total_seconds % 60

      format("%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    end

    # Check if token text is a special whisper token (not real speech)
    def self.is_special_token?(text)
      trimmed = text.strip
      return true if trimmed.start_with?('[_')
      return true if trimmed == '[BLANK_AUDIO]'
      return true if trimmed.match?(/^[\[\]()]$/)
      return true if trimmed.match?(/^(BLANK|AUDIO|AUD|ANK|BL|IO|BEG|END|TT|_|sil|ence)$/i)
      false
    end

    # Check if segment text contains only noise descriptions in parentheses
    def self.is_noise_segment?(segment_text)
      return false if segment_text.nil? || segment_text.empty?
      trimmed = segment_text.strip
      # Check if entire segment is just noise description(s) in parentheses
      trimmed.match?(/^\s*\([^)]*(?:keyboard|clicking|typing|noise|coughing|laughing|silence)[^)]*\)\s*$/i)
    end

    # [Improvement 2+5] Merge segments and format as speaker-attributed WebVTT
    # Works at segment level (not word level) to preserve sentence coherence
    # Splits long cues at sentence boundaries
    def self.merge_and_format_transcript(segments, recording_start, logger)
      return "" if segments.empty?

      lines = ["WEBVTT", ""]

      # Group consecutive segments by speaker, then emit VTT cues
      current_speaker_id = nil
      current_speaker_name = nil
      current_texts = []     # accumulated text pieces for current cue
      cue_start = nil        # absolute timestamp of cue start
      cue_end = nil          # absolute timestamp of cue end

      segments.each do |seg|
        speaker_changed = current_speaker_id && current_speaker_id != seg[:user_id]
        cue_too_long = cue_start && (
          current_texts.join(' ').length >= MAX_CUE_CHARS ||
          (seg[:abs_end] - cue_start) > MAX_CUE_DURATION_MS
        )

        # Emit current cue if speaker changed or cue too long
        if (speaker_changed || cue_too_long) && !current_texts.empty?
          emit_cues(lines, current_speaker_name, current_texts.join(' '), cue_start, cue_end, recording_start)
          current_texts = []
          cue_start = nil
        end

        # Initialize or update speaker
        if current_speaker_id.nil? || speaker_changed
          current_speaker_id = seg[:user_id]
          current_speaker_name = seg[:name]
        end

        cue_start ||= seg[:abs_start]
        cue_end = seg[:abs_end]
        current_texts << seg[:text]
      end

      # Emit final cue
      unless current_texts.empty?
        emit_cues(lines, current_speaker_name, current_texts.join(' '), cue_start, cue_end, recording_start)
      end

      logger.info("Generated WebVTT with #{lines.count { |l| l.include?('-->') }} cues")
      lines.join("\n")
    end

    # [Improvement 5] Emit one or more VTT cues, splitting long text at sentence boundaries
    def self.emit_cues(lines, speaker_name, full_text, abs_start, abs_end, recording_start)
      text = full_text.strip
      return if text.empty?

      # If short enough, emit as single cue
      if text.length <= MAX_CUE_CHARS
        relative_start = abs_start - recording_start
        relative_end = abs_end - recording_start
        lines << "#{format_timestamp(relative_start)} --> #{format_timestamp(relative_end)}"
        lines << "#{speaker_name}: #{text}"
        lines << ""
        return
      end

      # Split at sentence boundaries for long text
      sentences = split_into_sentences(text)
      total_duration = abs_end - abs_start
      total_chars = text.length

      # Distribute time proportionally across sentences
      current_offset = 0
      current_group = []
      current_group_chars = 0
      group_start_chars = 0

      sentences.each_with_index do |sentence, idx|
        current_group << sentence
        current_group_chars += sentence.length

        # Emit group if it's long enough or it's the last sentence
        at_end = (idx == sentences.length - 1)
        group_text = current_group.join(' ')

        if group_text.length >= MAX_CUE_CHARS / 2 || at_end
          # Calculate proportional timestamps
          char_ratio_start = total_chars > 0 ? group_start_chars.to_f / total_chars : 0
          char_ratio_end = total_chars > 0 ? (group_start_chars + current_group_chars).to_f / total_chars : 1

          cue_abs_start = abs_start + (total_duration * char_ratio_start).to_i
          cue_abs_end = abs_start + (total_duration * char_ratio_end).to_i

          relative_start = cue_abs_start - recording_start
          relative_end = cue_abs_end - recording_start

          lines << "#{format_timestamp(relative_start)} --> #{format_timestamp(relative_end)}"
          lines << "#{speaker_name}: #{group_text.strip}"
          lines << ""

          group_start_chars += current_group_chars
          current_group = []
          current_group_chars = 0
        end
      end
    end

    # Split text into sentences at .!? boundaries
    def self.split_into_sentences(text)
      # Split on sentence-ending punctuation followed by space or end of string
      # Keep the punctuation with the sentence
      sentences = text.scan(/[^.!?]*[.!?]+(?:\s|$)|[^.!?]+$/).map(&:strip).reject(&:empty?)
      # If scanning didn't produce results, return the whole text
      sentences.empty? ? [text] : sentences
    end

    # Generate plain text transcript with speaker labels
    def self.generate_plain_text(segments, recording_start)
      return "" if segments.empty?

      lines = []
      current_speaker_id = nil

      segments.each do |seg|
        if seg[:user_id] != current_speaker_id
          current_speaker_id = seg[:user_id]
          lines << "" unless lines.empty?
          lines << "#{seg[:name]}:"
        end
        lines << seg[:text]
      end

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
