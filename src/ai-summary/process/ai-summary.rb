# Set encoding to utf-8
# encoding: UTF-8

#
# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/
#
# Copyright (c) 2019 BigBlueButton Inc. and by respective authors (see below).
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.
#

# For PRODUCTION - Use system library
require '/usr/local/bigbluebutton/core/lib/recordandplayback'

require 'rubygems'
require 'optimist'
require 'yaml'
require 'json'
require 'erb'

require File.expand_path('../../../lib/ai-summary/llm_client.rb', __FILE__)

module WebVTTParser
  # Parse a WebVTT file and return array of cues
  # Returns: [{start: "00:00:00.252", end: "00:00:28.732", speaker: "Name", text: "..."}]
  def self.parse(transcript_diarized)
    content = transcript_diarized
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
end

module MarkdownConverter
  # Convert markdown text to HTML
  def self.convert(markdown_text)
    return '' if markdown_text.nil? || markdown_text.empty?

    html = markdown_text.dup

    # Escape HTML entities first
    html = escape_html(html)

    # Convert headers (must be done before other formatting)
    html = html.gsub(/^### (.+)$/m, '<h3>\1</h3>')
    html = html.gsub(/^## (.+)$/m, '<h2>\1</h2>')
    html = html.gsub(/^# (.+)$/m, '<h1>\1</h1>')

    # Convert horizontal rules
    html = html.gsub(/^---+$/, '<hr>')
    html = html.gsub(/^\*\*\*+$/, '<hr>')

    # Convert bold and italic (must be done before lists)
    html = html.gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
    html = html.gsub(/__(.+?)__/, '<strong>\1</strong>')
    html = html.gsub(/\*(.+?)\*/, '<em>\1</em>')
    html = html.gsub(/_(.+?)_/, '<em>\1</em>')

    # Convert inline code
    html = html.gsub(/`(.+?)`/, '<code>\1</code>')

    # Convert links
    html = html.gsub(/\[([^\]]+)\]\(([^)]+)\)/, '<a href="\2">\1</a>')

    # Convert lists (unordered)
    html = convert_unordered_lists(html)

    # Convert lists (ordered)
    html = convert_ordered_lists(html)

    # Convert paragraphs (double newlines to <p> tags)
    html = convert_paragraphs(html)

    html
  end

  private

  def self.escape_html(text)
    text.gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub('"', '&quot;')
        .gsub("'", '&#39;')
  end

  def self.convert_unordered_lists(html)
    lines = html.lines
    result = []
    in_list = false

    lines.each do |line|
      # Check for unordered list item (starts with -, *, or +)
      if line.match?(/^\s*[-*+]\s+(.+)/)
        unless in_list
          result << '<ul>'
          in_list = true
        end
        content = line.sub(/^\s*[-*+]\s+/, '').strip
        result << "<li>#{content}</li>"
      else
        if in_list
          result << '</ul>'
          in_list = false
        end
        result << line
      end
    end

    # Close list if still open
    result << '</ul>' if in_list

    result.join
  end

  def self.convert_ordered_lists(html)
    lines = html.lines
    result = []
    in_list = false

    lines.each do |line|
      # Check for ordered list item (starts with number followed by . or ))
      if line.match?(/^\s*\d+\.\s+(.+)/)
        unless in_list
          result << '<ol>'
          in_list = true
        end
        content = line.sub(/^\s*\d+\.\s+/, '').strip
        result << "<li>#{content}</li>"
      else
        if in_list
          result << '</ol>'
          in_list = false
        end
        result << line
      end
    end

    # Close list if still open
    result << '</ol>' if in_list

    result.join
  end

  def self.convert_paragraphs(html)
    # Split on double newlines to identify paragraph blocks
    blocks = html.split(/\n\n+/)

    blocks.map do |block|
      block = block.strip
      next block if block.empty?

      # Don't wrap if already HTML tags
      if block.start_with?('<h1>', '<h2>', '<h3>', '<ul>', '<ol>', '<hr>', '<pre>', '<blockquote>')
        block
      else
        # Check if entire block is just a list or header tag
        if block.match?(/^<(li|h\d|hr|ul|ol)/)
          block
        else
          # Wrap in paragraph tags, preserving internal newlines as <br>
          lines = block.split("\n")
          if lines.length > 1
            "<p>#{lines.join('<br>')}</p>"
          else
            "<p>#{block}</p>"
          end
        end
      end
    end.join("\n")
  end
end

module Extractors
  class AttendeesExtractor
    def self.extract(events_doc, logger)
      attendees = []

      # Get unique participant names from ParticipantJoinEvent
      events_doc.xpath("//event[@eventname='ParticipantJoinEvent']/name").each do |name_node|
        name = name_node.text.strip
        attendees << name unless attendees.include?(name) || name.empty?
      end

      logger.info("Extracted #{attendees.length} attendees")
      attendees.any? ? attendees.sort : []
    end
  end
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

  class PollsExtractor
    def self.extract(events_doc, logger)
      polls = []

      # Extract poll published events
      events_doc.xpath("//event[@eventname='PollPublishedRecordEvent']").each do |event|
        poll_id = event.at_xpath("pollId")&.text
        question = event.at_xpath("question")&.text

        # Parse answers
        answers = []
        event.xpath(".//answer").each do |answer|
          answers << {
            text: answer.at_xpath("key")&.text,
            votes: answer.at_xpath("numVotes")&.text.to_i
          }
        end

        polls << { id: poll_id, question: question, answers: answers } if question
      end

      logger.info("Extracted #{polls.length} polls")
      polls.any? ? polls : nil
    end
  end

  # Reads pre-computed transcription from post_archive/transcribe_audio.rb output
  # Expected input: raw_archive_dir/transcription/transcription.json
  class TranscriptExtractor
    # Maximum characters in a single VTT cue text before splitting at sentence boundaries
    MAX_CUE_CHARS = 200
    # Maximum duration (ms) for a single VTT cue before splitting
    MAX_CUE_DURATION_MS = 15_000

    # Extract transcript from pre-computed transcription.json.
    # Returns { plain: String, diarized: String } or nil if no transcription found.
    def self.extract(raw_archive_dir, target_dir, logger, events_doc = nil, config = {})
      transcription_file = "#{raw_archive_dir}/transcription/transcription.json"

      unless File.exist?(transcription_file)
        logger.warn("No transcription.json found at #{transcription_file}. " \
                    "Run post_archive/transcribe_audio.rb first.")
        return nil
      end

      begin
        json_data = JSON.parse(File.read(transcription_file))
      rescue JSON::ParserError => e
        logger.error("Failed to parse transcription.json: #{e.message}")
        return nil
      end

      tracks_data = json_data['tracks'] || []

      if tracks_data.empty?
        logger.warn("No tracks in transcription.json")
        return nil
      end

      # Determine recording start time and audio track → speaker mappings from events.xml
      recording_start = nil
      audio_tracks    = {}

      if events_doc
        recording_start = BigBlueButton::Events.first_event_timestamp(events_doc)
        audio_tracks    = extract_audio_track_mappings(events_doc, logger)
      end

      unless recording_start
        logger.error("Could not determine recording start time from events.xml")
        return nil
      end

      # Build a flat list of segments with absolute timestamps and speaker attribution
      segments = []

      tracks_data.each do |track|
        file_basename = track['file']
        track_info    = audio_tracks[file_basename]

        unless track_info
          logger.warn("No speaker mapping for audio track '#{file_basename}', " \
                      "attributing to 'Unknown Speaker'")
          track_info = {
            user_id:       file_basename,
            name:          'Unknown Speaker',
            timestamp_utc: recording_start
          }
        end

        (track['segments'] || []).each do |seg|
          text = seg['text'].to_s.strip
          next if text.empty?

          from_ms = seg.dig('offsets', 'from').to_i
          to_ms   = seg.dig('offsets', 'to').to_i

          segments << {
            abs_start: track_info[:timestamp_utc] + from_ms,
            abs_end:   track_info[:timestamp_utc] + to_ms,
            user_id:   track_info[:user_id],
            name:      track_info[:name],
            text:      text
          }
        end
      end

      if segments.empty?
        logger.warn("No transcript segments found in transcription.json")
        return nil
      end

      segments.sort_by! { |s| s[:abs_start] }
      logger.info("Loaded #{segments.size} segments from transcription.json " \
                  "(#{tracks_data.size} track(s))")

      # Generate WebVTT with speaker labels
      diarized      = merge_and_format_transcript(segments, recording_start, logger)
      diarized_file = "#{target_dir}/transcript_diarized.vtt"
      File.write(diarized_file, diarized)
      logger.info("Saved diarized transcript: #{diarized_file}")

      # Generate plain text
      plain_text      = generate_plain_text(segments)
      transcript_file = "#{target_dir}/transcript.txt"
      File.write(transcript_file, plain_text)
      logger.info("Saved plain transcript: #{transcript_file}")

      { plain: plain_text, diarized: diarized }
    end

    private

    # Format milliseconds as "HH:MM:SS.mmm"
    def self.format_timestamp(ms)
      ms           = [ms, 0].max
      total_seconds = ms / 1000
      millis        = ms % 1000
      hours         = total_seconds / 3600
      minutes       = (total_seconds % 3600) / 60
      seconds       = total_seconds % 60
      format('%02d:%02d:%02d.%03d', hours, minutes, seconds, millis)
    end

    # Build speaker-attributed WebVTT from sorted segment list
    def self.merge_and_format_transcript(segments, recording_start, logger)
      return '' if segments.empty?

      lines = ['WEBVTT', '']

      current_speaker_id   = nil
      current_speaker_name = nil
      current_texts        = []
      cue_start            = nil
      cue_end              = nil

      segments.each do |seg|
        speaker_changed = current_speaker_id && current_speaker_id != seg[:user_id]
        cue_too_long    = cue_start && (
          current_texts.join(' ').length >= MAX_CUE_CHARS ||
          (seg[:abs_end] - cue_start) > MAX_CUE_DURATION_MS
        )

        if (speaker_changed || cue_too_long) && !current_texts.empty?
          emit_cues(lines, current_speaker_name, current_texts.join(' '),
                    cue_start, cue_end, recording_start)
          current_texts = []
          cue_start     = nil
        end

        if current_speaker_id.nil? || speaker_changed
          current_speaker_id   = seg[:user_id]
          current_speaker_name = seg[:name]
        end

        cue_start ||= seg[:abs_start]
        cue_end     = seg[:abs_end]
        current_texts << seg[:text]
      end

      unless current_texts.empty?
        emit_cues(lines, current_speaker_name, current_texts.join(' '),
                  cue_start, cue_end, recording_start)
      end

      logger.info("Generated WebVTT with #{lines.count { |l| l.include?('-->') }} cues")
      lines.join("\n")
    end

    # Emit one or more VTT cues, splitting long text at sentence boundaries
    def self.emit_cues(lines, speaker_name, full_text, abs_start, abs_end, recording_start)
      text = full_text.strip
      return if text.empty?

      if text.length <= MAX_CUE_CHARS
        lines << "#{format_timestamp(abs_start - recording_start)} --> " \
                 "#{format_timestamp(abs_end - recording_start)}"
        lines << "#{speaker_name}: #{text}"
        lines << ''
        return
      end

      sentences      = split_into_sentences(text)
      total_duration = abs_end - abs_start
      total_chars    = text.length

      current_group        = []
      current_group_chars  = 0
      group_start_chars    = 0

      sentences.each_with_index do |sentence, idx|
        current_group       << sentence
        current_group_chars += sentence.length
        at_end               = idx == sentences.length - 1
        group_text           = current_group.join(' ')

        next unless group_text.length >= MAX_CUE_CHARS / 2 || at_end

        char_ratio_start = total_chars > 0 ? group_start_chars.to_f / total_chars : 0
        char_ratio_end   = total_chars > 0 ? (group_start_chars + current_group_chars).to_f / total_chars : 1

        cue_abs_start = abs_start + (total_duration * char_ratio_start).to_i
        cue_abs_end   = abs_start + (total_duration * char_ratio_end).to_i

        lines << "#{format_timestamp(cue_abs_start - recording_start)} --> " \
                 "#{format_timestamp(cue_abs_end - recording_start)}"
        lines << "#{speaker_name}: #{group_text.strip}"
        lines << ''

        group_start_chars  += current_group_chars
        current_group        = []
        current_group_chars  = 0
      end
    end

    # Split text into sentences at .!? boundaries
    def self.split_into_sentences(text)
      sentences = text.scan(/[^.!?]*[.!?]+(?:\s|$)|[^.!?]+$/).map(&:strip).reject(&:empty?)
      sentences.empty? ? [text] : sentences
    end

    # Generate plain text transcript with speaker-grouped lines
    def self.generate_plain_text(segments)
      return '' if segments.empty?

      lines              = []
      current_speaker_id = nil

      segments.each do |seg|
        if seg[:user_id] != current_speaker_id
          current_speaker_id = seg[:user_id]
          lines << '' unless lines.empty?
          lines << "#{seg[:name]}:"
        end
        lines << seg[:text]
      end

      lines.join("\n")
    end

    # Extract recording start time from RecordStatusEvent (status=true)
    def self.extract_recording_start_time(events_doc, logger)
      event = events_doc.xpath("//event[@eventname='RecordStatusEvent']").find do |e|
        e.xpath('status').text.strip == 'true'
      end

      if event
        ts = event.xpath('timestampUTC').text.to_i
        logger.info("Recording start timestampUTC: #{ts}")
        ts
      else
        logger.warn("No RecordStatusEvent with status=true found")
        nil
      end
    end

    # Build hash: audio_file_basename => { user_id:, name:, timestamp_utc: }
    def self.extract_audio_track_mappings(events_doc, logger)
      user_names = {}
      events_doc.xpath("//event[@eventname='ParticipantJoinEvent']").each do |event|
        user_id = event.xpath('userId').text.strip
        name    = event.xpath('name').text.strip
        user_names[user_id] = name unless user_id.empty? || name.empty?
      end
      logger.info("Found #{user_names.size} participant(s) in events.xml")

      audio_tracks = {}
      events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").each do |event|
        user_id       = event.xpath('userId').text.strip
        filename      = event.xpath('filename').text.strip
        timestamp_utc = event.xpath('timestampUTC').text.to_i

        next if user_id.empty? || filename.empty?

        basename = File.basename(filename)
        audio_tracks[basename] = {
          user_id:       user_id,
          name:          user_names[user_id] || "Unknown (#{user_id})",
          timestamp_utc: timestamp_utc
        }
      end
      logger.info("Found #{audio_tracks.size} AudioTrackPublishedEvent(s)")
      audio_tracks
    end
  end

  class SummaryExtractor
    def self.extract(notes_content, transcript, target_dir, logger)
      # Build structured prompt with clear section labels
      sections = []
      sections << "SHARED NOTES:\n#{notes_content}" if notes_content && !notes_content.empty?
      sections << "AUDIO TRANSCRIPT:\n#{transcript}" if transcript && !transcript.empty?
      combined_text = sections.join("\n\n")

      return nil if combined_text.empty?

      logger.info("Preparing to generate summary for #{combined_text.length} characters")

      # Create LLM client
      begin
        llm_client = LLMClient::Base.create(logger)
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

      # Create LLM client
      begin
        llm_client = LLMClient::Base.create(logger)
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

# Helper method to convert HTML to plain text
def html_to_plain_text(html_content)
  return "" if html_content.nil? || html_content.empty?

  text = html_content.dup
  # Remove style, script, and head tags with their content
  text.gsub!(/<(style|script|head)[^>]*>.*?<\/\1>/im, '')
  # Strip remaining HTML tags
  text.gsub!(/<[^>]*>/, "\n")
  # Remove HTML entities (numeric and named)
  text.gsub!(/&#\d+;|&[a-z]+;/i, ' ')
  # Remove Etherpad IDs (e.g., g.xxxxx$notes)
  text.gsub!(/^g\.\w+\$\w+\s*$/m, '')
  text.strip
end

# Helper method to render markdown using ERB template
def render_markdown_template(template_path, data)
  template_content = File.read(template_path, encoding: 'utf-8')
  erb = ERB.new(template_content, trim_mode: '-')

  # Create a binding with instance variables for ERB
  template_binding = binding
  data.each { |key, value| template_binding.local_variable_set(key, value) }

  # Set instance variables for ERB template access
  data.each { |key, value| instance_variable_set("@#{key}", value) }

  erb.result(binding)
end

# Helper method to render HTML using ERB template
def render_html_template(template_path, data)
  template_content = File.read(template_path, encoding: 'utf-8')
  erb = ERB.new(template_content, trim_mode: '-')

  # Set instance variables for ERB template access
  data.each { |key, value| instance_variable_set("@#{key}", value) }

  erb.result(binding)
end

# Helper method to build complete metadata XML
def build_metadata_xml(meeting_id, events_doc, raw_archive_dir, word_count)
  # Extract timing information
  meeting_start = events_doc.xpath("//event")[0][:timestamp]
  meeting_end = events_doc.xpath("//event").last[:timestamp]

  match = /.*-(\d+)$/.match(meeting_id)
  real_start_time = match[1]
  real_end_time = (real_start_time.to_i + (meeting_end.to_i - meeting_start.to_i)).to_s

  # Build initial XML structure
  builder = Builder::XmlMarkup.new(:indent => 2)
  xml = builder.recording {
    builder.id(meeting_id)
    builder.state("processed")
    builder.published(false)
    builder.start_time(real_start_time)
    builder.end_time(real_end_time)
    builder.participants(BigBlueButton::Events.get_num_participants(events_doc))
    builder.playback
    builder.meta {
      BigBlueButton::Events.get_meeting_metadata("#{raw_archive_dir}/events.xml").each { |k,v|
        builder.method_missing(k, v)
      }
    }
    builder.wordcount(word_count)
  }

  # Parse and append breakout room info if present
  metadata = Nokogiri::XML(xml)
  recording = metadata.root

  [events_doc.xpath("//meeting"),
   events_doc.xpath("//breakout"),
   events_doc.xpath("//breakoutRooms")].each do |nodes|
    recording << nodes if nodes.any?
  end

  # Format with no blanks
  Nokogiri::XML(metadata.to_xml) { |x| x.noblanks }
end

# Parse command line options
opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :default => '58f4a6b3-cd07-444d-8564-59116cb53974', :type => String
end

meeting_id = opts[:meeting_id]

# Resolve directories — works in both local dev and production deployment
script_dir  = File.expand_path(__dir__)           # .../process

BBB_SCRIPTS_DIR = '/usr/local/bigbluebutton/core/scripts'.freeze

if script_dir.start_with?("#{BBB_SCRIPTS_DIR}")
  # Production: configs live directly in the BBB scripts directory
  props       = YAML.safe_load(File.read("#{BBB_SCRIPTS_DIR}/bigbluebutton.yml"))
  format_props = YAML.safe_load(File.read("#{BBB_SCRIPTS_DIR}/ai-summary.yml"))
else
  # Development: configs are in the project root config/ directory
  project_root = File.expand_path('../../..', script_dir)
  props        = YAML.safe_load(File.read("#{project_root}/src/bigbluebutton.yml"))
  format_props  = YAML.safe_load(File.read("#{project_root}/src/ai-summary.yml"))
end

format = format_props['format']

# Set up paths
recording_dir = props['recording_dir']
raw_archive_dir = "#{recording_dir}/raw/#{meeting_id}"
log_dir = props['log_dir']
ai_summary_file = "#{raw_archive_dir}/notes/notes.#{format}"
target_dir = "#{recording_dir}/process/ai-summary/#{meeting_id}"
playback_dir = format_props['playback_dir']


# Main processing logic
unless FileTest.directory?(target_dir)
  FileUtils.mkdir_p "#{log_dir}/ai-summary"
  logger = Logger.new("#{log_dir}/ai-summary/process-#{meeting_id}.log", 'daily')
  BigBlueButton.logger = logger
  BigBlueButton.logger.info("Processing script ai-summary.rb")
  FileUtils.mkdir_p target_dir

  # Early exit if there are no notes for this meeting
  unless File.exist?(ai_summary_file)
    BigBlueButton.logger.info("There wasn't any note for #{meeting_id}")
    File.write("#{recording_dir}/status/processed/#{meeting_id}-ai-summary.done", "Processed #{meeting_id}")
    exit 0
  end

  begin
    # Copy notes file
    FileUtils.cp(ai_summary_file, "#{target_dir}/ai-summary.#{format}")

    # Load events.xml for metadata and extraction
    events_doc = Nokogiri::XML(File.open("#{raw_archive_dir}/events.xml"))

    # Initialize notes extractor and extract content
    notes_extractor = Extractors::NotesExtractor.new
    notes_content = notes_extractor.extract(raw_archive_dir, method(:html_to_plain_text), BigBlueButton.logger)
    word_count = notes_extractor.word_count

    # Extract all other data using extractors
    attendees = Extractors::AttendeesExtractor.extract(events_doc, BigBlueButton.logger)

    transcript = Extractors::TranscriptExtractor.extract(raw_archive_dir, target_dir, BigBlueButton.logger, events_doc, format_props)

    polls = Extractors::PollsExtractor.extract(events_doc, BigBlueButton.logger)

    # Handle transcript format (can be string or hash with plain/diarized)
    transcript_plain = transcript.is_a?(Hash) ? transcript[:plain] : transcript
    transcript_diarized = transcript.is_a?(Hash) ? transcript[:diarized] : nil

    transcript_cues = WebVTTParser.parse(transcript_diarized)

    summary = Extractors::SummaryExtractor.extract(notes_content, transcript_plain, target_dir, BigBlueButton.logger)

    # Collect all data for template
    template_data = {
      notes_content: notes_content,
      word_count: word_count,
      attendees: attendees,
      transcript: transcript_plain,
      transcript_diarized: transcript_diarized,
      polls: polls,
      summary: summary
    }

    # Render markdown from ERB template
    BigBlueButton.logger.info("Rendering ai-summary.md from template")
    template_path = "#{playback_dir}/notes.md.erb"
    notes_md_content = render_markdown_template(template_path, template_data)
    File.write("#{target_dir}/ai-summary.md", notes_md_content)
    BigBlueButton.logger.info("Created ai-summary.md with #{word_count} words and #{attendees.length} attendees")

    # Generate HTML report
    BigBlueButton.logger.info("Rendering ai-summary.html from template")

    # Extract action items using LLM
    action_items = Extractors::ActionItemsExtractor.extract(
      summary, transcript_plain, target_dir, BigBlueButton.logger
    )

    # Convert notes content to HTML
    notes_html = MarkdownConverter.convert(notes_content)

    # Extract key points from summary (lines starting with -, *, or •)
    key_points = []
    if summary && !summary.empty?
      summary.split("\n").each do |line|
        stripped = line.strip
        if stripped.match?(/^[-*•]\s+/)
          key_points << stripped.sub(/^[-*•]\s+/, '')
        end
      end
    end

    # Prepare HTML template data
    html_data = {
      title: "BigBlueButton Session — Summary & Transcript",
      subtitle: "Meeting notes, transcript, and AI-generated summary",
      attendees: attendees,
      attendee_count: attendees.length,
      word_count: word_count,
      transcript: transcript_cues,
      transcript_format: "Speaker-labeled",
      vtt_label: "WEBVTT",
      transcript_title: "Speaker-Labeled Transcript",
      transcript_open: true,
      timestamps_note: "Timestamps relative to recording start.",
      shared_notes: notes_html,
      summary: summary,
      key_points: key_points.empty? ? nil : key_points,
      action_items: action_items,
      footer: "Generated by BigBlueButton Notes processor. Optimized for print and dark/light mode."
    }

    # Render HTML
    html_template_path = "#{playback_dir}/notes.html.erb"
    notes_html_content = render_html_template(html_template_path, html_data)
    File.write("#{target_dir}/ai-summary.html", notes_html_content)
    BigBlueButton.logger.info("Created ai-summary.html with #{attendees.length} attendees and #{transcript_cues.length} transcript cues")

    metadata = build_metadata_xml(meeting_id, events_doc, raw_archive_dir, word_count)

    # Write metadata.xml
    File.write("#{target_dir}/metadata.xml", metadata.root)
    BigBlueButton.logger.info("Created metadata.xml with state=processed, timing info, and word count (#{word_count})")

    # Write status file
    File.write("#{recording_dir}/status/processed/#{meeting_id}-ai-summary.done", "Processed #{meeting_id}")

  rescue Exception => e
    BigBlueButton.logger.error(e.message)
    e.backtrace.each do |traceline|
      BigBlueButton.logger.error(traceline)
    end
    exit 1
  end
else
  File.write("#{recording_dir}/status/processed/#{meeting_id}-ai-summary.done", "Processed #{meeting_id}")
end
