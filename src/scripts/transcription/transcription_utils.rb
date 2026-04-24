#!/usr/bin/env ruby
# encoding: UTF-8
#
# transcription_utils.rb — Shared audio chunking utilities for transcription providers.
#
# Splits a BBB audio file into per-speech chunks using talking cues from events.xml,
# so each provider (albert_whisper, openai_whisper, …) can process them independently.
# Optionally filters silent chunks via Voice Activity Detection (VAD) before returning.
#
# Two audio backends are supported, selected via the livekit: parameter:
#
#   livekit: true  (default) — SFU / bbb-webrtc-sfu / LiveKit
#     One OGG file per participant. Talking cues derived from AudioTrackPublishedEvent
#     and ParticipantTalkingEvent. Floor fallback uses AudioTrackPublished/Unpublished.
#
#   livekit: false — FreeSWITCH (legacy single mixed file)
#     One WAV/Opus file for the whole room. Talking cues derived from all
#     ParticipantTalkingEvent entries within the StartRecordingEvent/StopRecordingEvent
#     window. Floor fallback uses the full recording interval.
#
# Usage:
#   require_relative 'transcription_utils'
#
#   result = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml,
#              livekit: true,
#              vad: { enabled: true, threshold: 0.05 })
#   # result is nil on audio conversion failure
#   # result[:chunks] is empty when no speech cues are found
#
#   result[:chunks].each do |chunk|
#     # chunk[:path]    — path to the WAV file
#     # chunk[:from_ms] — start offset in the original audio (ms)
#     # chunk[:to_ms]   — end offset in the original audio (ms)
#     process(chunk)
#   end
#
#   TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
#

require 'nokogiri'
require 'securerandom'
require 'fileutils'

