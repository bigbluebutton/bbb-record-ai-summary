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
require 'set'
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

      # Check if this is a timestamp line (format: "HH:MM:SS.mmm --> HH:MM:SS.mmm", hours may be >2 digits)
      if line.match?(/^\d+:\d{2}:\d{2}\.\d{3}\s+-->\s+\d+:\d{2}:\d{2}\.\d{3}$/)
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
    html = html.gsub(/^### (.+)$/, '<h3>\1</h3>')
    html = html.gsub(/^## (.+)$/, '<h2>\1</h2>')
    html = html.gsub(/^# (.+)$/, '<h1>\1</h1>')

    # Convert horizontal rules
    html = html.gsub(/^---+$/, '<hr>')
    html = html.gsub(/^\*\*\*+$/, '<hr>')

    # Convert tables (before inline formatting)
    html = convert_tables(html)

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
    pending_blanks = []

    lines.each do |line|
      # Check for unordered list item (starts with -, *, or +)
      if line.match?(/^\s*[-*+]\s+(.+)/)
        unless in_list
          result << '<ul>'
          in_list = true
        end
        # Discard any blank lines that appeared between list items (loose list)
        pending_blanks.clear
        content = line.sub(/^\s*[-*+]\s+/, '').strip
        result << "<li>#{content}</li>"
      elsif line.strip.empty? && in_list
        # Blank line inside a list — hold it until we know if the list continues
        pending_blanks << line
      else
        if in_list
          result << '</ul>'
          in_list = false
          result.concat(pending_blanks)
          pending_blanks = []
        end
        result << line
      end
    end

    # Close list if still open
    if in_list
      result << '</ul>'
    else
      result.concat(pending_blanks)
    end

    result.join
  end

  def self.convert_ordered_lists(html)
    lines = html.lines
    result = []
    in_list = false
    pending_blanks = []

    lines.each do |line|
      # Check for ordered list item (starts with number followed by .)
      if line.match?(/^\s*\d+\.\s+(.+)/)
        unless in_list
          result << '<ol>'
          in_list = true
        end
        # Discard any blank lines that appeared between list items (loose list)
        pending_blanks.clear
        content = line.sub(/^\s*\d+\.\s+/, '').strip
        result << "<li>#{content}</li>"
      elsif line.strip.empty? && in_list
        # Blank line inside a list — hold it until we know if the list continues
        pending_blanks << line
      else
        if in_list
          result << '</ol>'
          in_list = false
          result.concat(pending_blanks)
          pending_blanks = []
        end
        result << line
      end
    end

    # Close list if still open
    if in_list
      result << '</ol>'
    else
      result.concat(pending_blanks)
    end

    result.join
  end

  def self.convert_tables(html)
    lines = html.lines
    result = []
    i = 0

    while i < lines.length
      # Detect table: current line has pipes and next line is a separator (|---|)
      if lines[i].match?(/^\s*\|.+\|/) && i + 1 < lines.length && lines[i + 1].match?(/^\s*\|[\s\-:|]+\|/)
        table_lines = []
        j = i
        while j < lines.length && lines[j].match?(/^\s*\|.+\|/)
          table_lines << lines[j]
          j += 1
        end

        header_cells = parse_table_row(table_lines[0])
        data_rows = table_lines[2..].map { |row| parse_table_row(row) }

        table_html = "<table>\n<thead>\n<tr>"
        header_cells.each { |cell| table_html += "<th>#{cell}</th>" }
        table_html += "</tr>\n</thead>\n<tbody>\n"
        data_rows.each do |row|
          table_html += "<tr>"
          row.each { |cell| table_html += "<td>#{cell}</td>" }
          table_html += "</tr>\n"
        end
        table_html += "</tbody>\n</table>\n"

        result << table_html
        i = j
      else
        result << lines[i]
        i += 1
      end
    end

    result.join
  end

  def self.parse_table_row(line)
    parts = line.split('|')
    # Remove leading/trailing empty strings from outer pipes
    parts = parts[1..] if parts.first&.strip&.empty?
    parts = parts[0..-2] if parts.last&.strip&.empty?
    parts.map(&:strip)
  end

  def self.convert_paragraphs(html)
    # Split on double newlines to identify paragraph blocks
    blocks = html.split(/\n\n+/)

    blocks.map do |block|
      block = block.strip
      next block if block.empty?

      # Don't wrap if already HTML tags
      if block.start_with?('<h1>', '<h2>', '<h3>', '<ul>', '<ol>', '<hr>', '<pre>', '<blockquote>', '<table>')
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

      return nil if text_content.strip.empty?

      # Count words
      words = text_content.split(/\s+/)
      @word_count = words.length
      logger.info("Extracted notes: #{@word_count} words")

      { plain_text: text_content, html: html_content }
    end
  end

  class PollsExtractor
    # Both PollPublishedRecordEvent and PollStartedRecordEvent store answers as JSONs
    def self.parse_answers_json(raw_json)
      JSON.parse(raw_json).map { |a| { text: a["key"], votes: a["numVotes"].to_i } }
    rescue StandardError
      []
    end

    def self.extract(events_doc, logger)
      polls = []
      published_poll_ids = Set.new

      # Primary: PollPublishedRecordEvent (moderator explicitly closed the poll)
      events_doc.xpath("//event[@eventname='PollPublishedRecordEvent']").each do |event|
        poll_id = event.at_xpath("pollId")&.text
        question = event.at_xpath("question")&.text
        next unless question

        answers = parse_answers_json(event.at_xpath("answers")&.text.to_s)
        polls << { id: poll_id, question: question, answers: answers }
        published_poll_ids << poll_id
      end

      # Fallback: reconstruct polls that were started but never explicitly published
      # (e.g. meeting ended while poll was still open)
      started_polls = {}
      events_doc.xpath("//event[@eventname='PollStartedRecordEvent']").each do |event|
        poll_id = event.at_xpath("pollId")&.text
        next if poll_id.nil? || published_poll_ids.include?(poll_id)

        question = event.at_xpath("question")&.text
        next unless question

        # Answers are stored as a JSON array: [{"id":0,"key":"Margerita"}, ...]
        raw_answers = event.at_xpath("answers")&.text
        answer_defs = JSON.parse(raw_answers).each_with_object({}) do |a, h|
          h[a["id"]] = { text: a["key"], votes: 0 }
        end rescue {}

        started_polls[poll_id] = { question: question, answers: answer_defs }
      end

      events_doc.xpath("//event[@eventname='UserRespondedToPollRecordEvent']").each do |event|
        poll_id = event.at_xpath("pollId")&.text
        answer_id = event.at_xpath("answerId")&.text&.to_i
        next unless started_polls.key?(poll_id)
        next unless started_polls[poll_id][:answers].key?(answer_id)

        started_polls[poll_id][:answers][answer_id][:votes] += 1
      end

      started_polls.each do |poll_id, data|
        answers = data[:answers].sort_by { |id, _| id }.map { |_, a| a }
        polls << { id: poll_id, question: data[:question], answers: answers }
      end

      logger.info("Extracted #{polls.length} polls (#{published_poll_ids.size} published, #{started_polls.size} reconstructed)")
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
        recording_start = extract_recording_start_time(events_doc, logger)
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

      { plain: plain_text, diarized: diarized, language: json_data['language'], recording_start: recording_start }
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

      cues = []

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
          collect_cues(cues, current_speaker_name, current_texts.join(' '),
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
        collect_cues(cues, current_speaker_name, current_texts.join(' '),
                     cue_start, cue_end, recording_start)
      end

      cues.sort_by! { |c| c[:start_ms] }

      lines = ['WEBVTT', '']
      cues.each do |cue|
        lines << "#{format_timestamp(cue[:start_ms])} --> #{format_timestamp(cue[:end_ms])}"
        lines << "#{cue[:speaker]}: #{cue[:text]}"
        lines << ''
      end

      logger.info("Generated WebVTT with #{cues.size} cues")
      lines.join("\n")
    end

    # Collect one or more VTT cues into the array, splitting long text at sentence boundaries
    def self.collect_cues(cues, speaker_name, full_text, abs_start, abs_end, recording_start)
      text = full_text.strip
      return if text.empty?

      if text.length <= MAX_CUE_CHARS
        cues << { start_ms: abs_start - recording_start,
                  end_ms:   abs_end   - recording_start,
                  speaker:  speaker_name,
                  text:     text }
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

        cues << { start_ms: cue_abs_start - recording_start,
                  end_ms:   cue_abs_end   - recording_start,
                  speaker:  speaker_name,
                  text:     group_text.strip }

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

    # Extract recording start time as absolute UTC ms (consistent with AudioTrackPublishedEvent).
    # Tries RecordStatusEvent first, then falls back to the first event that carries timestampUTC.
    def self.extract_recording_start_time(events_doc, logger)
      # Preferred: explicit recording-start marker
      record_event = events_doc.xpath("//event[@eventname='RecordStatusEvent']").find do |e|
        e.xpath('status').text.strip == 'true'
      end

      if record_event
        ts = record_event.xpath('timestampUTC').text.to_i
        if ts > 0
          logger.info("Recording start from RecordStatusEvent timestampUTC: #{ts}")
          return ts
        end
      end

      # Fallback: first event in events.xml that has a timestampUTC child element.
      # NOTE: the `timestamp` attribute on events is ms since the BBB server started
      # (not Unix epoch), so we must use timestampUTC for a consistent time reference.
      events_doc.xpath("//event").each do |e|
        ts = e.at_xpath('timestampUTC')&.text.to_i
        if ts && ts > 0
          logger.info("Recording start from first event with timestampUTC: #{ts}")
          return ts
        end
      end

      logger.warn("Could not determine recording start from timestampUTC in events.xml")
      nil
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
    def self.polls_to_text(polls)
      return nil if polls.nil? || polls.empty?

      lines = polls.each_with_index.map do |poll, i|
        answers = poll[:answers].map { |a| "  - #{a[:text]}: #{a[:votes]} vote(s)" }.join("\n")
        "Poll #{i + 1}: #{poll[:question]}\n#{answers}"
      end
      lines.join("\n\n")
    end

    def self.format_chat_timestamp(ms)
      ms = [ms, 0].max
      total_seconds = ms / 1000
      hours   = total_seconds / 3600
      minutes = (total_seconds % 3600) / 60
      seconds = total_seconds % 60
      hours > 0 ? format('%d:%02d:%02d', hours, minutes, seconds) : format('%d:%02d', minutes, seconds)
    end

    def self.extract(notes_content, transcript, target_dir, logger, polls: nil, language: nil, chat: nil)
      # Build structured prompt with clear section labels
      sections = []
      sections << "SHARED NOTES:\n#{notes_content}" if notes_content && !notes_content.empty?
      sections << "AUDIO TRANSCRIPT:\n#{transcript}" if transcript && !transcript.empty?
      polls_text = polls_to_text(polls)
      sections << "POLL RESULTS:\n#{polls_text}" if polls_text
      if chat && !chat.empty?
        chat_lines = chat.map { |m| "[#{format_chat_timestamp(m[:timestamp_ms])}] #{m[:sender]}: #{m[:message]}" }
        sections << "CHAT MESSAGES:\n#{chat_lines.join("\n")}"
      end
      combined_text = sections.join("\n\n")

      return nil if combined_text.empty?

      logger.info("Preparing to generate summary for #{combined_text.length} characters")

      # Create LLM client
      begin
        llm_client = LLMClient::Base.create(logger, language: language)
      rescue StandardError => e
        raise "Failed to initialize LLM client: #{e.message}"
      end

      # Generate summary
      logger.info("Generating summary using LLM...")
      summary = llm_client.summarize(combined_text)

      # Return nil if disabled or empty response
      logger.warn("LLM returned nil or empty summary — skipping summary section") if summary.nil? || summary.strip.empty?
      return nil if summary.nil? || summary.strip.empty?

      # Save summary to file
      summary_file = "#{target_dir}/summary.txt"
      File.write(summary_file, summary.strip)

      logger.info("Generated summary: #{summary.length} characters, saved to summary.txt")
      summary.strip
    rescue StandardError => e
      logger.error("Summary generation failed: #{e.message}")
      nil
    end
  end

  class ActionItemsExtractor
    def self.extract(summary, transcript, target_dir, logger, polls: nil, language: nil, chat: nil)
      # Build input for LLM
      sections = []
      sections << "MEETING SUMMARY:\n#{summary}" if summary && !summary.empty?
      sections << "TRANSCRIPT:\n#{transcript}" if transcript && !transcript.empty?
      polls_text = SummaryExtractor.polls_to_text(polls)
      sections << "POLL RESULTS:\n#{polls_text}" if polls_text
      if chat && !chat.empty?
        chat_lines = chat.map { |m| "[#{SummaryExtractor.format_chat_timestamp(m[:timestamp_ms])}] #{m[:sender]}: #{m[:message]}" }
        sections << "CHAT MESSAGES:\n#{chat_lines.join("\n")}"
      end
      combined_text = sections.join("\n\n")

      # Return empty array if no content
      return [] if combined_text.empty?

      logger.info("Extracting action items from #{combined_text.length} characters")

      # Create LLM client
      begin
        llm_client = LLMClient::Base.create(logger, language: language)
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
        logger.warn("LLM returned nil or empty response for action items — skipping") if response.nil? || response.strip.empty?
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

  class ChatExtractor
    # Event names used across different BBB versions for public chat messages
    CHAT_EVENT_NAMES = %w[GroupChatMessageBroadcastEvent PublicChatEvent].freeze

    def self.extract(events_doc, recording_start_ms, logger)
      # Build userId → display name map
      user_names = {}
      events_doc.xpath("//event[@eventname='ParticipantJoinEvent']").each do |event|
        user_id = event.at_xpath('userId')&.text.to_s.strip
        name    = event.at_xpath('name')&.text.to_s.strip
        user_names[user_id] = name unless user_id.empty? || name.empty?
      end

      messages = []

      CHAT_EVENT_NAMES.each do |event_name|
        events_doc.xpath("//event[@eventname='#{event_name}']").each do |event|
          sender_id     = event.at_xpath('senderId')&.text.to_s.strip
          timestamp_utc = event.at_xpath('timestampUTC')&.text.to_i
          raw_message   = event.at_xpath('message')&.text.to_s

          next if sender_id.empty? || timestamp_utc == 0

          plain_message = strip_html(raw_message).strip
          next if plain_message.empty?

          messages << {
            timestamp_ms: timestamp_utc - recording_start_ms,
            sender:       user_names[sender_id] || sender_id,
            message:      plain_message
          }
        end
      end

      # Deduplicate identical messages that may appear in both event types
      messages.uniq! { |m| [m[:sender], m[:message], m[:timestamp_ms]] }
      messages.sort_by! { |m| m[:timestamp_ms] }

      logger.info("Extracted #{messages.size} public chat message(s)")
      messages
    end

    private

    def self.strip_html(html)
      # Nokogiri decodes XML entities when reading .text, so raw_message may
      # contain literal HTML tags (e.g. "<p>hello</p>"). Strip them to plain text.
      html.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
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

# Convert a VTT timestamp string "HH:MM:SS.mmm" to milliseconds
def vtt_timestamp_to_ms(ts)
  return 0 if ts.nil? || ts.empty?
  parts = ts.split(':')
  return 0 unless parts.length == 3
  hours   = parts[0].to_i
  minutes = parts[1].to_i
  sec_ms  = parts[2].split('.')
  seconds = sec_ms[0].to_i
  millis  = (sec_ms[1] || '0').to_i
  (hours * 3_600_000) + (minutes * 60_000) + (seconds * 1_000) + millis
end

# Helper method to render markdown using ERB template
def render_markdown_into_template(template_path, data)
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

# Read LLM config directly for feature flags (LLMClient::Base raises outside production)
BBB_CORE_DIR = '/usr/local/bigbluebutton/core'.freeze
llm_config_path = "#{BBB_CORE_DIR}/lib/ai-summary/llm.yml"
llm_config = File.exist?(llm_config_path) ? YAML.safe_load(File.read(llm_config_path)) : {}
include_chat_in_discussion = llm_config.fetch('include_chat_in_discussion', false)

# Set up paths
recording_dir = props['recording_dir']
raw_archive_dir = "#{recording_dir}/raw/#{meeting_id}"
log_dir = props['log_dir']
shared_notes_pdf_file = "#{raw_archive_dir}/notes/notes.pdf"
target_dir = "#{recording_dir}/process/ai-summary/#{meeting_id}"
playback_dir = format_props['playback_dir']


# Main processing logic
unless FileTest.directory?(target_dir)
  FileUtils.mkdir_p "#{log_dir}/ai-summary"
  logger = Logger.new("#{log_dir}/ai-summary/process-#{meeting_id}.log", 'daily')
  BigBlueButton.logger = logger
  BigBlueButton.logger.info("Processing script ai-summary.rb")
  FileUtils.mkdir_p target_dir

  begin
    # Copy notes file if present
    if File.exist?(shared_notes_pdf_file)
      FileUtils.cp(shared_notes_pdf_file, "#{target_dir}/ai-summary.pdf")
    else
      BigBlueButton.logger.info("No notes file found for #{meeting_id}, continuing without it")
    end

    # Load events.xml for metadata and extraction
    events_doc = Nokogiri::XML(File.open("#{raw_archive_dir}/events.xml"))

    # Initialize notes extractor and extract content
    notes_extractor = Extractors::NotesExtractor.new
    notes_content = notes_extractor.extract(raw_archive_dir, method(:html_to_plain_text), BigBlueButton.logger)
    notes_plain_text = notes_content&.fetch(:plain_text)
    notes_html_content = notes_content&.fetch(:html)
    word_count = notes_extractor.word_count

    # Extract all other data using extractors
    attendees = Extractors::AttendeesExtractor.extract(events_doc, BigBlueButton.logger)

    transcript = Extractors::TranscriptExtractor.extract(raw_archive_dir, target_dir, BigBlueButton.logger, events_doc, format_props)

    polls = Extractors::PollsExtractor.extract(events_doc, BigBlueButton.logger)

    # Handle transcript format (can be string or hash with plain/diarized)
    transcript_plain    = transcript.is_a?(Hash) ? transcript[:plain]    : transcript
    transcript_diarized = transcript.is_a?(Hash) ? transcript[:diarized] : nil
    transcript_language = transcript.is_a?(Hash) ? transcript[:language] : nil

    transcript_cues = WebVTTParser.parse(transcript_diarized)

    # Determine recording start time for chat relative timestamps
    recording_start_ms = transcript.is_a?(Hash) ? transcript[:recording_start] : nil
    recording_start_ms ||= Extractors::TranscriptExtractor.extract_recording_start_time(
      events_doc, BigBlueButton.logger
    )

    # Extract public chat messages
    chat_messages = if recording_start_ms
      Extractors::ChatExtractor.extract(events_doc, recording_start_ms, BigBlueButton.logger)
    else
      BigBlueButton.logger.warn("Skipping chat extraction: could not determine recording_start_ms")
      []
    end

    summary = Extractors::SummaryExtractor.extract(
      notes_plain_text, transcript_plain, target_dir, BigBlueButton.logger,
      polls: polls, language: transcript_language, chat: chat_messages
    )

    # Extract action items using LLM
    action_items = Extractors::ActionItemsExtractor.extract(
      summary, transcript_plain, target_dir, BigBlueButton.logger,
      polls: polls, language: transcript_language, chat: chat_messages
    )

    # Build merged discussion timeline (transcript cues + chat messages) sorted by time
    discussion_timeline = []
    if include_chat_in_discussion
      transcript_cues.each do |cue|
        discussion_timeline << {
          type:         :transcript,
          timestamp_ms: vtt_timestamp_to_ms(cue[:start]),
          display_time: cue[:start],
          start:        cue[:start],
          end:          cue[:end],
          speaker:      cue[:speaker],
          text:         cue[:text]
        }
      end

      chat_messages.each do |msg|
        ms = [msg[:timestamp_ms], 0].max
        total_s = ms / 1000
        h = total_s / 3600; m = (total_s % 3600) / 60; s = total_s % 60
        display = format('%02d:%02d:%02d.%03d', h, m, s, ms % 1000)
        discussion_timeline << {
          type:         :chat,
          timestamp_ms: msg[:timestamp_ms],
          display_time: display,
          sender:       msg[:sender],
          message:      msg[:message]
        }
      end

      discussion_timeline.sort_by! { |item| item[:timestamp_ms] }
      BigBlueButton.logger.info(
        "Built discussion timeline: #{discussion_timeline.size} items " \
        "(#{transcript_cues.size} transcript cues + #{chat_messages.size} chat messages)"
      )
    end

    # Collect all data for markdown template
    md_template_data = {
      notes_content: notes_plain_text,
      word_count: word_count,
      attendees: attendees,
      transcript: transcript_plain,
      transcript_diarized: transcript_cues,
      polls: polls,
      summary: summary,
      discussion_timeline: discussion_timeline
    }

    # Render markdown from ERB template
    BigBlueButton.logger.info("Rendering ai-summary.md from template")
    template_path = "#{playback_dir}/ai-summary.md.erb"
    notes_md_content = render_markdown_into_template(template_path, md_template_data)
    File.write("#{target_dir}/ai-summary.md", notes_md_content)
    BigBlueButton.logger.info("Created ai-summary.md with #{word_count} words and #{attendees.length} attendees")

    # Generate HTML report
    BigBlueButton.logger.info("Rendering ai-summary.html from template")

    # Use the pre-extracted HTML notes content directly
    notes_html = notes_html_content

    # Convert summary markdown to HTML for structured rendering
    summary_html = summary && !summary.empty? ? MarkdownConverter.convert(summary) : nil

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
      polls: polls,
      summary: summary,
      summary_html: summary_html,
      action_items: action_items,
      discussion_timeline: discussion_timeline,
      footer: "Generated by BigBlueButton Notes processor. Optimized for print and dark/light mode."
    }

    # Render HTML
    html_template_path = "#{playback_dir}/ai-summary.html.erb"
    html_content = render_html_template(html_template_path, html_data)
    File.write("#{target_dir}/ai-summary.html", html_content)
    BigBlueButton.logger.info("Created ai-summary.html with #{attendees.length} attendees and #{transcript_cues.length} transcript cues")

    # Render BlockNote-compatible JSON document - Should look like the generated markdown
    BigBlueButton.logger.info("Rendering ai-summary.json from template")
    json_template_path = "#{playback_dir}/ai-summary.json.erb"
    json_content = render_markdown_into_template(json_template_path, md_template_data)
    File.write("#{target_dir}/ai-summary.json", json_content)
    BigBlueButton.logger.info("Created ai-summary.json")

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
