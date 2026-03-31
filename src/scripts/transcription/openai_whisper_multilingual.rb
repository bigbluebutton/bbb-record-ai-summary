#!/usr/bin/env ruby
# encoding: UTF-8
#
# openai_whisper_multilingual.rb — Permissive settings for code-switching or accented speech.
#
# Scenario: meetings where participants speak in more than one language, switch between
# languages mid-sentence, or have strong accents in a non-primary language. A small
# temperature increase (0.10) allows the decoder more flexibility when the pronunciation
# diverges from training-data norms. Quality thresholds are eased slightly to avoid
# dropping valid segments that score lower due to accent mismatch.
#
# Language detection is left to whatever is configured in transcription.yml (or the
# OPENAI_LANGUAGE env var). If no language is configured, Whisper auto-detects per
# chunk — which is the most robust strategy for genuinely mixed-language audio.
# To force auto-detection regardless of config, set OPENAI_LANGUAGE="" before calling.
#
# Tuned parameters vs openai_whisper.rb defaults:
#   temperature:             0.10  (default: 0.0)
#   no_speech_threshold:     0.60  (default: 1.0 = disabled)
#   quality_score_threshold: 0.30  (default: 0.40)
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

ENV['WHISPER_TEMPERATURE']             ||= '0.10'
ENV['WHISPER_NO_SPEECH_THRESHOLD']     ||= '0.60'
ENV['WHISPER_QUALITY_SCORE_THRESHOLD'] ||= '0.30'

load File.join(__dir__, 'openai_whisper.rb')