module TranscriptionUtils
  MERGE_GAP_MS = 2_000

  # ---------------------------------------------------------------------------
  # VAD constants
  # ---------------------------------------------------------------------------

  # VAD is only run on clips shorter than this (longer clips are assumed speech).
  VAD_MAX_DURATION_MS = 10_000
  # Minimum absolute speech duration (ms) required for a clip to pass VAD.
  # The adaptive threshold is VAD_MIN_SPEECH_MS / clip_duration_ms, floored at
  # the configured speech_threshold. Keeps short clips from passing on just a
  # few noise frames while avoiding an overly strict threshold on longer clips.
  VAD_MIN_SPEECH_MS   = 150
  VAD_NODE_PATH       = `npm root -g 2>/dev/null`.strip.freeze

  # Inline Node.js script that runs node-vad on a 16 kHz mono WAV file and
  # prints the fraction of 30 ms frames classified as VOICE to stdout.
  # Requires: npm install -g node-vad
  VAD_INLINE_JS = <<~'JS'
    const VAD = require('node-vad');
    const fs  = require('fs');
    const SAMPLE_RATE = 16000, FRAME_BYTES = 960, WAV_HEADER = 44;
    async function run() {
      const pcm = fs.readFileSync(process.env.VAD_WAV).slice(WAV_HEADER);
      const vad = new VAD(VAD.Mode.VERY_AGGRESSIVE);
      let total = 0, speech = 0;
      for (let i = 0; i + FRAME_BYTES <= pcm.length; i += FRAME_BYTES) {
        const event = await vad.processAudio(pcm.slice(i, i + FRAME_BYTES), SAMPLE_RATE);
        total++;
        if (event === VAD.Event.VOICE) speech++;
      }
      process.stdout.write((total > 0 ? speech / total : 0).toFixed(4) + '\n');
    }
    run().catch(e => { process.stderr.write(e.message + '\n'); process.exit(1); });
  JS

  # ---------------------------------------------------------------------------
  # Public methods
  # ---------------------------------------------------------------------------

  # Returns audio duration in milliseconds via ffprobe, or nil on failure.
  def self.audio_duration_ms(path)
    out = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{path}" 2>/dev/null`.strip
    out.empty? ? nil : (out.to_f * 1000).round
  rescue
    nil
  end

  # Returns true if the WAV file at wav_path contains enough speech to be worth
  # transcribing, false otherwise.
  #
  # Options:
  #   enabled:        (Bool)  — when false, always returns true (VAD disabled)
  #   threshold:      (Float) — minimum speech-frame ratio (0.0–1.0); default 0.05
  #   min_speech_ms:  (Int)   — minimum absolute speech duration in ms; default VAD_MIN_SPEECH_MS
  #   max_duration_ms:(Int)   — clips longer than this skip VAD and pass through; default VAD_MAX_DURATION_MS
  #   force:          (Bool)  — run VAD even when enabled is false (used for hallucination re-checks)
  def self.has_speech?(wav_path, enabled:, threshold: 0.05,
                       min_speech_ms: VAD_MIN_SPEECH_MS, max_duration_ms: VAD_MAX_DURATION_MS,
                       force: false)
    return true unless enabled || force

    duration_ms = audio_duration_ms(wav_path).to_i
    return true if !force && duration_ms > max_duration_ms

    # Adaptive threshold: for short clips a fixed percentage can mean only a few
    # milliseconds of speech (e.g. 5% of 600 ms = 30 ms — humanly impossible).
    # Derive the threshold from the minimum absolute speech duration, floored at
    # the configured base threshold so long clips aren't penalized.
    adaptive = if duration_ms > 0
      [[min_speech_ms.to_f / duration_ms, threshold].max, 0.80].min
    else
      threshold
    end

    env = { 'VAD_WAV' => wav_path }
    env['NODE_PATH'] = VAD_NODE_PATH unless VAD_NODE_PATH.empty?
    out = IO.popen(env, ['node', '-e', VAD_INLINE_JS], &:read)
    status = $?
    unless status.success?
      log_info "  → VAD: node failed (is node-vad installed globally?), passing through"
      return true
    end

    ratio = out.strip.to_f
    log_info "  → VAD: #{(ratio * 100).round(1)}% speech frames (threshold: #{(adaptive * 100).round(1)}%)"
    ratio >= adaptive
  rescue => e
    log_info "  → VAD error: #{e.message}, passing through"
    true
  end

  # Converts audio to 16 kHz mono WAV required by whisper-based APIs.
  # Returns [path_to_use, temp_path_to_delete_later].
  # temp_path is nil when the original file is already a WAV or MP3.
  # Returns [nil, nil] on ffmpeg failure.
  def self.convert_to_wav(audio_file)
    ext = File.extname(audio_file).downcase.delete('.')
    return [audio_file, nil] if %w[mp3 wav].include?(ext)

    temp_wav = "/tmp/transcription_#{Process.pid}_#{SecureRandom.hex(6)}.wav"
    log_info "Converting #{ext} → WAV: #{File.basename(audio_file)}"
    ok = system(
      'ffmpeg', '-y', '-i', audio_file,
      '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
      temp_wav,
      [:out, :err] => '/dev/null'
    )
    unless ok && File.exist?(temp_wav)
      log_info "ERROR: ffmpeg conversion failed for #{File.basename(audio_file)}"
      return [nil, nil]
    end
    [temp_wav, temp_wav]
  end

  # Returns one cue covering the full recording interval for the given audio file.
  # Used as a fallback when no ParticipantTalkingEvents are present.
  #
  # livekit: true  — interval derived from AudioTrackPublished/Unpublished events.
  # livekit: false — interval derived from StartRecordingEvent/StopRecordingEvent.
  def self.extract_floor_cues(events_doc, audio_file, livekit: true)
    livekit ? extract_floor_cues_livekit(events_doc, audio_file)
            : extract_floor_cues_freeswitch(events_doc, audio_file)
  end

  # Merges cues whose inter-cue gap is smaller than gap_ms into a single cue.
  def self.merge_nearby_cues(cues, gap_ms)
    return [] if cues.empty?

    merged = [cues.first.dup]
    cues.each_cons(2) do |_prev, curr|
      gap = curr['from'] - merged.last['to']
      if gap <= gap_ms
        merged.last['to'] = curr['to']
      else
        merged << curr.dup
      end
    end
    merged
  end

  # Splits a flat array of (possibly overlapping) cues into non-overlapping segments.
  def self.resolve_overlapping_cues(cues)
    return cues if cues.size < 2

    events = []
    cues.each do |cue|
      events << [cue['from'], :start, cue]
      events << [cue['to'],   :end,   cue]
    end

    segments  = []
    active    = []
    prev_time = nil

    events.group_by { |e| e[0] }.sort_by { |t, _| t }.each do |time, grp|
      if prev_time && time > prev_time && active.any?
        seg = { 'from' => prev_time, 'to' => time }
        if active.size == 1
          c = active.first
          seg['speaker_id'] = c['speaker_id'] if c['speaker_id']
          seg['speaker']    = c['speaker']    if c['speaker']
        else
          seg['speaker_ids'] = active.map { |c| c['speaker_id'] }.compact.uniq
        end
        segments << seg
      end

      grp.sort_by { |e| e[1] == :end ? 0 : 1 }.each do |e|
        e[1] == :end ? active.reject! { |c| c.equal?(e[2]) } : active << e[2]
      end

      prev_time = time
    end

    segments
  end

  # Cuts a time slice from wav_path with ffmpeg into output_path.
  # Returns output_path on success, nil on failure.
  def self.cut_audio_chunk(wav_path, from_ms, to_ms, output_path)
    from_s     = (from_ms / 1000.0).to_s
    duration_s = ((to_ms - from_ms) / 1000.0).to_s
    ok = system(
      'ffmpeg', '-y',
      '-ss', from_s, '-t', duration_s,
      '-i', wav_path,
      '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
      output_path,
      [:out, :err] => '/dev/null'
    )
    ok && File.exist?(output_path) && File.size(output_path) > 0 ? output_path : nil
  end

  # Prepares all audio chunks for a given audio file and events.xml.
  #
  # Options:
  #   livekit:      (Bool or nil) — audio backend selection:
  #                                   true  = SFU/LiveKit (per-participant OGG files)
  #                                   false = FreeSWITCH (single mixed file)
  #                                   nil   = auto-detect from events.xml (default)
  #   merge_gap_ms: (Int)  — merge talking cues closer than this; default MERGE_GAP_MS
  #   vad:          (Hash) — VAD options applied to each chunk before it is returned:
  #                            enabled:         (Bool)  default false
  #                            threshold:       (Float) default 0.05
  #                            min_speech_ms:   (Int)   default VAD_MIN_SPEECH_MS
  #                            max_duration_ms: (Int)   default VAD_MAX_DURATION_MS
  #                          Chunks that fail VAD are deleted and excluded from the result.
  #
  # Returns a hash:
  #   {
  #     work_file:  String,   # path to the (possibly converted) WAV file
  #     temp_wav:   String,   # temp WAV to clean up later (nil if no conversion was needed)
  #     chunks_dir: String,   # temporary directory containing the chunk WAV files
  #     chunks:     Array     # [{path: String, from_ms: Integer, to_ms: Integer}, ...]
  #   }
  #
  # Returns nil if audio conversion fails.
  # Returns a result with chunks: [] if no speech cues are found (silent audio).
  def self.prepare_audio_chunks(audio_file, events_xml, livekit: nil, merge_gap_ms: MERGE_GAP_MS, vad: {})
    work_file, temp_wav = convert_to_wav(audio_file)
    return nil if work_file.nil?

    vad_enabled         = vad.fetch(:enabled, false)
    vad_threshold       = vad.fetch(:threshold, 0.05).to_f
    vad_min_speech_ms   = vad.fetch(:min_speech_ms, VAD_MIN_SPEECH_MS).to_i
    vad_max_duration_ms = vad.fetch(:max_duration_ms, VAD_MAX_DURATION_MS).to_i

    events_doc = Nokogiri::XML(File.read(events_xml))

    if livekit.nil?
      livekit = events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").any?
      log_info "Audio backend auto-detected: #{livekit ? 'livekit' : 'freeswitch'}"
    end

    if livekit
      raw_cues_livekit = extract_talking_cues_livekit(events_doc, audio_file)
      cues = merge_nearby_cues(raw_cues_livekit, merge_gap_ms)
      log_info "Talking cues: #{raw_cues_livekit.size} raw → #{cues.size} after merging (gap ≤ #{merge_gap_ms}ms)"
    else
      speaker_cues_freeswitch = extract_talking_cues_freeswitch(events_doc, audio_file)
      merged_cues = speaker_cues_freeswitch
                      .flat_map { |group| merge_nearby_cues(group, merge_gap_ms) }
                      .sort_by { |c| c['from'] }
      cues = resolve_overlapping_cues(merged_cues)
      log_info "Talking cues: #{speaker_cues_freeswitch.sum(&:size)} raw → #{merged_cues.size} merged → #{cues.size} after overlap resolution (gap ≤ #{merge_gap_ms}ms)"
    end

    if cues.empty?
      floor_cues = extract_floor_cues(events_doc, audio_file, livekit: livekit)
      if floor_cues.any?
        log_info "No talking cues — falling back to #{floor_cues.size} floor event interval(s)"
        cues = merge_nearby_cues(floor_cues, merge_gap_ms)
      else
        log_info "No talking cues and no floor events — treating as silent audio, skipping"
      end
    end

    chunks_dir = "/tmp/transcription_chunks_#{Process.pid}_#{SecureRandom.hex(6)}"
    FileUtils.mkdir_p(chunks_dir)

    chunks = []
    cues.each_with_index do |cue, i|
      # Pull the chunk start back by 1 second to avoid clipping the first word,
      # clamped to 0 so we never request a negative offset.
      from_ms  = [cue['from'] - 1_000, 0].max
      to_ms    = cue['to']
      out_path = File.join(chunks_dir, format('chunk_%04d.wav', i))
      path     = cut_audio_chunk(work_file, from_ms, to_ms, out_path)

      unless path
        log_info "  → ffmpeg cut failed for cue #{i + 1}, skipping"
        next
      end

      unless has_speech?(path, enabled: vad_enabled, threshold: vad_threshold,
                         min_speech_ms: vad_min_speech_ms, max_duration_ms: vad_max_duration_ms)
        log_info "  → VAD: insufficient speech in chunk #{i + 1}, skipping"
        File.delete(path)
        next
      end

      chunk = { path: path, from_ms: from_ms, to_ms: to_ms }
      chunk[:speaker_id]  = cue['speaker_id']  if cue['speaker_id']
      chunk[:speaker]     = cue['speaker']     if cue['speaker']
      chunk[:speaker_ids] = cue['speaker_ids'] if cue['speaker_ids']
      chunks << chunk
    end

    { work_file: work_file, temp_wav: temp_wav, chunks_dir: chunks_dir, chunks: chunks }
  end

  # Removes the temp chunks directory and the converted WAV file (if any).
  def self.cleanup_chunks(chunks_dir, temp_wav)
    FileUtils.rm_rf(chunks_dir) if chunks_dir && Dir.exist?(chunks_dir)
    File.delete(temp_wav) if temp_wav && File.exist?(temp_wav)
  end

  # Returns the display name of the participant who owns the given audio track,
  # or nil if no matching AudioTrackPublishedEvent/ParticipantJoinEvent pair is found.
  #
  # events_doc — a Nokogiri::XML::Document (already parsed)
  # audio_file — path or basename of the audio file
  def self.speaker_name_for_audio(events_doc, audio_file)
    audio_basename = File.basename(audio_file.to_s)
    track_user_id  = nil

    events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").each do |ev|
      if File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        track_user_id = ev.at_xpath('userId')&.text
        break
      end
    end

    return nil unless track_user_id

    events_doc.xpath("//event[@eventname='ParticipantJoinEvent']").each do |ev|
      if ev.at_xpath('userId')&.text == track_user_id
        name = ev.at_xpath('name')&.text&.strip
        return name unless name.nil? || name.empty?
      end
    end

    nil
  end

  # Returns an array of unique non-empty participant display names from all
  # ParticipantJoinEvents in the document.
  #
  # events_doc — a Nokogiri::XML::Document (already parsed)
  def self.all_speaker_names(events_doc)
    events_doc
      .xpath("//event[@eventname='ParticipantJoinEvent']")
      .filter_map { |ev| ev.at_xpath('name')&.text&.strip }
      .uniq
      .reject(&:empty?)
  end

  # ---------------------------------------------------------------------------
  # Private implementation methods
  # ---------------------------------------------------------------------------

  # SFU/LiveKit: cues from AudioTrackPublishedEvent + ParticipantTalkingEvent for
  # the specific user who owns the audio track. Timestamps from timestampUTC child
  # element (nanosecond or millisecond precision depending on BBB version — offsets
  # are computed as differences so the unit cancels out).
  def self.extract_talking_cues_livekit(events_doc, audio_file)
    audio_basename  = File.basename(audio_file)
    cues            = []
    inside_track    = false
    audio_start_utc = nil
    user_id         = nil
    cue_start_utc   = nil

    events_doc.xpath('//event').each do |ev|
      case ev['eventname']
      when 'AudioTrackPublishedEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        inside_track    = true
        audio_start_utc = ev.at_xpath('timestampUTC')&.text.to_i
        user_id         = ev.at_xpath('userId')&.text

      when 'AudioTrackUnpublishedEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        if cue_start_utc
          cues << { 'from' => cue_start_utc - audio_start_utc,
                    'to'   => ev.at_xpath('timestampUTC')&.text.to_i - audio_start_utc,
                    'speaker_id' => user_id }
          cue_start_utc = nil
        end
        inside_track = false

      when 'ParticipantTalkingEvent'
        next unless inside_track && ev.at_xpath('participant')&.text == user_id
        ts      = ev.at_xpath('timestampUTC')&.text.to_i
        talking = ev.at_xpath('talking')&.text == 'true'
        if talking
          cue_start_utc ||= ts
        elsif cue_start_utc
          cues << { 'from' => cue_start_utc - audio_start_utc, 'to' => ts - audio_start_utc,
                    'speaker_id' => user_id }
          cue_start_utc = nil
        end
      end
    end

    cues
  end

  # FreeSWITCH: per-user cues from ParticipantTalkingEvent within the
  # StartRecordingEvent/StopRecordingEvent window for the given audio file.
  # Each user is tracked independently so overlapping speakers produce separate cues.
  # Cues carry 'speaker_id' and 'speaker' (display name) when available.
  # Uses the event timestamp attribute (relative ms) for offsets.
  #
  # Floor filter: cues are dropped when the speaker has no AudioFloorChangedEvent
  def self.extract_talking_cues_freeswitch(events_doc, audio_file)
    audio_basename     = File.basename(audio_file)
    recording_start_ts = nil
    recording_end_ts   = nil

    events_doc.xpath('//event').each do |ev|
      case ev['eventname']
      when 'StartRecordingEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        recording_start_ts = ev['timestamp'].to_i
      when 'StopRecordingEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        recording_end_ts = ev['timestamp'].to_i
      end
    end

    return [] unless recording_start_ts

    # Build floor intervals [gained_ms, lost_ms] per participant (relative to recording start).
    # AudioFloorChangedEvent floor:true opens an interval; floor:false closes it.
    floor_intervals = Hash.new { |h, k| h[k] = [] }
    open_floors     = {}

    events_doc.xpath("//event[@eventname='AudioFloorChangedEvent']").each do |ev|
      participant = ev.at_xpath('participant')&.text
      next unless participant
      ts    = ev['timestamp'].to_i - recording_start_ts
      floor = ev.at_xpath('floor')&.text == 'true'
      if floor
        open_floors[participant] = ts
      elsif (gained_ts = open_floors.delete(participant))
        floor_intervals[participant] << [gained_ts, ts]
      end
    end
    recording_duration = recording_end_ts ? recording_end_ts - recording_start_ts : nil
    open_floors.each do |participant, gained_ts|
      floor_intervals[participant] << [gained_ts, recording_duration || Float::INFINITY]
    end

    # Track each user's open cue independently so simultaneous speakers don't interfere.
    open_cues    = {}                              # user_id => cue_start_ts
    speaker_cues = Hash.new { |h, k| h[k] = [] } # user_id => [cues]

    events_doc.xpath('//event').each do |ev|
      next unless ev['eventname'] == 'ParticipantTalkingEvent'

      ts = ev['timestamp'].to_i
      next if ts < recording_start_ts
      next if recording_end_ts && ts > recording_end_ts

      user_id = ev.at_xpath('participant')&.text
      talking = ev.at_xpath('talking')&.text == 'true'

      if talking
        open_cues[user_id] ||= ts
      elsif (cue_start_ts = open_cues.delete(user_id))
        cue = { 'from' => cue_start_ts - recording_start_ts,
                'to'   => ts - recording_start_ts }
        cue['speaker_id'] = user_id if user_id
        speaker_cues[user_id || :unknown] << cue
      end
    end

    # Close any cues still open at the recording boundary.
    boundary_ts = recording_end_ts || (open_cues.values.min || recording_start_ts)
    open_cues.each do |user_id, cue_start_ts|
      cue = { 'from' => cue_start_ts - recording_start_ts,
              'to'   => boundary_ts - recording_start_ts }
      cue['speaker_id'] = user_id if user_id
      speaker_cues[user_id || :unknown] << cue
    end

    if floor_intervals.any?
      before = speaker_cues.values.sum(&:size)
      speaker_cues.each_value do |cues|
        cues.select! do |cue|
          (floor_intervals[cue['speaker_id']] || []).any? do |gained, lost|
            gained <= cue['to'] && lost >= cue['from']
          end
        end
      end
      speaker_cues.reject! { |_, cues| cues.empty? }
      dropped = before - speaker_cues.values.sum(&:size)
      log_info "Floor filter: dropped #{dropped} cue(s) with no floor overlap" if dropped > 0
    end

    speaker_cues.values
  end

  # LiveKit floor fallback: one interval per AudioTrackPublished/Unpublished pair.
  def self.extract_floor_cues_livekit(events_doc, audio_file)
    audio_basename  = File.basename(audio_file)
    cues            = []
    audio_start_utc = nil
    floor_start_utc = nil

    events_doc.xpath('//event').each do |ev|
      case ev['eventname']
      when 'AudioTrackPublishedEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        audio_start_utc = ev.at_xpath('timestampUTC')&.text.to_i
        floor_start_utc = audio_start_utc

      when 'AudioTrackUnpublishedEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        if floor_start_utc && audio_start_utc
          cues << { 'from' => floor_start_utc - audio_start_utc,
                    'to'   => ev.at_xpath('timestampUTC')&.text.to_i - audio_start_utc }
          floor_start_utc = nil
        end
      end
    end

    cues
  end

  # FreeSWITCH floor fallback: single interval covering the full recording window.
  # Duration is derived from StopRecordingEvent; falls back to ffprobe if absent.
  def self.extract_floor_cues_freeswitch(events_doc, audio_file)
    audio_basename = File.basename(audio_file)
    start_ts       = nil
    stop_ts        = nil

    events_doc.xpath('//event').each do |ev|
      case ev['eventname']
      when 'StartRecordingEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        start_ts = ev['timestamp'].to_i
      when 'StopRecordingEvent'
        next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
        stop_ts = ev['timestamp'].to_i
      end
    end

    return [] unless start_ts

    duration_ms = stop_ts ? (stop_ts - start_ts) : audio_duration_ms(audio_file)
    return [] unless duration_ms && duration_ms > 0

    [{ 'from' => 0, 'to' => duration_ms }]
  end

  # Groups a flat array of cues by speaker_id so each group can be merged independently.
  def self.log_info(msg)
    if defined?($logger) && $logger
      $logger.info(msg)
      $stdout.puts "[INFO ] #{msg}"
    else
      $stderr.puts "INFO : #{msg}"
    end
  end

  private_class_method :log_info,
                       :resolve_overlapping_cues,
                       :extract_talking_cues_livekit, :extract_talking_cues_freeswitch,
                       :extract_floor_cues_livekit, :extract_floor_cues_freeswitch
end
