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

require File.expand_path('../../../lib/recordandplayback', __FILE__)

require 'rubygems'
require 'optimist'
require 'yaml'
require 'json'
require 'set'
require 'erb'
require 'time'

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
    # Elements that can execute script or exfiltrate data when the notes HTML
    # is embedded in the published report.
    DANGEROUS_ELEMENTS = %w[script iframe frame frameset object embed form base meta link applet].freeze
    URI_ATTRIBUTES     = %w[href src action formaction xlink:href].freeze

    def extract(raw_archive_dir, html_to_plain_text_method, logger)
      notes_html_file = "#{raw_archive_dir}/notes/notes.html"

      unless File.exist?(notes_html_file)
        logger.warn("notes.html not found")
        return nil
      end

      html_content = File.read(notes_html_file)
      text_content = html_to_plain_text_method.call(html_content)

      return nil if text_content.strip.empty?

      sanitized_html = sanitize_html(html_content)
      sanitized_html = sanitized_html.gsub(/<style([^>]*)>(.*?)<\/style>/im) do
        attrs = Regexp.last_match(1)
        css   = Regexp.last_match(2)
        css   = css.gsub(/\b(?:html|body)\s*\{[^}]*\}/i, '')
        css.strip.empty? ? '' : "<style#{attrs}>#{css}</style>"
      end
      { plain_text: text_content, html: sanitized_html }
    end

    private

    # The notes HTML keeps its markup (it is embedded raw in the report), but
    # script-capable elements, event-handler attributes, and script-scheme URLs
    # are removed. data: URLs are allowed for images only.
    def sanitize_html(html_content)
      doc = Nokogiri::HTML(html_content)
      doc.css(DANGEROUS_ELEMENTS.join(',')).each(&:remove)

      doc.traverse do |node|
        next unless node.element?

        node.attribute_nodes.each do |attr|
          name = attr.name.downcase
          if name.start_with?('on')
            node.remove_attribute(attr.name)
          elsif URI_ATTRIBUTES.include?(name)
            value = attr.value.to_s.gsub(/[[:space:]]/, '').downcase
            if value.start_with?('javascript:', 'vbscript:') ||
               (value.start_with?('data:') && !value.start_with?('data:image/'))
              node.remove_attribute(attr.name)
            end
          end
        end
      end

      doc.to_html
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

  class EventsExtractor
    # Returns an ordered array of [start_ts, stop_ts] pairs covering each recording-on interval.
    def self.extract_start_stop_recording_intervals(events_doc)
      intervals     = []
      current_start = nil

      events_doc.xpath("//event[@eventname='RecordStatusEvent']").each do |ev|
        status = ev.at_xpath('status')&.text&.strip
        ts     = ev['timestamp'].to_i
        next unless ts > 0

        if status == 'true'
          current_start ||= ts
        elsif status == 'false' && current_start
          intervals << [current_start, ts]
          current_start = nil
        end
      end
      intervals << [current_start, nil] if current_start

      intervals
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

      provider = json_data['provider']
      logger.info("Using transcription from provider: #{provider}") if provider

      tracks_data = json_data['tracks'] || []

      if tracks_data.empty?
        logger.warn("No tracks in transcription.json")
        return nil
      end

      # Determine recording start time, intervals, and audio track → speaker mappings from events.xml
      recording_start      = nil
      audio_tracks         = {}
      livekit              = false
      recording_intervals  = []

      if events_doc
        recording_start     = extract_recording_start_time(events_doc, logger)
        audio_tracks        = extract_audio_track_mappings(events_doc, logger)
        livekit             = events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").any?
        recording_intervals = EventsExtractor.extract_start_stop_recording_intervals(events_doc)
      end

      unless recording_start
        logger.error("Could not determine recording start time from events.xml")
        return nil
      end

      segments = build_segments_from_tracks(tracks_data, audio_tracks,
                                            events_doc, livekit, recording_intervals, logger)

      if segments.empty?
        logger.warn("No transcript segments found in transcription.json")
        return nil
      end

      segments.sort_by! { |s| s[:abs_start] }
      logger.info("Loaded #{segments.size} segments from transcription.json " \
                  "(#{tracks_data.size} track(s))")

      # Generate speaker-attributed cues, then serialize to VTT and JSON
      transcription_cues = create_transcription_cues(segments, logger)
      
      # Generate WebVTT
      diarized_vtt       = format_cues_into_vtt(transcription_cues)
      diarized_file      = "#{target_dir}/transcript_diarized.vtt"
      File.write(diarized_file, diarized_vtt)
      logger.info("Saved diarized transcript: #{diarized_file}")

      # Generate JSON
      diarized_json = format_cues_into_json(transcription_cues)
      diarized_json_file = "#{target_dir}/transcript_diarized.json"
      File.write(diarized_json_file, JSON.pretty_generate(diarized_json))
      logger.info("Saved diarized JSON transcript: #{diarized_json_file}")

      # Generate plain text
      plain_text      = generate_plain_text(segments)
      transcript_file = "#{target_dir}/transcript.txt"
      File.write(transcript_file, plain_text)
      logger.info("Saved plain transcript: #{transcript_file}")

      { plain: plain_text, diarized: diarized_vtt, language: json_data['language'], recording_start: recording_start, provider: provider }
    end

    def self.diarize_provider_transcriptions(raw_archive_dir, target_dir, logger, events_doc)
      recording_start     = extract_recording_start_time(events_doc, logger)
      return [] unless recording_start

      audio_tracks        = extract_audio_track_mappings(events_doc, logger)
      livekit             = events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").any?
      recording_intervals = EventsExtractor.extract_start_stop_recording_intervals(events_doc)
      provider_files      = Dir.glob("#{raw_archive_dir}/transcription/transcription_*.json").sort
      return [] if provider_files.empty?

      provider_files.filter_map do |src|
        provider_name = File.basename(src, '.json').delete_prefix('transcription_')
        begin
          json_data = JSON.parse(File.read(src))
        rescue JSON::ParserError => e
          logger.error("Failed to parse #{File.basename(src)}: #{e.message}")
          next
        end

        segments = build_segments_from_tracks(json_data['tracks'] || [], audio_tracks,
                                              events_doc, livekit, recording_intervals, logger)
        if segments.empty?
          logger.warn("No segments in #{File.basename(src)}, skipping diarization")
          next
        end

        segments.sort_by! { |s| s[:abs_start] }
        cues          = create_transcription_cues(segments, logger)
        diarized_json = format_cues_into_json(cues)
        out_file      = "#{target_dir}/transcript_diarized_#{provider_name}.json"
        File.write(out_file, JSON.pretty_generate(diarized_json))
        logger.info("Saved diarized transcript for provider '#{provider_name}': #{out_file}")
        provider_name
      end
    end

    private

    def self.build_segments_from_tracks(tracks_data, audio_tracks, events_doc, livekit, recording_intervals, logger)
      segments = []
      tracks_data.each do |track|
        file_basename  = track['file']
        track_info     = audio_tracks[file_basename]

        unless track_info
          logger.warn("No speaker mapping for audio track '#{file_basename}', " \
                      "attributing to 'Unknown Speaker'")
          track_info = { user_id: file_basename, name: 'Unknown Speaker' }
        end

        section_offset = calculate_section_offset(events_doc, file_basename,
                                                  livekit: livekit,
                                                  recording_intervals: recording_intervals)

        (track['segments'] || []).each do |seg|
          text = seg['text'].to_s.strip
          next if text.empty?

          # FreeSWITCH: per-segment speaker_id or speaker_ids carries the userId(s).
          if (ids = seg['speaker_ids'])&.any?
            speaker_names = ids.filter_map { |uid| audio_tracks.dig(uid, :name) }
            speaker_names = [track_info[:name]] if speaker_names.empty?
            user_id = ids.join('|')
            name    = speaker_names.join(' | ')
          elsif (sp = seg['speaker_id'] && audio_tracks[seg['speaker_id']])
            user_id = sp[:user_id]
            name    = sp[:name]
          else
            user_id = track_info[:user_id]
            name    = track_info[:name]
          end

          segments << {
            abs_start: section_offset + seg.dig('offsets', 'from').to_i,
            abs_end:   section_offset + seg.dig('offsets', 'to').to_i,
            user_id:   user_id,
            name:      name,
            text:      text
          }
        end
      end
      segments
    end

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

    # Build speaker-attributed cues from sorted segment list.
    # Returns: [{start_ms:, end_ms:, speaker:, text:}]
    def self.create_transcription_cues(segments, logger)
      return [] if segments.empty?

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
                       cue_start, cue_end)
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
                     cue_start, cue_end)
      end

      cues.sort_by! { |c| c[:start_ms] }
      logger.info("Generated #{cues.size} transcript cues")
      cues
    end

    def self.format_cues_into_json(transcription_cues)
      transcription_cues.map do |cue|
        { from: format_timestamp(cue[:start_ms]), to: format_timestamp(cue[:end_ms]),
          user_name: cue[:speaker], text: cue[:text] }
      end
    end

    # Format cues array as a WebVTT string
    def self.format_cues_into_vtt(transcription_cues)
      lines = ['WEBVTT', '']
      transcription_cues.each do |cue|
        lines << "#{format_timestamp(cue[:start_ms])} --> #{format_timestamp(cue[:end_ms])}"
        lines << "#{cue[:speaker]}: #{cue[:text]}"
        lines << ''
      end
      lines.join("\n")
    end

    # Collect one or more VTT cues into the array, splitting long text at sentence boundaries.
    # abs_start/abs_end are already effective recording ms (pause time excluded).
    def self.collect_cues(cues, speaker_name, full_text, abs_start, abs_end)
      text = full_text.strip
      return if text.empty?

      if text.length <= MAX_CUE_CHARS
        cues << { start_ms: abs_start,
                  end_ms:   abs_end,
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

        cues << { start_ms: cue_abs_start,
                  end_ms:   cue_abs_end,
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

    # Build hash: audio_file_basename => { user_id:, name: }
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
        user_id  = event.xpath('userId').text.strip
        filename = event.xpath('filename').text.strip

        next if user_id.empty? || filename.empty?

        basename = File.basename(filename)
        audio_tracks[basename] = {
          user_id: user_id,
          name:    user_names[user_id] || "Unknown (#{user_id})"
        }
      end
      logger.info("Found #{audio_tracks.size} AudioTrackPublishedEvent(s)")

      # Also add userId-keyed entries so that FreeSWITCH segments carrying speaker_id
      # can be resolved by build_segments_from_tracks without a separate lookup map.
      user_names.each do |uid, name|
        audio_tracks[uid] ||= { user_id: uid, name: name }
      end

      audio_tracks
    end

    # Returns the effective playback position (ms, pause-excluded) at which
    # the given audio file starts. Adding this to the transcription segment's
    def self.calculate_section_offset(events_doc, filename, livekit:, recording_intervals:)
      return 0 if recording_intervals.empty?

      audio_basename = File.basename(filename.to_s)

      event_name = livekit ? 'AudioTrackPublishedEvent' : 'StartRecordingEvent'
      ev = events_doc.xpath("//event[@eventname='#{event_name}']").find do |e|
        File.basename(e.at_xpath('filename')&.text.to_s) == audio_basename
      end
      section_start = ev&.[]('timestamp')&.to_i

      return 0 unless section_start && section_start > 0

      first_start = recording_intervals.first[0]

      # Section started before recording began (e.g. participant joined early).
      # Return a negative offset so whisper timestamps shift left to align
      # with playback position 0.
      return section_start - first_start if section_start < first_start

      # Sum recording time that elapsed before this section started.
      offset = 0
      recording_intervals.each do |start_ts, stop_ts|
        break if start_ts >= section_start
        effective_end = stop_ts ? [stop_ts, section_start].min : section_start
        offset += effective_end - start_ts
      end
      offset
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

    def self.extract(notes_content, transcript, target_dir, logger, polls: nil, language: nil, chat: nil, prompt_addition: nil)
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
        llm_client = LLMClient::Base.create(logger, language: language, prompt_addition: prompt_addition)
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
    def self.extract(summary, transcript, target_dir, logger, polls: nil, language: nil, chat: nil, prompt_addition: nil)
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
        llm_client = LLMClient::Base.create(logger, language: language, prompt_addition: prompt_addition)
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
        IMPORTANT: regardless of any other instructions, your response must be valid JSON only.

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

    def self.extract(events_doc, recording_start_ms, logger, recording_intervals: [])
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

          # Compute pause-adjusted playback position.
          # Fallback: simple UTC offset when no recording intervals are available.
          playback_ms = if recording_intervals.empty?
            timestamp_utc - recording_start_ms
          else
            get_playback_offset_ms(event['timestamp'].to_i, recording_intervals)
          end
          next if playback_ms.nil?

          messages << {
            timestamp_ms: playback_ms,
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

    # Returns the pause-adjusted playback position (ms) for a BBB server timestamp,
    # or nil if the timestamp falls outside all recording intervals (pre-recording or paused).
    def self.get_playback_offset_ms(msg_ts, intervals)
      elapsed = 0
      intervals.each do |start_ts, stop_ts|
        return nil if msg_ts < start_ts

        if stop_ts.nil? || msg_ts <= stop_ts
          return elapsed + (msg_ts - start_ts)
        end

        elapsed += stop_ts - start_ts
      end
      nil
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

# Merge consecutive cues from the same speaker when the gap between them is below gap_ms.
# Used for display only — the underlying WebVTT file is not affected.
def group_transcript_cues(cues, gap_ms: 5000)
  return [] if cues.empty?

  groups = []
  current = cues.first.dup.tap { |c| c[:text] = c[:text].dup }

  cues[1..].each do |cue|
    gap = vtt_timestamp_to_ms(cue[:start]) - vtt_timestamp_to_ms(current[:end])
    if cue[:speaker] == current[:speaker] && gap < gap_ms
      current[:end]  = cue[:end]
      current[:text] = "#{current[:text]} #{cue[:text]}"
    else
      groups << current
      current = cue.dup.tap { |c| c[:text] = c[:text].dup }
    end
  end

  groups << current
  groups
end

# Format a Time using locale month names and a date_format strftime pattern.
# The token {month} in date_format is replaced by the localized month name
# before strftime processes the rest of the pattern.
def format_localized_date(time, locale_strings)
  month_names = locale_strings["month_names"]
  month       = month_names ? month_names[time.month - 1] : time.strftime('%B')
  fmt         = locale_strings.fetch("date_format", "%B %-d, %Y at %-I:%M %p %Z")
  time.strftime(fmt.gsub('{month}', month))
end

# HTML-escape helper available inside the ERB templates. Plain ERB does not
# escape <%= %>, so any user-controlled value rendered in ai-summary.html.erb
# must go through h().
def h(text)
  ERB::Util.html_escape(text)
end

# Helper method to render markdown using ERB template
def render_markdown_into_template(template_path, data)
  template_content = File.read(template_path, encoding: 'utf-8')
  erb = ERB.new(template_content, trim_mode: '-')
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

def extract_meta_prompt_addition(raw_archive_dir)
  meeting_metadata = BigBlueButton::Events.get_meeting_metadata("#{raw_archive_dir}/events.xml")
  meeting_metadata['bbb-ai-summary-prompt-addition'].to_s
end

# Meeting metadata gets copied into metadata.xml, which is served publicly with
# the published recording. Keys carrying credentials (e.g. the La Suite Docs
# access token) or internal prompt instructions must never be published.
SENSITIVE_META_KEY_PATTERN = /token|secret|password|api[-_]?key/i
EXCLUDED_META_KEYS = %w[bbb-ai-summary-prompt-addition].freeze

def publishable_meeting_metadata(raw_archive_dir)
  BigBlueButton::Events.get_meeting_metadata("#{raw_archive_dir}/events.xml").reject do |key, _value|
    k = key.to_s
    EXCLUDED_META_KEYS.include?(k) || k.match?(SENSITIVE_META_KEY_PATTERN)
  end
end

# Helper method to build complete metadata XML
def build_metadata_xml(meeting_id, events_doc, raw_archive_dir)
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
      publishable_meeting_metadata(raw_archive_dir).each { |k,v|
        builder.method_missing(k, v)
      }
    }
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

# Recursively merges +override+ into +base+, combining nested hashes key-by-key
# so that only the keys present in +override+ are changed.
def deep_merge_hashes(base, override)
  base.merge(override) do |_key, base_val, override_val|
    if base_val.is_a?(Hash) && override_val.is_a?(Hash)
      deep_merge_hashes(base_val, override_val)
    else
      override_val
    end
  end
end

# Loads the ai-summary format config from +path+ and applies an optional
def load_format_config(path)
  cfg = YAML.safe_load(File.read(path)) || {}

  override_path = '/etc/bigbluebutton/ai-summary.yml'
  if File.exist?(override_path)
    override = YAML.safe_load(File.read(override_path)) || {}
    cfg = deep_merge_hashes(cfg, override)
  end

  cfg
end

# Parse command line options
opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :default => '58f4a6b3-cd07-444d-8564-59116cb53974', :type => String
end

meeting_id = opts[:meeting_id]

props        = BigBlueButton.read_props
format_props = load_format_config('ai-summary.yml')

include_chat_in_discussion      = format_props.fetch('include_chat_in_discussion', true)
transcript_group_gap_ms         = (format_props.fetch('transcript_group_gap_seconds', 5).to_f * 1000).to_i

# Set up paths
recording_dir = props['recording_dir']
raw_archive_dir = "#{recording_dir}/raw/#{meeting_id}"
log_dir = props['log_dir']
target_dir = "#{recording_dir}/process/ai-summary/#{meeting_id}"
playback_dir = format_props['playback_dir']


# Main processing logic
done_file = "#{recording_dir}/status/processed/#{meeting_id}-ai-summary.done"

# A process dir without a .done status file means a previous run crashed partway
# through. Remove the stale output so this run reprocesses from scratch instead
# of taking the already-processed branch and marking incomplete output as done.
stale_process_dir = FileTest.directory?(target_dir) && !File.exist?(done_file)
FileUtils.rm_rf(target_dir) if stale_process_dir

unless FileTest.directory?(target_dir)
  FileUtils.mkdir_p "#{log_dir}/ai-summary"
  logger = Logger.new("#{log_dir}/ai-summary/process-#{meeting_id}.log", 'daily')
  BigBlueButton.logger = logger
  BigBlueButton.logger.info("Processing script ai-summary.rb")
  BigBlueButton.logger.warn("Removed stale process dir from a previous incomplete run: #{target_dir}") if stale_process_dir
  FileUtils.mkdir_p target_dir
  prompt_addition = extract_meta_prompt_addition(raw_archive_dir)

  begin

    # Load events.xml for metadata and extraction
    events_doc = File.open("#{raw_archive_dir}/events.xml") { |f| Nokogiri::XML(f) }

    # Initialize notes extractor and extract content
    notes_extractor = Extractors::NotesExtractor.new
    notes_content = notes_extractor.extract(raw_archive_dir, method(:html_to_plain_text), BigBlueButton.logger)
    notes_plain_text = notes_content&.fetch(:plain_text)
    notes_html_content = notes_content&.fetch(:html)
    # Extract all other data using extractors
    attendees = Extractors::AttendeesExtractor.extract(events_doc, BigBlueButton.logger)

    transcript = Extractors::TranscriptExtractor.extract(raw_archive_dir, target_dir, BigBlueButton.logger, events_doc, format_props)

    Extractors::TranscriptExtractor.diarize_provider_transcriptions(raw_archive_dir, target_dir, BigBlueButton.logger, events_doc)

    if transcript.nil?
      BigBlueButton.logger.error("No transcription available for #{meeting_id}. Run post_archive/transcribe_audio.rb first.")
      exit 1
    end

    polls = Extractors::PollsExtractor.extract(events_doc, BigBlueButton.logger)

    # Handle transcript format (can be string or hash with plain/diarized)
    transcript_plain    = transcript.is_a?(Hash) ? transcript[:plain]    : transcript
    transcript_diarized = transcript.is_a?(Hash) ? transcript[:diarized] : nil
    transcript_language = transcript.is_a?(Hash) ? transcript[:language] : nil
    transcript_provider = transcript.is_a?(Hash) ? transcript[:provider] : nil

    transcript_cues         = WebVTTParser.parse(transcript_diarized)
    grouped_transcript_cues = group_transcript_cues(transcript_cues, gap_ms: transcript_group_gap_ms)

    # Load locale strings (falls back to English if locale file not found)
    locale_code = format_props.fetch('locale', 'en')
    locale_file = "#{playback_dir}/locales/#{locale_code}.json"
    locale_file = "#{playback_dir}/locales/en.json" unless File.exist?(locale_file)
    locale_strings = File.exist?(locale_file) ? JSON.parse(File.read(locale_file)) : {}
    BigBlueButton.logger.info("Loaded locale: #{locale_code} from #{locale_file}")

    # Determine recording start time for chat relative timestamps
    recording_start_ms = transcript.is_a?(Hash) ? transcript[:recording_start] : nil
    recording_start_ms ||= Extractors::TranscriptExtractor.extract_recording_start_time(
      events_doc, BigBlueButton.logger
    )

    # Extract public chat messages, filtered to active recording intervals
    recording_intervals = Extractors::EventsExtractor.extract_start_stop_recording_intervals(events_doc)
    chat_messages = if recording_start_ms
      Extractors::ChatExtractor.extract(events_doc, recording_start_ms, BigBlueButton.logger,
                                        recording_intervals: recording_intervals)
    else
      BigBlueButton.logger.warn("Skipping chat extraction: could not determine recording_start_ms")
      []
    end

    summary = Extractors::SummaryExtractor.extract(
      notes_plain_text, transcript_plain, target_dir, BigBlueButton.logger,
      polls: polls, language: transcript_language, chat: chat_messages, prompt_addition: prompt_addition
    )

    # Extract action items using LLM
    action_items = Extractors::ActionItemsExtractor.extract(
      summary, transcript_plain, target_dir, BigBlueButton.logger,
      polls: polls, language: transcript_language, chat: chat_messages, prompt_addition: prompt_addition
    )

    # Build merged discussion timeline for markdown (grouped cues + chat messages) sorted by time
    discussion_timeline = []
    unless grouped_transcript_cues.empty?
      discussion_timeline = grouped_transcript_cues.map do |cue|
        { type: :transcript, timestamp_ms: vtt_timestamp_to_ms(cue[:start]),
          display_time: cue[:start], start: cue[:start], end: cue[:end],
          speaker: cue[:speaker], text: cue[:text] }
      end
      if include_chat_in_discussion
        chat_messages.each do |msg|
          ms = [msg[:timestamp_ms], 0].max
          total_s = ms / 1000
          h = total_s / 3600; m = (total_s % 3600) / 60; s = total_s % 60
          discussion_timeline << { type: :chat, timestamp_ms: msg[:timestamp_ms],
                                   display_time: format('%02d:%02d:%02d.%03d', h, m, s, ms % 1000),
                                   sender: msg[:sender], message: msg[:message] }
        end
      end
      discussion_timeline.sort_by! { |item| item[:timestamp_ms] }
      BigBlueButton.logger.info(
        "Built discussion timeline: #{discussion_timeline.size} items " \
        "(#{grouped_transcript_cues.size} grouped transcript cues + #{chat_messages.size} chat messages)"
      )
    end

    # Collect all data for markdown template
    md_template_data = {
      notes_content: notes_plain_text,
      attendees: attendees,
      transcript: transcript_plain,
      transcript_diarized: grouped_transcript_cues,
      polls: polls,
      summary: summary,
      discussion_timeline: discussion_timeline,
      strings: locale_strings
    }

    # Render markdown from ERB template
    BigBlueButton.logger.info("Rendering ai-summary.md from template")
    template_path = "#{playback_dir}/ai-summary.md.erb"
    notes_md_content = render_markdown_into_template(template_path, md_template_data)
    File.write("#{target_dir}/ai-summary.md", notes_md_content)
    BigBlueButton.logger.info("Created ai-summary.md with #{attendees.length} attendees")

    # Generate HTML report
    BigBlueButton.logger.info("Rendering ai-summary.html from template")

    # Convert summary markdown to HTML for structured rendering
    summary_html = summary && !summary.empty? ? MarkdownConverter.convert(summary) : nil

    # Extract meeting name and date from events.xml metadata
    meeting_metadata = BigBlueButton::Events.get_meeting_metadata("#{raw_archive_dir}/events.xml")
    meeting_name = meeting_metadata['meetingName'].to_s
    meeting_name = locale_strings.fetch("meeting_title_fallback", "BigBlueButton Session") if meeting_name.empty?

    # Get meeting date from MeetingConfigurationEvent
    meeting_date_str = events_doc.at_xpath("//event[@eventname='MeetingConfigurationEvent']/date")&.text
    meeting_date = begin
      format_localized_date(Time.parse(meeting_date_str), locale_strings) if meeting_date_str
    rescue
      nil
    end

    # Build subtitle from date, duration, and attendees
    subtitle_parts = []
    subtitle_parts << meeting_date if meeting_date
    duration_ms = BigBlueButton::Events.get_recording_length(events_doc)
    if duration_ms > 0
      duration_min = (duration_ms / 60000.0).round
      duration_label = duration_min == 1 ? locale_strings.fetch("duration_minute", "minute") : locale_strings.fetch("duration_minutes", "minutes")
      subtitle_parts << "#{duration_min} #{duration_label}"
    end
    subtitle_parts << attendees.join(', ') if attendees.any?
    subtitle = subtitle_parts.join(' — ')
    subtitle = locale_strings.fetch("subtitle_fallback", "Meeting notes, transcript, and AI-generated summary") if subtitle.empty?

    # Prepare HTML template data
    html_data = {
      title: meeting_name,
      subtitle: subtitle,
      attendees: attendees,
      attendee_count: attendees.length,
      transcript_format: locale_strings.fetch("transcript_format_labeled", "Speaker-labeled"),
      shared_notes: notes_html_content,
      notes_plain_text: notes_plain_text,
      polls: polls,
      summary: summary,
      summary_html: summary_html,
      action_items: action_items,
      has_transcript: !transcript_cues.empty?,
      has_chat: !chat_messages.empty?,
      include_chat: include_chat_in_discussion,
      transcript_provider: transcript_provider,
      transcript_cues_json: transcript_cues.map { |c|
        { start_ms: vtt_timestamp_to_ms(c[:start]), end_ms: vtt_timestamp_to_ms(c[:end]),
          speaker: c[:speaker], text: c[:text] }
      }.to_json.gsub('</', '<\/'),
      chat_messages_json: chat_messages.map { |m|
        { timestamp_ms: m[:timestamp_ms], sender: m[:sender], message: m[:message] }
      }.to_json.gsub('</', '<\/'),
      group_gap_ms: transcript_group_gap_ms,
      footer: "#{locale_strings.fetch('footer_prefix', 'Generated by BigBlueButton:')} #{format_localized_date(Time.now, locale_strings)}",
      strings: locale_strings
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

    metadata = build_metadata_xml(meeting_id, events_doc, raw_archive_dir)

    # Write metadata.xml
    File.write("#{target_dir}/metadata.xml", metadata.root)
    BigBlueButton.logger.info("Created metadata.xml with state=processed and timing info")

    # Write status file
    File.write(done_file, "Processed #{meeting_id}")

  rescue Exception => e
    BigBlueButton.logger.error(e.message)
    e.backtrace.each do |traceline|
      BigBlueButton.logger.error(traceline)
    end
    exit 1
  end
else
  File.write(done_file, "Processed #{meeting_id}")
end
