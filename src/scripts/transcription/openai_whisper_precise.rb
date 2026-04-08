#!/usr/bin/env ruby
# encoding: UTF-8
#
# openai_whisper_precise.rb — Strict quality filtering for noisy or low-quality audio.
#
# Scenario: noisy rooms, HVAC hum, keyboard noise, telephone audio, poor microphones.
# Aggressively rejects segments with high no-speech probability and low quality scores.
# Fewer segments overall, but each one is high-confidence. Prefer this scenario when
# Whisper tends to hallucinate words or phrases over background noise.
#
# Tuned parameters vs openai_whisper.rb defaults:
#   no_speech_threshold:     0.35  (default: 1.0 = disabled)
#   quality_score_threshold: 0.65  (default: 0.40)
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

ENV['WHISPER_NO_SPEECH_THRESHOLD']     ||= '0.35'
ENV['WHISPER_QUALITY_SCORE_THRESHOLD'] ||= '0.65'
ENV['WHISPER_TEMPERATURE']             ||= '0.0'

load File.join(__dir__, 'openai_whisper.rb')
