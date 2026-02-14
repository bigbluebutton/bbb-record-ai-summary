# WebVTT parser
# Parses WEBVTT transcript files into structured array format

module WebVTTParser
  # Parse a WebVTT file and return array of cues
  # Returns: [{start: "00:00:00.252", end: "00:00:28.732", speaker: "Name", text: "..."}]
  def self.parse(vtt_file_path)
    return [] unless File.exist?(vtt_file_path)

    content = File.read(vtt_file_path)
    return [] if content.strip.empty?

    cues = []
    lines = content.lines.map(&:strip)

    # Verify WEBVTT header
    return [] unless lines.first&.start_with?('WEBVTT')

    i = 1  # Skip header
    while i < lines.length
      line = lines[i]

      # Skip empty lines
      if line.empty?
        i += 1
        next
      end

      # Check if this is a timestamp line (format: "00:00:00.000 --> 00:00:00.000")
      if line.match?(/^\d{2}:\d{2}:\d{2}\.\d{3}\s+-->\s+\d{2}:\d{2}:\d{2}\.\d{3}$/)
        # Parse timestamps
        timestamps = line.split('-->').map(&:strip)
        start_time = timestamps[0]
        end_time = timestamps[1]

        # Next line should be the speaker and text
        i += 1
        if i < lines.length
          speaker_line = lines[i]

          # Parse speaker and text (format: "Speaker: text")
          if speaker_line.include?(':')
            parts = speaker_line.split(':', 2)
            speaker = parts[0].strip
            text = parts[1]&.strip || ''

            cues << {
              start: start_time,
              end: end_time,
              speaker: speaker,
              text: text
            }
          else
            # No speaker label, use entire line as text
            cues << {
              start: start_time,
              end: end_time,
              speaker: 'Unknown',
              text: speaker_line
            }
          end
        end
      end

      i += 1
    end

    cues
  rescue StandardError => e
    # Return empty array on error, log will be handled by caller
    []
  end

  # Convert cues array to SRT format
  def self.to_srt(cues)
    lines = []

    cues.each_with_index do |cue, index|
      lines << (index + 1).to_s
      start_ts = cue[:start].gsub('.', ',')
      end_ts = cue[:end].gsub('.', ',')
      lines << "#{start_ts} --> #{end_ts}"
      lines << "#{cue[:speaker]}: #{cue[:text]}"
      lines << ''
    end

    lines.join("\n")
  end

  # Convert cues array back to WebVTT format (utility method)
  def self.to_webvtt(cues)
    lines = ['WEBVTT', '']

    cues.each do |cue|
      lines << "#{cue[:start]} --> #{cue[:end]}"
      lines << "#{cue[:speaker]}: #{cue[:text]}"
      lines << ''
    end

    lines.join("\n")
  end
end
