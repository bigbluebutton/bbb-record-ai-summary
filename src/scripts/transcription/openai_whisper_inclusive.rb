#!/usr/bin/env ruby
# encoding: UTF-8
#
# openai_whisper_inclusive.rb — Permissive quality filtering for clean or studio-quality audio.
#
# Scenario: high-quality microphones, recording studios, screencasts, or any environment
# where background noise is minimal and you want maximum segment coverage. Trusts the
# model's output more broadly, accepting segments that stricter scenarios would drop.
#
# Tuned parameters vs openai_whisper.rb defaults:
#   no_speech_threshold:     0.90  (default: 1.0 = disabled)
#   quality_score_threshold: 0.20  (default: 0.40)
#   temperature:             0.0   (same — deterministic)
#
# Any WHISPER_* or OPENAI_* environment variables set before this script are
# preserved: explicit caller values always win over these scenario defaults.
#

require 'nokogiri'
require_relative 'transcription_utils'

audio_file = ARGV[0]
events_xml = ARGV[2]

if audio_file && events_xml && File.exist?(events_xml)
  events_doc = Nokogiri::XML(File.read(events_xml))

  if ENV['WHISPER_PROMPT'].to_s.strip.empty?
    speaker_name = TranscriptionUtils.speaker_name_for_audio(events_doc, audio_file)
    if speaker_name
      $stderr.puts "INFO : Speaker: #{speaker_name}"
      ENV['WHISPER_PROMPT'] =
        "Meeting participant #{speaker_name} speaking. " \
        "This is their individual microphone audio from a meeting."
    end
  end

  if ENV['WHISPER_KNOWN_SPEAKER_NAMES'].to_s.strip.empty?
    all_names = TranscriptionUtils.all_speaker_names(events_doc)
    unless all_names.empty?
      $stderr.puts "INFO : Known speakers: #{all_names.join(', ')}"
      ENV['WHISPER_KNOWN_SPEAKER_NAMES'] = all_names.join(',')
    end
  end
end

ENV['WHISPER_NO_SPEECH_THRESHOLD']     ||= '0.90'
ENV['WHISPER_QUALITY_SCORE_THRESHOLD'] ||= '0.20'
ENV['WHISPER_TEMPERATURE']             ||= '0.0'

load File.join(__dir__, 'openai_whisper.rb')
