#!/usr/bin/env ruby
# encoding: UTF-8
#
# transcription_utils.rb — Shared audio chunking utilities for transcription providers.
#
# Splits a BBB audio file into per-speech chunks using talking cues from events.xml,
# so each provider (albert_whisper, openai_whisper, …) can process them independently.
#
# Usage:
#   require_relative 'transcription_utils'
#
#   result = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml)
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
  MERGE_GAP_MS = 1_000

  # Returns audio duration in milliseconds via ffprobe, or nil on failure.
  def self.audio_duration_ms(path)
    out = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{path}" 2>/dev/null`.strip
    out.empty? ? nil : (out.to_f * 1000).round
  rescue
    nil
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

  # Scans events.xml and returns per-speech cues for the given audio file,
  # derived from ParticipantTalkingEvents bracketed by AudioTrackPublished/Unpublished.
  def self.extract_talking_cues(events_doc, audio_file)
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
                    'to'   => ev.at_xpath('timestampUTC')&.text.to_i - audio_start_utc }
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
          cues << { 'from' => cue_start_utc - audio_start_utc, 'to' => ts - audio_start_utc }
          cue_start_utc = nil
        end
      end
    end

    cues
  end

  # Returns one cue per AudioTrackPublished→Unpublished interval for the given
  # audio file. Used as a fallback when no ParticipantTalkingEvents are present.
  def self.extract_floor_cues(events_doc, audio_file)
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
  def self.prepare_audio_chunks(audio_file, events_xml, merge_gap_ms: MERGE_GAP_MS)
    work_file, temp_wav = convert_to_wav(audio_file)
    return nil if work_file.nil?

    events_doc = Nokogiri::XML(File.read(events_xml))
    raw_cues   = extract_talking_cues(events_doc, audio_file)
    cues       = merge_nearby_cues(raw_cues, merge_gap_ms)
    log_info "Talking cues: #{raw_cues.size} raw → #{cues.size} after merging (gap ≤ #{merge_gap_ms}ms)"

    if cues.empty?
      floor_cues = extract_floor_cues(events_doc, audio_file)
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
      from_ms  = cue['from']
      to_ms    = cue['to']
      out_path = File.join(chunks_dir, format('chunk_%04d.wav', i))
      path     = cut_audio_chunk(work_file, from_ms, to_ms, out_path)
      if path
        chunks << { path: path, from_ms: from_ms, to_ms: to_ms }
      else
        log_info "  → ffmpeg cut failed for cue #{i + 1}, skipping"
      end
    end

    { work_file: work_file, temp_wav: temp_wav, chunks_dir: chunks_dir, chunks: chunks }
  end

  # Removes the temp chunks directory and the converted WAV file (if any).
  def self.cleanup_chunks(chunks_dir, temp_wav)
    FileUtils.rm_rf(chunks_dir) if chunks_dir && Dir.exist?(chunks_dir)
    File.delete(temp_wav) if temp_wav && File.exist?(temp_wav)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  def self.log_info(msg)
    if defined?($logger) && $logger
      $logger.info(msg)
      $stdout.puts "[INFO ] #{msg}"
    else
      $stderr.puts "INFO : #{msg}"
    end
  end
  private_class_method :log_info
end
